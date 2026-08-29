#!/usr/bin/env node
// Playbot chat lanes controllable from a Playbot controller chat or a normal
// terminal. A caller with a fresh PreToolUse marker is a Playbot chat that
// must belong to the configured controller project to operate across
// projects; it gets durable lanes with routed Stop-hook wake delivery. A
// caller without one is an external terminal that dispatches without a lane
// and supervises by polling.
//
// This executable has seven entry points:
//   serve             Run the stdio MCP server.
//   install           Register the MCP server and inert global Playbot hooks.
//   hook-pretool      Capture the exact Codex session invoking one MCP tool.
//   hook-stop         Wake a routed controller after a worker turn completes.
//   supervision-poll  Report one dispatched worker's persisted state as the
//                     firstmate watcher check that dispatch armed for it.
//   setup             Install, reload, and verify the complete integration.
//   doctor            Print bounded local integration diagnostics.
//
// The server talks to Playbot through its local Electron DevTools socket and
// invokes Playbot's own IPC handlers: threads:launch for chat and workspace
// creation on Playbot 0.94.0 and newer, with a detected fallback to the
// pre-0.94 threads:openThread and workspace:create channels, plus the
// unchanged threads:send and threads:archiveThread channels, whose send response
// is the thread snapshot that says whether Playbot delivered the message or is
// only holding it. On Playbot 0.95.x an explicit forced send promotes that exact
// held message through threads:steerMessage into the active turn without
// interrupting it. Guarded workspace retirement uses Playbot's own
// workspace:delete channel only after a fresh remote, Git, and thread-state
// inspection, then verifies every Playbot, filesystem, and Git-worktree removal.
// It reads
// Playbot's SQLite state only for discovery, exact session-to-chat identity,
// and completed-turn deduplication. It never writes either Playbot database
// directly.
//
// The question-card and pending-queue tools use four more of Playbot's own
// channels - app:metadata, threads:getSnapshot, threads:respondToUserInput, and
// threads:recallMessage - and every one of them is INTERNAL Playbot IPC rather
// than a published API, verified against the versions VERIFIED_PLAYBOT_VERSIONS
// names. A renamed channel or a changed snapshot shape refuses and names what is
// missing instead of guessing. Reading a snapshot RESUMES a chat that has not
// been resumed since Playbot started, exactly as opening it in the Playbot
// window does, and starts no agent turn; list_parked_threads is the persisted,
// non-resuming detector that keeps that cost off the fleet-wide poll.
//
// Durable private state defaults to ~/.playbot/mcp/project-chat. Routes are one
// file each so independent Stop hooks do not contend on one shared JSON blob.
// A global hook is silent unless a route names the stopping chat as its worker.
//
// Requires Node.js 22.5 or newer for node:sqlite.

import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { DatabaseSync } from "node:sqlite";

const SERVER_NAME = "playbot_lanes";
const SERVER_VERSION = "0.5.0";
const MCP_SCHEMA_VERSION = SERVER_VERSION;
const CALLER_MAX_AGE_MS = 15_000;
const WAKE_PREFIX = "[PLAYBOT_LANE_WAKE v1]";

// This exact list is the one allowance shared by retirement inventory and
// retirement itself. Playbot's Godot editor integration rewrites these eight
// tracked paths across unrelated worktrees. No directory prefix, extension,
// basename, or untracked file is inferred to be churn.
const PLAYBOT_TRACKED_CHURN_PATHS = Object.freeze([
  "prototype-game/addons/playbot/playbot_common.gd.uid",
  "prototype-game/addons/playbot/playbot_export_plugin.gd",
  "prototype-game/addons/playbot/playbot_export_plugin.gd.uid",
  "prototype-game/addons/playbot/playbot_log_capture.gd.source",
  "prototype-game/addons/playbot/playbot_runtime_bridge.gd.uid",
  "prototype-game/addons/playbot/playbot_runtime_debugger.gd.uid",
  "prototype-game/addons/playbot/plugin.gd.uid",
  "prototype-game/project.godot",
]);
const PLAYBOT_TRACKED_CHURN_SET = new Set(PLAYBOT_TRACKED_CHURN_PATHS);

function desktopDir() {
  if (process.env.PLAYBOT_DESKTOP_DIR) return path.resolve(process.env.PLAYBOT_DESKTOP_DIR);
  if (process.platform === "win32") return path.join(process.env.APPDATA ?? "", "@playbot", "desktop");
  if (process.platform === "darwin") return path.join(os.homedir(), "Library", "Application Support", "@playbot", "desktop");
  return path.join(os.homedir(), ".config", "@playbot", "desktop");
}

function harnessDir() {
  return path.resolve(process.env.PLAYBOT_HARNESS_HOME ?? path.join(os.homedir(), ".playbot", "harness"));
}

function stateDir() {
  return path.resolve(process.env.PLAYBOT_LANES_STATE_DIR ?? path.join(os.homedir(), ".playbot", "mcp", "project-chat"));
}

function controllerRoot() {
  return canonicalPath(process.env.PLAYBOT_LANES_CONTROLLER_ROOT ?? process.cwd());
}

function appDbPath() {
  return path.join(desktopDir(), "playbot.db");
}

function codexDbPath() {
  return path.join(harnessDir(), "state_5.sqlite");
}

function routesDir() {
  return path.join(stateDir(), "routes");
}

function callersDir() {
  return path.join(stateDir(), "callers");
}

function ensurePrivateDirs() {
  fs.mkdirSync(routesDir(), { recursive: true });
  fs.mkdirSync(callersDir(), { recursive: true });
}

function canonicalPath(value) {
  if (!value) return "";
  let result = path.resolve(String(value).replace(/^\\\\\?\\/, ""));
  try {
    result = fs.realpathSync.native(result);
  } catch {
    // Missing worktrees remain selectable by their persisted absolute path.
  }
  result = result.replace(/[\\/]+$/, "");
  return process.platform === "win32" ? result.toLowerCase() : result;
}

function nowIso() {
  return new Date().toISOString();
}

function safeId(value) {
  return String(value).replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 180);
}

function atomicWriteJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
  fs.rmSync(file, { force: true });
  fs.renameSync(tmp, file);
}

function readJson(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

const ROUTE_LOCK_WAIT = new Int32Array(new SharedArrayBuffer(4));
const ROUTE_LOCK_INCOMPLETE_MS = 2_000;

function processStartIdentity(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return null;
  if (process.platform === "linux") {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      const fields = stat.slice(stat.lastIndexOf(") ") + 2).trim().split(/\s+/);
      const started = fields[19];
      const boot = fs.readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
      return started && boot ? `linux:${boot}:${started}` : null;
    } catch {
      return null;
    }
  }
  if (process.platform !== "win32") {
    const result = spawnSync("ps", ["-o", "lstart=", "-p", String(pid)], { encoding: "utf8", timeout: 1_000 });
    const started = result.status === 0 ? String(result.stdout ?? "").trim() : "";
    return started ? `${process.platform}:${started}` : null;
  }
  const command = `(Get-Process -Id ${pid} -ErrorAction Stop).StartTime.ToUniversalTime().Ticks`;
  const result = spawnSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", command], { encoding: "utf8", timeout: 3_000, windowsHide: true });
  const started = result.status === 0 ? String(result.stdout ?? "").trim() : "";
  return /^\d+$/.test(started) ? `win32:${started}` : null;
}

const ROUTE_PROCESS_START_IDENTITY = processStartIdentity(process.pid);

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    if (error?.code === "EPERM") return true;
    throw error;
  }
}

function routeLockOwnerName(owner) {
  const identity = Buffer.from(owner.identity ?? "unavailable", "utf8").toString("base64url");
  return `owner-${owner.pid}-${identity}-${owner.token}.json`;
}

function parseRouteLockOwner(name) {
  const match = String(name).match(/^owner-([1-9]\d*)-([A-Za-z0-9_-]+)-([0-9a-f]{32})\.json$/);
  if (!match) return null;
  const pid = Number(match[1]);
  if (!Number.isSafeInteger(pid)) return null;
  const encodedIdentity = Buffer.from(match[2], "base64url").toString("utf8");
  return { pid, identity: encodedIdentity === "unavailable" ? null : encodedIdentity, token: match[3], name };
}

function fsyncDirectory(directory) {
  if (process.platform === "win32") return;
  const descriptor = fs.openSync(directory, "r");
  try {
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}

function createRouteLock(lock) {
  const owner = {
    pid: process.pid,
    identity: ROUTE_PROCESS_START_IDENTITY,
    token: crypto.randomBytes(16).toString("hex"),
  };
  owner.name = routeLockOwnerName(owner);
  const pendingPath = `${lock}.pending-${owner.token}`;
  let descriptor = null;
  try {
    descriptor = fs.openSync(pendingPath, "wx", 0o600);
    fs.writeSync(descriptor, `${JSON.stringify({ pid: owner.pid, identity: owner.identity, token: owner.token })}\n`, null, "utf8");
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = null;
    fs.linkSync(pendingPath, lock);
    fs.unlinkSync(pendingPath);
    fsyncDirectory(path.dirname(lock));
    return { ...owner, lock };
  } catch (error) {
    if (descriptor !== null) fs.closeSync(descriptor);
    try {
      fs.unlinkSync(pendingPath);
    } catch (unlinkError) {
      if (unlinkError?.code !== "ENOENT") throw unlinkError;
    }
    throw error;
  }
}

function parseRouteLockRecord(raw) {
  const legacy = raw.match(/^([1-9]\d*)\s*$/);
  if (legacy) return { pid: Number(legacy[1]), identity: null, token: null, legacy: true };
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!Number.isSafeInteger(parsed?.pid) || parsed.pid <= 0
    || (parsed.identity !== null && typeof parsed.identity !== "string")
    || !/^[0-9a-f]{32}$/.test(parsed?.token)) return null;
  return { pid: parsed.pid, identity: parsed.identity, token: parsed.token, legacy: false };
}

function recoverRouteLock(lock) {
  let stat;
  try {
    stat = fs.lstatSync(lock);
  } catch (error) {
    if (error?.code === "ENOENT") return true;
    throw error;
  }
  if (!stat.isDirectory()) {
    const raw = fs.readFileSync(lock, "utf8");
    const owner = parseRouteLockRecord(raw);
    if (!owner) throw new Error(`Durable lane route lock is unreadable: ${lock}`);
    if (processIsAlive(owner.pid)) {
      if (owner.legacy) return false;
      const identity = processStartIdentity(owner.pid);
      if (!owner.identity || !identity || identity === owner.identity) return false;
    }
    if (fs.readFileSync(lock, "utf8") !== raw) return false;
    fs.unlinkSync(lock);
    return true;
  }
  const entries = fs.readdirSync(lock).sort();
  if (entries.length === 0) {
    if (Date.now() - stat.mtimeMs < ROUTE_LOCK_INCOMPLETE_MS) return false;
    try {
      fs.rmdirSync(lock);
      return true;
    } catch (error) {
      if (error?.code === "ENOENT") return true;
      if (error?.code === "ENOTEMPTY") return false;
      throw error;
    }
  }
  if (entries.length !== 1) throw new Error(`Durable lane route lock has ambiguous ownership: ${lock}`);
  const owner = parseRouteLockOwner(entries[0]);
  if (!owner) throw new Error(`Durable lane route lock has unreadable ownership: ${lock}`);
  if (processIsAlive(owner.pid)) {
    const identity = processStartIdentity(owner.pid);
    if (!owner.identity || !identity || identity === owner.identity) return false;
  }
  if (fs.readdirSync(lock).join("\n") !== owner.name) return false;
  fs.unlinkSync(path.join(lock, owner.name));
  try {
    fs.rmdirSync(lock);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return true;
    if (error?.code === "ENOTEMPTY") return false;
    throw error;
  }
}

function releaseRouteLock(owner) {
  let raw;
  try {
    raw = fs.readFileSync(owner.lock, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") throw new Error(`Durable lane route lock ownership disappeared before release: ${owner.lock}`);
    throw error;
  }
  const current = parseRouteLockRecord(raw);
  if (!current
    || current.pid !== owner.pid
    || current.identity !== owner.identity
    || current.token !== owner.token) {
    throw new Error(`Durable lane route lock ownership changed before release: ${owner.lock}`);
  }
  fs.unlinkSync(owner.lock);
}

function withRoutesLock(action) {
  ensurePrivateDirs();
  const lock = path.join(stateDir(), ".routes-write.lock");
  const deadline = Date.now() + 10_000;
  let owner = null;
  while (owner === null) {
    try {
      owner = createRouteLock(lock);
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      if (recoverRouteLock(lock)) continue;
      if (Date.now() >= deadline) throw new Error(`Timed out waiting for durable lane route writes at ${lock}`);
      Atomics.wait(ROUTE_LOCK_WAIT, 0, 0, 20);
    }
  }
  try {
    return action();
  } finally {
    releaseRouteLock(owner);
  }
}

function updateRouteFile(file, allowMissing, update) {
  return withRoutesLock(() => {
    const current = readJson(file);
    if (!current && !allowMissing) throw new Error(`Lane route is missing or unreadable: ${path.basename(file)}`);
    const next = update(current);
    if (next) atomicWriteJson(file, next);
    return next ?? current;
  });
}

function openDb(file) {
  if (!fs.existsSync(file)) throw new Error(`Playbot database not found: ${file}`);
  return new DatabaseSync(file, { readOnly: true });
}

function queryAll(db, sql, params = []) {
  return db.prepare(sql).all(...params);
}

function queryOne(db, sql, params = []) {
  return db.prepare(sql).get(...params) ?? null;
}

function threadRows() {
  const db = openDb(appDbPath());
  try {
    return queryAll(db, `
      SELECT
        t.id AS thread_id,
        t.title,
        t.workspace_id,
        t.session_id,
        t.agent_status,
        t.pending_queue_json,
        t.has_unread,
        t.is_active,
        t.archived,
        t.approval_mode,
        t.plan_mode,
        t.last_user_activity_at,
        t.created_at,
        t.updated_at,
        w.project_id,
        w.name AS workspace_name,
        w.kind AS workspace_kind,
        w.is_selected AS workspace_selected,
        w.archive_state,
        p.name AS project_name
      FROM workspace_threads t
      JOIN workspaces w ON w.id = t.workspace_id
      JOIN projects p ON p.id = w.project_id
      ORDER BY t.updated_at DESC, t.position ASC
    `);
  } finally {
    db.close();
  }
}

function topology() {
  const db = openDb(appDbPath());
  try {
    const projects = queryAll(db, `
      SELECT id, name, default_working_root_id, deletion_state, created_at, updated_at
      FROM projects
      WHERE deletion_state = 'active'
      ORDER BY updated_at DESC
    `);
    const roots = queryAll(db, `
      SELECT
        pr.id AS project_root_id,
        pr.project_id,
        pr.position,
        r.id AS repository_id,
        r.name AS repository_name,
        r.path AS repository_path,
        r.default_branch
      FROM project_roots pr
      JOIN repositories r ON r.id = pr.repository_id
      ORDER BY pr.position ASC
    `);
    const workspaces = queryAll(db, `
      SELECT id, project_id, name, kind, is_selected, archive_state, created_at, updated_at
      FROM workspaces
      ORDER BY updated_at DESC
    `);
    const workspaceRoots = queryAll(db, `
      SELECT workspace_id, project_root_id, path, branch
      FROM workspace_roots
    `);
    return projects.map((project) => ({
      id: project.id,
      name: project.name,
      defaultWorkingRootId: project.default_working_root_id,
      roots: roots.filter((root) => root.project_id === project.id).map((root) => ({
        id: root.project_root_id,
        repositoryId: root.repository_id,
        repository: root.repository_name,
        path: root.repository_path,
        defaultBranch: root.default_branch,
      })),
      workspaces: workspaces.filter((workspace) => workspace.project_id === project.id).map((workspace) => ({
        id: workspace.id,
        name: workspace.name || (workspace.kind === "local" ? "Main" : workspace.id),
        kind: workspace.kind,
        selected: Boolean(workspace.is_selected),
        archiveState: workspace.archive_state,
        roots: workspaceRoots.filter((root) => root.workspace_id === workspace.id).map((root) => ({
          projectRootId: root.project_root_id,
          path: root.path,
          branch: root.branch,
        })),
      })),
    }));
  } finally {
    db.close();
  }
}

function projectPaths(project) {
  return new Set([
    ...project.roots.map((root) => canonicalPath(root.path)),
    ...project.workspaces.flatMap((workspace) => workspace.roots.map((root) => canonicalPath(root.path))),
  ].filter(Boolean));
}

function resolveProject(selector, projects = topology()) {
  if (!selector) throw new Error("project is required; use list_projects to choose an exact id, path, or unique name");
  const raw = String(selector).trim();
  const byId = projects.filter((project) => project.id === raw);
  if (byId.length === 1) return byId[0];
  const normalized = canonicalPath(raw);
  const byPath = projects.filter((project) => projectPaths(project).has(normalized));
  if (byPath.length === 1) return byPath[0];
  const byName = projects.filter((project) => project.name.toLowerCase() === raw.toLowerCase());
  if (byName.length === 1) return byName[0];
  if (byName.length > 1 || byPath.length > 1) {
    const matches = [...new Set([...byName, ...byPath].map((project) => `${project.id} (${[...projectPaths(project)][0] ?? "no path"})`))];
    throw new Error(`Ambiguous Playbot project '${raw}': ${matches.join(", ")}`);
  }
  throw new Error(`Playbot project not found: ${raw}`);
}

function resolveWorkspace(project, selector) {
  const active = project.workspaces.filter((workspace) => workspace.archiveState === "active");
  if (selector) {
    const raw = String(selector).trim();
    const normalized = canonicalPath(raw);
    const matches = active.filter((workspace) => workspace.id === raw
      || workspace.name.toLowerCase() === raw.toLowerCase()
      || workspace.roots.some((root) => canonicalPath(root.path) === normalized));
    if (matches.length === 1) return matches[0];
    if (matches.length > 1) throw new Error(`Ambiguous workspace '${raw}' in ${project.id}`);
    throw new Error(`Workspace not found in ${project.id}: ${raw}`);
  }
  if (active.length === 1) return active[0];
  const selected = active.filter((workspace) => workspace.selected);
  if (selected.length === 1) return selected[0];
  throw new Error(`Project ${project.id} has multiple active workspaces; provide workspace id or path`);
}

function resolveRetirementWorkspace(project, workspaceId) {
  const workspace = project.workspaces.find((candidate) => (
    candidate.archiveState === "active" && candidate.id === workspaceId
  ));
  if (workspace) return workspace;
  throw new Error(`retire_workspace requires an exact active workspace id returned by list_retirable_workspaces; no active workspace id matches '${workspaceId}'`);
}

function gitEnvironment() {
  const env = { ...process.env };
  const overrides = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
    "GIT_SHALLOW_FILE",
    "GIT_REPLACE_REF_BASE",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
  ];
  for (const name of overrides) delete env[name];
  for (const name of Object.keys(env)) {
    if (/^GIT_CONFIG_(?:KEY|VALUE)_\d+$/.test(name)) delete env[name];
  }
  return {
    ...env,
    GIT_GRAFT_FILE: process.platform === "win32" ? "NUL" : "/dev/null",
    GIT_NO_REPLACE_OBJECTS: "1",
    GIT_TERMINAL_PROMPT: "0",
  };
}

function git(root, args, options = {}) {
  const encoding = options.encoding ?? "utf8";
  const result = spawnSync("git", ["-C", root, ...args], {
    encoding,
    env: gitEnvironment(),
    input: options.input,
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw new Error(result.error.message);
  if (result.status !== 0) {
    const stderr = Buffer.isBuffer(result.stderr) ? result.stderr.toString("utf8") : String(result.stderr ?? "");
    const stdout = Buffer.isBuffer(result.stdout) ? result.stdout.toString("utf8") : String(result.stdout ?? "");
    throw new Error((stderr || stdout || `git exited ${result.status}`).trim());
  }
  return result.stdout;
}

function gitPathIdentity(value) {
  return process.platform === "win32" ? String(value).replaceAll("\\", "/") : String(value);
}

function stripTerminalLineEnding(value) {
  const text = String(value);
  if (text.endsWith("\r\n")) return text.slice(0, -2);
  return text.endsWith("\n") ? text.slice(0, -1) : text;
}

function pathPresence(value) {
  try {
    fs.lstatSync(value);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

function prefixGitPath(prefix, value) {
  return prefix ? `${prefix}/${value}` : value;
}

function assertNoGitAncestryOverrides(root) {
  const commonDir = stripTerminalLineEnding(git(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"]));
  const grafts = path.join(commonDir, "info", "grafts");
  if (pathPresence(grafts)) throw new Error(`Git graft metadata blocks retirement evidence: ${grafts}`);
  const replacementRefs = String(git(root, ["for-each-ref", "--format=%(refname)", "refs/replace/"]))
    .split(/\r?\n/)
    .filter(Boolean)
    .sort();
  if (replacementRefs.length > 0) {
    throw new Error(`Git replacement refs block retirement evidence: ${replacementRefs.join(", ")}`);
  }
}

function gitIndexWorktreeChanges(root) {
  const raw = git(root, ["ls-files", "--stage", "-z", "--"], { encoding: "buffer" });
  const changed = new Set();
  const filteredFiles = [];
  for (const record of raw.toString("utf8").split("\0")) {
    if (!record) continue;
    const separator = record.indexOf("\t");
    if (separator < 0) throw new Error("Git returned unreadable index-to-worktree evidence");
    const [mode, object, stage] = record.slice(0, separator).split(" ");
    if (!mode || !/^[0-9a-f]{40,64}$/i.test(object) || stage === undefined) throw new Error("Git returned unreadable index-to-worktree evidence");
    const file = gitPathIdentity(record.slice(separator + 1));
    if (stage !== "0") {
      changed.add(file);
      continue;
    }
    const worktreePath = path.join(root, file);
    let stat;
    try {
      stat = fs.lstatSync(worktreePath);
    } catch (error) {
      if (error?.code === "ENOENT") {
        if (mode !== "160000") changed.add(file);
        continue;
      }
      throw error;
    }
    if (mode === "100644" || mode === "100755") {
      if (!stat.isFile()) {
        changed.add(file);
        continue;
      }
      if (process.platform !== "win32" && ((stat.mode & 0o100) !== 0) !== (mode === "100755")) changed.add(file);
      filteredFiles.push({ file, object, worktreePath });
      continue;
    }
    if (mode === "120000") {
      let input;
      if (stat.isSymbolicLink()) input = fs.readlinkSync(worktreePath, { encoding: "buffer" });
      else if (stat.isFile()) input = fs.readFileSync(worktreePath);
      else {
        changed.add(file);
        continue;
      }
      const worktreeObject = stripTerminalLineEnding(git(root, ["hash-object", "--stdin"], { input }));
      if (worktreeObject !== object) changed.add(file);
      continue;
    }
    if (mode === "160000") {
      if (!stat.isDirectory()) {
        changed.add(file);
        continue;
      }
      if (fs.readdirSync(worktreePath).length === 0) continue;
      const worktreeObject = stripTerminalLineEnding(git(worktreePath, ["rev-parse", "--verify", "HEAD^{commit}"]));
      if (worktreeObject !== object) changed.add(file);
      continue;
    }
    throw new Error(`Git returned unsupported tracked mode ${mode} for ${file}`);
  }
  const ordinary = filteredFiles.filter((entry) => /^[A-Za-z0-9._/ -]+$/.test(entry.file));
  const ordinaryPaths = new Set(ordinary.map((entry) => entry.file));
  if (ordinary.length > 0) {
    const output = String(git(root, ["hash-object", "--filters", "--stdin-paths"], {
      input: `${ordinary.map((entry) => entry.file).join("\n")}\n`,
    })).trim().split(/\r?\n/);
    if (output.length !== ordinary.length || output.some((object) => !/^[0-9a-f]{40,64}$/i.test(object))) {
      throw new Error("Git returned unreadable filtered worktree-object evidence");
    }
    ordinary.forEach((entry, index) => {
      if (output[index] !== entry.object) changed.add(entry.file);
    });
  }
  for (const entry of filteredFiles.filter((candidate) => !ordinaryPaths.has(candidate.file))) {
    const input = fs.readFileSync(entry.worktreePath);
    const worktreeObject = stripTerminalLineEnding(git(root, ["hash-object", "--filters", `--path=${entry.file}`, "--stdin"], { input }));
    if (worktreeObject !== entry.object) changed.add(entry.file);
  }
  return [...changed].sort();
}

function shallowGitStatus(root) {
  const raw = git(root, [
    "-c", "core.untrackedCache=false",
    "-c", "core.fsmonitor=false",
    "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=traditional", "--ignore-submodules=none",
  ], { encoding: "buffer" });
  const records = raw.toString("utf8").split("\0");
  const tracked = new Set();
  const untracked = new Set();
  const ignored = new Set();
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index];
    if (!record) continue;
    const status = record.slice(0, 2);
    const file = gitPathIdentity(record.slice(3));
    if (status === "??") {
      untracked.add(file);
      continue;
    }
    if (status === "!!") {
      ignored.add(file);
      continue;
    }
    tracked.add(file);
    if (status.includes("R") || status.includes("C")) {
      const prior = records[index + 1];
      if (prior) tracked.add(gitPathIdentity(prior));
      index += 1;
    }
  }
  gitIndexWorktreeChanges(root).forEach((file) => tracked.add(file));
  const trackedPaths = [...tracked].sort();
  return {
    trackedPaths,
    allowedTrackedChurnPaths: trackedPaths.filter((file) => PLAYBOT_TRACKED_CHURN_SET.has(file)),
    blockingTrackedPaths: trackedPaths.filter((file) => !PLAYBOT_TRACKED_CHURN_SET.has(file)),
    untrackedPaths: [...untracked].sort(),
    ignoredPaths: [...ignored].sort(),
  };
}

function gitIndexFlags(root) {
  const raw = git(root, ["ls-files", "-v", "-z", "--"], { encoding: "buffer" });
  const flagged = [];
  for (const record of raw.toString("utf8").split("\0")) {
    if (!record) continue;
    if (record.length < 3 || record[1] !== " ") throw new Error("Git returned unreadable index-flag evidence");
    const flag = record[0];
    const assumeUnchanged = /^[a-z]$/.test(flag);
    const skipWorktree = flag.toUpperCase() === "S";
    if (assumeUnchanged || skipWorktree) {
      flagged.push({
        path: gitPathIdentity(record.slice(2)),
        assumeUnchanged,
        skipWorktree,
      });
    }
  }
  return flagged.sort((left, right) => left.path.localeCompare(right.path));
}

function gitOperationState(root) {
  const markers = [
    { operation: "merge", marker: "MERGE_HEAD" },
    { operation: "rebase", marker: "rebase-merge" },
    { operation: "rebase", marker: "rebase-apply" },
    { operation: "cherry-pick", marker: "CHERRY_PICK_HEAD" },
    { operation: "cherry-pick-or-revert-sequence", marker: "sequencer" },
    { operation: "revert", marker: "REVERT_HEAD" },
  ];
  const active = [];
  for (const candidate of markers) {
    const markerPath = stripTerminalLineEnding(git(root, ["rev-parse", "--path-format=absolute", "--git-path", candidate.marker]));
    if (pathPresence(markerPath)) active.push(candidate);
  }
  return active;
}

function gitSubmodulePaths(root) {
  const raw = git(root, ["ls-files", "--stage", "-z", "--"], { encoding: "buffer" });
  const paths = [];
  for (const record of raw.toString("utf8").split("\0")) {
    if (!record) continue;
    const separator = record.indexOf("\t");
    if (separator < 0) throw new Error("Git returned unreadable staged-path evidence");
    const [mode, object, stage] = record.slice(0, separator).split(" ");
    if (!mode || !object || stage === undefined) throw new Error("Git returned unreadable staged-path evidence");
    if (mode === "160000" && stage === "0") paths.push(gitPathIdentity(record.slice(separator + 1)));
  }
  return [...new Set(paths)].sort();
}

function exactCommitSubject(root, commit) {
  const raw = git(root, ["show", "-s", "--encoding=UTF-8", "--format=format:%B%x00", commit], { encoding: "buffer" });
  if (raw.length === 0 || raw.at(-1) !== 0 || raw.subarray(0, -1).includes(0)) {
    throw new Error(`Git returned unreadable commit-subject evidence for ${commit}`);
  }
  const message = raw.subarray(0, -1);
  const lineEnd = message.indexOf(0x0a);
  return message.subarray(0, lineEnd < 0 ? message.length : lineEnd).toString("utf8");
}

function commitRecords(root, raw, label) {
  const commits = raw.toString("utf8").split("\0").filter(Boolean);
  if (commits.some((commit) => !/^[0-9a-f]{40,64}$/i.test(commit))) {
    throw new Error(`Git returned unreadable ${label} evidence`);
  }
  return commits.map((commit) => ({ commit, subject: exactCommitSubject(root, commit) }));
}

function commitPseudoRefRecords(root) {
  const names = ["ORIG_HEAD", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "BISECT_HEAD"];
  const records = [];
  for (const ref of names) {
    const file = stripTerminalLineEnding(git(root, ["rev-parse", "--path-format=absolute", "--git-path", ref]));
    if (!pathPresence(file)) continue;
    const commits = fs.readFileSync(file, "utf8").split(/\r?\n/).filter(Boolean);
    if (commits.length === 0 || commits.some((commit) => !/^[0-9a-f]{40,64}$/i.test(commit))) {
      throw new Error(`Git returned unreadable persisted submodule ${ref} evidence`);
    }
    for (const candidate of commits) {
      const commit = stripTerminalLineEnding(git(root, ["rev-parse", "--verify", `${candidate}^{commit}`]));
      records.push({ ref, commit, subject: exactCommitSubject(root, commit) });
    }
  }
  return records.sort((left, right) => left.ref.localeCompare(right.ref) || left.commit.localeCompare(right.commit));
}

function persistedSubmoduleGitDirs(root) {
  const gitDir = stripTerminalLineEnding(git(root, ["rev-parse", "--path-format=absolute", "--git-dir"]));
  const modulesRoot = path.join(gitDir, "modules");
  if (!pathPresence(modulesRoot)) return { repositories: [], unreadable: [] };
  const repositories = [];
  const unreadable = [];
  const scan = (directory, logicalPrefix = "") => {
    let entries;
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch (error) {
      unreadable.push({ path: logicalPrefix || ".", gitDir: directory, error: error instanceof Error ? error.message : String(error) });
      return;
    }
    for (const entry of entries) {
      const entryPath = path.join(directory, entry.name);
      const logicalPath = prefixGitPath(logicalPrefix, gitPathIdentity(entry.name));
      if (!entry.isDirectory()) {
        unreadable.push({ path: logicalPath, gitDir: entryPath, error: "unexpected non-directory entry in persisted submodule storage" });
        continue;
      }
      let isRepository;
      try {
        isRepository = pathPresence(path.join(entryPath, "HEAD"))
          && pathPresence(path.join(entryPath, "config"))
          && pathPresence(path.join(entryPath, "objects"));
      } catch (error) {
        unreadable.push({ path: logicalPath, gitDir: entryPath, error: error instanceof Error ? error.message : String(error) });
        continue;
      }
      if (!isRepository) {
        scan(entryPath, logicalPath);
        continue;
      }
      repositories.push({ path: logicalPath, gitDir: entryPath });
      const nestedModules = path.join(entryPath, "modules");
      try {
        if (pathPresence(nestedModules)) scan(nestedModules, logicalPath);
      } catch (error) {
        unreadable.push({ path: logicalPath, gitDir: nestedModules, error: error instanceof Error ? error.message : String(error) });
      }
    }
  };
  scan(modulesRoot);
  return { repositories, unreadable };
}

function remoteRefRows(root, remote) {
  const rows = String(git(root, ["ls-remote", "--refs", remote])).split(/\r?\n/).filter(Boolean).map((row) => {
    const separator = row.indexOf("\t");
    const object = separator < 0 ? "" : row.slice(0, separator);
    const ref = separator < 0 ? "" : row.slice(separator + 1);
    if (!/^[0-9a-f]{40,64}$/i.test(object) || !ref.startsWith("refs/") || ref.includes("\t")) {
      throw new Error(`remote ${remote} returned unreadable ref evidence`);
    }
    return { ref, object };
  });
  return rows.sort((left, right) => left.ref.localeCompare(right.ref) || left.object.localeCompare(right.object));
}

function localDisposableRefRows(root) {
  const rows = String(git(root, [
    "for-each-ref",
    "--format=%(refname)%09%(objectname)%09%(symref)",
    "refs/",
  ])).split(/\r?\n/).filter(Boolean).map((row) => {
    const [ref, object, symbolicTarget, ...extra] = row.split("\t");
    if (!ref.startsWith("refs/")
      || !/^[0-9a-f]{40,64}$/i.test(object)
      || (symbolicTarget && !symbolicTarget.startsWith("refs/"))
      || extra.length > 0) {
      throw new Error("Git returned unreadable local submodule ref evidence");
    }
    return { ref, object, symbolicTarget: symbolicTarget || null };
  }).filter((entry) => !entry.ref.startsWith("refs/remotes/"));
  return rows.sort((left, right) => (
    left.ref.localeCompare(right.ref)
      || left.object.localeCompare(right.object)
      || String(left.symbolicTarget).localeCompare(String(right.symbolicTarget))
  ));
}

function gitIndexHeadChanges(root) {
  const raw = git(root, [
    "diff", "--cached", "--name-only", "--no-renames", "--ignore-submodules=none", "-z", "HEAD", "--",
  ], { encoding: "buffer" });
  return [...new Set(raw.toString("utf8").split("\0").filter(Boolean).map(gitPathIdentity))].sort();
}

function freshRemoteCommitTips(root, remote) {
  const before = remoteRefRows(root, remote);
  for (let index = 0; index < before.length; index += 64) {
    git(root, [
      "fetch",
      "--quiet",
      "--no-tags",
      "--no-write-fetch-head",
      remote,
      ...before.slice(index, index + 64).map((entry) => entry.ref),
    ]);
  }
  const after = remoteRefRows(root, remote);
  if (JSON.stringify(before) !== JSON.stringify(after)) {
    throw new Error(`remote ${remote} refs changed during persisted submodule inspection`);
  }
  const commits = new Set();
  for (const entry of after) {
    git(root, ["cat-file", "-e", entry.object]);
    try {
      commits.add(stripTerminalLineEnding(git(root, ["rev-parse", "--verify", `${entry.object}^{commit}`])));
    } catch {
      continue;
    }
  }
  return {
    remote,
    remoteUrl: String(git(root, ["remote", "get-url", remote])).trim(),
    observedAt: nowIso(),
    refCount: after.length,
    refs: after,
    commits: [...commits].sort(),
  };
}

function commitPublished(root, commit, remoteTips) {
  if (remoteTips.length === 0) return false;
  const remaining = String(git(root, ["rev-list", "--max-count=1", "--stdin"], {
    input: `${commit}\n--not\n${remoteTips.join("\n")}\n`,
  })).trim();
  return remaining === "";
}

function persistedSubmoduleState(root) {
  const discovered = persistedSubmoduleGitDirs(root);
  const repositories = [];
  const unreadable = [...discovered.unreadable];
  for (const repository of discovered.repositories) {
    try {
      assertNoGitAncestryOverrides(repository.gitDir);
      const head = {
        commit: stripTerminalLineEnding(git(repository.gitDir, ["rev-parse", "--verify", "HEAD^{commit}"])),
        subject: exactCommitSubject(repository.gitDir, "HEAD"),
      };
      const historyCandidates = commitRecords(
        repository.gitDir,
        git(repository.gitDir, ["log", "-z", "--format=%H", "--all", "--reflog", "HEAD"], { encoding: "buffer" }),
        "persisted submodule history",
      );
      const pseudoRefs = commitPseudoRefRecords(repository.gitDir);
      const candidates = [...new Map(
        [...historyCandidates, ...pseudoRefs].map((entry) => [entry.commit, { commit: entry.commit, subject: entry.subject }]),
      ).values()];
      let stashCommit = null;
      try {
        stashCommit = stripTerminalLineEnding(git(repository.gitDir, ["rev-parse", "--verify", "refs/stash^{commit}"]));
      } catch {
        stashCommit = null;
      }
      const remoteEvidence = [];
      const publicationProblems = [];
      const remotes = String(git(repository.gitDir, ["remote"])).split(/\r?\n/).map((item) => item.trim()).filter(Boolean);
      if (remotes.length === 0) publicationProblems.push("persisted submodule repository has no configured remote");
      for (const remote of remotes) {
        try {
          remoteEvidence.push(freshRemoteCommitTips(repository.gitDir, remote));
        } catch (error) {
          publicationProblems.push(`remote ${remote}: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
      const remoteTips = [...new Set(remoteEvidence.flatMap((entry) => entry.commits))].sort();
      const localOnlyCommits = candidates.filter((entry) => !commitPublished(repository.gitDir, entry.commit, remoteTips));
      const localOnlyPseudoRefs = pseudoRefs.filter((entry) => !commitPublished(repository.gitDir, entry.commit, remoteTips));
      const localRefs = localDisposableRefRows(repository.gitDir);
      const publishedRefs = new Set(remoteEvidence.flatMap((entry) => entry.refs.map((item) => `${item.ref}\0${item.object}`)));
      const localOnlyRefs = localRefs.filter((entry) => (
        entry.symbolicTarget !== null || !publishedRefs.has(`${entry.ref}\0${entry.object}`)
      ));
      const stagedPaths = gitIndexHeadChanges(repository.gitDir);
      const indexFlags = gitIndexFlags(repository.gitDir);
      const operations = gitOperationState(repository.gitDir);
      repositories.push({
        ...repository,
        head,
        stashCommit,
        localOnlyCommits,
        localOnlyPseudoRefs,
        localOnlyRefs,
        stagedPaths,
        indexFlags,
        operations,
        publicationEvidence: {
          candidateCommitCount: candidates.length,
          excludedRefNamespaces: ["refs/remotes/"],
          localRefs,
          pseudoRefs,
          remoteTips,
          remotes: remoteEvidence,
          problems: publicationProblems,
        },
      });
    } catch (error) {
      unreadable.push({ ...repository, error: error instanceof Error ? error.message : String(error) });
    }
  }
  return { repositories, unreadable };
}

function workspaceGitStatus(root, prefix = "", visited = new Set()) {
  const canonicalRoot = canonicalPath(root);
  if (visited.has(canonicalRoot)) throw new Error(`recursive submodule path resolves to an already inspected repository: ${canonicalRoot}`);
  visited.add(canonicalRoot);
  assertNoGitAncestryOverrides(root);
  const shallow = shallowGitStatus(root);
  const tracked = new Set(shallow.trackedPaths.map((file) => prefixGitPath(prefix, file)));
  const untracked = new Set(shallow.untrackedPaths.map((file) => prefixGitPath(prefix, file)));
  const ignored = new Set(shallow.ignoredPaths.map((file) => prefixGitPath(prefix, file)));
  const indexFlags = gitIndexFlags(root).map((entry) => ({ ...entry, path: prefixGitPath(prefix, entry.path) }));
  const operations = gitOperationState(root).map((entry) => ({ ...entry, repositoryPath: prefix || "." }));
  const submodules = [];
  const unreadableSubmodules = [];
  const persistedSubmodules = persistedSubmoduleState(root);
  for (const relativePath of gitSubmodulePaths(root)) {
    const nestedPrefix = prefixGitPath(prefix, relativePath);
    const nestedRoot = path.resolve(root, relativePath);
    if (!pathPresence(nestedRoot)) continue;
    let entries;
    try {
      entries = fs.readdirSync(nestedRoot);
    } catch (error) {
      unreadableSubmodules.push({ path: nestedPrefix, error: error instanceof Error ? error.message : String(error) });
      continue;
    }
    if (entries.length === 0) continue;
    try {
      const nestedTop = canonicalPath(stripTerminalLineEnding(git(nestedRoot, ["rev-parse", "--show-toplevel"])));
      if (nestedTop !== canonicalPath(nestedRoot)) throw new Error(`path resolves inside Git worktree ${nestedTop} instead of naming it exactly`);
      const nested = workspaceGitStatus(nestedRoot, nestedPrefix, visited);
      nested.trackedPaths.forEach((file) => tracked.add(file));
      nested.untrackedPaths.forEach((file) => untracked.add(file));
      nested.ignoredPaths.forEach((file) => ignored.add(file));
      indexFlags.push(...nested.indexFlags);
      operations.push(...nested.operations);
      submodules.push({ path: nestedPrefix, inspected: true }, ...nested.submodules);
      unreadableSubmodules.push(...nested.unreadableSubmodules);
    } catch (error) {
      unreadableSubmodules.push({ path: nestedPrefix, error: error instanceof Error ? error.message : String(error) });
    }
  }
  visited.delete(canonicalRoot);
  const trackedPaths = [...tracked].sort();
  return {
    trackedPaths,
    allowedTrackedChurnPaths: trackedPaths.filter((file) => PLAYBOT_TRACKED_CHURN_SET.has(file)),
    blockingTrackedPaths: trackedPaths.filter((file) => !PLAYBOT_TRACKED_CHURN_SET.has(file)),
    untrackedPaths: [...untracked].sort(),
    ignoredPaths: [...ignored].sort(),
    indexFlags: indexFlags.sort((left, right) => left.path.localeCompare(right.path)),
    operations,
    submodules,
    persistedSubmodules: persistedSubmodules.repositories,
    unreadableSubmodules: [...unreadableSubmodules, ...persistedSubmodules.unreadable],
  };
}

function landingRemote(root, landingBranch) {
  const requested = String(landingBranch ?? "").trim();
  if (!requested) throw new Error("landingBranch is required and must name the branch this workspace lands on");
  const remotes = String(git(root, ["remote"])).split(/\r?\n/).map((item) => item.trim()).filter(Boolean);
  let remote = null;
  let branch = requested.replace(/^refs\/heads\//, "");
  const remoteRefMatch = requested.match(/^refs\/remotes\/([^/]+)\/(.+)$/);
  if (remoteRefMatch && remotes.includes(remoteRefMatch[1])) {
    [, remote, branch] = remoteRefMatch;
  } else {
    const slash = requested.indexOf("/");
    const prefix = slash > 0 ? requested.slice(0, slash) : "";
    if (prefix && remotes.includes(prefix)) {
      remote = prefix;
      branch = requested.slice(slash + 1);
    }
  }
  git(root, ["check-ref-format", "--branch", branch]);
  if (!remote) {
    const upstream = String(git(root, [
      "for-each-ref",
      "--format=%(upstream:remotename)%09%(upstream:remoteref)",
      `refs/heads/${branch}`,
    ])).trim();
    if (upstream) {
      const [upstreamRemote, upstreamRef] = upstream.split("\t");
      if (!upstreamRemote || !upstreamRef?.startsWith("refs/heads/")) {
        throw new Error(`landing branch ${requested} has an unreadable upstream binding`);
      }
      if (!remotes.includes(upstreamRemote)) {
        throw new Error(`landing branch ${requested} has an upstream binding without a readable remote`);
      }
      remote = upstreamRemote;
    } else if (remotes.length === 1) {
      [remote] = remotes;
    } else if (remotes.length === 0) {
      throw new Error(`landing branch ${requested} has no remote from which to obtain current evidence`);
    } else {
      throw new Error(`landing branch ${requested} has no upstream and this repository has multiple remotes; name it as <remote>/${requested}`);
    }
  }
  const remoteRef = `refs/heads/${branch}`;
  const observedAt = nowIso();
  const rows = String(git(root, ["ls-remote", "--exit-code", remote, remoteRef])).trim().split(/\r?\n/).filter(Boolean);
  if (rows.length !== 1) throw new Error(`remote ${remote} did not resolve exactly one ${remoteRef}`);
  const [commit, resolvedRef] = rows[0].split(/\s+/);
  if (!/^[0-9a-f]{40,64}$/i.test(commit) || resolvedRef !== remoteRef) {
    throw new Error(`remote ${remote} returned unreadable evidence for ${remoteRef}`);
  }
  try {
    git(root, ["cat-file", "-e", `${commit}^{commit}`]);
  } catch {
    git(root, ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", remote, remoteRef]);
    git(root, ["cat-file", "-e", `${commit}^{commit}`]);
  }
  return {
    requested,
    remote,
    remoteUrl: String(git(root, ["remote", "get-url", remote])).trim(),
    branch,
    remoteRef,
    commit,
    observedAt,
  };
}

function aheadCommits(root, landingCommit) {
  assertNoGitAncestryOverrides(root);
  const raw = git(root, ["log", "-z", "--format=%H", `${landingCommit}..HEAD`], { encoding: "buffer" });
  return commitRecords(root, raw, "ahead-commit");
}

function gitWorktreePaths(projectRootPath) {
  return git(projectRootPath, ["worktree", "list", "--porcelain", "-z"], { encoding: "buffer" })
    .toString("utf8")
    .split("\0")
    .filter((field) => field.startsWith("worktree "))
    .map((field) => canonicalPath(field.slice("worktree ".length)));
}

function inspectWorkspaceRoot(project, workspaceRoot, landingBranch) {
  const rootPath = canonicalPath(workspaceRoot.path);
  const result = {
    projectRootId: workspaceRoot.projectRootId,
    path: rootPath,
    branch: workspaceRoot.branch,
    head: null,
    landing: null,
    commitsAhead: [],
    tracked: {
      paths: [],
      allowedChurnPaths: [],
      blockingPaths: [],
      allowlist: PLAYBOT_TRACKED_CHURN_PATHS,
    },
    untrackedPaths: [],
    ignoredPaths: [],
    indexFlags: [],
    operations: [],
    submodules: { inspected: [], persisted: [], unreadable: [] },
    gitRegistration: null,
    blockers: [],
  };
  let rootPresent;
  try {
    rootPresent = rootPath ? pathPresence(rootPath) : false;
  } catch (error) {
    result.blockers.push({ code: "git-unreadable", message: `Workspace root cannot be checked at ${rootPath}: ${error instanceof Error ? error.message : String(error)}` });
    return result;
  }
  if (!rootPresent) {
    result.blockers.push({ code: "missing-root", message: `Workspace root is missing: ${workspaceRoot.path || "<empty>"}` });
    return result;
  }
  try {
    const top = canonicalPath(stripTerminalLineEnding(git(rootPath, ["rev-parse", "--show-toplevel"])));
    if (top !== rootPath) throw new Error(`root resolves inside Git worktree ${top} instead of naming it exactly`);
    result.head = {
      commit: String(git(rootPath, ["rev-parse", "--verify", "HEAD^{commit}"])).trim(),
      subject: exactCommitSubject(rootPath, "HEAD"),
    };
    const status = workspaceGitStatus(rootPath);
    result.tracked.paths = status.trackedPaths;
    result.tracked.allowedChurnPaths = status.allowedTrackedChurnPaths;
    result.tracked.blockingPaths = status.blockingTrackedPaths;
    result.untrackedPaths = status.untrackedPaths;
    result.ignoredPaths = status.ignoredPaths;
    result.indexFlags = status.indexFlags;
    result.operations = status.operations;
    result.submodules.inspected = status.submodules;
    result.submodules.persisted = status.persistedSubmodules;
    result.submodules.unreadable = status.unreadableSubmodules;
    const projectRoot = project.roots.find((candidate) => candidate.id === workspaceRoot.projectRootId);
    if (!projectRoot?.path) throw new Error(`project root ${workspaceRoot.projectRootId} is missing`);
    result.gitRegistration = {
      projectRootPath: canonicalPath(projectRoot.path),
      registered: gitWorktreePaths(projectRoot.path).includes(rootPath),
    };
  } catch (error) {
    result.blockers.push({ code: "git-unreadable", message: `Git state is unreadable at ${rootPath}: ${error instanceof Error ? error.message : String(error)}` });
    return result;
  }
  try {
    result.landing = landingRemote(rootPath, landingBranch);
    result.commitsAhead = aheadCommits(rootPath, result.landing.commit);
  } catch (error) {
    result.blockers.push({ code: "landing-branch-unresolvable", message: `Landing branch ${landingBranch} cannot be verified from current remote evidence at ${rootPath}: ${error instanceof Error ? error.message : String(error)}` });
  }
  if (result.commitsAhead.length > 0) {
    result.blockers.push({
      code: "unlanded-commits",
      message: `${result.commitsAhead.length} commit(s) are ahead of ${landingBranch}`,
      commits: result.commitsAhead,
    });
  }
  if (result.tracked.blockingPaths.length > 0) {
    result.blockers.push({
      code: "tracked-modifications",
      message: `${result.tracked.blockingPaths.length} tracked path(s) fall outside Playbot's exact churn allowlist`,
      paths: result.tracked.blockingPaths,
    });
  }
  if (result.indexFlags.length > 0) {
    result.blockers.push({
      code: "index-flags",
      message: `${result.indexFlags.length} tracked path(s) have assume-unchanged or skip-worktree index flags and cannot be proven clean`,
      paths: result.indexFlags.map((entry) => entry.path),
      entries: result.indexFlags,
    });
  }
  if (result.operations.length > 0) {
    result.blockers.push({
      code: "git-operation-in-progress",
      message: `${result.operations.length} in-progress Git operation marker(s) prevent a complete clean-workspace verdict`,
      operations: result.operations,
    });
  }
  if (result.submodules.unreadable.length > 0) {
    result.blockers.push({
      code: "submodule-unreadable",
      message: `${result.submodules.unreadable.length} populated submodule path(s) cannot be completely inspected`,
      submodules: result.submodules.unreadable,
    });
  }
  const submoduleLocalHistory = result.submodules.persisted.filter((entry) => (
    entry.stashCommit
      || entry.localOnlyCommits.length > 0
      || entry.localOnlyRefs.length > 0
      || entry.stagedPaths.length > 0
      || entry.indexFlags.length > 0
      || entry.operations.length > 0
  ));
  if (submoduleLocalHistory.length > 0) {
    result.blockers.push({
      code: "submodule-local-history",
      message: `${submoduleLocalHistory.length} persisted submodule Git director${submoduleLocalHistory.length === 1 ? "y contains" : "ies contain"} stashed history, unpushed commits, unpublished refs, staged index state, index flags, or in-progress operations that workspace deletion would remove`,
      submodules: submoduleLocalHistory,
    });
  }
  if (result.untrackedPaths.length > 0) {
    result.blockers.push({
      code: "untracked-files",
      message: `${result.untrackedPaths.length} untracked path(s) would be deleted and are never classified as Playbot churn`,
      paths: result.untrackedPaths,
    });
  }
  if (result.ignoredPaths.length > 0) {
    result.blockers.push({
      code: "ignored-files",
      message: `${result.ignoredPaths.length} ignored path(s) would be deleted and are never classified as Playbot churn`,
      paths: result.ignoredPaths,
    });
  }
  return result;
}

function inspectWorkspace(project, workspace, landingBranch) {
  const unarchivedThreads = threadRows()
    .filter((row) => row.workspace_id === workspace.id && !row.archived)
    .map((row) => ({ id: row.thread_id, title: row.title, status: row.agent_status, updatedAt: row.updated_at }));
  const blockingThreads = unarchivedThreads.filter((thread) => thread.status === "working" || thread.status === "pending_input");
  const evidence = {
    workspace: {
      id: workspace.id,
      name: workspace.name,
      kind: workspace.kind,
      selected: workspace.selected,
      archiveState: workspace.archiveState,
      projectId: project.id,
      project: project.name,
    },
    landingBranch: String(landingBranch ?? ""),
    threads: { unarchived: unarchivedThreads, blocking: blockingThreads },
    roots: [],
    blockers: [],
  };
  if (workspace.kind === "local") {
    evidence.blockers.push({ code: "local-workspace", message: "Local workspaces are never retirable" });
  }
  if (blockingThreads.length > 0) {
    evidence.blockers.push({
      code: "active-threads",
      message: `${blockingThreads.length} unarchived chat(s) are working or pending input`,
      threads: blockingThreads,
    });
  }
  if (workspace.roots.length === 0) {
    evidence.blockers.push({ code: "missing-root", message: "Workspace has no persisted workspace roots" });
  } else if (workspace.kind !== "local") {
    evidence.roots = workspace.roots.map((root) => inspectWorkspaceRoot(project, root, landingBranch));
    evidence.blockers.push(...evidence.roots.flatMap((root) => root.blockers));
  } else {
    evidence.roots = workspace.roots.map((root) => ({
      projectRootId: root.projectRootId,
      path: canonicalPath(root.path),
      branch: root.branch,
      inspection: "skipped because Local workspaces are never retirable",
    }));
  }
  evidence.retirable = evidence.blockers.length === 0;
  evidence.verdict = evidence.retirable ? "retirable" : "blocked";
  return evidence;
}

function retirementAuditPath() {
  return path.join(stateDir(), "workspace-retirements.jsonl");
}

function appendRetirementAudit(record) {
  ensurePrivateDirs();
  const file = retirementAuditPath();
  const descriptor = fs.openSync(file, "a", 0o600);
  try {
    fs.writeSync(descriptor, `${JSON.stringify(record)}\n`, null, "utf8");
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
  fs.chmodSync(file, 0o600);
  return file;
}

function validateRetirementRoute(route, name) {
  if (!route || typeof route !== "object" || Array.isArray(route)) throw new Error("route JSON is not an object");
  const failures = [];
  if (route.version !== 1) failures.push("version is not 1");
  if (typeof route.id !== "string" || !route.id.trim()) failures.push("id is missing");
  else if (`${safeId(route.id)}.json` !== name) failures.push("id does not match the route filename");
  if (typeof route.active !== "boolean") failures.push("active is not boolean");
  for (const endpoint of ["supervisor", "worker"]) {
    const value = route[endpoint];
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      failures.push(`${endpoint} is missing`);
      continue;
    }
    if (typeof value.id !== "string" || !value.id.trim()) failures.push(`${endpoint}.id is missing`);
    if (typeof value.workspaceId !== "string" || !value.workspaceId.trim()) failures.push(`${endpoint}.workspaceId is missing`);
  }
  if (typeof route.createdAt !== "string" || !route.createdAt.trim()) failures.push("createdAt is missing");
  if (typeof route.updatedAt !== "string" || !route.updatedAt.trim()) failures.push("updatedAt is missing");
  if (failures.length > 0) throw new Error(`route schema is invalid: ${failures.join(", ")}`);
  return route;
}

function strictRouteInventory(workspaceId) {
  ensurePrivateDirs();
  const inventory = [];
  for (const name of fs.readdirSync(routesDir()).filter((entry) => entry.endsWith(".json")).sort()) {
    const file = path.join(routesDir(), name);
    let contentSha256 = null;
    try {
      const raw = fs.readFileSync(file);
      contentSha256 = crypto.createHash("sha256").update(raw).digest("hex");
      const route = validateRetirementRoute(JSON.parse(raw.toString("utf8")), name);
      inventory.push({
        file: name,
        id: route.id ?? null,
        contentSha256,
        readable: true,
        namesWorkspace: route.supervisor?.workspaceId === workspaceId || route.worker?.workspaceId === workspaceId,
        active: route.active === true,
        route,
      });
    } catch (error) {
      inventory.push({
        file: name,
        id: null,
        contentSha256,
        readable: false,
        namesWorkspace: null,
        active: null,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }
  return inventory;
}

function publicRouteInventory(inventory) {
  return inventory.map(({ route: _route, ...entry }) => entry);
}

function routeInventoryProblems(inventory) {
  return inventory
    .filter((entry) => !entry.readable)
    .map((entry) => `Lane route ${entry.file} could not be read: ${entry.error}`);
}

function routeReconciliation(baseline, after, observationError = null) {
  if (after === null) {
    return {
      removedFiles: [],
      addedFiles: [],
      matchingBefore: baseline.filter((entry) => entry.namesWorkspace).map((entry) => entry.file),
      matchingAfter: [],
      changedFiles: [],
      remainingActive: [],
      uncertain: [
        ...baseline.filter((entry) => !entry.readable).map((entry) => `baseline ${entry.file}: ${entry.error}`),
        observationError ?? "post-action route inventory is unavailable",
      ],
    };
  }
  const beforeByFile = new Map(baseline.map((entry) => [entry.file, entry]));
  const afterByFile = new Map(after.map((entry) => [entry.file, entry]));
  return {
    removedFiles: baseline.filter((entry) => !afterByFile.has(entry.file)).map((entry) => entry.file),
    addedFiles: after.filter((entry) => !beforeByFile.has(entry.file)).map((entry) => entry.file),
    matchingBefore: baseline.filter((entry) => entry.namesWorkspace).map((entry) => entry.file),
    matchingAfter: after.filter((entry) => entry.namesWorkspace).map((entry) => entry.file),
    changedFiles: after.filter((entry) => beforeByFile.has(entry.file)
      && beforeByFile.get(entry.file).contentSha256 !== entry.contentSha256).map((entry) => entry.file),
    remainingActive: after.filter((entry) => entry.namesWorkspace && entry.active).map((entry) => entry.file),
    uncertain: [
      ...baseline.filter((entry) => !entry.readable).map((entry) => `baseline ${entry.file}: ${entry.error}`),
      ...after.filter((entry) => !entry.readable).map((entry) => `after ${entry.file}: ${entry.error}`),
    ],
  };
}

function captureWorkspaceRouteBaseline(workspaceId) {
  return withRoutesLock(() => publicRouteInventory(strictRouteInventory(workspaceId)));
}

function observeWorkspaceRoutes(workspaceId, baseline) {
  try {
    const after = withRoutesLock(() => publicRouteInventory(strictRouteInventory(workspaceId)));
    return {
      affected: [],
      baseline,
      after,
      reconciliation: routeReconciliation(baseline, after),
      problems: [...new Set([...routeInventoryProblems(baseline), ...routeInventoryProblems(after)])],
    };
  } catch (error) {
    const message = `Lane routes could not be reconciled: ${error instanceof Error ? error.message : String(error)}`;
    return {
      affected: [],
      baseline,
      after: null,
      reconciliation: routeReconciliation(baseline, null, message),
      problems: [message],
    };
  }
}

function deactivateWorkspaceRoutes(workspaceId, baseline) {
  const affected = [];
  const problems = [];
  let beforeDeactivation = [];
  let after = null;
  try {
    withRoutesLock(() => {
      problems.push(...routeInventoryProblems(baseline));
      const current = strictRouteInventory(workspaceId);
      beforeDeactivation = publicRouteInventory(current);
      problems.push(...routeInventoryProblems(current));
      for (const { file: name, route } of current.filter((item) => item.namesWorkspace)) {
        const file = path.join(routesDir(), name);
        const wasActive = route.active === true;
        route.active = false;
        route.updatedAt = nowIso();
        route.retiredWorkspace = workspaceId;
        route.retiredWorkspaceAt = route.updatedAt;
        try {
          atomicWriteJson(file, route);
          affected.push({ id: route.id ?? null, file: name, wasActive, deactivated: true });
        } catch (error) {
          affected.push({ id: route.id ?? null, file: name, wasActive, deactivated: false });
          problems.push(`Lane ${route.id ?? name} could not be deactivated: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
      const verified = strictRouteInventory(workspaceId);
      after = publicRouteInventory(verified);
      problems.push(...routeInventoryProblems(verified));
      for (const route of verified.filter((item) => item.namesWorkspace && item.active)) {
        problems.push(`Lane ${route.id ?? route.file} still names retired workspace ${workspaceId} and remains active`);
      }
    });
  } catch (error) {
    problems.push(`Lane routes could not be deactivated and verified: ${error instanceof Error ? error.message : String(error)}`);
  }
  const observationError = after === null ? problems.at(-1) : null;
  return {
    affected,
    baseline,
    beforeDeactivation,
    after,
    reconciliation: routeReconciliation(baseline, after, observationError),
    problems: [...new Set(problems)],
  };
}

function verifyWorkspaceRetirement(project, inspection) {
  const workspaceId = inspection.workspace.id;
  const checks = {
    workspaceRowGone: false,
    workspaceRowCount: null,
    workspaceRootRowsGone: false,
    workspaceRootRowCount: null,
    workspaceRootRows: [],
    worktreeDirectoriesGone: [],
    gitRegistrationsGone: [],
  };
  const problems = [];
  try {
    const db = openDb(appDbPath());
    try {
      checks.workspaceRowCount = Number(queryOne(db, "SELECT COUNT(*) AS count FROM workspaces WHERE id = ?", [workspaceId])?.count ?? -1);
      checks.workspaceRootRows = queryAll(db, "SELECT project_root_id, path, branch FROM workspace_roots WHERE workspace_id = ? ORDER BY project_root_id, path", [workspaceId])
        .map((row) => ({ projectRootId: row.project_root_id, path: row.path, branch: row.branch }));
      checks.workspaceRootRowCount = checks.workspaceRootRows.length;
      checks.workspaceRowGone = checks.workspaceRowCount === 0;
      checks.workspaceRootRowsGone = checks.workspaceRootRowCount === 0;
    } finally {
      db.close();
    }
  } catch (error) {
    problems.push(`Playbot database verification failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!checks.workspaceRowGone) problems.push(`Playbot workspaces row still exists for ${workspaceId}`);
  if (!checks.workspaceRootRowsGone) problems.push(`Playbot workspace_roots rows still exist for ${workspaceId}`);
  for (const root of inspection.roots) {
    try {
      const directoryGone = !pathPresence(root.path);
      checks.worktreeDirectoriesGone.push({ path: root.path, gone: directoryGone });
      if (!directoryGone) problems.push(`Worktree directory still exists: ${root.path}`);
    } catch (error) {
      checks.worktreeDirectoriesGone.push({ path: root.path, gone: false, error: error instanceof Error ? error.message : String(error) });
      problems.push(`Worktree directory removal cannot be verified for ${root.path}: ${error instanceof Error ? error.message : String(error)}`);
    }
    const projectRoot = project.roots.find((candidate) => candidate.id === root.projectRootId);
    if (!projectRoot?.path) {
      checks.gitRegistrationsGone.push({ path: root.path, gone: false, error: "project root path missing" });
      problems.push(`Git registration for ${root.path} cannot be checked because project root ${root.projectRootId} is missing`);
      continue;
    }
    try {
      if (typeof root.gitRegistration?.registered !== "boolean") throw new Error("pre-action Git registration evidence is missing");
      const registered = gitWorktreePaths(projectRoot.path);
      const gone = !registered.includes(canonicalPath(root.path));
      checks.gitRegistrationsGone.push({
        path: root.path,
        beforeRegistered: root.gitRegistration.registered,
        gone,
        removed: root.gitRegistration.registered && gone,
      });
      if (!gone) problems.push(`Git worktree registration still exists: ${root.path}`);
    } catch (error) {
      checks.gitRegistrationsGone.push({ path: root.path, gone: false, error: error instanceof Error ? error.message : String(error) });
      problems.push(`Git worktree registration verification failed for ${root.path}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return { complete: problems.length === 0, checks, problems };
}

function retirementReconciliation(verification) {
  const directoryChecks = verification.checks.worktreeDirectoriesGone;
  const registrationChecks = verification.checks.gitRegistrationsGone;
  const removed = {
    workspaceRow: verification.checks.workspaceRowGone,
    workspaceRootRows: verification.checks.workspaceRootRowsGone,
    directories: directoryChecks.filter((entry) => entry.gone).map((entry) => entry.path),
    gitRegistrations: registrationChecks.filter((entry) => entry.removed).map((entry) => entry.path),
  };
  const remaining = {
    workspaceRowCount: verification.checks.workspaceRowCount,
    workspaceRootRows: verification.checks.workspaceRootRows,
    directories: directoryChecks.filter((entry) => !entry.gone && !entry.error).map((entry) => entry.path),
    gitRegistrations: registrationChecks.filter((entry) => !entry.gone && !entry.error).map((entry) => entry.path),
    alreadyMissingGitRegistrations: registrationChecks.filter((entry) => entry.gone && entry.beforeRegistered === false).map((entry) => entry.path),
  };
  const uncertain = [
    ...(verification.checks.workspaceRowCount === null ? ["workspace row"] : []),
    ...(verification.checks.workspaceRootRowCount === null ? ["workspace root rows"] : []),
    ...directoryChecks.filter((entry) => entry.error).map((entry) => `directory ${entry.path}: ${entry.error}`),
    ...registrationChecks.filter((entry) => entry.error).map((entry) => `Git registration ${entry.path}: ${entry.error}`),
  ];
  return { removed, remaining, uncertain };
}

function captureWorkspaceRetirementBaseline(project, inspection) {
  const db = openDb(appDbPath());
  let workspaceRows;
  let workspaceRootRows;
  try {
    workspaceRows = queryAll(db, `
      SELECT id, project_id, name, kind, is_selected, archive_state
      FROM workspaces WHERE id = ?
    `, [inspection.workspace.id]).map((row) => ({
      id: row.id,
      projectId: row.project_id,
      name: row.name || (row.kind === "local" ? "Main" : row.id),
      kind: row.kind,
      selected: Boolean(row.is_selected),
      archiveState: row.archive_state,
    }));
    workspaceRootRows = queryAll(db, `
      SELECT project_root_id, path, branch
      FROM workspace_roots WHERE workspace_id = ?
      ORDER BY project_root_id, path
    `, [inspection.workspace.id]).map((row) => ({
      projectRootId: row.project_root_id,
      path: row.path,
      branch: row.branch,
    }));
  } finally {
    db.close();
  }
  if (workspaceRows.length !== 1) throw new Error(`expected one workspace row and found ${workspaceRows.length}`);
  const inspectedWorkspace = {
    id: inspection.workspace.id,
    projectId: inspection.workspace.projectId,
    name: inspection.workspace.name,
    kind: inspection.workspace.kind,
    selected: inspection.workspace.selected,
    archiveState: inspection.workspace.archiveState,
  };
  if (JSON.stringify(workspaceRows[0]) !== JSON.stringify(inspectedWorkspace)) {
    throw new Error("workspace row changed after the immediate safety inspection");
  }
  const compareRoots = (left, right) => {
    const leftKey = `${left.projectRootId}\0${left.path}`;
    const rightKey = `${right.projectRootId}\0${right.path}`;
    return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
  };
  workspaceRootRows.sort(compareRoots);
  const inspectedRoots = inspection.roots
    .map((root) => ({ projectRootId: root.projectRootId, path: root.path, branch: root.branch }))
    .sort(compareRoots);
  if (JSON.stringify(workspaceRootRows) !== JSON.stringify(inspectedRoots)) {
    throw new Error("workspace root rows changed after the immediate safety inspection");
  }
  const directories = inspection.roots.map((root) => ({ path: root.path, present: pathPresence(root.path) }));
  if (directories.some((entry) => !entry.present)) throw new Error("a workspace directory disappeared after the immediate safety inspection");
  const gitRegistrations = inspection.roots.map((root) => {
    const projectRoot = project.roots.find((candidate) => candidate.id === root.projectRootId);
    if (!projectRoot?.path) throw new Error(`project root ${root.projectRootId} is missing`);
    const registered = gitWorktreePaths(projectRoot.path).includes(canonicalPath(root.path));
    if (registered !== root.gitRegistration.registered) {
      throw new Error(`Git registration changed after the immediate safety inspection for ${root.path}`);
    }
    return {
      path: root.path,
      projectRootPath: canonicalPath(projectRoot.path),
      registered,
    };
  });
  return {
    database: { workspaceRows, workspaceRootRows },
    directories,
    gitRegistrations,
    routes: captureWorkspaceRouteBaseline(inspection.workspace.id),
  };
}

async function retireWorkspace(project, workspace, landingBranch) {
  const inspection = inspectWorkspace(project, workspace, landingBranch);
  if (!inspection.retirable) {
    const summary = inspection.blockers.map((blocker) => `${blocker.code}: ${blocker.message}`).join("; ");
    throw Object.assign(new Error(`Workspace ${workspace.id} failed its immediate retirement safety recheck: ${summary}`), {
      data: { inspection },
    });
  }
  let baseline;
  try {
    baseline = captureWorkspaceRetirementBaseline(project, inspection);
  } catch (error) {
    throw Object.assign(new Error(`Workspace ${workspace.id} failed its pre-action retirement baseline: ${error instanceof Error ? error.message : String(error)}`), {
      data: { inspection },
    });
  }
  const routeBaseline = baseline.routes;
  const ipcPayload = { workspaceId: workspace.id, preserveWorktrees: false };
  let ipcError = null;
  try {
    await playbotInvoke("workspace:delete", ipcPayload);
  } catch (error) {
    ipcError = error instanceof Error ? error.message : String(error);
  }

  if (ipcError) {
    const verification = verifyWorkspaceRetirement(project, inspection);
    const reconciliation = retirementReconciliation(verification);
    const deletionObserved = verification.checks.workspaceRowGone
      || verification.checks.workspaceRootRowsGone
      || verification.checks.worktreeDirectoriesGone.some((entry) => entry.gone)
      || verification.checks.gitRegistrationsGone.some((entry) => entry.removed);
    const routes = verification.complete
      ? deactivateWorkspaceRoutes(workspace.id, routeBaseline)
      : observeWorkspaceRoutes(workspace.id, routeBaseline);
    const retryWarning = "Do not retry workspace deletion blindly; inspect the workspace and this reconciliation evidence first.";
    const audit = {
      at: nowIso(),
      project: { id: project.id, name: project.name },
      workspace: inspection.workspace,
      workspacePaths: inspection.roots.map((root) => root.path),
      deletedPaths: reconciliation.removed.directories,
      remainingPaths: reconciliation.remaining.directories,
      heads: inspection.roots.map((root) => ({ projectRootId: root.projectRootId, path: root.path, ...root.head })),
      landingBranch: inspection.landingBranch,
      verifiedLandingCommits: inspection.roots.map((root) => ({
        projectRootId: root.projectRootId,
        remote: root.landing.remote,
        remoteRef: root.landing.remoteRef,
        commit: root.landing.commit,
        observedAt: root.landing.observedAt,
      })),
      affectedLaneRoutes: routes.affected,
      ipc: { channel: "workspace:delete", payload: ipcPayload, succeeded: false, error: ipcError },
      baseline,
      verification,
      reconciliation,
      deletionObserved,
      retryWarning,
      routeProblems: routes.problems,
      routeAfter: routes.after,
      routeReconciliation: routes.reconciliation,
    };
    let auditResult;
    try {
      auditResult = { appended: true, path: appendRetirementAudit(audit) };
    } catch (error) {
      auditResult = { appended: false, path: retirementAuditPath(), error: error instanceof Error ? error.message : String(error) };
    }
    const failure = {
      deleted: verification.complete,
      partialAction: deletionObserved && !verification.complete,
      workspace: inspection.workspace,
      landingBranch: inspection.landingBranch,
      ipc: { channel: "workspace:delete", payload: ipcPayload, succeeded: false, error: ipcError },
      baseline,
      verification,
      reconciliation,
      routes,
      audit: auditResult,
      postActionComplete: false,
      retryWarning,
      problems: [
        `Playbot workspace:delete rejected: ${ipcError}`,
        ...verification.problems,
        ...routes.problems,
        ...(auditResult.appended ? [] : [`Audit record could not be appended: ${auditResult.error}`]),
      ],
    };
    const outcome = verification.complete ? "deletion occurred despite the rejection" : deletionObserved ? "partial deletion occurred" : "no removal was verified";
    throw Object.assign(new Error(`Playbot workspace:delete rejected for ${workspace.id}; ${outcome}. ${retryWarning}`), { data: failure });
  }

  const verification = verifyWorkspaceRetirement(project, inspection);
  const reconciliation = retirementReconciliation(verification);
  const routes = verification.complete
    ? deactivateWorkspaceRoutes(workspace.id, routeBaseline)
    : observeWorkspaceRoutes(workspace.id, routeBaseline);
  const deletionObserved = verification.checks.workspaceRowGone
    || verification.checks.workspaceRootRowsGone
    || verification.checks.worktreeDirectoriesGone.some((entry) => entry.gone)
    || verification.checks.gitRegistrationsGone.some((entry) => entry.removed);
  const deletedPaths = reconciliation.removed.directories;
  const retryWarning = verification.complete
    ? null
    : "Do not retry workspace deletion blindly; inspect the workspace and this reconciliation evidence first.";
  const audit = {
    at: nowIso(),
    project: { id: project.id, name: project.name },
    workspace: inspection.workspace,
    workspacePaths: inspection.roots.map((root) => root.path),
    deletedPaths,
    remainingPaths: reconciliation.remaining.directories,
    heads: inspection.roots.map((root) => ({ projectRootId: root.projectRootId, path: root.path, ...root.head })),
    landingBranch: inspection.landingBranch,
    verifiedLandingCommits: inspection.roots.map((root) => ({
      projectRootId: root.projectRootId,
      remote: root.landing.remote,
      remoteRef: root.landing.remoteRef,
      commit: root.landing.commit,
      observedAt: root.landing.observedAt,
    })),
    affectedLaneRoutes: routes.affected,
    ipc: { channel: "workspace:delete", payload: ipcPayload, succeeded: true },
    baseline,
    verification,
    reconciliation,
    deletionObserved,
    retryWarning,
    routeProblems: routes.problems,
    routeAfter: routes.after,
    routeReconciliation: routes.reconciliation,
  };
  let auditResult;
  try {
    auditResult = { appended: true, path: appendRetirementAudit(audit) };
  } catch (error) {
    auditResult = { appended: false, path: retirementAuditPath(), error: error instanceof Error ? error.message : String(error) };
  }
  const problems = [
    ...verification.problems,
    ...routes.problems,
    ...(auditResult.appended ? [] : [`Audit record could not be appended: ${auditResult.error}`]),
  ];
  return {
    deleted: verification.complete,
    partialAction: !verification.complete,
    workspace: inspection.workspace,
    landingBranch: inspection.landingBranch,
    ipc: { channel: "workspace:delete", payload: ipcPayload, succeeded: true },
    baseline,
    verification,
    reconciliation,
    deletionObserved,
    routes,
    audit: auditResult,
    postActionComplete: problems.length === 0,
    retryWarning,
    problems,
  };
}

// An explicit workspace selector is resolved against the project's ACTIVE
// workspaces, so the unscoped project-wide search applies the same filter: a
// chat in an archived workspace is out of scope, so it is neither addressable
// nor able to make an active chat's title ambiguous.
//
// This is the ONE place that owns which chats are in scope, and every reader
// that offers a chat to a caller goes through it - with a project id to scope to
// one project, or with null to serve every live project - so a chat one reader
// offers is by construction resolvable by another. Copying the scope rule per
// call site is what let the parked detector hand back candidates its own
// confirming read then refused. A reader that genuinely needs a wider scope asks
// for it explicitly against threadRows().
function threadsForProject(projectId = null, workspaceId = null, includeArchived = false) {
  const liveProjects = new Set(topology().map((project) => project.id));
  return threadRows().filter((row) => liveProjects.has(row.project_id)
    && (!projectId || row.project_id === projectId)
    && (workspaceId ? row.workspace_id === workspaceId : row.archive_state === "active")
    && (includeArchived || !row.archived));
}

// The explicit wider scope threadsForProject's note points at, and the ONE place
// that owns it: an exact thread id, wherever that chat lives. Selecting a chat
// out of a caller's request is resolution and belongs in the scoped accessor;
// this is for a chat that is already identified - a registered lane's supervisor
// or worker, or a row being re-read for fresh persisted state after it was
// resolved and acted on. Re-applying the resolution scope there would refuse a
// chat the caller was already acting on, and after a completed write it would
// report a failure for work that succeeded.
function threadRowById(threadId) {
  const rows = threadId ? threadRows().filter((row) => row.thread_id === threadId && !row.archived) : [];
  return rows.length === 1 ? rows[0] : null;
}

function refreshThread(row) {
  const fresh = threadRowById(row.thread_id);
  if (!fresh) throw new Error(`Thread ${row.thread_id} is no longer readable in Playbot state; use list_threads to see the chats its project holds`);
  return fresh;
}

function publicThread(row) {
  return {
    id: row.thread_id,
    title: row.title,
    projectId: row.project_id,
    project: row.project_name,
    workspaceId: row.workspace_id,
    workspace: row.workspace_name || (row.workspace_kind === "local" ? "Main" : row.workspace_id),
    sessionId: row.session_id,
    status: row.agent_status,
    // Playbot holds undeliverable messages in a persisted queue the sender never
    // sees, so every chat view reports how many are still waiting.
    queuedCount: queuedMessageCount(row.pending_queue_json),
    hasUnread: Boolean(row.has_unread),
    isActive: Boolean(row.is_active),
    archived: Boolean(row.archived),
    updatedAt: row.updated_at,
    url: `playbot://workspace/${row.workspace_id}/thread/${row.thread_id}`,
  };
}

function resolveThread(projectId, workspaceId, selector, includeArchived = false) {
  const rows = threadsForProject(projectId, workspaceId, includeArchived);
  if (!selector) throw new Error("thread is required; use list_threads or create_chat");
  const raw = String(selector).trim();
  const exact = rows.filter((row) => row.thread_id === raw || row.session_id === raw);
  if (exact.length === 1) return exact[0];
  if (exact.length > 1) throw new Error(`Ambiguous thread id '${raw}': ${exact.map((row) => row.thread_id).join(", ")}`);
  const byTitle = rows.filter((row) => row.title.toLowerCase() === raw.toLowerCase());
  if (byTitle.length === 1) return byTitle[0];
  if (byTitle.length > 1) throw new Error(`Ambiguous thread title '${raw}': ${byTitle.map((row) => row.thread_id).join(", ")}`);
  const scope = workspaceId ? `workspace ${workspaceId}` : `project ${projectId}`;
  throw new Error(`Thread not found in ${scope}: ${raw}; use list_threads to see the chats it holds`);
}

// A thread selector already identifies one chat, so the workspace it lives in
// is derived from the matched row rather than guessed. Resolving the workspace
// first made every request without an explicit workspace fall back to whichever
// workspace happened to be selected in the Playbot UI, and then scoped the
// thread lookup to that one workspace - so a chat anywhere else reported
// "Thread not found" even though the caller had named it exactly. An explicit
// workspace selector still narrows the lookup and still fails closed when it
// does not match.
function resolveThreadInProject(project, workspaceSelector, threadSelector, includeArchived = false) {
  const workspaceId = workspaceSelector ? resolveWorkspace(project, workspaceSelector).id : null;
  return resolveThread(project.id, workspaceId, threadSelector, includeArchived);
}

class CdpClient {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 0;
    this.pending = new Map();
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (!message.id || !this.pending.has(message.id)) return;
      const { resolve } = this.pending.get(message.id);
      this.pending.delete(message.id);
      resolve(message);
    };
  }

  async send(method, params = {}) {
    const id = ++this.nextId;
    const result = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.socket.send(JSON.stringify({ id, method, params }));
    return result;
  }

  async evaluate(expression) {
    const response = await this.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
      userGesture: false,
    });
    if (response.error) throw new Error(response.error.message || "CDP evaluation failed");
    if (response.result?.exceptionDetails) {
      throw new Error(response.result.exceptionDetails.exception?.description || response.result.exceptionDetails.text || "Playbot IPC evaluation failed");
    }
    return response.result?.result?.value;
  }

  close() {
    this.socket.close();
  }
}

async function connectCdp(url) {
  const socket = new WebSocket(url);
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Timed out connecting to Playbot DevTools")), 2_500);
    socket.onopen = () => {
      clearTimeout(timer);
      resolve();
    };
    socket.onerror = () => {
      clearTimeout(timer);
      reject(new Error("Could not connect to Playbot DevTools"));
    };
  });
  const client = new CdpClient(socket);
  await client.send("Runtime.enable");
  return client;
}

async function withPlaybotPage(callback) {
  const portFile = path.join(desktopDir(), "DevToolsActivePort");
  if (!fs.existsSync(portFile)) throw new Error(`Playbot DevTools port not found: ${portFile}`);
  const port = fs.readFileSync(portFile, "utf8").split(/\r?\n/, 1)[0].trim();
  const response = await fetch(`http://127.0.0.1:${port}/json`, { signal: AbortSignal.timeout(2_500) });
  const targets = (await response.json()).filter((target) => target.type === "page" && target.webSocketDebuggerUrl);
  for (const target of targets) {
    const client = await connectCdp(target.webSocketDebuggerUrl);
    try {
      const usable = await client.evaluate("Boolean(window.electronAPI && typeof window.electronAPI.invoke === 'function')");
      if (usable) return await callback(client);
    } finally {
      client.close();
    }
  }
  throw new Error("No Playbot project renderer exposes electronAPI.invoke");
}

async function playbotInvoke(channel, payload) {
  return withPlaybotPage((client) => client.evaluate(`window.electronAPI.invoke(${JSON.stringify(channel)}, ${JSON.stringify(payload)})`));
}

function createThreadId() {
  return `chat-lane-${Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
}

// Playbot 0.94.0 removed threads:openThread and workspace:create and folded
// both into threads:launch. The probe payload below is rejected by every
// known Playbot schema before any handler code can run, so classifying the
// rejection detects which API this Playbot exposes without side effects:
// a missing-handler rejection means the pre-0.94 channels, any other
// rejection means threads:launch, and an accepted probe is an explicit
// error rather than a guess.
const CHAT_API_PROBE = { destination: { kind: "fm-capability-probe" } };
let detectedChatApi = null;

async function chatCreationApi() {
  if (detectedChatApi) return detectedChatApi;
  const outcome = await withPlaybotPage((client) => client.evaluate(
    `window.electronAPI.invoke("threads:launch", ${JSON.stringify(CHAT_API_PROBE)}).then(() => ({ accepted: true }), (error) => ({ accepted: false, message: String((error && error.message) || error) }))`
  ));
  if (!outcome || outcome.accepted !== false) {
    throw new Error("Playbot accepted the threads:launch capability probe; refusing to guess the chat-creation API");
  }
  detectedChatApi = /No handler registered/i.test(outcome.message ?? "") ? "openThread" : "launch";
  return detectedChatApi;
}

function workspaceCreatePayload(projectId, { name, baseBranch, branch } = {}) {
  const trimmed = (value) => String(value ?? "").trim();
  const payload = { strategy: "project", projectId };
  if (trimmed(name)) payload.name = trimmed(name);
  if (trimmed(branch)) payload.branch = trimmed(branch);
  if (trimmed(baseBranch)) payload.baseBranch = trimmed(baseBranch);
  return payload;
}

function readBackWorkspace(project, workspaceId) {
  const fresh = topology().find((candidate) => candidate.id === project.id)
    ?.workspaces.find((workspace) => workspace.id === workspaceId);
  if (!fresh) throw new Error(`Created workspace ${workspaceId} is not visible in Playbot state yet`);
  return fresh;
}

async function createWorkspace(project, options = {}) {
  if (await chatCreationApi() === "openThread") {
    const created = await playbotInvoke("workspace:create", workspaceCreatePayload(project.id, options));
    const workspaceId = created?.id;
    if (!workspaceId) throw new Error("Playbot did not return the created workspace id");
    return readBackWorkspace(project, workspaceId);
  }
  const launch = await playbotInvoke("threads:launch", {
    destination: { kind: "new-workspace", workspace: workspaceCreatePayload(project.id, options) },
    thread: { title: "Firstmate workspace setup", approvalMode: "default", planMode: false },
    activate: false,
  });
  const workspaceId = launch?.workspace?.id;
  const placeholderThreadId = launch?.thread?.id;
  if (!workspaceId || !placeholderThreadId) throw new Error("Playbot did not return the launched workspace and chat ids");
  try {
    await playbotInvoke("threads:archiveThread", { threadId: placeholderThreadId, nextActiveThreadId: null });
  } catch (error) {
    throw new Error(`Workspace ${workspaceId} was created, but archiving its setup chat ${placeholderThreadId} failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  return readBackWorkspace(project, workspaceId);
}

function assertNewWorkspaceRequest(name, args) {
  const request = args.newWorkspace;
  const eligible = name === "create_chat" || name === "dispatch";
  if (request === undefined || !eligible) return false;
  if (typeof request !== "object" || request === null || Array.isArray(request)) {
    throw new Error("newWorkspace must be an object with optional name, baseBranch, and branch");
  }
  if (args.workspace) throw new Error("Provide workspace or newWorkspace, not both");
  if (name === "dispatch" && args.thread) throw new Error("thread cannot be combined with newWorkspace; a just-created workspace has no existing chats");
  return true;
}

async function createChat({ project, workspace, newWorkspace, title, approvalMode = "full-access", planMode = false }) {
  const projects = topology();
  const targetProject = resolveProject(project, projects);
  const cleanTitle = String(title ?? "").trim();
  if (!cleanTitle) throw new Error("title must not be blank; Playbot requires a non-empty chat title");
  if (await chatCreationApi() === "launch") {
    const destination = newWorkspace === undefined
      ? { kind: "existing-workspace", workspaceId: resolveWorkspace(targetProject, workspace).id }
      : { kind: "new-workspace", workspace: workspaceCreatePayload(targetProject.id, newWorkspace) };
    const launch = await playbotInvoke("threads:launch", {
      destination,
      thread: { title: cleanTitle, approvalMode, planMode: Boolean(planMode) },
      activate: false,
    });
    const threadId = launch?.thread?.id;
    const workspaceId = launch?.workspace?.id ?? destination.workspaceId;
    if (!threadId || !workspaceId) throw new Error("Playbot did not return the launched chat and workspace ids");
    return publicThread(resolveThread(targetProject.id, workspaceId, threadId));
  }
  const targetWorkspace = newWorkspace === undefined
    ? resolveWorkspace(targetProject, workspace)
    : await createWorkspace(targetProject, newWorkspace);
  const threadId = createThreadId();
  await playbotInvoke("threads:openThread", {
    id: threadId,
    workspaceId: targetWorkspace.id,
    title: cleanTitle,
    approvalMode,
    planMode: Boolean(planMode),
  });
  const row = resolveThread(targetProject.id, targetWorkspace.id, threadId);
  return publicThread(row);
}

// Every read of a Playbot snapshot projection goes through this one accessor. A
// projection is a list or it is unreadable; it is never silently empty, because
// an empty list is a positive claim - "nothing is held", "no card remains" -
// that an unreadable shape has not earned. The caller picks the mode: a
// PRE-ACTION read collects the unreadable names and refuses by name, while a
// POST-ACTION read must not throw, because the write already succeeded, so it
// reports the affected field as null and warns naming the projection.
const UNREADABLE_PROJECTION = Symbol("unreadable projection");

function snapshotProjection(snapshot, key, unreadable) {
  const value = snapshot && typeof snapshot === "object" && !Array.isArray(snapshot) ? snapshot[key] : undefined;
  if (Array.isArray(value)) return value;
  if (unreadable && !unreadable.includes(key)) unreadable.push(key);
  return UNREADABLE_PROJECTION;
}

function unreadableProjections(snapshot, keys) {
  const unreadable = [];
  for (const key of keys) snapshotProjection(snapshot, key, unreadable);
  return unreadable;
}

// Playbot accepts a send it cannot deliver yet and holds it in a queue the
// sender is never told about, so a bare "the channel returned" is not evidence
// the worker saw anything. The send response is Playbot's own thread snapshot,
// and it distinguishes held from in-flight from accepted; report that verdict
// instead of implying success.
const SEND_SNAPSHOT_REQUIRED_KEYS = ["pendingMessages", "outboundMessages"];

async function deliveryVerdict(response, text, threadId) {
  if (!response || typeof response !== "object") {
    return {
      state: "unknown",
      messageId: null,
      queuedTotal: null,
      note: "Playbot returned no thread snapshot for this send, so delivery is unconfirmed. Check list_queued_messages before resending, because a resend compounds the queue.",
    };
  }
  // A snapshot that IS returned without a readable queue projection is a
  // renamed shape, not a legacy Playbot, so it is refused by name. A projection
  // that is present but not a list is just as unreadable as a removed one, and
  // treating it as an empty list would claim delivery for a held message.
  const missing = unreadableProjections(response, SEND_SNAPSHOT_REQUIRED_KEYS);
  if (missing.length > 0) {
    throw new Error(`${playbotVersionLabel(await playbotVersion())} returned a send snapshot for ${threadId} without ${missing.join(", ")}, so whether the message was delivered or is only held cannot be read. `
      + `This surface is verified against Playbot ${VERIFIED_PLAYBOT_VERSIONS}; re-verify the snapshot shape, and check list_queued_messages before resending.`);
  }
  const queued = snapshotProjection(response, "pendingMessages");
  const outbound = snapshotProjection(response, "outboundMessages");
  // Playbot projects both lists in arrival order and omits createdAtMs from the
  // queued one, so the most recent match is the last one, not the newest stamp.
  const newestMatch = (list) => {
    const matches = list.filter((message) => message?.text === text);
    return matches[matches.length - 1] ?? null;
  };

  const held = newestMatch(queued);
  if (held) {
    return {
      state: "queued",
      messageId: held.id ?? null,
      queuedTotal: queued.length,
      queuedAhead: queued.findIndex((message) => message === held),
      note: "Playbot is HOLDING this message and the worker has not seen it. It stays held until the running turn ends or the chat's pending card is answered. Do not resend: use get_thread_card to answer the card, or drop_queued_message to withdraw a superseded instruction.",
    };
  }
  const inFlight = newestMatch(outbound);
  if (inFlight) {
    return {
      state: inFlight.status === "failed" ? "failed" : "sending",
      messageId: inFlight.id ?? null,
      queuedTotal: queued.length,
      ...inFlight.reason ? { reason: inFlight.reason } : {},
    };
  }
  return { state: "delivered", messageId: null, queuedTotal: queued.length };
}

// The invoke returning is the only evidence a send reached Playbot. Everything
// after it - reading back the row, refusing an unreadable verdict - can still
// throw on a message Playbot may already have delivered, so those failures are
// marked and must never be treated as "the send did not happen".
function sendReachedPlaybot(error) {
  return Boolean(error && typeof error === "object" && error.sendReachedPlaybot);
}

function forcedDeliveryVerdict(response, priorDelivery) {
  const messageId = priorDelivery.messageId;
  if (!response || typeof response !== "object") {
    return {
      delivery: {
        state: "unknown",
        messageId,
        queuedTotal: null,
        note: "Playbot accepted the force request but returned no thread snapshot, so immediate steering is unconfirmed. Read list_queued_messages before acting again.",
      },
      force: {
        requested: true,
        state: "unknown",
        mechanism: "threads:steerMessage",
        activeTurn: "not interrupted",
      },
    };
  }
  const missing = unreadableProjections(response, SEND_SNAPSHOT_REQUIRED_KEYS);
  if (missing.length > 0) {
    return {
      delivery: {
        state: "unknown",
        messageId,
        queuedTotal: null,
        note: `Playbot accepted the force request but its response carried no readable ${missing.join(", ")}, so immediate steering is unconfirmed. Read list_queued_messages before acting again.`,
      },
      force: {
        requested: true,
        state: "unknown",
        mechanism: "threads:steerMessage",
        activeTurn: "not interrupted",
      },
    };
  }
  const queued = snapshotProjection(response, "pendingMessages");
  const outbound = snapshotProjection(response, "outboundMessages");
  const held = queued.find((message) => message?.id === messageId) ?? null;
  if (held?.steering === true) {
    return {
      delivery: {
        state: "steering",
        messageId,
        queuedTotal: queued.length,
        queuedAhead: queued.findIndex((message) => message === held),
        note: "Playbot marked this exact message as steering into the active turn. The turn continues and is not interrupted.",
      },
      force: {
        requested: true,
        state: "applied",
        mechanism: "threads:steerMessage",
        activeTurn: "continues",
        evidence: "Playbot's response snapshot marked the exact queued message steering=true",
      },
    };
  }
  if (held) {
    return {
      delivery: {
        state: "queued",
        messageId,
        queuedTotal: queued.length,
        queuedAhead: queued.findIndex((message) => message === held),
        note: "Playbot still reports this exact message as held, so force was not applied and the worker has not seen it.",
      },
      force: {
        requested: true,
        state: "not-applied",
        mechanism: "threads:steerMessage",
        activeTurn: "unchanged",
        evidence: "Playbot's response snapshot still marked the exact message queued without steering",
      },
    };
  }
  const inFlight = outbound.find((message) => message?.id === messageId) ?? null;
  if (inFlight) {
    return {
      delivery: {
        state: inFlight.status === "failed" ? "failed" : "sending",
        messageId,
        queuedTotal: queued.length,
        ...inFlight.reason ? { reason: inFlight.reason } : {},
      },
      force: {
        requested: true,
        state: "not-needed",
        mechanism: "threads:steerMessage",
        activeTurn: "unchanged",
        evidence: `Playbot's response snapshot moved the exact message to outbound state ${inFlight.status ?? "unknown"}`,
      },
    };
  }
  return {
    delivery: {
      state: "unknown",
      messageId,
      queuedTotal: queued.length,
      note: "Playbot accepted the force request but its response did not confirm the exact queued message id, so immediate steering and delivery remain unconfirmed. Read list_queued_messages before acting again.",
    },
    force: {
      requested: true,
      state: "not-applied",
      mechanism: "threads:steerMessage",
      activeTurn: "not interrupted",
      evidence: "Playbot's response snapshot did not contain the exact queued message id",
    },
  };
}

async function sendMessage(row, text, force = false) {
  if (row.archived) throw new Error(`Cannot send to archived thread ${row.thread_id}`);
  const value = String(text ?? "").trim();
  if (!value) throw new Error("message must not be empty");
  const resultThread = () => {
    try {
      return publicThread(refreshThread(row));
    } catch {
      return publicThread(row);
    }
  };
  const response = await playbotInvoke("threads:send", { threadId: row.thread_id, text: value });
  let fresh = null;
  try {
    try {
      fresh = refreshThread(row);
    } catch {
      fresh = null;
    }
    const sendResult = () => ({
      thread: resultThread(),
      supervisionAcceptance: fresh ? supervisionArmingBaseline(fresh) : null,
    });
    const delivery = await deliveryVerdict(response, value, row.thread_id);
    if (!force) return { ...sendResult(), delivery };
    if (delivery.state !== "queued") {
      const forceState = delivery.state === "delivered" || delivery.state === "sending"
        ? "not-needed"
        : delivery.state === "failed" ? "not-applied" : "unknown";
      return {
        ...sendResult(),
        delivery,
        force: {
          requested: true,
          state: forceState,
          mechanism: "threads:steerMessage",
          activeTurn: "unchanged",
          evidence: `Playbot's send response reported delivery state ${delivery.state}, so no exact queued message was available to promote`,
        },
      };
    }
    if (!delivery.messageId) {
      return {
        ...sendResult(),
        delivery: {
          ...delivery,
          note: "Playbot confirmed the message is queued but returned no message id, so force was not attempted because the exact held message cannot be addressed safely.",
        },
        force: {
          requested: true,
          state: "not-applied",
          mechanism: "threads:steerMessage",
          activeTurn: "unchanged",
          reason: "Playbot returned no exact queued message id",
        },
      };
    }
    let forcedResponse;
    try {
      forcedResponse = await playbotInvoke("threads:steerMessage", {
        threadId: row.thread_id,
        messageId: delivery.messageId,
      });
    } catch (error) {
      return {
        ...sendResult(),
        delivery: {
          state: "unknown",
          messageId: delivery.messageId,
          queuedTotal: null,
          note: "The message was queued before the force request, but Playbot returned no confirming force response. Immediate steering is unconfirmed; read list_queued_messages before acting again.",
        },
        force: {
          requested: true,
          state: "unknown",
          mechanism: "threads:steerMessage",
          activeTurn: "unknown",
          reason: error instanceof Error ? error.message : String(error),
        },
      };
    }
    return {
      ...sendResult(),
      ...forcedDeliveryVerdict(forcedResponse, delivery),
    };
  } catch (error) {
    const accepted = error instanceof Error ? error : new Error(String(error));
    accepted.sendReachedPlaybot = true;
    if (fresh) accepted.supervisionAcceptance = supervisionArmingBaseline(fresh);
    throw accepted;
  }
}

// ---------------------------------------------------------------------------
// Question cards, live snapshots, and the pending-message queue.
//
// These channels are Playbot's INTERNAL app IPC, not a published API. Playbot's
// own built-in MCP surface is read-only, so there is no supported write route to
// a parked card; this is the same call Playbot's UI makes when a human clicks an
// option. Everything here is verified against the Playbot versions named below,
// so a renamed channel or a dropped snapshot field must refuse and name what is
// missing rather than answer from a half-understood shape.
// ---------------------------------------------------------------------------

const VERIFIED_PLAYBOT_VERSIONS = "0.95.x";
const SNAPSHOT_REQUIRED_KEYS = ["agentStatus", "phase"];
// Every projection below must be a list. One that arrives as anything else is
// as unreadable as a removed one, and reading it as empty would report a card
// or a held message as absent.
const SNAPSHOT_REQUIRED_LIST_KEYS = [
  "userInputRequests",
  "approvalRequests",
  "mcpElicitationRequests",
  "respondingRequestIds",
  "pendingMessages",
  "outboundMessages",
];
let detectedPlaybotVersion;

async function playbotVersion() {
  if (detectedPlaybotVersion !== undefined) return detectedPlaybotVersion;
  let metadata;
  try {
    metadata = await playbotInvoke("app:metadata", undefined);
  } catch {
    // Only a successful read is cached; this process outlives one bad moment.
    return null;
  }
  const version = metadata?.version;
  if (typeof version !== "string" || !version.trim()) return null;
  detectedPlaybotVersion = version.trim();
  return detectedPlaybotVersion;
}

function playbotVersionLabel(version) {
  return version ? `Playbot ${version}` : "this Playbot (version unreadable)";
}

// A renamed or removed channel is the exact upgrade failure this surface has to
// survive, and Playbot reports it as a distinct missing-handler rejection.
async function cardInvoke(channel, payload) {
  try {
    return await playbotInvoke(channel, payload);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (/No handler registered/i.test(message)) {
      throw new Error(`${playbotVersionLabel(await playbotVersion())} does not register the '${channel}' channel this tool needs. `
        + `The card, snapshot, and queue tools are verified against Playbot ${VERIFIED_PLAYBOT_VERSIONS} internal IPC. `
        + "Answer or clear the card in the Playbot window and re-verify the channel names against the installed Playbot before using this tool again.");
    }
    throw error;
  }
}

function assertSnapshotShape(snapshot, threadId, version) {
  if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot)) {
    throw new Error(`Playbot returned no thread snapshot for ${threadId}; expected an object from 'threads:getSnapshot'`);
  }
  const missing = [
    ...SNAPSHOT_REQUIRED_KEYS.filter((key) => snapshot[key] === undefined),
    ...unreadableProjections(snapshot, SNAPSHOT_REQUIRED_LIST_KEYS),
  ];
  if (missing.length > 0) {
    throw new Error(`${playbotVersionLabel(version)} returned a thread snapshot without ${missing.join(", ")}. `
      + `This surface is verified against Playbot ${VERIFIED_PLAYBOT_VERSIONS}; re-verify the snapshot shape before trusting these tools.`);
  }
  return snapshot;
}

// Reading a snapshot resumes a chat that has not been resumed in this Playbot
// run, exactly as opening it in the Playbot window does. list_parked_threads is
// the non-resuming detector; this is the confirming read.
async function threadSnapshot(row) {
  const version = await playbotVersion();
  const snapshot = await cardInvoke("threads:getSnapshot", { threadId: row.thread_id });
  return { snapshot: assertSnapshotShape(snapshot, row.thread_id, version), version };
}

function publicQuestion(question) {
  return {
    id: question?.id ?? null,
    header: question?.header ?? null,
    question: question?.question ?? null,
    isOther: Boolean(question?.isOther),
    isSecret: Boolean(question?.isSecret),
    // Playbot renders a free-text field instead of options when a question
    // carries none, and an extra free-text slot alongside them when isOther.
    freeTextOnly: question?.options === null || question?.options === undefined,
    options: (question?.options ?? []).map((option) => ({
      label: option?.label ?? null,
      description: option?.description ?? null,
    })),
  };
}

function publicCard(request, kind, snapshot, unreadable) {
  const params = request?.params ?? {};
  const responding = snapshotProjection(snapshot, "respondingRequestIds", unreadable);
  return {
    requestId: request?.id ?? null,
    kind,
    method: request?.method ?? null,
    // params.threadId is the Codex session id, not the Playbot chat id.
    sessionId: params.threadId ?? null,
    turnId: params.turnId ?? null,
    itemId: params.itemId ?? null,
    answerable: kind === "question",
    responding: responding === UNREADABLE_PROJECTION ? null : responding.some((id) => String(id) === String(request?.id)),
    questions: (params.questions ?? []).map(publicQuestion),
  };
}

const CARD_PROJECTIONS = [
  ["userInputRequests", "question"],
  ["approvalRequests", "approval"],
  ["mcpElicitationRequests", "elicitation"],
];

// null, never [], when any card projection was unreadable: an empty card list
// reads as "the card is cleared", which an unreadable shape has not shown.
function publicCards(snapshot, unreadable) {
  const groups = CARD_PROJECTIONS.map(([key, kind]) => [snapshotProjection(snapshot, key, unreadable), kind]);
  if (groups.some(([list]) => list === UNREADABLE_PROJECTION)) return null;
  return groups.flatMap(([list, kind]) => list.map((request) => publicCard(request, kind, snapshot, unreadable)));
}

function publicQueuedMessage(message, status) {
  return {
    id: message?.id ?? null,
    text: message?.text ?? null,
    status,
    createdAtMs: message?.createdAtMs ?? null,
    ...message?.steering ? { steering: true } : {},
    ...message?.reason ? { reason: message.reason } : {},
  };
}

// Playbot holds a message it cannot deliver yet in pendingMessages and reports
// an in-flight or rejected one in outboundMessages, so a message id that is in
// neither list has actually reached the agent's turn.
function publicQueue(snapshot, unreadable) {
  const queued = snapshotProjection(snapshot, "pendingMessages", unreadable);
  const outbound = snapshotProjection(snapshot, "outboundMessages", unreadable);
  const withStatus = (status) => outbound === UNREADABLE_PROJECTION
    ? null
    : outbound.filter((message) => message?.status === status).map((message) => publicQueuedMessage(message, status));
  return {
    queued: queued === UNREADABLE_PROJECTION ? null : queued.map((message) => publicQueuedMessage(message, "queued")),
    sending: withStatus("sending"),
    failed: withStatus("failed"),
  };
}

// "not-recallable" means Playbot had already delivered the message, so a warning
// about the snapshot must never carry "the recall was applied" past that path: a
// supervisor would read a superseded instruction as withdrawn when it was not.
function recallOutcomeClause(outcome) {
  return outcome === "recalled"
    ? "The recall was applied"
    : `The recall was NOT applied - Playbot reported outcome ${outcome ?? "none"}`;
}

// null means the ledger is present but unreadable, never that nothing is held;
// 0 is reserved for an absent or empty queue.
function persistedMessages(pendingQueueJson) {
  if (typeof pendingQueueJson !== "string" || !pendingQueueJson.trim()) return [];
  const ledger = readJsonText(pendingQueueJson);
  return Array.isArray(ledger?.messages) ? ledger.messages : null;
}

function queuedMessages(pendingQueueJson) {
  const messages = persistedMessages(pendingQueueJson);
  if (messages === null) return null;
  return messages.filter((message) => {
    const state = message?.state?.type;
    return state === undefined || state === "queued" || state === "steering";
  });
}

function queuedMessageCount(pendingQueueJson) {
  const messages = queuedMessages(pendingQueueJson);
  return messages === null ? null : messages.length;
}

function readJsonText(text) {
  if (typeof text !== "string" || !text.trim()) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

// Playbot uses each option's LABEL as its answer value, so a value is sent
// byte-for-byte as get_thread_card reported it: nothing here trims, cases, or
// otherwise rewrites it, because an altered label no longer matches the option.
// Only a value with no content at all is rejected.
function answerValues(questionId, value) {
  const values = Array.isArray(value) ? value : [value];
  for (const entry of values) {
    if (typeof entry !== "string") throw new Error(`Answer for question '${questionId}' must be a string or an array of strings`);
  }
  const present = values.filter((entry) => entry.trim().length > 0);
  if (present.length === 0) throw new Error(`Answer for question '${questionId}' must not be empty; use skip=true to skip the card instead`);
  return present;
}

// Playbot's own renderer lets a human answer some questions on a card and skip
// the rest, so a partial answer is reported rather than refused: refusing would
// be stricter than Playbot itself, but a caller must never read a partial
// response as a complete one.
function buildCardResponse(card, answers, skip) {
  const asked = card.questions.map((question) => question.id);
  if (skip) {
    if (answers !== undefined && Object.keys(answers).length > 0) throw new Error("skip=true answers the card with no selection; omit answers");
    return { response: { answers: {} }, answered: [], unanswered: asked, partial: false };
  }
  const entries = Object.entries(answers ?? {});
  if (entries.length === 0) throw new Error("answers must name at least one question id, or pass skip=true to skip the card");
  const known = new Set(asked);
  const unknown = entries.map(([id]) => id).filter((id) => !known.has(id));
  if (unknown.length > 0) {
    throw new Error(`Question not on request ${card.requestId}: ${unknown.join(", ")}; this card asks ${asked.join(", ")}`);
  }
  const response = { answers: {} };
  for (const [id, value] of entries) response.answers[id] = { answers: answerValues(id, value) };
  const answered = entries.map(([id]) => id);
  const unanswered = asked.filter((id) => !answered.includes(id));
  return { response, answered, unanswered, partial: unanswered.length > 0 };
}

function findAnswerableCard(snapshot, requestId) {
  const cards = publicCards(snapshot);
  const requests = snapshotProjection(snapshot, "userInputRequests");
  const match = requests === UNREADABLE_PROJECTION ? null : requests.find((request) => String(request?.id) === String(requestId));
  if (match) return { request: match, card: publicCard(match, "question", snapshot) };
  const other = cards.find((card) => String(card.requestId) === String(requestId));
  if (other) {
    throw new Error(`Request ${requestId} is a ${other.kind} card, not a question card; answer_thread_card only answers question cards`);
  }
  const available = cards.map((card) => `${card.requestId} (${card.kind})`);
  throw new Error(`No pending request ${requestId} on this chat${available.length > 0 ? `; it currently holds ${available.join(", ")}` : " and it holds no pending card at all"}. `
    + "Re-read get_thread_card: the card may already have been answered, or Playbot may have restarted and dropped it.");
}

function codexSession(sessionId) {
  if (!sessionId || !fs.existsSync(codexDbPath())) return null;
  const db = openDb(codexDbPath());
  try {
    return queryOne(db, `
      SELECT id, rollout_path, cwd, title, updated_at_ms, archived
      FROM threads
      WHERE id = ?
    `, [sessionId]);
  } finally {
    db.close();
  }
}

function readTail(file, maxBytes = 4 * 1024 * 1024) {
  const stat = fs.statSync(file);
  const start = Math.max(0, stat.size - maxBytes);
  const length = stat.size - start;
  const fd = fs.openSync(file, "r");
  try {
    const buffer = Buffer.alloc(length);
    fs.readSync(fd, buffer, 0, length, start);
    let text = buffer.toString("utf8");
    if (start > 0) text = text.slice(text.indexOf("\n") + 1);
    return text;
  } finally {
    fs.closeSync(fd);
  }
}

function recentConversation(row, turnLimit = 8) {
  const session = codexSession(row.session_id);
  if (!session?.rollout_path || !fs.existsSync(session.rollout_path)) {
    return { thread: publicThread(row), turns: [], finalAnswer: null, completion: null };
  }
  const events = [];
  let completion = null;
  for (const line of readTail(session.rollout_path).split(/\r?\n/)) {
    if (!line.trim()) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    if (record.type !== "event_msg") continue;
    const payload = record.payload ?? {};
    if (payload.type === "user_message" && typeof payload.message === "string") {
      events.push({ role: "user", text: payload.message, timestamp: record.timestamp ?? null });
    } else if (payload.type === "agent_message" && typeof payload.message === "string") {
      events.push({ role: "assistant", text: payload.message, phase: payload.phase ?? null, timestamp: record.timestamp ?? null });
    } else if (payload.type === "task_complete") {
      completion = {
        turnId: payload.turn_id ?? null,
        finalAnswer: payload.last_agent_message ?? null,
        completedAt: payload.completed_at ?? null,
        durationMs: payload.duration_ms ?? null,
      };
    }
  }
  return {
    thread: publicThread(row),
    turns: events.slice(-Math.max(1, Number(turnLimit) * 2)),
    finalAnswer: completion?.finalAnswer ?? [...events].reverse().find((event) => event.role === "assistant")?.text ?? null,
    completion,
  };
}

function callerFileName(payload) {
  const stamp = String(Date.now()).padStart(16, "0");
  return path.join(callersDir(), `${stamp}-${process.pid}-${safeId(payload.sessionId)}-${crypto.randomBytes(3).toString("hex")}.json`);
}

function normalizeToolName(name) {
  return String(name ?? "").trim();
}

function toolMatches(markerName, toolName) {
  const marker = normalizeToolName(markerName).toLowerCase();
  const tool = normalizeToolName(toolName).toLowerCase();
  return marker === tool || marker.endsWith(`__${tool}`) || marker.endsWith(`:${tool}`);
}

function recordCaller(payload) {
  ensurePrivateDirs();
  const toolName = normalizeToolName(payload.tool_name ?? payload.toolName);
  if (!toolName.toLowerCase().startsWith(`mcp__${SERVER_NAME}__`)) return false;
  const sessionId = payload.session_id ?? payload.sessionId;
  if (!sessionId) return false;
  atomicWriteJson(callerFileName({ sessionId }), {
    version: 1,
    sessionId,
    cwd: payload.cwd ?? null,
    toolName,
    recordedAtMs: Date.now(),
  });
  return true;
}

function consumeCaller(toolName) {
  ensurePrivateDirs();
  const cutoff = Date.now() - CALLER_MAX_AGE_MS;
  const candidates = [];
  for (const name of fs.readdirSync(callersDir())) {
    const file = path.join(callersDir(), name);
    const marker = readJson(file);
    if (!marker || marker.recordedAtMs < cutoff) {
      fs.rmSync(file, { force: true });
      continue;
    }
    if (toolMatches(marker.toolName, toolName)) candidates.push({ file, marker });
  }
  const sessions = new Map();
  for (const candidate of candidates) {
    const prior = sessions.get(candidate.marker.sessionId);
    if (!prior || candidate.marker.recordedAtMs > prior.marker.recordedAtMs) sessions.set(candidate.marker.sessionId, candidate);
  }
  if (sessions.size > 1) {
    throw new Error(`Caller identity is ambiguous across ${sessions.size} active Playbot sessions; retry the tool call when only this controller is invoking it`);
  }
  if (sessions.size === 0) return null;
  const chosen = [...sessions.values()][0];
  for (const candidate of candidates.filter((item) => item.marker.sessionId === chosen.marker.sessionId)) fs.rmSync(candidate.file, { force: true });
  return chosen.marker;
}

function rowForSession(sessionId) {
  // Deliberately the raw rows, not the scoped accessor: a chat must be able to
  // identify itself wherever it lives, including an archived workspace.
  const rows = threadRows().filter((row) => row.session_id === sessionId && !row.archived);
  if (rows.length === 1) return rows[0];
  if (rows.length > 1) throw new Error(`Codex session ${sessionId} maps to multiple Playbot chats`);
  return null;
}

function identifyController(toolName) {
  const marker = consumeCaller(toolName);
  if (!marker) return null;
  const row = rowForSession(marker.sessionId);
  if (!row) throw new Error(`Current Codex session is not mapped to a persisted Playbot chat yet: ${marker.sessionId}`);
  return row;
}

function controllerForTool(toolName) {
  const row = identifyController(toolName);
  if (!row) return null;
  const project = topology().find((candidate) => candidate.id === row.project_id);
  if (!project || !projectPaths(project).has(controllerRoot())) {
    throw new Error(`The calling chat ${row.thread_id} is not in the configured controller project ${controllerRoot()}`);
  }
  return row;
}

function routePath(routeId) {
  return path.join(routesDir(), `${safeId(routeId)}.json`);
}

function routeIdFor(supervisorThreadId, workerThreadId) {
  return `lane-${crypto.createHash("sha256").update(`${supervisorThreadId}\n${workerThreadId}`).digest("hex").slice(0, 16)}`;
}

function loadRoutes() {
  ensurePrivateDirs();
  return fs.readdirSync(routesDir())
    .filter((name) => name.endsWith(".json"))
    .map((name) => readJson(path.join(routesDir(), name)))
    .filter(Boolean)
    .sort((left, right) => String(right.updatedAt).localeCompare(String(left.updatedAt)));
}

function saveRoute(supervisor, worker) {
  if (supervisor.thread_id === worker.thread_id) throw new Error("A Playbot lane cannot route a chat back to itself");
  const id = routeIdFor(supervisor.thread_id, worker.thread_id);
  return updateRouteFile(routePath(id), true, (prior) => {
    const currentSupervisor = threadRowById(supervisor.thread_id);
    const currentWorker = threadRowById(worker.thread_id);
    if (!currentSupervisor || currentSupervisor.archive_state !== "active") throw new Error(`Supervisor ${supervisor.thread_id} is no longer active in Playbot state`);
    if (!currentWorker || currentWorker.archive_state !== "active") throw new Error(`Worker ${worker.thread_id} is no longer active in Playbot state`);
    const existingCompletion = prior ? null : recentConversation(currentWorker, 1).completion;
    return {
      version: 1,
      id,
      active: true,
      supervisor: publicThread(currentSupervisor),
      worker: publicThread(currentWorker),
      createdAt: prior?.createdAt ?? nowIso(),
      updatedAt: nowIso(),
      lastNotifiedTurnId: prior?.lastNotifiedTurnId ?? existingCompletion?.turnId ?? null,
      lastNotifiedAt: prior?.lastNotifiedAt ?? null,
    };
  });
}

function registerLane(supervisor, worker) {
  return saveRoute(supervisor, worker);
}

// --- Watcher supervision poll for external-terminal lanes ---------------------
//
// A Playbot-chat caller gets registerLane above and its routed Stop-hook wakes.
// An external-terminal caller gets no push path at all: identify_current_thread
// reports external-terminal, register_lane refuses it, and a Stop hook only ever
// wakes a chat. Polling is therefore the only supervision that exists for it, and
// leaving the caller to write that poll by hand is what produced three dispatched
// workers with nothing watching them on 2026-08-24. A dispatch result that names
// polling tools while arming no poll instructs the caller instead of serving it,
// so arming is this server's job and happens inside the dispatch call.
//
// This is a stdio server with no life between calls, so it cannot poll itself.
// It registers the poll with the supervision that already exists - firstmate's
// watcher - by writing state/<task-id>.check.sh under the controller root and
// binding it through bin/fm-check-register.sh, which is the one owner of the
// watcher's trust binding. The watcher executes only the exact bytes that
// registration bound, so the check is generated from the fixed template below
// with nothing interpolated but this server's own resolved paths and the
// validated task and thread ids; no caller-supplied text ever reaches it, and
// the trust store is never written here.
//
// create_chat deliberately arms nothing. It creates an empty chat and starts no
// agent turn, so there is no worker to supervise yet and an armed poll would
// immediately report a chat that stopped without a card. The dispatch that sends
// that chat its task is what arms the poll.

const SUPERVISION_CHECK_MARKER = "# fm-playbot-lane-supervision-poll v1";
const SUPERVISION_TOOLS = ["get_thread_status", "read_thread", "get_thread_card"];
const SUPERVISION_CHECK_SHEBANG = "#!/usr/bin/env bash";
const SUPERVISION_SIDECAR_VERSION = "fm-playbot-lane-poll-v8";
const SUPERVISION_SIDECAR_VERSION_V7 = "fm-playbot-lane-poll-v7";
const SUPERVISION_SIDECAR_VERSION_V6 = "fm-playbot-lane-poll-v6";
const SUPERVISION_SIDECAR_VERSION_V5 = "fm-playbot-lane-poll-v5";
const SUPERVISION_SIDECAR_VERSION_V4 = "fm-playbot-lane-poll-v4";
const SUPERVISION_SIDECAR_VERSION_V3 = "fm-playbot-lane-poll-v3";
const SUPERVISION_SIDECAR_VERSION_V2 = "fm-playbot-lane-poll-v2";
const SUPERVISION_DELIVERY_STATES = new Set(["delivered", "queued", "sending", "recall-pending", "recalled", "failed", "unknown", "unconfirmed"]);
// The status a chat that Playbot no longer holds is recorded under. It is not
// one of Playbot's own agent_status values, so it can never collide with one.
const SUPERVISION_ABSENT = "chat-absent";

// The shape bin/fm-pr-lib.sh's fm_task_id_path_safe accepts, plus the 64-character
// bound fm_task_id_creation_valid applies, because this id names a file in the
// controller's state directory and fm-check-register.sh revalidates it before
// binding anything.
function supervisionTaskIdValid(value) {
  return typeof value === "string"
    && value.length > 0
    && value.length <= 64
    && !value.startsWith(".")
    && /^[A-Za-z0-9._-]+$/.test(value);
}

function supervisionRefuse(message) {
  throw new Error(message);
}

function supervisionErrorDetail(error) {
  return error instanceof Error ? error.message : String(error);
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

// Quoting alone would survive a newline, but a template whose every line is one
// command is far easier to audit than one that might not be, so a path carrying
// a newline or NUL refuses instead of being escaped into the file.
function supervisionPath(value, label) {
  const text = String(value ?? "");
  if (!text || !path.isAbsolute(text) || /[\0\n\r]/.test(text)) {
    supervisionRefuse(`${label} is not a usable absolute path for a generated check: ${JSON.stringify(text)}`);
  }
  return text;
}

function supervisionCheckScript({ taskId, threadId, generation, nodeBin, scriptPath, desktop, state }) {
  return `${SUPERVISION_CHECK_SHEBANG}
${SUPERVISION_CHECK_MARKER}
# Firstmate watcher poll for one Playbot lane worker, armed by
# bin/fm-playbot-lanes.mjs when an external-terminal caller dispatched that
# worker. Generated from a fixed template: the only interpolated values are this
# server's own resolved paths and the validated task and thread ids.
# Prints one line when the worker parks on a card. After proven delivery, it
# prints one line on the change into a stopped or unreadable state and retires
# itself; without that proof it reports the uncertainty and remains armed.
# Silent while the worker is working and after it has reported a finished one.
# Re-arm through dispatch rather than editing this file: the watcher runs only
# the exact bytes bin/fm-check-register.sh bound, so an edit disarms the poll.
set -u
export PLAYBOT_DESKTOP_DIR=${shellQuote(desktop)}
exec ${shellQuote(nodeBin)} ${shellQuote(scriptPath)} supervision-poll --task ${shellQuote(taskId)} --thread ${shellQuote(threadId)} --state ${shellQuote(state)} --generation ${shellQuote(generation)}
`;
}

function supervisionCheckIsOurs(text) {
  return text.startsWith(`${SUPERVISION_CHECK_SHEBANG}\n${SUPERVISION_CHECK_MARKER}\n`);
}

// This server's own absolute path, which is also where fm-check-register.sh
// lives: both are in the tracked bin/ directory, while the controller root is
// the firstmate HOME that owns state/. Resolving the helper from the code root
// rather than from the home is what lets a secondmate home, whose state/ and
// bin/ are different directories, arm a poll at all.
function supervisionSelfScript() {
  const raw = process.argv[1];
  if (!raw) supervisionRefuse("this server's own script path is unknown, so no check can name it");
  try {
    return fs.realpathSync.native(path.resolve(raw));
  } catch {
    return path.resolve(raw);
  }
}

function serverBuildIdentity() {
  return `sha256:${crypto.createHash("sha256").update(fs.readFileSync(supervisionSelfScript())).digest("hex")}`;
}

function supervisionStateDir() {
  const state = path.join(controllerRoot(), "state");
  let stat;
  try {
    stat = fs.lstatSync(state);
  } catch {
    supervisionRefuse(`${state} does not exist, so PLAYBOT_LANES_CONTROLLER_ROOT is not a firstmate home that can hold a watcher poll`);
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    supervisionRefuse(`${state} is not a real directory, so no watcher poll can be written there`);
  }
  return state;
}

// fm-check-register.sh resolves its state directory as
// ${FM_STATE_OVERRIDE:-$FM_HOME/state}, so an inherited override would bind a
// directory other than the one this arming just wrote into - and if a check of
// the same name happened to live there, it would report success for bytes this
// server never wrote. The arming deliberately resolves state from the
// controller root, so the redirecting variables are cleared for this child and
// FM_HOME alone decides.
function supervisionRegister(taskId, register) {
  const env = { ...process.env, FM_HOME: controllerRoot() };
  delete env.FM_STATE_OVERRIDE;
  delete env.FM_ROOT_OVERRIDE;
  const result = spawnSync(register, [taskId], {
    env,
    encoding: "utf8",
    timeout: 20_000,
  });
  if (result.error) return { ok: false, detail: result.error.message };
  if (result.status !== 0) {
    const detail = `${result.stderr ?? ""} ${result.stdout ?? ""}`.trim() || `exit ${result.status}`;
    return { ok: false, detail };
  }
  return { ok: true, detail: String(result.stdout ?? "").trim() };
}

function supervisionWriteCheck(state, taskId, script) {
  return supervisionPublish(state, `${taskId}.check.sh`, script, 0o700);
}

// The armed poll must not rewrite its own check to remember anything: the
// watcher executes only the exact bytes fm-check-register.sh bound, so a check
// that edited itself would disarm itself. The last observed status therefore
// lives in this private sidecar beside the check, written with the same atomic
// temp-then-rename discipline, and is removed with the check when the poll
// retires or the task is torn down.
function supervisionSidecarPath(state, taskId) {
  return path.join(state, `${taskId}.lane-poll`);
}

// One observation is a status AND the row's updated_at, because a bare status
// cannot tell a worker that ran and finished from one that never started: both
// read back as 'ready'. threadRows() already selects t.updated_at, so the pair
// costs no extra read and no extra file.
function supervisionField(value) {
  return String(value ?? "").replace(/[\r\n]+/g, " ");
}

function supervisionDeliveryState(value) {
  return SUPERVISION_DELIVERY_STATES.has(value) ? value : "unconfirmed";
}

function supervisionMessageKey(value) {
  if (typeof value !== "string" || value.length === 0) return null;
  return `sha256:${crypto.createHash("sha256").update(value).digest("hex")}`;
}

function supervisionThreadKey(value) {
  return supervisionMessageKey(value);
}

function supervisionTimestampMs(value) {
  const parsed = Date.parse(String(value ?? ""));
  return Number.isFinite(parsed) ? parsed : null;
}

function supervisionWriteSidecar(state, taskId, observation) {
  const delivery = supervisionDeliveryState(observation.deliveryState);
  const messageKey = observation.messageKey ?? "none";
  const acceptanceMs = observation.acceptanceMs ?? "none";
  const threadKey = observation.threadKey ?? "none";
  const body = `${SUPERVISION_SIDECAR_VERSION}\n${supervisionField(observation.status)}\n${supervisionField(observation.updatedAt)}\n${delivery}\n${supervisionField(observation.generation)}\n${messageKey}\n${acceptanceMs}\n${threadKey}\n`;
  return supervisionPublish(state, `${taskId}.lane-poll`, body, 0o600);
}

function supervisionSameObservation(left, right) {
  return Boolean(left) && Boolean(right)
    && left.status === supervisionField(right.status)
    && left.updatedAt === supervisionField(right.updatedAt)
    && supervisionDeliveryState(left.deliveryState) === supervisionDeliveryState(right.deliveryState)
    && (left.messageKey ?? null) === (right.messageKey ?? null)
    && (left.acceptanceMs ?? null) === (right.acceptanceMs ?? null)
    && (left.threadKey ?? null) === (right.threadKey ?? null)
    && (left.generation ?? null) === (right.generation ?? null);
}

function supervisionPublish(state, name, contents, mode) {
  const target = path.join(state, name);
  const tmp = path.join(state, `.fm-playbot-check.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`);
  try {
    fs.writeFileSync(tmp, contents, { encoding: "utf8", mode });
    // writeFileSync's mode is masked by the umask this server inherited, and
    // fm-check-register.sh requires the check to be exactly 0700, so the mode
    // is set explicitly rather than requested.
    fs.chmodSync(tmp, mode);
    fs.renameSync(tmp, target);
  } catch (error) {
    fs.rmSync(tmp, { force: true });
    supervisionRefuse(`could not write ${target}: ${error instanceof Error ? error.message : String(error)}`);
  }
  return target;
}

function supervisionReadSidecarText(state, taskId) {
  try {
    return fs.readFileSync(supervisionSidecarPath(state, taskId), "utf8");
  } catch {
    return null;
  }
}

function supervisionReadSidecar(state, taskId) {
  const text = supervisionReadSidecarText(state, taskId);
  if (text === null) return null;
  const lines = text.split("\n");
  if (!lines[1]) return null;
  if (lines[0] === SUPERVISION_SIDECAR_VERSION_V2) {
    return { status: lines[1], updatedAt: lines[2] ?? "", deliveryState: "unconfirmed", generation: null };
  }
  if (lines[0] === SUPERVISION_SIDECAR_VERSION_V3 && ["delivered", "unconfirmed"].includes(lines[3])) {
    return { status: lines[1], updatedAt: lines[2] ?? "", deliveryState: lines[3], generation: null };
  }
  if (lines[0] === SUPERVISION_SIDECAR_VERSION_V4
    && ["delivered", "unconfirmed"].includes(lines[3])
    && /^[a-f0-9]{32}$/.test(lines[4] ?? "")) {
    return { status: lines[1], updatedAt: lines[2] ?? "", deliveryState: lines[3], generation: lines[4] };
  }
  if (lines[0] === SUPERVISION_SIDECAR_VERSION_V5) {
    if (!SUPERVISION_DELIVERY_STATES.has(lines[3])
      || !/^[a-f0-9]{32}$/.test(lines[4] ?? "")) return null;
    return { status: lines[1], updatedAt: lines[2] ?? "", deliveryState: lines[3], generation: lines[4], messageKey: null };
  }
  if (lines[0] === SUPERVISION_SIDECAR_VERSION_V6) {
    if (!SUPERVISION_DELIVERY_STATES.has(lines[3])
      || !/^[a-f0-9]{32}$/.test(lines[4] ?? "")
      || !/^(?:none|sha256:[a-f0-9]{64})$/.test(lines[5] ?? "")) return null;
    return {
      status: lines[1],
      updatedAt: lines[2] ?? "",
      deliveryState: lines[3],
      generation: lines[4],
      messageKey: lines[5] === "none" ? null : lines[5],
      acceptanceMs: null,
    };
  }
  if (lines[0] === SUPERVISION_SIDECAR_VERSION_V7) {
    if (!SUPERVISION_DELIVERY_STATES.has(lines[3])
      || !/^[a-f0-9]{32}$/.test(lines[4] ?? "")
      || !/^(?:none|sha256:[a-f0-9]{64})$/.test(lines[5] ?? "")
      || !/^(?:none|[0-9]+)$/.test(lines[6] ?? "")) return null;
    return {
      status: lines[1],
      updatedAt: lines[2] ?? "",
      deliveryState: lines[3],
      generation: lines[4],
      messageKey: lines[5] === "none" ? null : lines[5],
      acceptanceMs: lines[6] === "none" ? null : Number(lines[6]),
      threadKey: null,
    };
  }
  if (lines[0] !== SUPERVISION_SIDECAR_VERSION
    || !SUPERVISION_DELIVERY_STATES.has(lines[3])
    || !/^[a-f0-9]{32}$/.test(lines[4] ?? "")
    || !/^(?:none|sha256:[a-f0-9]{64})$/.test(lines[5] ?? "")
    || !/^(?:none|[0-9]+)$/.test(lines[6] ?? "")
    || !/^(?:none|sha256:[a-f0-9]{64})$/.test(lines[7] ?? "")) return null;
  return {
    status: lines[1],
    updatedAt: lines[2] ?? "",
    deliveryState: lines[3],
    generation: lines[4],
    messageKey: lines[5] === "none" ? null : lines[5],
    acceptanceMs: lines[6] === "none" ? null : Number(lines[6]),
    threadKey: lines[7] === "none" ? null : lines[7],
  };
}

function supervisionCheckLockAcquire(state, taskId) {
  const helper = path.join(path.dirname(supervisionSelfScript()), "fm-check-publish-lock.sh");
  return new Promise((resolve, reject) => {
    const child = spawn(helper, [state, taskId], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (error = null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve({ child });
    };
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      finish(new Error(`timed out acquiring the shared publication lock for state/${taskId}.check.sh`));
    }, 6_500);
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      if (stdout === "locked\n") finish();
      else if (stdout.includes("\n")) {
        child.kill("SIGTERM");
        finish(new Error(`could not verify the shared publication lock for state/${taskId}.check.sh`));
      }
    });
    child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    child.once("error", (error) => finish(new Error(`could not acquire the shared publication lock for state/${taskId}.check.sh: ${supervisionErrorDetail(error)}`)));
    child.once("exit", (status) => {
      if (!settled) finish(new Error(`could not acquire the shared publication lock for state/${taskId}.check.sh: ${stderr.trim() || `exit ${status}`}`));
    });
  });
}

function supervisionCheckLockRelease(held, taskId) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (problem) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(problem);
    };
    const timer = setTimeout(() => {
      held.child.kill("SIGKILL");
      finish(`timed out releasing the shared publication lock for state/${taskId}.check.sh`);
    }, 2_000);
    held.child.once("exit", (status) => finish(status === 0 ? null : `could not release the shared publication lock for state/${taskId}.check.sh: exit ${status}`));
    held.child.once("error", (error) => finish(`could not release the shared publication lock for state/${taskId}.check.sh: ${supervisionErrorDetail(error)}`));
    held.child.stdin.end("release\n");
  });
}

async function supervisionWithCheckLock(state, taskId, callback) {
  const held = await supervisionCheckLockAcquire(state, taskId);
  let result;
  let problem = null;
  try {
    result = await callback();
  } catch (error) {
    problem = error;
  }
  const releaseProblem = await supervisionCheckLockRelease(held, taskId);
  if (problem) {
    const detail = supervisionErrorDetail(problem);
    supervisionRefuse(releaseProblem ? `${detail}; ${releaseProblem}` : detail);
  }
  if (releaseProblem) supervisionRefuse(releaseProblem);
  return result;
}

// Retire exactly what arming created. The merged-PR poll retires itself the same
// way through fm_pr_poll_retirement_publish, and for the same reason: a check
// nothing will act on again must stop being armed rather than re-waking
// firstmate every check interval for news it has already handled.
function supervisionRetire(state, taskId) {
  const checkName = `${taskId}.check.sh`;
  const checkPath = path.join(state, checkName);
  try {
    fs.rmSync(checkPath, { force: true });
    try {
      fs.lstatSync(checkPath);
      return { checkRemoved: false, problems: [`${checkName}: removal reported success but the check still exists`] };
    } catch (error) {
      if (!(error instanceof Error) || error.code !== "ENOENT") {
        return { checkRemoved: false, problems: [`${checkName}: could not confirm removal: ${error instanceof Error ? error.message : String(error)}`] };
      }
    }
  } catch (error) {
    return { checkRemoved: false, problems: [`${checkName}: ${error instanceof Error ? error.message : String(error)}`] };
  }

  const problems = [];
  // The executable check is what fires, so its trust binding and observed-state
  // record are removed only after the check is confirmed gone. If check removal
  // fails, leaving all three artifacts intact keeps the poll armed and registered
  // instead of turning it into a rejected unauthenticated check on every sweep.
  for (const name of [`${taskId}.check-trust`, `${taskId}.lane-poll`]) {
    try {
      fs.rmSync(path.join(state, name), { force: true });
    } catch (error) {
      problems.push(`${name}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return { checkRemoved: true, problems };
}

// Write the sidecar and bind the check, in that order, so a poll can never run
// against a state directory that has no record of what it last saw.
function supervisionBind({ state, taskId, register, observation }) {
  try {
    supervisionWriteSidecar(state, taskId, observation);
  } catch (error) {
    return { ok: false, detail: `the poll's observed-state record could not be written: ${error instanceof Error ? error.message : String(error)}` };
  }
  const registration = supervisionRegister(taskId, register);
  if (!registration.ok) {
    return { ok: false, detail: `fm-check-register.sh refused to bind state/${taskId}.check.sh: ${registration.detail}` };
  }
  return { ok: true, detail: registration.detail };
}

// A failed arming must never leave the task with LESS supervision than it had.
// fm-check-register.sh removes the trust file when its own final verify fails,
// so even an identical-bytes re-arm has to be restored and rebound; only an
// arming that created the check from nothing removes it outright.
function supervisionRestore({ state, taskId, register, existed, previousCheck, previousSidecar }) {
  try {
    if (existed) {
      supervisionWriteCheck(state, taskId, previousCheck);
      if (previousSidecar === null) fs.rmSync(supervisionSidecarPath(state, taskId), { force: true });
      else supervisionPublish(state, `${taskId}.lane-poll`, previousSidecar, 0o600);
      const registration = supervisionRegister(taskId, register);
      if (!registration.ok) return { ok: false, detail: `restoration re-registration failed: ${registration.detail}` };
      return { ok: true, detail: registration.detail };
    }
    fs.rmSync(path.join(state, `${taskId}.check.sh`), { force: true });
    fs.rmSync(supervisionSidecarPath(state, taskId), { force: true });
    return { ok: true, detail: "removed the unbound replacement" };
  } catch (error) {
    return { ok: false, detail: `restoration failed: ${error instanceof Error ? error.message : String(error)}` };
  }
}

// The accepted row is recorded before the poll ever runs so its task-specific
// activity boundary separates this turn from any turn that finished before it.
function supervisionArmingBaseline(worker) {
  return {
    status: String(worker.agent_status ?? "unknown"),
    updatedAt: String(worker.updated_at ?? ""),
    acceptanceMs: supervisionTimestampMs(worker.last_user_activity_at),
    threadKey: supervisionThreadKey(worker.thread_id),
  };
}

function supervisionArmingObservation(baseline, delivery, generation) {
  return {
    ...baseline,
    deliveryState: delivery?.state === "steering" ? "delivered" : supervisionDeliveryState(delivery?.state),
    messageKey: supervisionMessageKey(delivery?.messageId),
    acceptanceMs: baseline.acceptanceMs ?? null,
    generation,
  };
}

async function supervisionPrepareRecall(threadId, messageId) {
  const messageKey = supervisionMessageKey(messageId);
  const threadKey = supervisionThreadKey(threadId);
  if (!messageKey || !threadKey) return [];
  const state = path.join(controllerRoot(), "state");
  let stat;
  try {
    stat = fs.lstatSync(state);
  } catch {
    return [];
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) return [];
  const tasks = fs.readdirSync(state)
    .filter((name) => name.endsWith(".lane-poll"))
    .map((name) => name.slice(0, -".lane-poll".length))
    .filter(supervisionTaskIdValid)
    .filter((taskId) => {
      const previous = supervisionReadSidecar(state, taskId);
      return previous?.threadKey === threadKey
        && previous.messageKey === messageKey
        && ["queued", "sending"].includes(previous.deliveryState);
    });
  const prepared = [];
  for (const taskId of tasks) {
    await supervisionWithCheckLock(state, taskId, () => {
      const previous = supervisionReadSidecar(state, taskId);
      if (!previous
        || previous.messageKey !== messageKey
        || previous.threadKey !== threadKey
        || !["queued", "sending"].includes(previous.deliveryState)) return;
      supervisionWriteSidecar(state, taskId, { ...previous, deliveryState: "recall-pending" });
      prepared.push({
        state,
        taskId,
        generation: previous.generation,
        messageKey,
        threadKey,
        deliveryState: previous.deliveryState,
        acceptanceMs: previous.acceptanceMs,
      });
    });
  }
  return prepared;
}

async function supervisionResolveRecall(prepared, outcome, threadId) {
  const problems = [];
  let row = null;
  if (outcome === "not-recallable") {
    try {
      row = threadRowById(threadId);
    } catch {
      row = null;
    }
  }
  for (const item of prepared) {
    try {
      const rolloutAcceptanceMs = outcome === "not-recallable"
        && item.threadKey === supervisionThreadKey(row?.thread_id)
        ? supervisionRolloutAcceptanceMs(row, item.messageKey, item.acceptanceMs)
        : null;
      await supervisionWithCheckLock(item.state, item.taskId, () => {
        const current = supervisionReadSidecar(item.state, item.taskId);
        if (!current
          || current.generation !== item.generation
          || current.messageKey !== item.messageKey
          || current.threadKey !== item.threadKey
          || current.deliveryState !== "recall-pending") return;
        const deliveryState = outcome === "recalled"
          ? "recalled"
          : outcome === "not-recallable" && rolloutAcceptanceMs !== null
            ? "delivered"
            : outcome === "not-recallable" ? item.deliveryState : "recall-pending";
        const acceptanceMs = rolloutAcceptanceMs === null
          ? current.acceptanceMs
          : Math.max(current.acceptanceMs ?? rolloutAcceptanceMs, rolloutAcceptanceMs);
        supervisionWriteSidecar(item.state, item.taskId, { ...current, deliveryState, acceptanceMs });
      });
    } catch (error) {
      problems.push(`state/${item.taskId}.lane-poll: ${supervisionErrorDetail(error)}`);
    }
  }
  return problems;
}

// Arm one worker's watcher poll and report exactly what happened. Never throws
// into the caller's dispatch: the send has already reached Playbot by the time
// this runs, so a failure here is reported loudly in the result rather than
// turning a completed dispatch into an error.
async function armSupervisionPoll({ requestedTaskId, worker, baseline = null, delivery = null }) {
  const taskId = requestedTaskId ?? worker.workspace_id;
  const taskIdSource = requestedTaskId ? "argument" : "workspace-id";
  const report = {
    mode: "poll",
    tools: SUPERVISION_TOOLS,
    taskId,
    taskIdSource,
    thread: worker.thread_id,
    check: supervisionTaskIdValid(taskId) ? `state/${taskId}.check.sh` : null,
    armed: false,
  };
  try {
    if (!supervisionTaskIdValid(taskId)) {
      supervisionRefuse(`'${taskId}' cannot key a watcher poll; pass taskId as a firstmate task id of up to 64 characters from A-Z, a-z, 0-9, dot, dash, and underscore, not starting with a dot`);
    }
    if (!/^[A-Za-z0-9._-]{1,200}$/.test(String(worker.thread_id))) {
      supervisionRefuse(`Playbot thread id '${worker.thread_id}' is not a shape this generated check can carry`);
    }
    const state = supervisionStateDir();
    const script = supervisionSelfScript();
    const register = path.join(path.dirname(script), "fm-check-register.sh");
    const lockHelper = path.join(path.dirname(script), "fm-check-publish-lock.sh");
    if (!fs.existsSync(register) || !fs.existsSync(lockHelper)) {
      supervisionRefuse(`the watcher's registration or publication-lock helper is missing beside ${script}, so no poll was armed`);
    }
    const generation = crypto.randomBytes(16).toString("hex");
    const desired = supervisionCheckScript({
      taskId,
      threadId: worker.thread_id,
      generation,
      nodeBin: supervisionPath(process.execPath, "the Node runtime"),
      scriptPath: supervisionPath(script, "this server's script"),
      desktop: supervisionPath(desktopDir(), "the Playbot desktop directory"),
      state: supervisionPath(state, "the controller's state directory"),
    });
    const bound = await supervisionWithCheckLock(state, taskId, () => {
      const target = path.join(state, `${taskId}.check.sh`);
      let previous = null;
      let existed = false;
      let stat = null;
      try {
        stat = fs.lstatSync(target);
      } catch {
        stat = null;
      }
      if (stat) {
        if (!stat.isFile() || stat.isSymbolicLink()) {
          supervisionRefuse(`state/${taskId}.check.sh exists and is not a regular file, so it was left untouched`);
        }
        const text = fs.readFileSync(target, "utf8");
        if (!supervisionCheckIsOurs(text)) {
          supervisionRefuse(`state/${taskId}.check.sh already holds a check this server did not generate, so it was left untouched; dispatch with a different taskId or retire that check first`);
        }
        existed = true;
        previous = text;
        report.rearmed = true;
      }
      const previousSidecar = existed ? supervisionReadSidecarText(state, taskId) : null;
      if (previous !== desired) supervisionWriteCheck(state, taskId, desired);
      const observation = supervisionArmingObservation(baseline ?? supervisionArmingBaseline(worker), delivery, generation);
      const registration = supervisionBind({ state, taskId, register, observation });
      if (!registration.ok) {
        const restored = supervisionRestore({ state, taskId, register, existed, previousCheck: previous, previousSidecar });
        supervisionRefuse(restored.ok ? registration.detail : `${registration.detail}; ${restored.detail}`);
      }
      return registration;
    });
    report.armed = true;
    report.registration = bound.detail;
    report.firesOn = "the worker parking on a card, and the change into stopping without one or becoming unreadable";
    report.silentWhile = "working, and after it has reported a worker that finished";
    report.retiresOn = "after proven delivery, reporting a worker that stopped or became unreadable, which removes the check, its trust binding, and its observed-state record; failed, recalled, or unconfirmed delivery stays armed";
    report.note = taskIdSource === "workspace-id"
      ? "No taskId was given, so the poll is keyed on the workspace id and firstmate's task teardown will not retire it; retire it by hand when the work lands."
      : "Firstmate's task teardown retires this poll with the task.";
    return report;
  } catch (error) {
    report.armed = false;
    report.problem = error instanceof Error ? error.message : String(error);
    return report;
  }
}

function supervisionArmWarning(report) {
  return `SUPERVISION NOT ARMED: this worker was dispatched and nothing is polling it. ${report.problem} Arm a poll before relying on a wake, or supervise it by hand with ${SUPERVISION_TOOLS.join(", ")}.`;
}

// --- The armed poll itself ---------------------------------------------------
//
// Runs as the watcher's per-task check, once per check interval, from the
// generated script above. It reads persisted Playbot state only: it contacts
// Playbot not at all, resumes nothing, and starts no turn, which is what keeps a
// per-task poll cheap enough for the watcher to run unattended.
//
// A persisted pending_input is a CANDIDATE, never proof: Playbot's own
// restorePersistedAgentStatus collapses working into pending_input for a merely
// database-hydrated chat, so the wake line says so and names get_thread_card as
// the confirming read, exactly as list_parked_threads does.

function supervisionOneLine(text, max = 400) {
  const value = String(text ?? "").replace(/\s+/g, " ").trim();
  return value.length <= max ? value : `${value.slice(0, max - 12)} [truncated]`;
}

function supervisionHeldClause(queued) {
  if (queued === null) return ", held messages unreadable";
  if (queued > 0) return `, ${queued} held message${queued === 1 ? "" : "s"}`;
  return "";
}

function supervisionRolloutAcceptanceMs(row, messageKey, acceptanceMs) {
  if (typeof row?.session_id !== "string" || !row.session_id || !messageKey || !Number.isFinite(acceptanceMs)) return null;
  let session;
  try {
    session = codexSession(row.session_id);
  } catch {
    return null;
  }
  if (!session?.rollout_path || !fs.existsSync(session.rollout_path)) return null;
  const inspect = (bytes) => {
    if (bytes.length === 0) return null;
    let record;
    try {
      record = JSON.parse(bytes.toString("utf8").replace(/\r$/, ""));
    } catch {
      return null;
    }
    const timestampMs = supervisionTimestampMs(record.timestamp);
    if (timestampMs !== null && timestampMs < acceptanceMs) return { stop: true, acceptanceMs: null };
    const payload = record.type === "event_msg" ? record.payload : null;
    if (payload?.type !== "user_message" || timestampMs === null) return null;
    return supervisionMessageKey(payload.client_id) === messageKey
      ? { stop: true, acceptanceMs: timestampMs }
      : null;
  };
  let fd;
  try {
    fd = fs.openSync(session.rollout_path, "r");
    let position = fs.fstatSync(fd).size;
    let carry = Buffer.alloc(0);
    const chunk = Buffer.alloc(64 * 1024);
    while (position > 0) {
      const length = Math.min(chunk.length, position);
      position -= length;
      fs.readSync(fd, chunk, 0, length, position);
      const data = carry.length > 0
        ? Buffer.concat([chunk.subarray(0, length), carry])
        : chunk.subarray(0, length);
      let lineEnd = data.length;
      let newline;
      while ((newline = data.lastIndexOf(0x0a, lineEnd - 1)) >= 0) {
        const result = inspect(data.subarray(newline + 1, lineEnd));
        if (result?.stop) return result.acceptanceMs;
        lineEnd = newline;
      }
      carry = Buffer.from(data.subarray(0, lineEnd));
    }
    return inspect(carry)?.acceptanceMs ?? null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

// A finished worker is news exactly once, so a stop is reported on the CHANGE
// into it and the poll then retires itself. A worker that is still parked is a
// standing condition rather than a transition and keeps firing every interval,
// because it genuinely still needs its supervisor.
//
// The change is decided against status and updated_at beyond the task-specific
// activity boundary. That keeps a prior turn's completion out of this task while
// retaining a ready-to-working-to-ready completion the poll never sampled.
//
// Retirement is irreversible - there is no re-arm tool - so it may only ever
// happen once the worker has actually RECEIVED its task. A dispatch onto a busy
// chat is held in Playbot's queue, and that worker's earlier turn can end before
// the queue drains, so an idle worker with a held message has not stopped: its
// task has not started, and the poll stays armed. A queue that cannot be read
// counts the same way, because unreadable is not proof of delivery, and keeping
// a poll armed costs one wake while dropping one costs the supervision entirely.
//
// Every branch that can print fires on a DIFFERENCE from the last observation
// and never on a condition merely still being true, so an undrained queue is
// reported when it appears and then stays quiet. The single exception is
// pending_input, which keeps firing every interval on purpose: a parked card is
// resolved by the supervisor answering it, so that repeated wake is actionable
// where a queue firstmate has already seen is not.
function supervisionPollDecision(taskId, threadId, previous) {
  const row = threadRowById(threadId);
  const messages = row ? queuedMessages(row.pending_queue_json) : [];
  const queued = messages === null ? null : messages.length;
  const taskQueued = Array.isArray(messages)
    && previous?.messageKey
    && messages.some((message) => supervisionMessageKey(message?.id) === previous.messageKey);
  const status = row ? supervisionField(row.agent_status ?? "unknown") : SUPERVISION_ABSENT;
  const updatedAt = row ? supervisionField(row.updated_at) : "";
  const updatedAtMs = supervisionTimestampMs(updatedAt);
  const priorDelivery = supervisionDeliveryState(previous?.deliveryState);
  const previousAcceptanceMs = Number.isFinite(previous?.acceptanceMs) ? previous.acceptanceMs : null;
  const taskBoundToThread = previous?.messageKey
    && previous?.threadKey === supervisionThreadKey(row?.thread_id);
  const deliveryCanAdvance = ["queued", "sending", "recall-pending"].includes(priorDelivery) && Boolean(taskBoundToThread);
  const rolloutAcceptanceMs = deliveryCanAdvance
    ? supervisionRolloutAcceptanceMs(row, previous.messageKey, previousAcceptanceMs)
    : null;
  const taskAccepted = rolloutAcceptanceMs !== null;
  const acceptanceMs = rolloutAcceptanceMs === null
    ? previousAcceptanceMs
    : Math.max(previousAcceptanceMs ?? rolloutAcceptanceMs, rolloutAcceptanceMs);
  const afterAcceptance = acceptanceMs !== null && updatedAtMs > acceptanceMs;
  const deliveryState = deliveryCanAdvance && taskAccepted
    ? "delivered"
    : priorDelivery;
  const delivered = deliveryState === "delivered";
  const observed = {
    status,
    updatedAt,
    deliveryState,
    messageKey: previous?.messageKey ?? null,
    acceptanceMs,
    threadKey: previous?.threadKey ?? null,
    generation: previous?.generation ?? null,
  };
  if (status === "working") return { ...observed, line: null, retire: false, remember: true };
  const held = supervisionHeldClause(queued);
  if (status === "pending_input") {
    return {
      ...observed,
      line: `playbot lane ${taskId}: worker ${threadId} may be parked on a card${held}; confirm with get_thread_card before answering anything`,
      retire: false,
      remember: true,
    };
  }
  const changed = !supervisionSameObservation(previous, observed);
  if (!changed && !(delivered && row && afterAcceptance)) {
    return { ...observed, line: null, retire: false, remember: false };
  }
  if (!delivered) {
    let unreadable;
    let delivery;
    if (!row) {
      unreadable = `worker chat ${threadId} is no longer readable in Playbot state while task delivery is ${priorDelivery}`;
      delivery = "the worker may not have seen the task";
    } else if (queued === null) {
      unreadable = `worker ${threadId} is idle (status ${status}) with its task queue unreadable${held}`;
      delivery = "the worker may not have seen the task";
    } else if (taskQueued) {
      unreadable = `worker ${threadId} is idle (status ${status}) with its dispatched task still queued${held}`;
      delivery = "the worker has not seen it and has not started";
    } else if (queued > 0) {
      unreadable = `worker ${threadId} is idle (status ${status}) with other messages still queued${held} while task delivery remains ${priorDelivery}`;
      delivery = "the worker may not have seen the task";
    } else {
      unreadable = `worker ${threadId} is idle (status ${status}) while task delivery remains ${priorDelivery}`;
      delivery = priorDelivery === "failed"
        ? "Playbot reported that the task was not sent"
        : ["recall-pending", "recalled"].includes(priorDelivery)
          ? "the task was recalled or its recall is still being resolved"
          : "the worker may not have seen the task";
    }
    return {
      ...observed,
      line: `playbot lane ${taskId}: ${unreadable}, so ${delivery}; this poll stays armed, and list_queued_messages reads the queue`,
      retire: false,
      remember: true,
    };
  }
  if (row && acceptanceMs !== null && !afterAcceptance) {
    return { ...observed, line: null, retire: false, remember: true };
  }
  const stopped = row
    ? `playbot lane ${taskId}: worker ${threadId} stopped without a card (status ${status})${held}`
    : `playbot lane ${taskId}: worker chat ${threadId} is no longer readable in Playbot state (archived or removed)`;
  return { ...observed, line: stopped, retire: true, remember: false };
}

function supervisionPollArgs(argv) {
  const values = { task: null, thread: null, state: null, generation: null };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag !== "--task" && flag !== "--thread" && flag !== "--state" && flag !== "--generation") throw new Error(`unrecognized argument: ${flag}`);
    const value = argv[index + 1];
    if (value === undefined) throw new Error(`${flag} requires a value`);
    values[flag.slice(2)] = value;
    index += 1;
  }
  if (!values.task || !values.thread || !values.state) {
    throw new Error("--task, --thread and --state are all required; re-arm this poll through dispatch");
  }
  if (!supervisionTaskIdValid(values.task)) throw new Error(`'${values.task}' cannot key a watcher poll`);
  if (values.generation !== null && !/^[a-f0-9]{32}$/.test(values.generation)) throw new Error("--generation is not a valid poll generation");
  return values;
}

// The watcher discards this poll's stderr and exit code and wakes on stdout
// alone, so every failure is reported as the single stdout line too. A poll that
// crashed silently would read as "nothing to report", which is the exact silence
// this whole surface exists to remove.
async function supervisionPoll(argv) {
  let taskId = null;
  try {
    const { task, thread, state, generation } = supervisionPollArgs(argv);
    taskId = task;
    const result = await supervisionWithCheckLock(state, task, () => {
      const previous = supervisionReadSidecar(state, task);
      if (!previous) {
        return { line: `playbot lane ${task}: supervision poll failed: its observed-state record is unreadable, so this check remains armed` };
      }
      if ((previous.generation ?? null) !== generation) return { line: null };
      try {
        const decision = supervisionPollDecision(task, thread, previous);
        let line = decision.line;
        if (decision.retire) {
          const retirement = supervisionRetire(state, task);
          if (!retirement.checkRemoved) {
            line = `${line}; retirement failed and this check is still armed: ${retirement.problems.join("; ")}`;
          } else {
            line = `${line}; this poll has retired itself`;
            if (retirement.problems.length > 0) {
              line = `${line}; the executable check was removed, but cleanup left orphaned artifacts: ${retirement.problems.join("; ")}`;
            }
          }
        } else if (decision.remember && !supervisionSameObservation(previous, decision)) {
          try {
            supervisionWriteSidecar(state, task, decision);
          } catch (error) {
            const detail = supervisionErrorDetail(error);
            line = line
              ? `${line}; the poll could not record this observation: ${detail}`
              : `playbot lane ${task}: worker ${thread} is working, but the poll could not record that observation, so it cannot tell a finished worker from a still-running one: ${detail}`;
          }
        }
        return { line };
      } catch (error) {
        const detail = supervisionErrorDetail(error);
        let line = `playbot lane ${task}: worker ${thread} is unreadable because the supervision poll failed: ${detail}`;
        if (previous.deliveryState === "delivered") {
          const retirement = supervisionRetire(state, task);
          if (!retirement.checkRemoved) {
            line = `${line}; the task was delivered, but retirement failed and this check is still armed: ${retirement.problems.join("; ")}`;
          } else {
            line = `${line}; the task was delivered, so this poll has retired itself`;
            if (retirement.problems.length > 0) {
              line = `${line}; the executable check was removed, but cleanup left orphaned artifacts: ${retirement.problems.join("; ")}`;
            }
          }
        } else {
          const observed = { status: "poll-unreadable", updatedAt: "", deliveryState: previous.deliveryState, messageKey: previous.messageKey ?? null, acceptanceMs: previous.acceptanceMs ?? null, threadKey: previous.threadKey ?? null, generation };
          if (supervisionSameObservation(previous, observed)) return { line: null };
          line = `${line}; task delivery or its queue is unconfirmed, so this poll stays armed`;
          try {
            supervisionWriteSidecar(state, task, observed);
          } catch (writeError) {
            line = `${line}; the poll could not record this observation: ${supervisionErrorDetail(writeError)}`;
          }
        }
        return { line };
      }
    });
    if (result.line) console.log(supervisionOneLine(result.line));
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.log(supervisionOneLine(`playbot lane ${taskId ?? "unknown"}: supervision poll failed: ${detail}`));
  }
}

function bounded(text, max = 4_000) {
  const value = String(text ?? "").trim();
  return value.length <= max ? value : `${value.slice(0, max)}\n[truncated]`;
}

// A persisted route is read back on every hook run and returned verbatim by
// list_lanes, so one writer owns the whole last-notification record: every field
// describing a notification is set or removed together here, and no field from
// an earlier one survives to contradict the wake beside it.
function recordNotified(route, worker, eventId, deliveryState, error = null) {
  return updateRouteFile(routePath(route.id), false, (current) => {
    if (current.active !== true) return null;
    current.lastNotifiedTurnId = eventId;
    current.lastNotifiedAt = nowIso();
    current.lastNotifiedDelivery = deliveryState;
    if (error) current.lastNotifiedError = error;
    else delete current.lastNotifiedError;
    current.updatedAt = nowIso();
    current.worker = publicThread(worker);
    return current;
  });
}

async function processStop(payload) {
  const sessionId = payload.session_id ?? payload.sessionId;
  if (!sessionId) return { matched: 0, notified: 0 };
  const worker = rowForSession(sessionId);
  if (!worker) return { matched: 0, notified: 0 };
  const matches = loadRoutes().filter((route) => route.active && route.worker?.id === worker.thread_id);
  let notified = 0;
  // A routed worker must stay wakeable wherever its chat lives, exactly as
  // rowForSession found it, so this is the exact-id accessor rather than the
  // scoped one, and an unreadable row ends the run instead of throwing through
  // the routes still waiting to be processed.
  const currentWorker = threadRowById(worker.thread_id);
  if (!currentWorker) return { matched: matches.length, notified };
  for (const route of matches) {
    const conversation = recentConversation(currentWorker, 2);
    const completedTurnId = conversation.completion?.turnId ?? null;
    let eventId = completedTurnId;
    let eventKind = "completed turn";
    if (!eventId || route.lastNotifiedTurnId === eventId) {
      if (currentWorker.agent_status !== "pending_input") continue;
      eventId = `pending:${currentWorker.updated_at}`;
      eventKind = "input request";
    }
    if (route.lastNotifiedTurnId === eventId) continue;
    // A registered supervisor is addressed by exact id and stays wakeable
    // wherever it lives, so this is the exact-id accessor too.
    const supervisor = threadRowById(route.supervisor?.id);
    if (!supervisor || supervisor.thread_id === currentWorker.thread_id) continue;
    const message = [
      WAKE_PREFIX,
      `Lane: ${route.id}`,
      `Worker: ${currentWorker.project_name} / ${currentWorker.title} (${currentWorker.thread_id})`,
      `Worker event: ${eventKind} ${eventId}`,
      `Persisted status: ${currentWorker.agent_status ?? "unknown"}`,
      "Result:",
      bounded(conversation.finalAnswer ?? "The worker completed without a persisted final message."),
      "Read or continue the worker through the playbot_lanes MCP tools.",
    ].join("\n");
    try {
      let delivery = null;
      if (process.env.PLAYBOT_LANES_DRY_RUN === "1") {
        atomicWriteJson(path.join(stateDir(), "last-dry-run-wake.json"), {
          at: nowIso(),
          routeId: route.id,
          supervisorThreadId: supervisor.thread_id,
          workerThreadId: currentWorker.thread_id,
          turnId: eventId,
          message,
        });
      } else {
        ({ delivery } = await sendMessage(supervisor, message));
      }
      // A wake Playbot rejected must stay eligible for retry. Nothing throws on
      // a rejection, so recording the turn as notified would suppress it
      // permanently and leave no trace anywhere. A queued wake is fine: Playbot
      // delivers it when the controller's turn frees up.
      if (delivery?.state === "failed") {
        atomicWriteJson(path.join(stateDir(), "last-hook-error.json"), {
          at: nowIso(),
          routeId: route.id,
          workerThreadId: currentWorker.thread_id,
          turnId: eventId,
          delivery,
          error: `Playbot rejected the lane wake: ${delivery.reason ?? "no reason reported"}`,
        });
        continue;
      }
      // "unknown" means opposite things on the two Playbot generations, so it is
      // classified with the detection the adapter already has rather than a new
      // probe: on a pre-0.94 Playbot threads:send returns nothing, so unknown is
      // the normal, information-free result and the wake must advance; on a
      // Playbot whose send path CAN report a verdict, unknown means it returned
      // something it should not have, which is a real anomaly. Wrongly advancing
      // loses a wake silently - the worker finishes, nobody is told, and there is
      // no retry and no error - while wrongly refusing only repeats a
      // self-announcing wake. Silent loss is the worse failure, so an
      // unclassifiable unknown stays eligible for retry and is recorded.
      // The detection is resolved into a local here rather than awaited inside
      // the branch: the send has already returned, so a throw from the probe is
      // not a send failure and must not be recorded as one.
      let legacySendPath = false;
      let detectionError = null;
      if (delivery?.state === "unknown") {
        try {
          legacySendPath = await chatCreationApi() === "openThread";
        } catch (error) {
          detectionError = error instanceof Error ? error.message : String(error);
        }
      }
      if (delivery?.state === "unknown" && !legacySendPath) {
        const unconfirmed = detectionError
          ? `Playbot returned no thread snapshot for the lane wake, and the chat-creation detection that would say whether this Playbot can report a verdict at all failed: ${detectionError}`
          : "Playbot returned no thread snapshot for the lane wake, so delivery is unconfirmed on a Playbot whose send path reports a verdict";
        atomicWriteJson(path.join(stateDir(), "last-hook-error.json"), {
          at: nowIso(),
          routeId: route.id,
          workerThreadId: currentWorker.thread_id,
          turnId: eventId,
          delivery,
          error: `${unconfirmed}. Check list_queued_messages for ${supervisor.thread_id} before the next hook run resends it.`,
        });
        continue;
      }
      recordNotified(route, currentWorker, eventId, delivery?.state ?? null);
      notified += 1;
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      atomicWriteJson(path.join(stateDir(), "last-hook-error.json"), {
        at: nowIso(),
        routeId: route.id,
        workerThreadId: currentWorker.thread_id,
        turnId: eventId,
        sendReachedPlaybot: sendReachedPlaybot(error),
        error: reason,
      });
      // A send Playbot accepted counts as notified even when its verdict could
      // not be read, on the same rule that makes a queued wake a success:
      // Playbot has the message. Leaving the turn unnotified would resend the
      // identical wake on the next hook run and grow the very invisible queue
      // this surface exists to expose - a change feeding the defect it was
      // written to remove. Only a send that never reached Playbot stays
      // eligible for retry.
      if (sendReachedPlaybot(error)) {
        recordNotified(route, currentWorker, eventId, "unreadable", reason);
        notified += 1;
      }
    }
  }
  return { matched: matches.length, notified };
}

function tomlString(value) {
  return JSON.stringify(String(value));
}

function replaceTomlSection(source, sectionPrefix, replacement) {
  const lines = source.replace(/\r\n/g, "\n").split("\n");
  const output = [];
  let skipping = false;
  for (const line of lines) {
    const match = line.match(/^\s*\[([^\]]+)\]\s*$/);
    if (match) {
      skipping = match[1] === sectionPrefix || match[1].startsWith(`${sectionPrefix}.`);
      if (skipping) continue;
    }
    if (!skipping) output.push(line);
  }
  return `${output.join("\n").trimEnd()}\n\n${replacement.trim()}\n`;
}

function mergeHook(hooks, event, entry, marker) {
  hooks[event] ??= [];
  const exists = hooks[event].some((group) => (group.hooks ?? []).some((hook) => typeof hook.command === "string" && hook.command.includes(marker)));
  if (!exists) hooks[event].push(entry);
}

async function install() {
  ensurePrivateDirs();
  const script = path.resolve(process.argv[1]);
  const node = process.execPath;
  const configPath = path.join(harnessDir(), "config.toml");
  const hooksPath = path.join(harnessDir(), "hooks.json");
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  const block = [
    `[mcp_servers.${SERVER_NAME}]`,
    `command = ${tomlString(node)}`,
    `args = [${tomlString("--no-warnings")}, ${tomlString(script)}, ${tomlString("serve")}]`,
    "startup_timeout_sec = 30",
    "enabled = true",
    "",
    `[mcp_servers.${SERVER_NAME}.env]`,
    `PLAYBOT_LANES_CONTROLLER_ROOT = ${tomlString(controllerRoot())}`,
    `PLAYBOT_LANES_STATE_DIR = ${tomlString(stateDir())}`,
    `PLAYBOT_LANES_SCHEMA_VERSION = ${tomlString(MCP_SCHEMA_VERSION)}`,
  ].join("\n");
  const config = fs.existsSync(configPath) ? fs.readFileSync(configPath, "utf8") : "";
  fs.writeFileSync(configPath, replaceTomlSection(config, `mcp_servers.${SERVER_NAME}`, block), "utf8");

  const hooks = readJson(hooksPath, { hooks: {} });
  hooks.hooks ??= {};
  const commandBase = `${JSON.stringify(node)} --no-warnings ${JSON.stringify(script)}`;
  mergeHook(hooks.hooks, "PreToolUse", {
    matcher: ".*",
    hooks: [{ type: "command", command: `${commandBase} hook-pretool`, timeout: 10 }],
  }, "fm-playbot-lanes.mjs\" hook-pretool");
  mergeHook(hooks.hooks, "Stop", {
    hooks: [{ type: "command", command: `${commandBase} hook-stop`, timeout: 20 }],
  }, "fm-playbot-lanes.mjs\" hook-stop");
  atomicWriteJson(hooksPath, hooks);
  let reload = "not attempted";
  let schemaVersion = null;
  let reloadSucceeded = false;
  try {
    const servers = await playbotInvoke("codex:mcpServers:reload", undefined);
    reload = Array.isArray(servers) ? `reloaded ${servers.length} MCP server record(s)` : "reload requested";
    schemaVersion = MCP_SCHEMA_VERSION;
    reloadSucceeded = true;
  } catch (error) {
    reload = `reload deferred: ${error instanceof Error ? error.message : String(error)}`;
  }
  const installation = {
    version: 2,
    installedAt: nowIso(),
    script,
    node,
    controllerRoot: controllerRoot(),
    configPath,
    hooksPath,
    schemaVersion,
    buildIdentity: serverBuildIdentity(),
    reloadSucceeded,
  };
  atomicWriteJson(path.join(stateDir(), "installation.json"), installation);
  return { installed: true, configPath, hooksPath, stateDir: stateDir(), reload, reloadSucceeded, buildIdentity: installation.buildIdentity };
}

function installedHookStatus() {
  const hooksPath = path.join(harnessDir(), "hooks.json");
  const hooks = readJson(hooksPath, { hooks: {} });
  const commands = Object.values(hooks.hooks ?? {})
    .flatMap((groups) => Array.isArray(groups) ? groups : [])
    .flatMap((group) => Array.isArray(group.hooks) ? group.hooks : [])
    .map((hook) => typeof hook.command === "string" ? hook.command : "");
  const preToolUse = commands.filter((command) => command.includes("fm-playbot-lanes.mjs") && command.includes("hook-pretool")).length;
  const stop = commands.filter((command) => command.includes("fm-playbot-lanes.mjs") && command.includes("hook-stop")).length;
  return {
    path: hooksPath,
    preToolUse,
    stop,
    ready: preToolUse === 1 && stop === 1,
  };
}

function toolDefinitions() {
  const object = (properties = {}, required = []) => ({ type: "object", properties, required, additionalProperties: false });
  const string = (description) => ({ type: "string", description });
  const boolean = (description, defaultValue) => ({ type: "boolean", description, default: defaultValue });
  const newWorkspace = () => ({
    ...object({
      name: string("Optional workspace name; Playbot shows a generated name when omitted"),
      baseBranch: string("Optional branch the workspace worktrees are taken from; each root's default target branch when omitted"),
      branch: string("Optional name for the new working branch; generated when omitted"),
    }),
    description: "Create a new workspace first and target it. Mutually exclusive with workspace.",
  });
  return [
    {
      name: "list_projects",
      description: "List every Playbot project and workspace globally, including stable ids and root paths. Does not resume chats.",
      inputSchema: object(),
      annotations: { readOnlyHint: true },
    },
    {
      name: "list_threads",
      description: "List Playbot chats for one exact project id, root path, or unique project name. Duplicate project names are rejected.",
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name"), includeArchived: boolean("Include archived chats", false) }, ["project"]),
      annotations: { readOnlyHint: true },
    },
    {
      name: "identify_current_thread",
      description: "Identify the Playbot chat calling this MCP from its PreToolUse session marker, or report an external-terminal caller. Never guesses from the visibly selected chat.",
      inputSchema: object(),
      annotations: { readOnlyHint: true },
    },
    {
      name: "create_workspace",
      description: "Create a new Playbot workspace in one project through Playbot's own IPC, optionally from a chosen base branch. On Playbot 0.94.0 and newer this launches and immediately archives one setup chat, because workspace creation is folded into chat launch, and does not change the selected workspace; on 0.93.x Playbot marks the workspace selected within its project.",
      inputSchema: object({ project: string("Project id, root path, or unique project name"), name: string("Optional workspace name; Playbot shows a generated name when omitted"), baseBranch: string("Optional branch the workspace worktrees are taken from; each root's default target branch when omitted"), branch: string("Optional name for the new working branch; generated when omitted") }, ["project"]),
    },
    {
      name: "list_retirable_workspaces",
      description: "Inspect every active workspace in one exact project against a caller-named landing branch using current remote branch evidence, unarchived thread states, commits and subjects ahead, and exact tracked and untracked paths. Local workspaces and any workspace with uncertain evidence are reported blocked.",
      inputSchema: object({
        project: string("Project id, root path, or unique project name"),
        landingBranch: string("Explicit branch these workspaces must already be landed on; name <remote>/<branch> when a local branch has no unambiguous upstream"),
      }, ["project", "landingBranch"]),
      annotations: { readOnlyHint: true },
    },
    {
      name: "retire_workspace",
      description: "Delete one exact non-Local Playbot workspace only after immediately re-running the complete landing, thread, and Git safety inspection. Requires confirm=true, invokes workspace:delete with preserveWorktrees=false, verifies every database, directory, and Git-worktree removal, deactivates matching lane routes, and appends a private audit record.",
      inputSchema: object({
        project: string("Project id, root path, or unique project name"),
        workspace: string("Exact active workspace id from list_retirable_workspaces"),
        landingBranch: string("Explicit branch this workspace must already be landed on; use the same value just inspected"),
        confirm: { type: "boolean", const: true },
      }, ["project", "workspace", "landingBranch", "confirm"]),
      annotations: { destructiveHint: true },
    },
    {
      name: "create_chat",
      description: "Create an empty Playbot chat in one project workspace without focusing it or starting an agent turn. Can create the workspace first via newWorkspace.",
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name"), newWorkspace: newWorkspace(), title: string("Chat title"), approvalMode: { type: "string", enum: ["default", "auto-review", "full-access"] }, planMode: boolean("Create in Plan mode", false) }, ["project", "title"]),
    },
    {
      name: "send_message",
      description: `Send a message to an existing Playbot chat in any project without selecting or focusing that chat. Reports delivery from Playbot's own response: state "delivered" means the worker accepted it, "sending" means it is in flight, "queued" means Playbot is HOLDING it and the worker has not seen it, "steering" means Playbot marked the exact message for the current active turn, "failed" carries Playbot's reason, and "unknown" means delivery could not be confirmed. force=true explicitly promotes a queued message into the active turn through Playbot ${VERIFIED_PLAYBOT_VERSIONS} threads:steerMessage without interrupting that turn; it does not answer a pending card. Never treat a queued or unknown send as delivered.`,
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project's active workspaces"), thread: string("Thread id, Codex session id, or unique exact title"), message: string("Message to send"), force: boolean("Promote this exact message into a currently active turn instead of leaving it queued; Playbot 0.95.x only", false) }, ["project", "thread", "message"]),
    },
    {
      name: "read_thread",
      description: "Read a bounded recent Playbot conversation directly from its persisted Codex rollout without resuming the chat.",
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project's active workspaces"), thread: string("Thread id, Codex session id, or unique exact title"), turnLimit: { type: "integer", minimum: 1, maximum: 30, default: 8 } }, ["project", "thread"]),
      annotations: { readOnlyHint: true },
    },
    {
      name: "get_thread_status",
      description: "Get one Playbot chat's persisted status and route membership without resuming it.",
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project's active workspaces"), thread: string("Thread id, Codex session id, or unique exact title") }, ["project", "thread"]),
      annotations: { readOnlyHint: true },
    },
    {
      name: "list_parked_threads",
      description: `Cheap detector for chats that may be parked on a question or approval card, read from persisted state without resuming any chat or focusing the Playbot window. These are CANDIDATES only: Playbot reports a merely rehydrated chat's status as pending_input even when it is not parked, so confirm each one with get_thread_card before acting. Verified against Playbot ${VERIFIED_PLAYBOT_VERSIONS}.`,
      inputSchema: object({ project: string("Optional project id, root path, or unique project name; every project when omitted") }),
      // The only one of the three card reads that is genuinely side-effect-free:
      // it never contacts Playbot. get_thread_card and list_queued_messages
      // deliberately carry no readOnlyHint, because that hint is what lets a
      // client call a tool freely without approval, and the resume those two
      // perform is the exact cost this cheap persisted detector exists to keep
      // off an unbounded poll.
      annotations: { readOnlyHint: true },
    },
    {
      name: "get_thread_card",
      description: `Read the pending question, approval, and MCP cards for one named chat, with every question's exact text and option labels, plus its live queued messages. Addresses the chat explicitly and never acts on the visibly selected one. This is the confirming read for list_parked_threads and it RESUMES a chat that has not been resumed since Playbot started, exactly as opening that chat in the Playbot window does; it starts no agent turn. Uses Playbot ${VERIFIED_PLAYBOT_VERSIONS} internal IPC and refuses if the channel or snapshot shape has changed.`,
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project's active workspaces"), thread: string("Thread id, Codex session id, or unique exact title") }, ["project", "thread"]),
    },
    {
      name: "answer_thread_card",
      description: `Answer one named chat's pending question card, the same call Playbot makes when a human clicks an option. Re-reads the chat's live cards first and refuses unless requestId is pending on THAT chat, because Playbot resolves a request id globally and a mismatched pair would answer another worker's card. Pass each answer as the option label exactly as get_thread_card reported it, byte for byte and untrimmed, or as free text where the question allows it, or skip=true to skip the card. Answering only some of a multi-question card is allowed, as it is in Playbot, and is reported as partial with the question ids that received no answer. A response Playbot already had in flight is reported rather than refused. Uses Playbot ${VERIFIED_PLAYBOT_VERSIONS} internal IPC.`,
      inputSchema: object({
        project: string("Project id, root path, or unique project name"),
        workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project's active workspaces"),
        thread: string("Thread id, Codex session id, or unique exact title"),
        requestId: { description: "Pending question requestId exactly as get_thread_card returned it", type: ["integer", "string"] },
        answers: { description: "Answer per question id: the exact option label, free text, or an array of either", type: "object", additionalProperties: { type: ["string", "array"], items: { type: "string" } } },
        skip: boolean("Skip the card without choosing any option; answers must then be omitted", false),
        expectTurnId: string("Refuse unless the card still belongs to this turn id"),
        expectItemId: string("Refuse unless the card still belongs to this tool-call item id"),
      }, ["project", "thread", "requestId"]),
    },
    {
      name: "list_queued_messages",
      description: `List one named chat's undelivered messages: queued, in flight, and failed. Playbot holds a message it cannot deliver yet and tells the sender nothing, so this is how a pile becomes visible. Resumes an unresumed chat the same way get_thread_card does. Uses Playbot ${VERIFIED_PLAYBOT_VERSIONS} internal IPC.`,
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project's active workspaces"), thread: string("Thread id, Codex session id, or unique exact title") }, ["project", "thread"]),
    },
    {
      name: "drop_queued_message",
      description: `Recall one queued or in-flight message from a named chat so a superseded instruction is removed instead of resent, the same call Playbot's own recall control makes. Returns outcome "recalled" when it was removed and "not-recallable" when it had already been delivered; neither is an error. Uses Playbot ${VERIFIED_PLAYBOT_VERSIONS} internal IPC.`,
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project's active workspaces"), thread: string("Thread id, Codex session id, or unique exact title"), messageId: string("Message id from list_queued_messages") }, ["project", "thread", "messageId"]),
    },
    {
      name: "register_lane",
      description: "Bind an existing worker chat to the current controller chat so its future completed turns wake the controller.",
      inputSchema: object({ project: string("Worker project id, root path, or unique project name"), workspace: string("Optional worker workspace id, path, or name; omit to resolve the thread anywhere in the project's active workspaces"), thread: string("Worker thread id, Codex session id, or unique exact title") }, ["project", "thread"]),
    },
    {
      name: "dispatch",
      description: `Resolve or create a worker chat by project and send the task, optionally creating an isolated workspace first. Reports the same delivery verdict as send_message, so a task Playbot is only holding is never reported as delivered. force=true has the same exact-message steering semantics when dispatch resolves an existing busy chat; a new or idle chat normally needs no promotion. A Playbot-chat caller also receives a routed Stop-hook wake. An external-terminal caller has no push path, so this call arms that worker's firstmate watcher poll itself rather than asking the caller to remember to: it writes and registers state/<taskId>.check.sh, which fires when the worker parks on a card or stops and stays silent while it works. The result's supervision block reports which path was taken and, when arming failed, says so instead of leaving an unwatched worker looking supervised.`,
      inputSchema: object({ project: string("Worker project id, root path, or unique project name"), workspace: string("Optional worker workspace id, path, or name; omit to resolve the thread anywhere in the project's active workspaces"), newWorkspace: newWorkspace(), thread: string("Optional existing worker thread id, session id, or exact title"), title: string("Title when a worker chat must be created"), message: string("Task to send"), taskId: { description: "Firstmate task id the armed watcher poll is keyed on; missing, null, or non-string values use the worker's workspace id, which arms the poll but leaves task teardown unable to retire it", type: ["string", "null", "number", "boolean", "object", "array"] }, force: boolean("Promote this exact task into a resolved existing worker's active turn instead of leaving it queued; Playbot 0.95.x only", false), approvalMode: { type: "string", enum: ["default", "auto-review", "full-access"], default: "full-access" }, planMode: boolean("Create a new worker in Plan mode", false) }, ["project", "message"]),
    },
    {
      name: "list_lanes",
      description: "List durable Playbot worker-to-controller routes and their last delivered completion turn.",
      inputSchema: object({ activeOnly: boolean("Return only active routes", true) }),
      annotations: { readOnlyHint: true },
    },
    {
      name: "close_lane",
      description: "Disable one Playbot lane without archiving either chat.",
      inputSchema: object({ laneId: string("Lane id returned by dispatch or register_lane") }, ["laneId"]),
    },
    {
      name: "archive_chat",
      description: "Archive one Playbot chat. Requires confirm=true and never archives the current controller implicitly.",
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project's active workspaces"), thread: string("Thread id, Codex session id, or unique exact title"), confirm: { type: "boolean", const: true } }, ["project", "thread", "confirm"]),
    },
  ];
}

async function handleTool(name, args = {}) {
  if (name === "identify_current_thread") {
    const row = identifyController(name);
    return row
      ? { controller: "playbot-chat", thread: publicThread(row) }
      : { controller: "external-terminal", thread: null };
  }
  const caller = controllerForTool(name);
  const projects = topology();
  if (name === "list_projects") return { projects };
  if (name === "list_lanes") return { lanes: loadRoutes().filter((route) => !args.activeOnly || route.active) };
  if (name === "close_lane") {
    const file = routePath(args.laneId);
    const route = updateRouteFile(file, false, (current) => {
      current.active = false;
      current.updatedAt = nowIso();
      return current;
    });
    return { lane: route };
  }

  if (name === "list_parked_threads") {
    const scope = args.project ? resolveProject(args.project, projects).id : null;
    // No scope-widening parameter: the confirming read this hands back has no
    // matching one, so an archived chat offered here would be a candidate
    // get_thread_card then refuses to resolve.
    const candidates = threadsForProject(scope, null)
      .filter((row) => row.agent_status === "pending_input")
      .map(publicThread);
    return {
      candidates,
      confirmWith: "get_thread_card",
      note: "Persisted status only. Playbot reports a rehydrated chat as pending_input even when it is not parked, so confirm each candidate with get_thread_card before answering anything.",
    };
  }

  const project = resolveProject(args.project, projects);
  if (name === "list_retirable_workspaces") {
    const landingBranch = String(args.landingBranch ?? "").trim();
    if (!landingBranch) throw new Error("list_retirable_workspaces requires an explicit landingBranch");
    const workspaces = project.workspaces
      .filter((workspace) => workspace.archiveState === "active")
      .map((workspace) => inspectWorkspace(project, workspace, landingBranch));
    return {
      project: { id: project.id, name: project.name },
      landingBranch,
      trackedChurnAllowlist: PLAYBOT_TRACKED_CHURN_PATHS,
      untrackedBoundary: "Untracked files are reported and block retirement; the tracked-churn allowlist never applies to them.",
      workspaces,
    };
  }
  if (name === "retire_workspace") {
    if (args.confirm !== true) throw new Error("retire_workspace requires confirm=true after a fresh list_retirable_workspaces inspection");
    const selector = typeof args.workspace === "string" ? args.workspace : "";
    if (!selector) throw new Error("retire_workspace requires one exact workspace selector from list_retirable_workspaces");
    const landingBranch = String(args.landingBranch ?? "").trim();
    if (!landingBranch) throw new Error("retire_workspace requires an explicit landingBranch");
    const workspace = resolveRetirementWorkspace(project, selector);
    return retireWorkspace(project, workspace, landingBranch);
  }
  if (name === "create_workspace") {
    return { workspace: await createWorkspace(project, args) };
  }
  if (name === "create_chat") {
    const wantsNewWorkspace = assertNewWorkspaceRequest(name, args);
    return { thread: await createChat({ project: project.id, workspace: args.workspace, newWorkspace: wantsNewWorkspace ? args.newWorkspace : undefined, title: args.title, approvalMode: args.approvalMode, planMode: args.planMode }) };
  }

  if (name === "dispatch") {
    const wantsNewWorkspace = assertNewWorkspaceRequest(name, args);
    // Validated before anything is created or sent: a taskId that cannot key a
    // check would otherwise be discovered only after the worker was already
    // working, which is the unwatched-worker case this arming exists to remove.
    // Only a string is a taskId. A JSON null is what a client sends for an
    // optional field it did not set, and coercing it would arm the literal
    // state/null.check.sh - a poll keyed on nothing teardown will ever retire,
    // which the next unset dispatch would then silently retarget off this
    // worker. An absent taskId takes the documented workspace-id fallback so a
    // poll still exists.
    const requestedTaskId = typeof args.taskId === "string" ? args.taskId : null;
    if (requestedTaskId !== null && !supervisionTaskIdValid(requestedTaskId)) {
      throw new Error(`taskId '${requestedTaskId}' cannot key a watcher poll; use a firstmate task id of up to 64 characters from A-Z, a-z, 0-9, dot, dash, and underscore, not starting with a dot`);
    }
    let worker = null;
    if (!wantsNewWorkspace) {
      if (args.thread) {
        worker = resolveThreadInProject(project, args.workspace, args.thread);
      } else if (args.title) {
        const workspace = resolveWorkspace(project, args.workspace);
        const matches = threadsForProject(project.id, workspace.id).filter((row) => row.title.toLowerCase() === String(args.title).trim().toLowerCase());
        if (matches.length > 1) throw new Error(`Ambiguous worker title '${args.title}': ${matches.map((row) => row.thread_id).join(", ")}`);
        worker = matches[0] ?? null;
      }
    }
    if (!worker) {
      const created = await createChat({ project: project.id, workspace: args.workspace, newWorkspace: wantsNewWorkspace ? args.newWorkspace : undefined, title: args.title || "Firstmate task", approvalMode: args.approvalMode || "full-access", planMode: args.planMode });
      worker = resolveThread(project.id, created.workspaceId, created.id);
    }
    const lane = caller ? registerLane(caller, worker) : null;
    const armingBaseline = caller ? null : supervisionArmingBaseline(worker);
    try {
      const { supervisionAcceptance, ...sent } = await sendMessage(worker, args.message, args.force === true);
      if (caller) {
        return {
          lane,
          ...sent,
          supervision: {
            mode: "routed-wake",
            laneId: lane.id,
            note: "This caller is a Playbot chat, so the worker's completed turns wake it through the registered lane and no watcher poll was armed.",
          },
        };
      }
      const acceptedBaseline = supervisionAcceptance?.acceptanceMs === null
        || supervisionAcceptance?.acceptanceMs === undefined
        ? null
        : supervisionAcceptance;
      const supervision = await armSupervisionPoll({
        requestedTaskId,
        worker,
        baseline: acceptedBaseline ?? { ...armingBaseline, acceptanceMs: null },
        delivery: acceptedBaseline ? sent.delivery : null,
      });
      const result = { lane: null, ...sent, supervision };
      if (!supervision.armed) result.warnings = [supervisionArmWarning(supervision)];
      return result;
    } catch (error) {
      // Only a send that never reached Playbot may tear the lane down. When the
      // send was accepted the message may already be with the worker, so the
      // route must survive to carry every later wake even though the refusal
      // still reaches the caller.
      if (lane && !sendReachedPlaybot(error)) {
        updateRouteFile(routePath(lane.id), false, (current) => {
          current.active = false;
          current.updatedAt = nowIso();
          current.error = error instanceof Error ? error.message : String(error);
          return current;
        });
      }
      // The mirror of that rule for an external-terminal caller: a send Playbot
      // ACCEPTED whose verdict could not be read still leaves a worker that may
      // be working, so it gets its poll even though the refusal reaches the
      // caller. The thrown message carries the arming outcome, because a refusal
      // has no result body to report it in.
      if (!lane && sendReachedPlaybot(error)) {
        const supervision = await armSupervisionPoll({ requestedTaskId, worker, baseline: error.supervisionAcceptance ?? armingBaseline });
        const suffix = supervision.armed
          ? `Playbot accepted the task, so its watcher poll was armed as ${supervision.check}.`
          : supervisionArmWarning(supervision);
        throw new Error(`${error instanceof Error ? error.message : String(error)} ${suffix}`);
      }
      throw error;
    }
  }

  if (name === "list_threads") {
    const workspace = resolveWorkspace(project, args.workspace);
    return { project: { id: project.id, name: project.name }, workspace, threads: threadsForProject(project.id, workspace.id, Boolean(args.includeArchived)).map(publicThread) };
  }
  const thread = resolveThreadInProject(project, args.workspace, args.thread, name === "archive_chat");
  if (name === "send_message") {
    const { supervisionAcceptance: _supervisionAcceptance, ...sent } = await sendMessage(thread, args.message, args.force === true);
    return sent;
  }
  if (name === "read_thread") return recentConversation(thread, args.turnLimit ?? 8);
  if (name === "get_thread_status") {
    const publicValue = publicThread(thread);
    return { thread: publicValue, lanes: loadRoutes().filter((route) => route.supervisor?.id === thread.thread_id || route.worker?.id === thread.thread_id) };
  }
  if (name === "get_thread_card") {
    const { snapshot, version } = await threadSnapshot(thread);
    const cards = publicCards(snapshot);
    return {
      thread: publicThread(thread),
      playbot: { version, verifiedVersions: VERIFIED_PLAYBOT_VERSIONS },
      parked: cards.length > 0,
      status: snapshot.agentStatus ?? null,
      phase: snapshot.phase ?? null,
      cards,
      queue: publicQueue(snapshot),
      warnings: cards.length === 0 && thread.agent_status === "pending_input"
        ? ["Persisted status says pending_input but the live chat holds no pending card; treat it as not parked."]
        : [],
    };
  }
  if (name === "answer_thread_card") {
    // The re-read is the safety property, not a courtesy: Playbot resolves a
    // request id against one process-wide registry, so a stale or borrowed id
    // paired with this chat would answer a different worker's card. Only an id
    // this read found on THIS chat is ever sent, and it is sent as the value
    // Playbot itself reported.
    const { snapshot, version } = await threadSnapshot(thread);
    const { request, card } = findAnswerableCard(snapshot, args.requestId);
    if (args.expectTurnId !== undefined && String(args.expectTurnId) !== String(card.turnId)) {
      throw new Error(`Request ${card.requestId} now belongs to turn ${card.turnId}, not ${args.expectTurnId}; re-read get_thread_card before answering`);
    }
    if (args.expectItemId !== undefined && String(args.expectItemId) !== String(card.itemId)) {
      throw new Error(`Request ${card.requestId} now belongs to item ${card.itemId}, not ${args.expectItemId}; re-read get_thread_card before answering`);
    }
    const { response, answered, unanswered, partial } = buildCardResponse(card, args.answers, args.skip === true);
    // Playbot's own registry refuses a second response to an already-resolved
    // request, so a response already in flight is reported rather than blocking
    // the answer: refusing here would also refuse a legitimate retry after a
    // response that stalled, which is the likelier case than a genuine race.
    const warnings = [];
    if (card.responding) {
      warnings.push(`Playbot already had a response in flight for request ${card.requestId} when this answer was sent; if a human answered it first, Playbot rejects the duplicate rather than applying it twice.`);
    }
    if (partial) {
      warnings.push(`Partial answer: this card asked ${card.questions.map((question) => question.id).join(", ")} and ${unanswered.join(", ")} received no answer, so the worker resumes with those unanswered.`);
    }
    const after = await cardInvoke("threads:respondToUserInput", {
      threadId: thread.thread_id,
      requestId: request.id,
      response,
    });
    // The answer already reached Playbot, so an unreadable response snapshot is
    // reported, never thrown: throwing would call a completed answer a failure.
    const unreadableAfter = [];
    const remaining = publicCards(after, unreadableAfter);
    // Only the card projections decide whether cardsRemaining could be read. An
    // unreadable respondingRequestIds leaves it populated and correct, and each
    // card already carries responding: null, so claiming otherwise here would
    // contradict the payload shipped beside it.
    if (remaining === null) {
      const unreadableCards = unreadableAfter.filter((key) => CARD_PROJECTIONS.some(([projection]) => projection === key));
      warnings.push(`The answer was sent, but Playbot's response snapshot carried no readable ${unreadableCards.join(", ")}, so cardsRemaining is null rather than empty: whether this chat still holds a card is unknown, and get_thread_card is the way to find out.`);
    }
    return {
      answered: true,
      thread: publicThread(refreshThread(thread)),
      playbot: { version, verifiedVersions: VERIFIED_PLAYBOT_VERSIONS },
      requestId: request.id,
      skipped: args.skip === true,
      partial,
      answeredQuestions: answered,
      unansweredQuestions: unanswered,
      alreadyResponding: card.responding,
      sentAnswers: response.answers,
      statusAfter: after?.agentStatus ?? null,
      phaseAfter: after?.phase ?? null,
      cardsRemaining: remaining,
      warnings,
    };
  }
  if (name === "list_queued_messages") {
    const { snapshot, version } = await threadSnapshot(thread);
    return {
      thread: publicThread(thread),
      playbot: { version, verifiedVersions: VERIFIED_PLAYBOT_VERSIONS },
      ...publicQueue(snapshot),
    };
  }
  if (name === "drop_queued_message") {
    const messageId = String(args.messageId ?? "").trim();
    if (!messageId) throw new Error("messageId must not be empty; use list_queued_messages to choose one");
    const version = await playbotVersion();
    const preparedRecalls = await supervisionPrepareRecall(thread.thread_id, messageId);
    const result = await cardInvoke("threads:recallMessage", { threadId: thread.thread_id, messageId });
    const supervisionProblems = await supervisionResolveRecall(preparedRecalls, result?.outcome, thread.thread_id);
    // The recall already happened, so an unreadable queue projection is reported
    // as null and warned about rather than thrown, and never as an empty queue: a
    // supervisor reads an empty queueAfter as "the pile is gone" and acts on it.
    const unreadableAfter = [];
    const queueAfter = publicQueue(result?.snapshot, unreadableAfter);
    return {
      thread: publicThread(refreshThread(thread)),
      playbot: { version, verifiedVersions: VERIFIED_PLAYBOT_VERSIONS },
      messageId,
      outcome: result?.outcome ?? null,
      recalled: result?.outcome === "recalled" ? result.message ?? null : null,
      queueAfter,
      warnings: [
        ...unreadableAfter.length > 0
          ? [`${recallOutcomeClause(result?.outcome)}, and Playbot's response snapshot carried no readable ${unreadableAfter.join(", ")}, so that part of queueAfter is null rather than empty: what remains held is unknown, and list_queued_messages is the way to find out.`]
          : [],
        ...supervisionProblems.length > 0
          ? [`${recallOutcomeClause(result?.outcome)}, but its watcher delivery record could not be finalized and remains fail-safe: ${supervisionProblems.join("; ")}`]
          : [],
      ],
    };
  }
  if (name === "register_lane") {
    if (!caller) throw new Error("register_lane requires a Playbot controller chat; external-terminal callers supervise with get_thread_status and read_thread");
    return { lane: registerLane(caller, thread) };
  }
  if (name === "archive_chat") {
    if (args.confirm !== true) throw new Error("archive_chat requires confirm=true");
    await playbotInvoke("threads:archiveThread", { threadId: thread.thread_id, nextActiveThreadId: null });
    withRoutesLock(() => {
      for (const route of loadRoutes().filter((item) => item.supervisor?.id === thread.thread_id || item.worker?.id === thread.thread_id)) {
        route.active = false;
        route.updatedAt = nowIso();
        atomicWriteJson(routePath(route.id), route);
      }
    });
    return { archived: thread.thread_id };
  }
  throw new Error(`Unknown tool: ${name}`);
}

function mcpResult(value) {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
    structuredContent: value,
  };
}

function writeRpc(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

async function handleRpc(request) {
  if (request.method === "initialize") {
    return {
      protocolVersion: request.params?.protocolVersion ?? "2025-06-18",
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
    };
  }
  if (request.method === "ping") return {};
  if (request.method === "tools/list") return { tools: toolDefinitions() };
  if (request.method === "tools/call") return mcpResult(await handleTool(request.params?.name, request.params?.arguments ?? {}));
  if (request.method?.startsWith("notifications/")) return undefined;
  throw Object.assign(new Error(`Method not found: ${request.method}`), { code: -32601 });
}

async function serve() {
  ensurePrivateDirs();
  process.stdin.setEncoding("utf8");
  let buffer = "";
  for await (const chunk of process.stdin) {
    buffer += chunk;
    for (;;) {
      const newline = buffer.indexOf("\n");
      if (newline < 0) break;
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      let request;
      try {
        request = JSON.parse(line);
      } catch {
        continue;
      }
      if (request.id === undefined) {
        await handleRpc(request).catch(() => undefined);
        continue;
      }
      try {
        const result = await handleRpc(request);
        writeRpc({ jsonrpc: "2.0", id: request.id, result });
      } catch (error) {
        writeRpc({
          jsonrpc: "2.0",
          id: request.id,
          error: {
            code: Number.isInteger(error?.code) ? error.code : -32603,
            message: error instanceof Error ? error.message : String(error),
            ...(error?.data === undefined ? {} : { data: error.data }),
          },
        });
      }
    }
  }
}

async function readStdinJson() {
  let input = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) input += chunk;
  if (!input.trim()) return {};
  return JSON.parse(input);
}

async function doctor() {
  const projects = topology();
  let renderer = false;
  let mcpServer = null;
  let chatCreation = null;
  try {
    renderer = await withPlaybotPage(async () => true);
    const servers = await playbotInvoke("codex:mcpServers:list", undefined);
    mcpServer = Array.isArray(servers) ? servers.find((server) => server.name === SERVER_NAME) ?? null : null;
  } catch {
    renderer = false;
  }
  let playbotApp = null;
  if (renderer) {
    try {
      chatCreation = await chatCreationApi();
    } catch {
      chatCreation = null;
    }
    playbotApp = { version: await playbotVersion(), verifiedVersions: VERIFIED_PLAYBOT_VERSIONS };
  }
  const buildIdentity = serverBuildIdentity();
  const installation = readJson(path.join(stateDir(), "installation.json"));
  return {
    server: `${SERVER_NAME}@${SERVER_VERSION}`,
    node: process.version,
    controllerRoot: controllerRoot(),
    stateDir: stateDir(),
    appDb: appDbPath(),
    codexDb: codexDbPath(),
    renderer,
    mcpServer,
    buildIdentity,
    installation,
    chatCreation,
    playbotApp,
    hooks: installedHookStatus(),
    projects: projects.map((project) => ({ id: project.id, name: project.name, paths: [...projectPaths(project)] })),
    routes: loadRoutes().length,
  };
}

function readiness(diagnostics) {
  const controllerPresent = diagnostics.projects.some((project) => project.paths.includes(controllerRoot()));
  const expectedToolCount = toolDefinitions().length;
  const configuredSchemaVersion = diagnostics.mcpServer?.env?.PLAYBOT_LANES_SCHEMA_VERSION ?? null;
  const schemaVersion = diagnostics.installation?.schemaVersion ?? null;
  const buildIdentityMatches = diagnostics.installation?.reloadSucceeded === true
    && diagnostics.installation?.buildIdentity === diagnostics.buildIdentity;
  const ready = diagnostics.renderer
    && diagnostics.hooks.ready
    && diagnostics.mcpServer?.enabled === true
    && diagnostics.mcpServer?.error == null
    && diagnostics.mcpServer?.toolCount === expectedToolCount
    && configuredSchemaVersion === MCP_SCHEMA_VERSION
    && schemaVersion === MCP_SCHEMA_VERSION
    && buildIdentityMatches;
  return {
    ready,
    checks: {
      renderer: diagnostics.renderer,
      controllerPresent,
      hooks: diagnostics.hooks,
      mcpEnabled: diagnostics.mcpServer?.enabled === true,
      mcpError: diagnostics.mcpServer?.error ?? null,
      toolCount: diagnostics.mcpServer?.toolCount ?? null,
      expectedToolCount,
      configuredSchemaVersion,
      schemaVersion,
      expectedSchemaVersion: MCP_SCHEMA_VERSION,
      buildIdentity: diagnostics.buildIdentity,
      installedBuildIdentity: diagnostics.installation?.buildIdentity ?? null,
      buildIdentityMatches,
    },
  };
}

async function setup() {
  const initialDiagnostics = await doctor();
  const initial = readiness(initialDiagnostics);
  if (initial.ready) {
    return {
      ...initial,
      changed: false,
      installation: null,
      diagnostics: initialDiagnostics,
    };
  }
  const installation = await install();
  const diagnostics = await doctor();
  return {
    ...readiness(diagnostics),
    changed: true,
    installation,
    diagnostics,
  };
}

async function main() {
  const command = process.argv[2] ?? "serve";
  if (command === "serve") return serve();
  if (command === "install") return console.log(JSON.stringify(await install(), null, 2));
  if (command === "setup") {
    const result = await setup();
    console.log(JSON.stringify(result, null, 2));
    if (!result.ready) process.exitCode = 1;
    return;
  }
  if (command === "doctor") return console.log(JSON.stringify(await doctor(), null, 2));
  if (command === "supervision-poll") return await supervisionPoll(process.argv.slice(3));
  if (command === "hook-pretool") {
    try {
      recordCaller(await readStdinJson());
    } catch {
      // Hook transport is deliberately fail-open and silent.
    }
    return;
  }
  if (command === "hook-stop") {
    try {
      await processStop(await readStdinJson());
    } catch (error) {
      try {
        ensurePrivateDirs();
        atomicWriteJson(path.join(stateDir(), "last-hook-error.json"), {
          at: nowIso(),
          error: error instanceof Error ? error.message : String(error),
        });
      } catch {
        // A Stop hook must never block the worker from completing.
      }
    }
    return;
  }
  throw new Error(`Unknown command: ${command}`);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
