// Local workspace mutation owner for fm-playbot-lanes.mjs addon-guard.
// Every Git-visible Godot project with an addons/playbot tree must hold a
// complete, app-bundle-identical addon before reset or stash; a worktree with
// no addon tree preserves nothing and keeps every other check.
// reset accepts one ref, refuses backward/divergent history and any tracked or
// untracked product changes outside the preserved trees except the caller's
// listed tracked Playbot churn, whose diff it prints before reverting. It makes a private
// temporary backup first, restores tracked/untracked/ignored files after Git,
// and retains the backup on any failure. stash accepts only --all/-a,
// --include-untracked/-u, and --message/-m; exact addon pathspec exclusions keep
// the injected trees out of the stash. Neither operation stages addon files.
// verify requires current bundle identity; check-index also refuses staged
// addon changes so injected helpers cannot enter a product commit.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function files(directory, relative = "") {
  const out = [];
  const absolute = path.join(directory, relative);
  const stat = fs.lstatSync(absolute);
  if (stat.isSymbolicLink()) throw new Error(`Addon preservation refuses symlinks: ${absolute}`);
  if (!stat.isDirectory()) throw new Error(`Addon directory unreadable: ${absolute}`);
  for (const entry of fs.readdirSync(absolute, { withFileTypes: true })) {
    const name = path.join(relative, entry.name);
    if (entry.isDirectory()) out.push(...files(directory, name));
    else if (entry.isFile()) out.push({ name, bytes: fs.readFileSync(path.join(directory, name)), mode: fs.statSync(path.join(directory, name)).mode & 0o777 });
    else throw new Error(`Addon preservation refuses special files: ${name}`);
  }
  return out;
}

function verifiedAddons(root, report) {
  if (!report.projects.length) return [];
  if (!report.bundle?.confirmed || report.errors.length) throw new Error(`Addon bundle identity is unconfirmed; start Playbot so its app bundle can be read before preservation. ${JSON.stringify({ bundle: report.bundle, errors: report.errors })}`);
  return report.projects.map((project) => {
    if (fs.lstatSync(project.addon.path).isSymbolicLink()) throw new Error("Addon preservation refuses a symlinked addon directory.");
    const directory = fs.realpathSync.native(project.addon.path);
    const relative = path.relative(root, directory);
    if (!relative || relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) throw new Error("Addon lies outside this Git worktree.");
    if (!project.addon.byteIdentical || project.addon.version !== report.bundle.version) throw new Error(`Addon is incomplete or differs from the current app bundle: ${project.addon.path}; obtain a supported Playbot update before reset/stash/validation.`);
    return { directory, relative: relative.split(path.sep).join("/") };
  });
}

function statIfPresent(file) {
  try { return fs.lstatSync(file); } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function restoreFile(directory, file, boundary) {
  const destination = path.join(directory, file.name);
  const parent = path.dirname(destination);
  // Never follow a reset-created symlink out of the owned addon tree.
  for (let current = parent; current === boundary || current.startsWith(`${boundary}${path.sep}`); current = path.dirname(current)) {
    const stat = statIfPresent(current);
    if (stat && (stat.isSymbolicLink() || !stat.isDirectory())) throw new Error(`Unsafe addon restore directory: ${current}`);
    if (current === boundary) break;
  }
  const stat = statIfPresent(destination);
  if (stat && (!stat.isFile() || stat.isSymbolicLink())) throw new Error(`Unsafe addon restore file: ${destination}`);
  fs.mkdirSync(parent, { recursive: true });
  fs.writeFileSync(destination, file.bytes, { mode: file.mode });
  fs.chmodSync(destination, file.mode);
}

export async function guardAddon({ root, report, operation, args, git, indexFlags, operations, trackedChurn, verify }) {
  const addons = verifiedAddons(root, report);
  const owned = (file) => addons.some((addon) => file.startsWith(`${addon.relative}/`));
  if (operation === "verify" || operation === "check-index") {
    if (args.length) throw new Error(`${operation} takes no arguments`);
    if (operation === "check-index") {
      const staged = git(root, ["diff", "--cached", "--name-only", "-z", "HEAD", "--"]).split("\0").filter(Boolean).filter(owned);
      if (staged.length) throw new Error(`Injected addon changes are staged for a product commit: ${staged.join(", ")}; unstage only these addon paths before committing.`);
    }
    return { operation, verified: true, addons: addons.map((addon) => addon.relative) };
  }
  if (!["reset", "stash"].includes(operation)) throw new Error("addon-guard expects verify, check-index, reset <ref>, or stash [--all|--include-untracked] [--message text]");
  let command, churn = [];
  if (operation === "reset") {
    if (args.length !== 1 || !args[0] || args[0].startsWith("-")) throw new Error("addon-guard reset requires exactly one target ref");
    const target = git(root, ["rev-parse", "--verify", `${args[0]}^{commit}`]).trim();
    git(root, ["merge-base", "--is-ancestor", "HEAD", target]);
    if (operations.length) throw new Error("Reset refuses an in-progress Git operation.");
    if (indexFlags.length) throw new Error("Reset refuses assume-unchanged or skip-worktree index flags.");
    const changed = git(root, ["diff", "HEAD", "--name-only", "-z", "--"]).split("\0").filter(Boolean);
    const untracked = git(root, ["ls-files", "--others", "--exclude-standard", "-z"]).split("\0").filter(Boolean);
    churn = changed.filter((file) => !owned(file) && trackedChurn(file));
    const outside = [...changed.filter((file) => !churn.includes(file)), ...untracked].filter((file) => !owned(file));
    const targetPaths = git(root, ["ls-tree", "-r", "--name-only", "-z", target]).split("\0").filter(Boolean);
    const ignored = git(root, ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"]).split("\0").filter(Boolean);
    outside.push(...ignored.filter((file) => !owned(file) && targetPaths.some((targetPath) => file === targetPath || file.startsWith(`${targetPath}/`) || targetPath.startsWith(`${file}/`))));
    if (outside.length) throw new Error(`Reset would risk product work outside preserved addons: ${outside.join(", ")}`);
    command = ["reset", "--hard", target];
  } else {
    for (let i = 0; i < args.length; i++) {
      if (["--all", "-a", "--include-untracked", "-u"].includes(args[i])) continue;
      if (["--message", "-m"].includes(args[i]) && typeof args[++i] === "string") continue;
      throw new Error("addon-guard stash accepts only --all, --include-untracked, and --message text");
    }
    command = ["stash", "push", ...args, "--", ".", ...addons.map((addon) => `:(exclude,literal)${addon.relative}`)];
  }
  const snapshots = addons.map((addon, index) => ({ ...addon, index, files: files(addon.directory) }));
  const backup = fs.mkdtempSync(path.join(os.tmpdir(), "fm-playbot-addon-"));
  fs.chmodSync(backup, 0o700);
  for (const addon of snapshots) for (const file of addon.files) restoreFile(path.join(backup, String(addon.index)), file, backup);
  fs.writeFileSync(path.join(backup, "manifest.json"), JSON.stringify({ root, operation, addons: snapshots.map(({ directory, index, files: inventory }) => ({ directory, index, files: inventory.map(({ name, mode }) => ({ name, mode })) })) }, null, 2));
  process.stderr.write(`Addon preservation backup: ${backup}\n`);
  if (churn.length) process.stderr.write(`Reverting listed Playbot tracked churn: ${churn.join(", ")}\n${git(root, ["diff", "HEAD", "--", ...churn.map((file) => `:(literal)${file}`)])}\n`);
  try {
    verifiedAddons(root, await verify());
    for (const addon of snapshots) for (const file of addon.files) {
      if (!file.bytes.equals(fs.readFileSync(path.join(addon.directory, file.name)))) throw new Error(`Addon changed after backup: ${file.name}`);
    }
  } catch (error) { throw new Error(`${error.message}; Git was not run; complete addon backup retained at ${backup}`); }
  let commandError;
  try { git(root, command); } catch (error) { commandError = error; }
  try {
    // Restore even if Git failed part-way; retain any extra new files rather
    // than treating addon ownership as permission to delete them.
    for (const addon of snapshots) for (const file of addon.files) restoreFile(addon.directory, file, root);
    for (const addon of snapshots) for (const file of addon.files) {
      if (!file.bytes.equals(fs.readFileSync(path.join(addon.directory, file.name)))) throw new Error(`Preserved addon byte verification failed: ${file.name}`);
    }
    verifiedAddons(root, await verify());
    if (commandError) throw commandError;
    fs.rmSync(backup, { recursive: true });
    return { operation, preserved: true, verified: true, addons: addons.map((addon) => addon.relative), ...(operation === "reset" ? { revertedChurn: churn } : {}) };
  } catch (error) { throw new Error(`${error.message}; complete addon backup retained at ${backup}`); }
}
