// Read-only Godot evidence for fm-playbot-lanes.mjs; never executes app code,
// launchers, or engine commands. The caller owns IPC and workspace selection.
// PLAYBOT_LANES_APP_RESOURCES can name a packaged app's resources directory on
// any platform. Linux otherwise discovers it from running Playbot executables.
// Bundle identity must match app:metadata before its bytes become authoritative.
import fs from "node:fs";
import path from "node:path";

function regularFileBytes(file) {
  if (!fs.statSync(file).isFile()) throw new Error(`Not a regular file: ${file}`);
  return fs.readFileSync(file);
}

function packageVersion(resources) {
  const archive = path.join(resources, "app.asar");
  if (!fs.existsSync(archive)) {
    return JSON.parse(regularFileBytes(path.join(resources, "app/package.json")).toString("utf8")).version;
  }
  if (!fs.statSync(archive).isFile()) throw new Error("app.asar is not a regular file");
  const fd = fs.openSync(archive, "r");
  try {
    const prefix = Buffer.alloc(16);
    if (fs.readSync(fd, prefix, 0, 16, 0) !== 16) throw new Error("truncated asar header");
    const headerSize = prefix.readUInt32LE(4), jsonSize = prefix.readUInt32LE(12);
    if (jsonSize > 32 * 1024 * 1024 || headerSize < jsonSize + 8) throw new Error("invalid asar header");
    const header = Buffer.alloc(jsonSize);
    if (fs.readSync(fd, header, 0, jsonSize, 16) !== jsonSize) throw new Error("truncated asar index");
    const entry = JSON.parse(header.toString("utf8")).files?.["package.json"];
    const offset = Number(entry?.offset), size = Number(entry?.size);
    if (entry?.unpacked || !Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(size) || size <= 0 || size > 1024 * 1024) throw new Error("package.json unavailable in asar");
    const bytes = Buffer.alloc(size);
    if (fs.readSync(fd, bytes, 0, size, 8 + headerSize + offset) !== size) throw new Error("truncated package.json");
    return JSON.parse(bytes.toString("utf8")).version;
  } finally {
    fs.closeSync(fd);
  }
}

export function engineBundle(appVersion) {
  const candidates = new Set(), errors = [];
  if (process.env.PLAYBOT_LANES_APP_RESOURCES) {
    candidates.add(path.resolve(process.env.PLAYBOT_LANES_APP_RESOURCES));
  } else if (process.platform === "linux") {
    let processes = [];
    try { processes = fs.readdirSync("/proc"); } catch (error) { errors.push({ source: "/proc", message: error.message }); }
    for (const name of processes) {
      if (!/^\d+$/.test(name)) continue;
      try {
        const executable = fs.readlinkSync(`/proc/${name}/exe`);
        if (/^playbot$/i.test(path.basename(executable))) candidates.add(path.join(path.dirname(executable), "resources"));
      } catch { /* Other processes need not be readable. */ }
    }
  }
  const found = [];
  for (const resources of candidates) {
    try {
      const version = packageVersion(resources);
      if (!appVersion || version !== appVersion) throw new Error(`bundle app version ${version} differs from observed app ${appVersion ?? "unconfirmed"}`);
      const addonPath = path.join(resources, "app.asar.unpacked/electron/backend/godot-plugin/addons/playbot");
      const versionText = addonVersion(addonPath);
      if (!versionText) throw new Error("bundled addon version unreadable");
      found.push({ resources, appVersion: version, path: addonPath, version: versionText });
    } catch (error) {
      errors.push({ resources, message: error.message });
    }
  }
  return found.length === 1 ? { ...found[0], confirmed: true } : {
    confirmed: false, path: null, version: null, errors,
    reason: found.length > 1 ? "multiple matching app bundles" : "app bundle unreadable or undiscovered",
  };
}

function addonVersion(directory) {
  return /^\s*version\s*=\s*"([^"\r\n]+)"\s*$/m.exec(regularFileBytes(path.join(directory, "plugin.cfg")).toString("utf8"))?.[1] ?? null;
}

function bundledFiles(directory, relative = "") {
  const files = [];
  for (const entry of fs.readdirSync(path.join(directory, relative), { withFileTypes: true })) {
    const file = path.join(relative, entry.name);
    if (entry.isDirectory()) files.push(...bundledFiles(directory, file));
    else if (entry.isFile()) files.push(file);
    else throw new Error(`unsupported bundled file type: ${file}`);
  }
  return files.sort();
}

function inspectAddon(projectPath, bundle) {
  const directory = path.join(projectPath, "addons/playbot");
  const result = { path: directory, version: null, byteIdentical: null, missingFiles: [], differingFiles: [], unreadableFiles: [] };
  try { result.version = addonVersion(directory); } catch { /* File inventory below reports the exact absence. */ }
  if (!bundle.confirmed) return result;
  try {
    const files = bundledFiles(bundle.path);
    if (files.length === 0) throw new Error("bundled addon is empty");
    for (const file of files) {
      let actual;
      try { actual = regularFileBytes(path.join(directory, file)); } catch (error) {
        (error.code === "ENOENT" ? result.missingFiles : result.unreadableFiles).push(file);
        continue;
      }
      if (!actual.equals(fs.readFileSync(path.join(bundle.path, file)))) result.differingFiles.push(file);
    }
    result.byteIdentical = result.unreadableFiles.length ? null : result.missingFiles.length === 0 && result.differingFiles.length === 0;
  } catch (error) {
    result.unreadableFiles.push(`bundle: ${error.message}`);
  }
  return result;
}

function liveHeadlessExecutable(instance, projectPath) {
  if (process.platform !== "linux" || !Number.isSafeInteger(instance?.pid) || instance.pid <= 0) return null;
  try {
    const executable = fs.readlinkSync(`/proc/${instance.pid}/exe`);
    if (!/^godot(?:[-_.]|$)/i.test(path.basename(executable))) return null;
    const args = fs.readFileSync(`/proc/${instance.pid}/cmdline`).toString("utf8").split("\0").filter(Boolean);
    if (!args.includes("--headless")) return null;
    const pathIndex = args.indexOf("--path");
    const launchedPath = pathIndex >= 0 ? args[pathIndex + 1] : args.find((arg) => arg.startsWith("--path="))?.slice(7);
    if (!launchedPath || fs.realpathSync.native(launchedPath) !== fs.realpathSync.native(projectPath)) return null;
    return executable;
  } catch { return null; }
}

function inspectExecutable(instance, projectPath) {
  const result = { path: null, canonicalPath: null, source: null, kind: "unconfirmed" };
  // A configured editor or PATH candidate is not a selection: Playbot checks
  // executable version compatibility before choosing it. Use the existing
  // headless launch log or a live process bound to this exact project; never
  // run --version. The bounded launch log may be gone after a long import.
  if (instance?.type !== "headless") return result;
  const paths = (Array.isArray(instance.processLogs) ? instance.processLogs : [])
    .filter((line) => typeof line === "string" && line.startsWith("[Headless] Godot path: "))
    .map((line) => line.slice("[Headless] Godot path: ".length));
  const observedProcess = liveHeadlessExecutable(instance, projectPath);
  const selected = observedProcess ?? paths.at(-1);
  if (!selected || !path.isAbsolute(selected)) return result;
  result.path = selected;
  result.source = observedProcess ? "live-headless-process" : "existing-headless-launch-log";
  try {
    result.canonicalPath = fs.realpathSync.native(selected);
    if (!fs.statSync(selected).isFile()) throw new Error("selected executable is not a regular file");
    const fd = fs.openSync(selected, "r");
    const bytes = Buffer.alloc(64 * 1024);
    let size;
    try { size = fs.readSync(fd, bytes, 0, bytes.length, 0); } finally { fs.closeSync(fd); }
    const head = bytes.subarray(0, size);
    if (["flatpak", "flatpak-spawn", "bwrap", "unshare", "firejail"].includes(path.basename(result.canonicalPath))) result.kind = "namespace-launcher";
    else if (head.subarray(0, 4).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46]))) result.kind = "native-binary";
    else if (head.subarray(0, 2).toString() === "MZ" || ["feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe"].includes(head.subarray(0, 4).toString("hex"))) result.kind = "native-binary";
    else if (head.subarray(0, 2).toString() === "#!") {
      result.kind = /(?:^|\n)\s*(?:exec\s+)?(?:[\w/.-]*\/)?(?:flatpak|bwrap|unshare|firejail)\s/m.test(head.toString("utf8")) ? "namespace-launcher" : "unconfirmed-script";
    }
  } catch (error) { result.error = error.message; }
  return result;
}

const VERDICT_ORDER = ["missing-addon-files", "addon-drift", "identity-admission-rejected", "identity-admission-risk", "engine-failure", "startup-pending", "unconfirmed"];
function verdict(reasons) {
  return VERDICT_ORDER.find((candidate) => reasons.some((reason) => reason.verdict === candidate)) ?? "ready";
}

export function inspectEngineProject(project, bundle) {
  const reasons = [];
  const add = (value, code, message) => reasons.push({ verdict: value, code, message });
  const storedPath = project.projectPath;
  let canonicalPath = null;
  try { canonicalPath = fs.realpathSync.native(storedPath); } catch (error) { add("unconfirmed", "project-unreadable", error.message); }
  if (canonicalPath && path.resolve(storedPath) !== canonicalPath) add("identity-admission-risk", "project-path-alias", "Stored and canonical project paths differ; Playbot can bind a different engine identity.");
  const addon = inspectAddon(storedPath, bundle);
  if (!bundle.confirmed) add("unconfirmed", "bundle-unconfirmed", bundle.reason);
  if (addon.missingFiles.length) add("missing-addon-files", "missing-addon-files", "Required bundled addon files are missing.");
  if (addon.differingFiles.length || (bundle.confirmed && addon.version && addon.version !== bundle.version)) add("addon-drift", "addon-drift", "Workspace addon differs from the app bundle.");
  if (!addon.version || addon.unreadableFiles.length) add("unconfirmed", "addon-unreadable", "Addon version or complete file inventory could not be read.");
  const snapshot = project.snapshot;
  const routed = Array.isArray(snapshot?.instances) && typeof snapshot.routedInstanceId === "string"
    ? snapshot.instances.filter((candidate) => candidate?.id === snapshot.routedInstanceId) : [];
  const instance = routed.length === 1 ? routed[0] : null;
  if (snapshot?.connectionBlocked === true) add("identity-admission-risk", "connection-blocked", "Playbot reports project connection blocked; the rejection cause is unconfirmed.");
  else if (snapshot?.connectionBlocked !== false) add("unconfirmed", "connection-unconfirmed", "Project connection admission state is unreadable.");
  if (!instance) add("unconfirmed", "session-unconfirmed", "No existing routed engine session was observed; no session was started.");
  else {
    if (instance.pluginStatus === "outdated" || (instance.pluginVersion && instance.pluginVersion !== bundle.version)) add("addon-drift", "loaded-addon-drift", "The existing session reports an outdated or different loaded addon.");
    if (instance.lifecycleStatus === "starting" || instance.lifecycleStatus === "connecting") add("startup-pending", "startup-pending", "Existing headless engine startup is still pending.");
    if (instance.failure) {
      // A generic connection timeout does not prove PID admission rejection.
      // Reserve this verdict for an explicit structured rejection code.
      const rejected = ["registration-rejected", "identity-rejected", "admission-rejected", "process-id-mismatch"].includes(instance.failure.code);
      add(rejected ? "identity-admission-rejected" : "engine-failure", rejected ? "registration-rejected" : "engine-failure", instance.failure.message ?? "Existing engine reports a failure.");
    }
    if (!["idle-edit", "idle-play", "busy"].includes(instance.status) || instance.type !== "headless" || instance.lifecycleStatus !== "connected" || snapshot.preferredInstanceType !== "headless" || instance.pluginStatus !== "up_to_date" || instance.pluginVersion !== bundle.version) add("unconfirmed", "session-unconfirmed", "A connected session with the bundled loaded addon is not confirmed.");
  }
  const selectedExecutable = inspectExecutable(instance, storedPath);
  if (selectedExecutable.kind === "namespace-launcher") add("identity-admission-risk", "namespace-launcher", "The observed launcher uses a process namespace; Playbot's host process-number admission can reject it.");
  else if (selectedExecutable.kind !== "native-binary") add("unconfirmed", "executable-unconfirmed", "The selected executable and its launcher identity cannot be confirmed without starting a process.");
  const session = instance ? {
    id: instance.id, type: instance.type, status: instance.status,
    lifecycleStatus: instance.lifecycleStatus ?? null,
    pluginStatus: instance.pluginStatus ?? null, pluginVersion: instance.pluginVersion ?? null,
    startupActivity: instance.startupActivity ?? null, statusMessage: instance.statusMessage ?? null,
    failure: instance.failure ?? null,
  } : null;
  return { storedPath, canonicalPath, normalizedProjectPath: project.normalizedProjectPath ?? null, engineKind: project.engineKind, addon, selectedExecutable, session, verdict: verdict(reasons), reasons };
}

export function engineReadinessReport(app, bundle, workspace, projects, errors) {
  const reports = projects.map((project) => inspectEngineProject(project, bundle));
  const reasons = reports.flatMap((project) => project.reasons);
  if (reports.length === 0 || errors.length) reasons.push({ verdict: "unconfirmed", code: "discovery-unconfirmed", message: "Complete Godot project discovery is not confirmed." });
  return { app, bundle, workspaceId: workspace.id, observedAt: new Date().toISOString(), verdict: verdict(reasons), ready: reasons.length === 0, projects: reports, reasons, errors };
}

export function addonPreservationReport(app, bundle, projectPaths, errors) {
  return { app, bundle, projects: projectPaths.map((projectPath) => ({ projectPath, addon: inspectAddon(projectPath, bundle) })), errors };
}
