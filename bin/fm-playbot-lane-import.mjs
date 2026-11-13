// Operator-owned implementation of fm-playbot-lanes.mjs lane-import <JSON|->.
// Not an MCP tool: implementation workers must never invoke real Godot.
// Required JSON: project, workspace (exact ids), expectedBranch (literal short
// branch), expectedHead, base (full local ancestor SHAs), landingBranch (explicit
// local landing branch), godotProject (Git-root
// relative directory, or "."), godot (absolute executable), companions (exact
// Git-root relative .gd.uid/.import paths). mode is generate (default) or check.
// base must equal git merge-base expectedHead refs/heads/<landingBranch> and
// the sole full-SHA Guide-check-base trailer on expectedHead.
// Optional importCleanGuard="scripts/check_import_clean.py" runs the existing
// project receipt gate on the resulting committed head (no overrides).
// Run at the exact registered lane Git root; Playbot-owned branch names work.
// Linux only: fresh XDG directories and an empty ANDROID_HOME prevent the
// editor from discovering host SDK/ADB/settings. Self-contained installs are
// refused because they bypass XDG. Recovery mode disables plugins/tool scripts.
// Executes only --version, --help, and --headless --recovery-mode --import
// --path <exact-project>. Version must be 4.7.1.stable[.official.<hash>].
// generate imports, commits, then requires a clean import on the committed
// head. check imports once and requires no product change. Ignored .godot
// caches are the only exempt output. All unexpected mutations stay in place.
// A private index builds one companion-only commit; an index lock and CAS ref
// update protect existing staging. Only authorized index entries advance.
// No Git commit hooks/filters, reset, clean, stash, host settings edits, ADB
// or Playbot engine IPC.
// JSON reports source counts, resulting head, exact companions and SHA-256s.
// Failure retains private evidence/backups in the Git directory and reports its
// path; no automatic retry or destructive recovery is attempted.
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { snapshotAddonTrees } from "./fm-playbot-addon-guard.mjs";

const SHA = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const ASSET = /\.(?:png|jpe?g|svg|webp|bmp|tga|exr|hdr|dds|ktx|wav|ogg|mp3|flac|ttf|otf|woff2?|glb|gltf|fbx|obj|blend|dae|csv|po|pot)$/i;
const digest = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
const entries = (raw) => raw.split("\0").filter(Boolean);
function present(file) { return fs.lstatSync(file, { throwIfNoEntry: false }); }
function relativeFile(file) {
  if (typeof file !== "string" || !file || path.posix.normalize(file) !== file || file.startsWith("/") || file.split("/").some((part) => ["..", ".git", ".godot", ""].includes(part)) || /[\\\x00-\x1f\x7f]/.test(file)) throw new Error(`Unsafe relative path: ${JSON.stringify(file)}`);
  return file;
}
function regular(root, file) {
  const components = file.split("/");
  for (let i = 1; i <= components.length; i++) {
    const part = path.join(root, ...components.slice(0, i));
    const stat = fs.lstatSync(part);
    if (stat.isSymbolicLink() || (i === components.length ? !stat.isFile() : !stat.isDirectory())) throw new Error(`Import refuses nonregular path: ${file}`);
  }
  return fs.readFileSync(path.join(root, file));
}
function cacheDirectories(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) cacheDirectories(file);
    else if (!entry.isFile()) throw new Error(`Import refuses nonregular cache entry: ${file}`);
  }
}
function treeSnapshot(root, project, relative = "", out = new Map()) {
  for (const entry of fs.readdirSync(path.join(root, relative), { withFileTypes: true })) {
    const file = relative ? `${relative}/${entry.name}` : entry.name;
    if (entry.name === ".git") continue;
    const inProject = project === "." || file === project || file.startsWith(`${project}/`);
    const cache = project === "." ? ".godot" : `${project}/.godot`;
    if (file === cache) {
      if (!entry.isDirectory() || entry.isSymbolicLink()) throw new Error("Import refuses a symlinked/non-directory .godot cache");
      cacheDirectories(path.join(root, file));
      continue;
    }
    if (entry.isDirectory()) treeSnapshot(root, project, file, out);
    else {
      const stat = fs.lstatSync(path.join(root, file));
      if (inProject && !stat.isFile()) throw new Error(`Import refuses nonregular project entry: ${file}`);
      if (!stat.isFile() && !stat.isSymbolicLink()) throw new Error(`Import refuses special file: ${file}`);
      const bytes = stat.isSymbolicLink() ? fs.readlinkSync(path.join(root, file), { encoding: "buffer" }) : fs.readFileSync(path.join(root, file));
      out.set(file, { sha256: digest(bytes), mode: stat.mode & 0o777, symlink: stat.isSymbolicLink() });
    }
  }
  return out;
}
function changes(before, after) {
  return [...new Set([...before.keys(), ...after.keys()])].filter((file) => JSON.stringify(before.get(file)) !== JSON.stringify(after.get(file))).sort();
}
function writeJson(file, value) { fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 }); }

export function companionSources(companions, godotProject) {
  if (godotProject !== ".") relativeFile(godotProject);
  if (!Array.isArray(companions) || new Set(companions).size !== companions.length) throw new Error("Companion inventory must be a unique array");
  return companions.map((file) => {
    relativeFile(file);
    const source = file.endsWith(".gd.uid") ? file.slice(0, -4) : file.endsWith(".import") && ASSET.test(file.slice(0, -7)) ? file.slice(0, -7) : null;
    if (!source || (godotProject !== "." && !source.startsWith(`${godotProject}/`)) || /(?:^|\/)addons\/playbot(?:\/|$)/.test(source)) throw new Error(`Companion is not authorized by a script/asset: ${file}`);
    return { path: file, source };
  });
}

export async function laneImport(args, { root, git, gitEnvironment, identity, guards, addonProjects }) {
  if (!args || typeof args !== "object" || Array.isArray(args)) throw new Error("lane-import requires a JSON object");
  const allowed = ["project", "workspace", "expectedBranch", "expectedHead", "base", "landingBranch", "godotProject", "godot", "companions", "mode", "importCleanGuard"];
  if (Object.keys(args).some((key) => !allowed.includes(key))) throw new Error("Unknown lane-import argument");
  const { expectedBranch, expectedHead, base, landingBranch, godotProject, godot, companions, mode = "generate", importCleanGuard } = args;
  if (!["generate", "check"].includes(mode) || !SHA.test(expectedHead ?? "") || !SHA.test(base ?? "") || typeof expectedBranch !== "string" || !expectedBranch || expectedBranch.startsWith("refs/")) throw new Error("Require mode generate|check, literal expectedBranch, full expectedHead and base SHA");
  if (typeof godot !== "string" || !path.isAbsolute(godot) || typeof godotProject !== "string") throw new Error("Require absolute godot executable and relative godotProject directory");
  if (godotProject !== ".") relativeFile(godotProject);
  if (!Array.isArray(companions) || companions.some((file) => typeof file !== "string") || new Set(companions).size !== companions.length || (mode === "generate" && companions.length === 0)) throw new Error("Require unique exact companions (nonempty for generate)");
  companions.forEach(relativeFile);
  if (process.platform !== "linux") throw new Error("lane-import currently supports Linux workstation/server hosts only");
  if (typeof landingBranch !== "string" || !landingBranch || landingBranch.startsWith("refs/")) throw new Error("Require an explicit local landingBranch");
  if (importCleanGuard !== undefined && (importCleanGuard !== "scripts/check_import_clean.py" || godotProject !== "prototype-game")) throw new Error("Supported importCleanGuard is scripts/check_import_clean.py");
  const selected = fs.realpathSync.native(godot);
  if (!fs.statSync(selected).isFile()) throw new Error("Godot executable is not a regular file");
  for (const marker of ["_sc_", "._sc_"]) if (present(path.join(path.dirname(selected), marker))) throw new Error("Self-contained Godot bypasses isolated XDG settings; use a standalone binary");
  const executableHash = digest(fs.readFileSync(selected));
  const projectFile = godotProject === "." ? "project.godot" : `${godotProject}/project.godot`;
  const within = (file) => godotProject === "." || file.startsWith(`${godotProject}/`);
  const addonPath = (file) => /(?:^|\/)addons\/playbot(?:\/|$)/.test(file);
  const expectedRef = `refs/heads/${expectedBranch}`;
  let requiredHead = expectedHead;
  const checkIdentity = async () => {
    const observed = await identity(args);
    if (observed.branch !== expectedBranch || git(root, ["symbolic-ref", "HEAD"]).trim() !== expectedRef || git(root, ["rev-parse", "HEAD"]).trim() !== requiredHead) throw new Error("Lane branch/head differs from expectedBranch/expectedHead");
    guards();
    if (git(root, ["merge-base", requiredHead, `refs/heads/${landingBranch}`]).trim() !== base) throw new Error("base differs from merge-base HEAD with the explicit landingBranch");
    return observed;
  };
  git(root, ["check-ref-format", "--branch", expectedBranch]);
  git(root, ["check-ref-format", "--branch", landingBranch]);
  const lane = await checkIdentity();
  regular(root, projectFile);
  if (git(root, ["rev-parse", "--verify", `${base}^{commit}`]).trim() !== base) throw new Error("base is not an exact local commit");
  git(root, ["merge-base", "--is-ancestor", base, expectedHead]);
  const trailers = git(root, ["show", "-s", "--format=%(trailers:key=Guide-check-base,valueonly)", expectedHead]).trim().split(/\r?\n/).filter(Boolean);
  if (trailers.length !== 1 || trailers[0] !== base) throw new Error("expectedHead needs one full-SHA Guide-check-base trailer equal to base");
  if (base === expectedHead) throw new Error("Guide-check-base must be a strict ancestor of the task head");
  const tree = entries(git(root, ["ls-tree", "-r", "-z", expectedHead])).map((row) => {
    const [header, file] = row.split("\t");
    const [fileMode, type, object] = header.split(" ");
    return { file, mode: fileMode, type, object };
  });
  if (tree.some((entry) => within(entry.file) && !["100644", "100755"].includes(entry.mode))) throw new Error("Godot project has symlink/submodule entries");
  const cachePrefix = godotProject === "." ? ".godot/" : `${godotProject}/.godot/`;
  if (tree.some((entry) => entry.file.startsWith(cachePrefix))) throw new Error("Tracked .godot cache blocks import-clean");
  const headFiles = new Map(tree.map((entry) => [entry.file, entry]));
  if (!headFiles.has(projectFile)) throw new Error("project.godot must be tracked at expectedHead");
  const sourcePaths = entries(git(root, ["diff", "--no-ext-diff", "--no-textconv", "--name-only", "--no-renames", "--diff-filter=AM", "-z", base, expectedHead, "--"]));
  const changedSources = new Set(sourcePaths);
  for (const { path: companion, source } of companionSources(companions, godotProject)) {
    if (!changedSources.has(source) || !headFiles.has(source)) throw new Error(`Companion is not authorized by a changed branch script/asset: ${companion}`);
    regular(root, source);
  }
  const addons = snapshotAddonTrees(root, (await addonProjects()).map((project) => path.join(project, "addons/playbot")));
  const staged = entries(git(root, ["diff", "--no-ext-diff", "--no-textconv", "--cached", "--name-only", "--no-renames", "-z", "HEAD", "--"]));
  if (staged.some(addonPath)) throw new Error("Injected addon changes are staged; unstage only addon paths first");
  if (staged.some((file) => within(file) && !addonPath(file))) throw new Error("Project has staged product edits; commit them before importing expectedHead");
  const untracked = entries(git(root, ["ls-files", "--others", "--exclude-standard", "-z"]));
  if (untracked.some((file) => within(file) && !addonPath(file))) throw new Error("Project has untracked product work; preserve it outside the project before import");
  // Compare actual project bytes to HEAD without stat-cache shortcuts or filters.
  for (const entry of tree.filter((entry) => within(entry.file) && !addonPath(entry.file))) {
    const bytes = regular(root, entry.file);
    const blob = git(root, ["cat-file", "blob", entry.object], { encoding: "buffer" });
    if (!bytes.equals(blob) || (fs.statSync(path.join(root, entry.file)).mode & 0o111) !== (entry.mode === "100755" ? 0o111 : 0)) throw new Error(`Project differs from committed head (including filters/mode): ${entry.file}`);
  }
  // Ignored evidence and credentials are preserved by the complete snapshot.
  // Existing authorized sidecars are ambiguous even when Git ignores them.
  for (const file of companions) if (!headFiles.has(file) && present(path.join(root, file))) throw new Error(`Pre-existing untracked/ignored companion: ${file}`);
  const verifyGate = () => {
    if (!importCleanGuard) return;
    for (const file of [importCleanGuard, "scripts/check_guide_compliance.py", "scripts/guide_submission_checks.py"]) {
      const gateBytes = regular(root, file);
      const gateBlob = git(root, ["show", `${requiredHead}:${file}`], { encoding: "buffer" });
      if (!gateBytes.equals(gateBlob)) throw new Error(`Import-clean guard differs from the committed head: ${file}`);
    }
  };
  verifyGate();
  const before = treeSnapshot(root, godotProject);
  const gitDir = git(root, ["rev-parse", "--absolute-git-dir"]).trim();
  const indexPath = git(root, ["rev-parse", "--path-format=absolute", "--git-path", "index"]).trim();
  if (!fs.lstatSync(indexPath).isFile() || fs.lstatSync(indexPath).isSymbolicLink()) throw new Error("Import requires a regular existing Git index");
  const originalIndex = fs.readFileSync(indexPath);
  const lock = `${indexPath}.lock`;
  let lockFd = fs.openSync(lock, "wx", 0o600);
  let lockIdentity = fs.fstatSync(lockFd);
  const ownsLock = () => {
    const stat = present(lock);
    return stat && stat.dev === lockIdentity.dev && stat.ino === lockIdentity.ino;
  };
  let scratch, published = null, indexPublished = false;
  try {
    scratch = fs.mkdtempSync(path.join(gitDir, "fm-lane-import-"));
    fs.chmodSync(scratch, 0o700);
    process.stderr.write(`Lane import evidence/backups: ${scratch}\n`);
    fs.writeFileSync(path.join(scratch, "index.before"), originalIndex, { mode: 0o600 });
    for (const addon of addons) for (const file of addon.files) {
      const backup = path.join(scratch, "addons", addon.relative, file.name);
      fs.mkdirSync(path.dirname(backup), { recursive: true, mode: 0o700 });
      fs.writeFileSync(backup, file.bytes, { mode: 0o600 });
    }
    const dirty = new Set([...staged, ...entries(git(root, ["diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "--"])), ...untracked]);
    for (const file of dirty) {
      const stat = present(path.join(root, file));
      if (!stat?.isFile() || stat.isSymbolicLink()) continue;
      const backup = path.join(scratch, "prior-work", file);
      fs.mkdirSync(path.dirname(backup), { recursive: true, mode: 0o700 });
      fs.writeFileSync(backup, fs.readFileSync(path.join(root, file)), { mode: 0o600 });
    }
    writeJson(path.join(scratch, "before.json"), { args, lane, executableHash, files: Object.fromEntries(before) });
    const env = { ...gitEnvironment() };
    for (const name of Object.keys(env)) if (/^(?:ANDROID|ADB|GODOT|JAVA|JDK|LD_|DYLD_|XDG_|PYTHON)/.test(name)) delete env[name];
    // Linux Godot resolves settings from XDG and SDK/ADB from ANDROID_HOME.
    // An empty private SDK also protects the normal Android exporter, which
    // recovery mode alone does not disable. Never read/write the host settings.
    Object.assign(env, { XDG_CONFIG_HOME: path.join(scratch, "config"), XDG_DATA_HOME: path.join(scratch, "data"), XDG_CACHE_HOME: path.join(scratch, "cache"), ANDROID_HOME: path.join(scratch, "empty-sdk"), ANDROID_SDK_ROOT: path.join(scratch, "empty-sdk") });
    for (const name of ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "ANDROID_HOME"]) fs.mkdirSync(env[name], { mode: 0o700 });
    const invoke = (argv, label, timeout = 120000, command = selected) => {
      if (digest(fs.readFileSync(selected)) !== executableHash) throw new Error("Godot executable bytes changed");
      const result = spawnSync(command, argv, { cwd: root, env, encoding: "utf8", timeout, maxBuffer: 16 * 1024 * 1024 });
      fs.writeFileSync(path.join(scratch, `${label}.log`), `${result.stdout ?? ""}\n${result.stderr ?? ""}`, { mode: 0o600 });
      if (result.error || result.status !== 0) throw new Error(`Godot ${label} failed: ${result.error?.message ?? `exit ${result.status}, signal ${result.signal ?? "none"}`}`);
      if (digest(fs.readFileSync(selected)) !== executableHash) throw new Error("Godot executable bytes changed during execution");
      return result.stdout.trim();
    };
    const version = invoke(["--version"], "version", 10000);
    if (!/^4\.7\.1\.stable(?:\.official\.[0-9a-f]+)?$/.test(version)) throw new Error(`Godot version mismatch: require 4.7.1.stable, observed ${JSON.stringify(version)}`);
    const help = invoke(["--help"], "help", 10000);
    for (const flag of ["--headless", "--recovery-mode", "--import", "--path"]) if (!help.includes(flag)) throw new Error(`Godot editor does not advertise ${flag}`);
    await checkIdentity();
    const importArgs = ["--headless", "--recovery-mode", "--import", "--path", path.join(root, godotProject)];
    invoke(importArgs, "import");
    await checkIdentity();
    const first = treeSnapshot(root, godotProject);
    const mutations = changes(before, first);
    const unexpected = mutations.filter((file) => mode === "check" || !companions.includes(file));
    if (unexpected.length) throw new Error(`Unexpected import mutations preserved: ${JSON.stringify(unexpected)}`);
    const inventory = companions.map((file) => {
      const bytes = regular(root, file);
      if (file.endsWith(".gd.uid")) {
        if (!/^uid:\/\/[a-z0-9]+\n?$/.test(bytes.toString("utf8"))) throw new Error(`Malformed generated UID: ${file}`);
      } else {
        const text = bytes.toString("utf8"), source = file.slice(0, -7);
        const resource = `res://${godotProject === "." ? source : source.slice(godotProject.length + 1)}`;
        if (bytes.includes(0) || !/^\[remap\]\r?$/m.test(text) || !/^\[deps\]\r?$/m.test(text) || !/^\[params\]\r?$/m.test(text) || !text.split(/\r?\n/).includes(`source_file=${JSON.stringify(resource)}`)) throw new Error(`Malformed generated import metadata or mismatched source: ${file}`);
      }
      if ((fs.statSync(path.join(root, file)).mode & 0o111) !== 0) throw new Error(`Generated companion is executable: ${file}`);
      return { path: file, sha256: digest(bytes), changed: mutations.includes(file) };
    });
    // Complete addon and full-tree snapshots cover addon and product
    // drift even when the imported editor returned success.
    snapshotAddonTrees(root, (await addonProjects()).map((project) => path.join(project, "addons/playbot")));
    await checkIdentity();
    if (!originalIndex.equals(fs.readFileSync(indexPath))) throw new Error("Existing index changed during import; refusing commit");
    const changed = inventory.filter((entry) => entry.changed);
    if (mode === "generate" && changed.length) {
      const temporaryIndex = path.join(scratch, "commit.index");
      const indexEnv = { ...gitEnvironment(), GIT_INDEX_FILE: temporaryIndex, GIT_OPTIONAL_LOCKS: "0" };
      git(root, ["read-tree", expectedHead], { env: indexEnv });
      const records = changed.map((entry) => {
        const object = git(root, ["hash-object", "-w", "--stdin"], { input: regular(root, entry.path) }).trim();
        return `100644 ${object}\t${entry.path}\0`;
      }).join("");
      git(root, ["update-index", "-z", "--index-info"], { env: indexEnv, input: records });
      const newTree = git(root, ["write-tree"], { env: indexEnv }).trim();
      const message = `Generate Godot 4.7.1 lane companions\n\nGuide-check-base: ${base}\n`;
      const commit = git(root, ["-c", "commit.gpgSign=false", "commit-tree", newTree, "-p", expectedHead], { input: message }).trim();
      const actual = entries(git(root, ["diff-tree", "--no-commit-id", "--name-only", "-r", "-z", expectedHead, commit]));
      if (JSON.stringify(actual.sort()) !== JSON.stringify(changed.map((entry) => entry.path).sort())) throw new Error("Generated commit inventory differs from authorization");
      const nextIndex = path.join(scratch, "next.index");
      fs.writeFileSync(nextIndex, originalIndex, { mode: 0o600 });
      git(root, ["update-index", "-z", "--index-info"], { env: { ...indexEnv, GIT_INDEX_FILE: nextIndex }, input: records });
      await checkIdentity();
      if (changes(first, treeSnapshot(root, godotProject)).length || !originalIndex.equals(fs.readFileSync(indexPath))) throw new Error("Workspace/index drift before publication; refusing commit");
      if (!ownsLock()) throw new Error("Index lock ownership changed; refusing publication");
      fs.writeFileSync(lockFd, fs.readFileSync(nextIndex));
      git(root, ["update-ref", "-m", "Firstmate lane companions", expectedRef, commit, expectedHead]);
      published = commit;
      fs.renameSync(lock, indexPath);
      indexPublished = true;
      requiredHead = commit;
      fs.closeSync(lockFd);
      lockFd = null;
      lockFd = fs.openSync(lock, "wx", 0o600);
      lockIdentity = fs.fstatSync(lockFd);
    }
    const committedIndex = fs.readFileSync(indexPath);
    if (mode === "generate" || importCleanGuard) {
      if (importCleanGuard) {
        verifyGate();
        invoke(["-B", path.join(root, importCleanGuard), "--", selected, ...importArgs], "import-clean-gate", 120000, "python3");
        const receipt = JSON.parse(regular(root, "prototype-game/.godot/automation-data/guide-checks/import.json").toString("utf8"));
        if (receipt.schema !== "frogpile.import-clean.v1" || receipt.sha !== requiredHead || receipt.exit_code !== 0 || receipt.unchanged !== true) throw new Error("Import-clean gate did not certify the resulting head");
      } else invoke(importArgs, "import-clean");
      const dirty = changes(first, treeSnapshot(root, godotProject));
      if (dirty.length) throw new Error(`Import-clean failed on committed head ${requiredHead}; mutations preserved: ${JSON.stringify(dirty)}`);
    }
    await checkIdentity();
    if (!committedIndex.equals(fs.readFileSync(indexPath))) throw new Error("Index drift during committed-head import-clean check");
    const result = { option: "B", mode, ...lane, branch: expectedBranch, sourceHead: expectedHead, head: published ?? expectedHead, base, godot: { path: selected, version, sha256: executableHash }, sourceCounts: { headTracked: tree.length, changed: sourcePaths.length, authorizedCompanions: companions.length }, committedCompanions: changed.length, companions: inventory, importClean: true, importCleanGuard: importCleanGuard ?? null, ...(importCleanGuard ? { importCleanReceipt: "prototype-game/.godot/automation-data/guide-checks/import.json" } : {}), evidence: scratch };
    writeJson(path.join(scratch, "result.json"), result);
    return result;
  } catch (error) {
    if (scratch) {
      try { writeJson(path.join(scratch, "failure.json"), { error: error.message, head: published, mutations: changes(before, treeSnapshot(root, godotProject)) }); } catch { /* Retain the original error and backups even if evidence is unreadable. */ }
    }
    throw new Error(`${error.message}; all workspace mutations preserved${published ? `; branch advanced to ${published}${indexPublished ? "; inspect retained import output" : "; index recovery requires inspection"}` : "; no commit published"}${scratch ? `; evidence/backups: ${scratch}` : ""}`);
  } finally {
    const owned = lockFd !== null && ownsLock();
    if (lockFd !== null) fs.closeSync(lockFd);
    // On a ref-publication/index-publication gap retain the prepared index.lock
    // and original backup for explicit recovery instead of clearing evidence.
    if (owned && (!published || indexPublished)) {
      fs.unlinkSync(lock);
    }
  }
}
