#!/usr/bin/env node
// Playbot chat lanes controllable from a Playbot controller chat or a normal
// terminal. A caller with a fresh PreToolUse marker is a Playbot chat that
// must belong to the configured controller project to operate across
// projects; it gets durable lanes with routed Stop-hook wake delivery. A
// caller without one is an external terminal that dispatches without a lane
// and supervises by polling.
//
// This executable has six entry points:
//   serve          Run the stdio MCP server.
//   install        Register the MCP server and inert global Playbot hooks.
//   hook-pretool   Capture the exact Codex session invoking one MCP tool.
//   hook-stop      Wake a routed controller after a worker turn completes.
//   setup          Install, reload, and verify the complete integration.
//   doctor         Print bounded local integration diagnostics.
//
// The server talks to Playbot through its local Electron DevTools socket and
// invokes Playbot's own IPC handlers: threads:launch for chat and workspace
// creation on Playbot 0.94.0 and newer, with a detected fallback to the
// pre-0.94 threads:openThread and workspace:create channels, plus the
// unchanged threads:send and threads:archiveThread channels, whose send response
// is the thread snapshot that says whether Playbot delivered the message or is
// only holding it. It reads
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

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { DatabaseSync } from "node:sqlite";

const SERVER_NAME = "playbot_lanes";
const SERVER_VERSION = "0.3.0";
const CALLER_MAX_AGE_MS = 15_000;
const WAKE_PREFIX = "[PLAYBOT_LANE_WAKE v1]";

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

function threadsForProject(projectId, workspaceId = null, includeArchived = false) {
  return threadRows().filter((row) => row.project_id === projectId
    && (!workspaceId || row.workspace_id === workspaceId)
    && (includeArchived || !row.archived));
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

// Playbot accepts a send it cannot deliver yet and holds it in a queue the
// sender is never told about, so a bare "the channel returned" is not evidence
// the worker saw anything. The send response is Playbot's own thread snapshot,
// and it distinguishes held from in-flight from accepted; report that verdict
// instead of implying success.
function deliveryVerdict(response, text) {
  if (!response || typeof response !== "object" || response.pendingMessages === undefined || response.outboundMessages === undefined) {
    return {
      state: "unknown",
      messageId: null,
      queuedTotal: null,
      note: "Playbot returned no thread snapshot for this send, so delivery is unconfirmed. Check list_queued_messages before resending, because a resend compounds the queue.",
    };
  }
  const queued = response.pendingMessages ?? [];
  const outbound = response.outboundMessages ?? [];
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

async function sendMessage(row, text) {
  if (row.archived) throw new Error(`Cannot send to archived thread ${row.thread_id}`);
  const value = String(text ?? "").trim();
  if (!value) throw new Error("message must not be empty");
  const response = await playbotInvoke("threads:send", { threadId: row.thread_id, text: value });
  return {
    thread: publicThread(resolveThread(row.project_id, row.workspace_id, row.thread_id)),
    delivery: deliveryVerdict(response, value),
  };
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
const SNAPSHOT_REQUIRED_KEYS = [
  "agentStatus",
  "phase",
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
  try {
    const metadata = await playbotInvoke("app:metadata", undefined);
    const version = metadata?.version;
    detectedPlaybotVersion = typeof version === "string" && version.trim() ? version.trim() : null;
  } catch {
    detectedPlaybotVersion = null;
  }
  return detectedPlaybotVersion;
}

function playbotVersionLabel(version) {
  return version ? `Playbot ${version}` : "this Playbot (version unreadable)";
}

async function playbotProvenance() {
  return { version: await playbotVersion(), verifiedVersions: VERIFIED_PLAYBOT_VERSIONS };
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
  const missing = SNAPSHOT_REQUIRED_KEYS.filter((key) => snapshot[key] === undefined);
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

function publicCard(request, kind, snapshot) {
  const params = request?.params ?? {};
  return {
    requestId: request?.id ?? null,
    kind,
    method: request?.method ?? null,
    // params.threadId is the Codex session id, not the Playbot chat id.
    sessionId: params.threadId ?? null,
    turnId: params.turnId ?? null,
    itemId: params.itemId ?? null,
    answerable: kind === "question",
    responding: (snapshot.respondingRequestIds ?? []).some((id) => String(id) === String(request?.id)),
    questions: (params.questions ?? []).map(publicQuestion),
  };
}

function publicCards(snapshot) {
  return [
    ...(snapshot.userInputRequests ?? []).map((request) => publicCard(request, "question", snapshot)),
    ...(snapshot.approvalRequests ?? []).map((request) => publicCard(request, "approval", snapshot)),
    ...(snapshot.mcpElicitationRequests ?? []).map((request) => publicCard(request, "elicitation", snapshot)),
  ];
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
function publicQueue(snapshot) {
  const outbound = snapshot.outboundMessages ?? [];
  return {
    queued: (snapshot.pendingMessages ?? []).map((message) => publicQueuedMessage(message, "queued")),
    sending: outbound.filter((message) => message.status === "sending").map((message) => publicQueuedMessage(message, "sending")),
    failed: outbound.filter((message) => message.status === "failed").map((message) => publicQueuedMessage(message, "failed")),
  };
}

function queuedMessageCount(pendingQueueJson) {
  const ledger = readJsonText(pendingQueueJson);
  return Array.isArray(ledger?.messages) ? ledger.messages.length : 0;
}

function readJsonText(text) {
  if (typeof text !== "string" || !text.trim()) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function normalizeAnswerValues(questionId, value) {
  const values = Array.isArray(value) ? value : [value];
  const cleaned = values.map((entry) => {
    if (typeof entry !== "string") throw new Error(`Answer for question '${questionId}' must be a string or an array of strings`);
    return entry.trim();
  }).filter((entry) => entry.length > 0);
  if (cleaned.length === 0) throw new Error(`Answer for question '${questionId}' must not be empty; use skip=true to skip the card instead`);
  return cleaned;
}

// Playbot's own renderer uses each option's LABEL as its answer value, so an
// answer is passed through exactly as get_thread_card reported it rather than
// normalized or reconstructed here.
function buildCardResponse(card, answers, skip) {
  if (skip) {
    if (answers !== undefined && Object.keys(answers).length > 0) throw new Error("skip=true answers the card with no selection; omit answers");
    return { answers: {} };
  }
  const entries = Object.entries(answers ?? {});
  if (entries.length === 0) throw new Error("answers must name at least one question id, or pass skip=true to skip the card");
  const known = new Set(card.questions.map((question) => question.id));
  const unknown = entries.map(([id]) => id).filter((id) => !known.has(id));
  if (unknown.length > 0) {
    throw new Error(`Question not on request ${card.requestId}: ${unknown.join(", ")}; this card asks ${[...known].join(", ")}`);
  }
  const response = { answers: {} };
  for (const [id, value] of entries) response.answers[id] = { answers: normalizeAnswerValues(id, value) };
  return response;
}

function findAnswerableCard(snapshot, requestId) {
  const cards = publicCards(snapshot);
  const match = (snapshot.userInputRequests ?? []).find((request) => String(request?.id) === String(requestId));
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

function saveRoute(supervisor, worker, prior = null) {
  if (supervisor.thread_id === worker.thread_id) throw new Error("A Playbot lane cannot route a chat back to itself");
  const id = routeIdFor(supervisor.thread_id, worker.thread_id);
  const existingCompletion = prior ? null : recentConversation(worker, 1).completion;
  const route = {
    version: 1,
    id,
    active: true,
    supervisor: publicThread(supervisor),
    worker: publicThread(worker),
    createdAt: prior?.createdAt ?? nowIso(),
    updatedAt: nowIso(),
    lastNotifiedTurnId: prior?.lastNotifiedTurnId ?? existingCompletion?.turnId ?? null,
    lastNotifiedAt: prior?.lastNotifiedAt ?? null,
  };
  atomicWriteJson(routePath(id), route);
  return route;
}

function registerLane(supervisor, worker) {
  const prior = readJson(routePath(routeIdFor(supervisor.thread_id, worker.thread_id)));
  return saveRoute(supervisor, worker, prior);
}

function bounded(text, max = 4_000) {
  const value = String(text ?? "").trim();
  return value.length <= max ? value : `${value.slice(0, max)}\n[truncated]`;
}

async function processStop(payload) {
  const sessionId = payload.session_id ?? payload.sessionId;
  if (!sessionId) return { matched: 0, notified: 0 };
  const worker = rowForSession(sessionId);
  if (!worker) return { matched: 0, notified: 0 };
  const matches = loadRoutes().filter((route) => route.active && route.worker?.id === worker.thread_id);
  let notified = 0;
  for (const route of matches) {
    const currentWorker = resolveThread(worker.project_id, worker.workspace_id, worker.thread_id);
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
    const supervisorRows = threadRows().filter((row) => row.thread_id === route.supervisor?.id && !row.archived);
    if (supervisorRows.length !== 1 || supervisorRows[0].thread_id === currentWorker.thread_id) continue;
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
      if (process.env.PLAYBOT_LANES_DRY_RUN === "1") {
        atomicWriteJson(path.join(stateDir(), "last-dry-run-wake.json"), {
          at: nowIso(),
          routeId: route.id,
          supervisorThreadId: supervisorRows[0].thread_id,
          workerThreadId: currentWorker.thread_id,
          turnId: eventId,
          message,
        });
      } else {
        await sendMessage(supervisorRows[0], message);
      }
      route.lastNotifiedTurnId = eventId;
      route.lastNotifiedAt = nowIso();
      route.updatedAt = nowIso();
      route.worker = publicThread(currentWorker);
      atomicWriteJson(routePath(route.id), route);
      notified += 1;
    } catch (error) {
      atomicWriteJson(path.join(stateDir(), "last-hook-error.json"), {
        at: nowIso(),
        routeId: route.id,
        workerThreadId: currentWorker.thread_id,
        error: error instanceof Error ? error.message : String(error),
      });
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
  atomicWriteJson(path.join(stateDir(), "installation.json"), {
    version: 1,
    installedAt: nowIso(),
    script,
    node,
    controllerRoot: controllerRoot(),
    configPath,
    hooksPath,
  });

  let reload = "not attempted";
  try {
    const servers = await playbotInvoke("codex:mcpServers:reload", undefined);
    reload = Array.isArray(servers) ? `reloaded ${servers.length} MCP server record(s)` : "reload requested";
  } catch (error) {
    reload = `reload deferred: ${error instanceof Error ? error.message : String(error)}`;
  }
  return { installed: true, configPath, hooksPath, stateDir: stateDir(), reload };
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
      name: "create_chat",
      description: "Create an empty Playbot chat in one project workspace without focusing it or starting an agent turn. Can create the workspace first via newWorkspace.",
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name"), newWorkspace: newWorkspace(), title: string("Chat title"), approvalMode: { type: "string", enum: ["default", "auto-review", "full-access"] }, planMode: boolean("Create in Plan mode", false) }, ["project", "title"]),
    },
    {
      name: "send_message",
      description: "Send a message to an existing Playbot chat in any project without selecting or focusing that chat. Reports delivery from Playbot's own send response: state \"delivered\" means the worker accepted it, \"sending\" means it is in flight, \"queued\" means Playbot is HOLDING it and the worker has not seen it, \"failed\" carries Playbot's reason, and \"unknown\" means delivery could not be confirmed. Never treat a queued or unknown send as delivered.",
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project"), thread: string("Thread id, Codex session id, or unique exact title"), message: string("Message to send") }, ["project", "thread", "message"]),
    },
    {
      name: "read_thread",
      description: "Read a bounded recent Playbot conversation directly from its persisted Codex rollout without resuming the chat.",
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project"), thread: string("Thread id, Codex session id, or unique exact title"), turnLimit: { type: "integer", minimum: 1, maximum: 30, default: 8 } }, ["project", "thread"]),
      annotations: { readOnlyHint: true },
    },
    {
      name: "get_thread_status",
      description: "Get one Playbot chat's persisted status and route membership without resuming it.",
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project"), thread: string("Thread id, Codex session id, or unique exact title") }, ["project", "thread"]),
      annotations: { readOnlyHint: true },
    },
    {
      name: "list_parked_threads",
      description: `Cheap detector for chats that may be parked on a question or approval card, read from persisted state without resuming any chat or focusing the Playbot window. These are CANDIDATES only: Playbot reports a merely rehydrated chat's status as pending_input even when it is not parked, so confirm each one with get_thread_card before acting. Verified against Playbot ${VERIFIED_PLAYBOT_VERSIONS}.`,
      inputSchema: object({ project: string("Optional project id, root path, or unique project name; every project when omitted"), includeArchived: boolean("Include archived chats", false) }),
      annotations: { readOnlyHint: true },
    },
    {
      name: "get_thread_card",
      description: `Read the pending question, approval, and MCP cards for one named chat, with every question's exact text and option labels, plus its live queued messages. Addresses the chat explicitly and never acts on the visibly selected one. This is the confirming read for list_parked_threads and it RESUMES a chat that has not been resumed since Playbot started, exactly as opening that chat in the Playbot window does; it starts no agent turn. Uses Playbot ${VERIFIED_PLAYBOT_VERSIONS} internal IPC and refuses if the channel or snapshot shape has changed.`,
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project"), thread: string("Thread id, Codex session id, or unique exact title") }, ["project", "thread"]),
      annotations: { readOnlyHint: true },
    },
    {
      name: "answer_thread_card",
      description: `Answer one named chat's pending question card, the same call Playbot makes when a human clicks an option. Re-reads the chat's live cards first and refuses unless requestId is pending on THAT chat, because Playbot resolves a request id globally and a mismatched pair would answer another worker's card. Pass each answer as the option label exactly as get_thread_card reported it, or as free text where the question allows it, or skip=true to skip the card. Uses Playbot ${VERIFIED_PLAYBOT_VERSIONS} internal IPC.`,
      inputSchema: object({
        project: string("Project id, root path, or unique project name"),
        workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project"),
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
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project"), thread: string("Thread id, Codex session id, or unique exact title") }, ["project", "thread"]),
      annotations: { readOnlyHint: true },
    },
    {
      name: "drop_queued_message",
      description: `Recall one queued or in-flight message from a named chat so a superseded instruction is removed instead of resent, the same call Playbot's own recall control makes. Returns outcome "recalled" when it was removed and "not-recallable" when it had already been delivered; neither is an error. Uses Playbot ${VERIFIED_PLAYBOT_VERSIONS} internal IPC.`,
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project"), thread: string("Thread id, Codex session id, or unique exact title"), messageId: string("Message id from list_queued_messages") }, ["project", "thread", "messageId"]),
    },
    {
      name: "register_lane",
      description: "Bind an existing worker chat to the current controller chat so its future completed turns wake the controller.",
      inputSchema: object({ project: string("Worker project id, root path, or unique project name"), workspace: string("Optional worker workspace id, path, or name; omit to resolve the thread anywhere in the project"), thread: string("Worker thread id, Codex session id, or unique exact title") }, ["project", "thread"]),
    },
    {
      name: "dispatch",
      description: "Resolve or create a worker chat by project and send the task, optionally creating an isolated workspace first. Reports the same delivery verdict as send_message, so a task Playbot is only holding is never reported as delivered. A Playbot-chat caller also receives a routed Stop-hook wake; an external-terminal caller supervises with get_thread_status, read_thread, and get_thread_card.",
      inputSchema: object({ project: string("Worker project id, root path, or unique project name"), workspace: string("Optional worker workspace id, path, or name; omit to resolve the thread anywhere in the project"), newWorkspace: newWorkspace(), thread: string("Optional existing worker thread id, session id, or exact title"), title: string("Title when a worker chat must be created"), message: string("Task to send"), approvalMode: { type: "string", enum: ["default", "auto-review", "full-access"], default: "full-access" }, planMode: boolean("Create a new worker in Plan mode", false) }, ["project", "message"]),
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
      inputSchema: object({ project: string("Project id, root path, or unique project name"), workspace: string("Optional workspace id, path, or name; omit to resolve the thread anywhere in the project"), thread: string("Thread id, Codex session id, or unique exact title"), confirm: { type: "boolean", const: true } }, ["project", "thread", "confirm"]),
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
    const route = readJson(file);
    if (!route) throw new Error(`Lane not found: ${args.laneId}`);
    route.active = false;
    route.updatedAt = nowIso();
    atomicWriteJson(file, route);
    return { lane: route };
  }

  if (name === "list_parked_threads") {
    const scope = args.project ? resolveProject(args.project, projects).id : null;
    const candidates = threadRows()
      .filter((row) => (!scope || row.project_id === scope)
        && (args.includeArchived ? true : !row.archived)
        && row.agent_status === "pending_input")
      .map(publicThread);
    return {
      candidates,
      confirmWith: "get_thread_card",
      note: "Persisted status only. Playbot reports a rehydrated chat as pending_input even when it is not parked, so confirm each candidate with get_thread_card before answering anything.",
    };
  }

  const project = resolveProject(args.project, projects);
  if (name === "create_workspace") {
    return { workspace: await createWorkspace(project, args) };
  }
  if (name === "create_chat") {
    const wantsNewWorkspace = assertNewWorkspaceRequest(name, args);
    return { thread: await createChat({ project: project.id, workspace: args.workspace, newWorkspace: wantsNewWorkspace ? args.newWorkspace : undefined, title: args.title, approvalMode: args.approvalMode, planMode: args.planMode }) };
  }

  if (name === "dispatch") {
    const wantsNewWorkspace = assertNewWorkspaceRequest(name, args);
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
    try {
      const { thread, delivery } = await sendMessage(worker, args.message);
      return caller
        ? { lane, thread, delivery }
        : {
            lane: null,
            thread,
            delivery,
            supervision: {
              mode: "poll",
              tools: ["get_thread_status", "read_thread", "get_thread_card"],
            },
          };
    } catch (error) {
      if (lane) {
        lane.active = false;
        lane.updatedAt = nowIso();
        lane.error = error instanceof Error ? error.message : String(error);
        atomicWriteJson(routePath(lane.id), lane);
      }
      throw error;
    }
  }

  if (name === "list_threads") {
    const workspace = resolveWorkspace(project, args.workspace);
    return { project: { id: project.id, name: project.name }, workspace, threads: threadsForProject(project.id, workspace.id, Boolean(args.includeArchived)).map(publicThread) };
  }
  const thread = resolveThreadInProject(project, args.workspace, args.thread, name === "archive_chat");
  if (name === "send_message") return sendMessage(thread, args.message);
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
    const response = buildCardResponse(card, args.answers, args.skip === true);
    const after = await cardInvoke("threads:respondToUserInput", {
      threadId: thread.thread_id,
      requestId: request.id,
      response,
    });
    const remaining = after && typeof after === "object" ? publicCards(after) : [];
    return {
      answered: true,
      thread: publicThread(resolveThread(thread.project_id, thread.workspace_id, thread.thread_id)),
      playbot: { version, verifiedVersions: VERIFIED_PLAYBOT_VERSIONS },
      requestId: request.id,
      skipped: args.skip === true,
      sentAnswers: response.answers,
      statusAfter: after?.agentStatus ?? null,
      phaseAfter: after?.phase ?? null,
      cardsRemaining: remaining,
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
    const result = await cardInvoke("threads:recallMessage", { threadId: thread.thread_id, messageId });
    const snapshot = result?.snapshot;
    return {
      thread: publicThread(resolveThread(thread.project_id, thread.workspace_id, thread.thread_id)),
      playbot: { version, verifiedVersions: VERIFIED_PLAYBOT_VERSIONS },
      messageId,
      outcome: result?.outcome ?? null,
      recalled: result?.outcome === "recalled" ? result.message ?? null : null,
      ...snapshot && typeof snapshot === "object" ? { queueAfter: publicQueue(snapshot) } : {},
    };
  }
  if (name === "register_lane") {
    if (!caller) throw new Error("register_lane requires a Playbot controller chat; external-terminal callers supervise with get_thread_status and read_thread");
    return { lane: registerLane(caller, thread) };
  }
  if (name === "archive_chat") {
    if (args.confirm !== true) throw new Error("archive_chat requires confirm=true");
    await playbotInvoke("threads:archiveThread", { threadId: thread.thread_id, nextActiveThreadId: null });
    for (const route of loadRoutes().filter((item) => item.supervisor?.id === thread.thread_id || item.worker?.id === thread.thread_id)) {
      route.active = false;
      route.updatedAt = nowIso();
      atomicWriteJson(routePath(route.id), route);
    }
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
  return {
    server: `${SERVER_NAME}@${SERVER_VERSION}`,
    node: process.version,
    controllerRoot: controllerRoot(),
    stateDir: stateDir(),
    appDb: appDbPath(),
    codexDb: codexDbPath(),
    renderer,
    mcpServer,
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
  const ready = diagnostics.renderer
    && diagnostics.hooks.ready
    && diagnostics.mcpServer?.enabled === true
    && diagnostics.mcpServer?.error == null
    && diagnostics.mcpServer?.toolCount === expectedToolCount;
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
