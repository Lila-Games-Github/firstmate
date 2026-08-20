#!/usr/bin/env bash
# Hermetic behavior tests for bin/fm-playbot-lanes.mjs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || {
  printf 'ok - fm-playbot-lanes: skipped (node unavailable)\n'
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-playbot-lanes)
export FIXTURE_ROOT="$TMP_ROOT/fixture"
export PLAYBOT_DESKTOP_DIR="$FIXTURE_ROOT/desktop"
export PLAYBOT_HARNESS_HOME="$FIXTURE_ROOT/harness"
export PLAYBOT_LANES_STATE_DIR="$FIXTURE_ROOT/lanes"
export PLAYBOT_LANES_CONTROLLER_ROOT="$FIXTURE_ROOT/controller"
SCRIPT="$ROOT/bin/fm-playbot-lanes.mjs"

mkdir -p "$PLAYBOT_DESKTOP_DIR" "$PLAYBOT_HARNESS_HOME" "$PLAYBOT_LANES_CONTROLLER_ROOT" "$FIXTURE_ROOT/worker" "$FIXTURE_ROOT/worker-two"

FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const root = process.env.FIXTURE_ROOT;
const desktop = path.join(root, 'desktop');
const harness = path.join(root, 'harness');
const app = new DatabaseSync(path.join(desktop, 'playbot.db'));
app.exec(`
  CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, default_working_root_id TEXT, deletion_state TEXT, created_at TEXT, updated_at TEXT);
  CREATE TABLE repositories (id TEXT PRIMARY KEY, name TEXT, path TEXT, default_branch TEXT);
  CREATE TABLE project_roots (id TEXT PRIMARY KEY, project_id TEXT, repository_id TEXT, position INTEGER);
  CREATE TABLE workspaces (id TEXT PRIMARY KEY, project_id TEXT, name TEXT, kind TEXT, is_selected INTEGER, archive_state TEXT, created_at TEXT, updated_at TEXT);
  CREATE TABLE workspace_roots (workspace_id TEXT, project_root_id TEXT, path TEXT, branch TEXT);
  CREATE TABLE workspace_threads (
    id TEXT PRIMARY KEY, workspace_id TEXT, title TEXT, position INTEGER, is_active INTEGER,
    session_id TEXT, approval_mode TEXT, plan_mode INTEGER, ephemeral INTEGER,
    draft_input TEXT, pending_queue_json TEXT, agent_status TEXT, has_unread INTEGER,
    last_user_activity_at TEXT, created_at TEXT, updated_at TEXT, archived INTEGER
  );
`);
const now = '2026-07-29T12:00:00.000Z';
const projects = [
  ['project-controller', 'firstmate', 'root-controller', path.join(root, 'controller'), 'ws-controller'],
  ['project-worker', 'prototype-game', 'root-worker', path.join(root, 'worker'), 'ws-worker'],
  ['project-worker-two', 'prototype-game', 'root-worker-two', path.join(root, 'worker-two'), 'ws-worker-two'],
];
for (const [projectId, name, rootId, repoPath, workspaceId] of projects) {
  const repoId = `repo-${projectId}`;
  app.prepare('INSERT INTO projects VALUES (?, ?, ?, ?, ?, ?)').run(projectId, name, rootId, 'active', now, now);
  app.prepare('INSERT INTO repositories VALUES (?, ?, ?, ?)').run(repoId, name, repoPath, 'main');
  app.prepare('INSERT INTO project_roots VALUES (?, ?, ?, ?)').run(rootId, projectId, repoId, 0);
  app.prepare('INSERT INTO workspaces VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run(workspaceId, projectId, null, 'local', 1, 'active', now, now);
  app.prepare('INSERT INTO workspace_roots VALUES (?, ?, ?, ?)').run(workspaceId, rootId, repoPath, 'main');
}
const insertThread = app.prepare('INSERT INTO workspace_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
insertThread.run('chat-controller', 'ws-controller', 'Firstmate', 0, 1, 'controller-session', 'full-access', 0, 0, '', null, 'working', 0, now, now, now, 0);
insertThread.run('chat-worker', 'ws-worker', 'Greeting', 0, 1, 'worker-session', 'full-access', 0, 0, '', null, 'ready', 0, now, now, now, 0);
app.close();

const rollout = path.join(harness, 'worker-rollout.jsonl');
fs.writeFileSync(rollout, [
  JSON.stringify({ timestamp: now, type: 'event_msg', payload: { type: 'user_message', message: 'Ping' } }),
  JSON.stringify({ timestamp: now, type: 'event_msg', payload: { type: 'agent_message', message: 'ACK', phase: 'final_answer' } }),
  JSON.stringify({ timestamp: now, type: 'event_msg', payload: { type: 'task_complete', turn_id: 'turn-worker-1', last_agent_message: 'ACK', completed_at: 1785326400, duration_ms: 100 } }),
].join('\n') + '\n');
const codex = new DatabaseSync(path.join(harness, 'state_5.sqlite'));
codex.exec('CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, cwd TEXT, title TEXT, updated_at_ms INTEGER, archived INTEGER)');
codex.prepare('INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?)').run('worker-session', rollout, path.join(root, 'worker'), 'Greeting', 1785326400000, 0);
codex.prepare('INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?)').run('controller-session', path.join(harness, 'controller-rollout.jsonl'), path.join(root, 'controller'), 'Firstmate', 1785326400000, 0);
codex.close();
NODE

node --check "$SCRIPT" || fail "fm-playbot-lanes script failed node syntax validation"
pass "fm-playbot-lanes: node syntax is valid"

rpc() {
  printf '%s\n' "$1" | node --no-warnings "$SCRIPT" serve
}

out=$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}')
OUT="$out" node --no-warnings <<'NODE' || fail "list_projects did not return all fixture projects"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.projects.length !== 3) process.exit(1);
NODE
pass "fm-playbot-lanes: global project discovery is project-id and path aware"

out=$(PLAYBOT_LANES_CONTROLLER_ROOT="$FIXTURE_ROOT/not-a-playbot-project" rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"identify_current_thread","arguments":{}}}')
OUT="$out" node --no-warnings <<'NODE' || fail "normal-terminal caller was not identified without a Playbot controller project"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.controller !== 'external-terminal' || value.thread !== null) process.exit(1);
NODE
pass "fm-playbot-lanes: normal-terminal callers need no Playbot controller project"

out=$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_threads","arguments":{"project":"prototype-game"}}}')
OUT="$out" node --no-warnings <<'NODE' || fail "duplicate project names were not rejected"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('Ambiguous Playbot project')) process.exit(1);
NODE
pass "fm-playbot-lanes: duplicate project names fail closed"

printf '%s\n' '{"session_id":"controller-session","cwd":"fixture-controller","tool_name":"mcp__playbot_lanes__identify_current_thread"}' \
  | node --no-warnings "$SCRIPT" hook-pretool
out=$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"identify_current_thread","arguments":{}}}')
OUT="$out" node --no-warnings <<'NODE' || fail "PreToolUse session marker did not identify the controller"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.thread.id !== 'chat-controller') process.exit(1);
NODE
pass "fm-playbot-lanes: caller identity comes from the exact Codex session marker"

printf '%s\n' '{"session_id":"worker-session","cwd":"fixture-worker","tool_name":"mcp__playbot_lanes__identify_current_thread"}' \
  | node --no-warnings "$SCRIPT" hook-pretool
out=$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"identify_current_thread","arguments":{}}}')
OUT="$out" node --no-warnings <<'NODE' || fail "a Playbot chat outside the controller project could not identify itself"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.controller !== 'playbot-chat' || value.thread.id !== 'chat-worker') process.exit(1);
NODE
pass "fm-playbot-lanes: identity stays readable for chats outside the controller project"

printf '%s\n' '{"session_id":"worker-session","cwd":"fixture-worker","tool_name":"mcp__playbot_lanes__list_projects"}' \
  | node --no-warnings "$SCRIPT" hook-pretool
out=$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}')
OUT="$out" node --no-warnings <<'NODE' || fail "a worker chat was allowed to use the controller MCP"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('not in the configured controller project')) process.exit(1);
NODE
pass "fm-playbot-lanes: cross-project tools are restricted to the configured controller project"

worker_path=$(FIXTURE_ROOT="$FIXTURE_ROOT" node -e 'console.log(require("node:path").join(process.env.FIXTURE_ROOT, "worker"))')
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"read_thread\",\"arguments\":{\"project\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path"),\"thread\":\"Greeting\",\"turnLimit\":2}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "read_thread did not read the persisted completion"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.thread.id !== 'chat-worker' || value.finalAnswer !== 'ACK' || value.completion.turnId !== 'turn-worker-1') process.exit(1);
NODE
pass "fm-playbot-lanes: thread reads are bounded and non-resuming"

out=$(PLAYBOT_LANES_CONTROLLER_ROOT="$FIXTURE_ROOT/not-a-playbot-project" rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_status\",\"arguments\":{\"project\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path"),\"thread\":\"Greeting\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "normal-terminal caller could not read thread status without a controller project"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.thread.id !== 'chat-worker' || value.thread.status !== 'ready') process.exit(1);
NODE
pass "fm-playbot-lanes: normal-terminal callers can poll thread status"

out=$(PLAYBOT_LANES_CONTROLLER_ROOT="$FIXTURE_ROOT/not-a-playbot-project" rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"read_thread\",\"arguments\":{\"project\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path"),\"thread\":\"Greeting\",\"turnLimit\":2}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "normal-terminal caller could not read a thread without a controller project"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.thread.id !== 'chat-worker' || value.finalAnswer !== 'ACK') process.exit(1);
NODE
pass "fm-playbot-lanes: normal-terminal callers can read worker conversations"

out=$(PLAYBOT_LANES_CONTROLLER_ROOT="$FIXTURE_ROOT/not-a-playbot-project" rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"register_lane\",\"arguments\":{\"project\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path"),\"thread\":\"Greeting\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "normal-terminal register_lane was not refused with polling guidance"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('requires a Playbot controller chat')) process.exit(1);
if (!value.error.message.includes('get_thread_status and read_thread')) process.exit(1);
NODE
pass "fm-playbot-lanes: normal-terminal register_lane fails closed toward polling supervision"

printf '%s\n' '{"session_id":"controller-session","cwd":"fixture-controller","tool_name":"mcp__playbot_lanes__register_lane"}' \
  | node --no-warnings "$SCRIPT" hook-pretool
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"register_lane\",\"arguments\":{\"project\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path"),\"thread\":\"Greeting\"}}}")
lane_id=$(OUT="$out" node -e 'process.stdout.write(JSON.parse(process.env.OUT).result.structuredContent.lane.id)')
[ -n "$lane_id" ] || fail "register_lane did not return a lane id"

FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const rollout = path.join(process.env.FIXTURE_ROOT, 'harness', 'worker-rollout.jsonl');
const now = '2026-07-29T12:01:00.000Z';
fs.appendFileSync(rollout, [
  JSON.stringify({ timestamp: now, type: 'event_msg', payload: { type: 'user_message', message: 'Second ping' } }),
  JSON.stringify({ timestamp: now, type: 'event_msg', payload: { type: 'agent_message', message: 'SECOND ACK', phase: 'final_answer' } }),
  JSON.stringify({ timestamp: now, type: 'event_msg', payload: { type: 'task_complete', turn_id: 'turn-worker-2', last_agent_message: 'SECOND ACK', completed_at: 1785326460, duration_ms: 100 } }),
].join('\n') + '\n');
NODE

printf '%s\n' '{"session_id":"worker-session","stop_hook_active":false}' \
  | PLAYBOT_LANES_DRY_RUN=1 node --no-warnings "$SCRIPT" hook-stop
[ -f "$PLAYBOT_LANES_STATE_DIR/last-dry-run-wake.json" ] || fail "Stop hook did not produce a dry-run wake"
LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$lane_id.json" node --no-warnings <<'NODE' || fail "Stop hook did not persist the delivered turn id"
const route = JSON.parse(require('node:fs').readFileSync(process.env.LANE_FILE, 'utf8'));
if (route.lastNotifiedTurnId !== 'turn-worker-2') process.exit(1);
NODE
before=$(cksum "$PLAYBOT_LANES_STATE_DIR/routes/$lane_id.json")
printf '%s\n' '{"session_id":"worker-session","stop_hook_active":true}' \
  | PLAYBOT_LANES_DRY_RUN=1 node --no-warnings "$SCRIPT" hook-stop
after=$(cksum "$PLAYBOT_LANES_STATE_DIR/routes/$lane_id.json")
[ "$before" = "$after" ] || fail "Stop hook did not deduplicate the completed turn"
pass "fm-playbot-lanes: Stop wake delivery is routed, durable, and turn-deduplicated"

node --no-warnings "$SCRIPT" install >/dev/null
node --no-warnings "$SCRIPT" install >/dev/null
CONFIG="$PLAYBOT_HARNESS_HOME/config.toml" HOOKS="$PLAYBOT_HARNESS_HOME/hooks.json" node --no-warnings <<'NODE' || fail "install was not idempotent"
const fs = require('node:fs');
const config = fs.readFileSync(process.env.CONFIG, 'utf8');
const hooks = JSON.parse(fs.readFileSync(process.env.HOOKS, 'utf8'));
if ((config.match(/\[mcp_servers\.playbot_lanes\]/g) || []).length !== 1) process.exit(1);
const commands = Object.values(hooks.hooks).flatMap(groups => groups.flatMap(group => group.hooks || [])).map(hook => hook.command || '');
if (commands.filter(command => command.includes('hook-pretool')).length !== 1) process.exit(1);
if (commands.filter(command => command.includes('hook-stop')).length !== 1) process.exit(1);
NODE
pass "fm-playbot-lanes: installer merges one MCP server and one hook of each kind"

out=$(node --no-warnings "$SCRIPT" doctor)
OUT="$out" node --no-warnings <<'NODE' || fail "doctor did not recognize the exact installed hook set as ready"
const value = JSON.parse(process.env.OUT);
if (!value.hooks.ready || value.hooks.preToolUse !== 1 || value.hooks.stop !== 1) process.exit(1);
NODE
pass "fm-playbot-lanes: hook readiness requires one owned hook of each kind"

threads_before=$(FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(path.join(process.env.FIXTURE_ROOT, 'desktop', 'playbot.db'), { readOnly: true });
process.stdout.write(String(db.prepare('SELECT COUNT(*) AS count FROM workspace_threads').get().count));
db.close();
NODE
)
setup_out=$(node --no-warnings "$SCRIPT" setup)
setup_rc=$?
[ "$setup_rc" -ne 0 ] || fail "setup succeeded without a reachable Playbot renderer"
OUT="$setup_out" node --no-warnings <<'NODE' || fail "setup did not fail closed with inspectable readiness checks"
const value = JSON.parse(process.env.OUT);
if (value.ready !== false || value.changed !== true) process.exit(1);
if (value.checks.renderer !== false || value.checks.controllerPresent !== true) process.exit(1);
if (!value.checks.hooks.ready || value.checks.expectedToolCount !== 13) process.exit(1);
NODE
threads_after=$(FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(path.join(process.env.FIXTURE_ROOT, 'desktop', 'playbot.db'), { readOnly: true });
process.stdout.write(String(db.prepare('SELECT COUNT(*) AS count FROM workspace_threads').get().count));
db.close();
NODE
)
[ "$threads_before" = "$threads_after" ] || fail "setup created or removed a Playbot chat"
pass "fm-playbot-lanes: setup repairs only when needed and never creates a startup chat"

out=$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_projects","arguments":{}}}')
OUT="$out" node --no-warnings <<'NODE' || fail "list_projects did not expose each workspace root's branch"
const value = JSON.parse(process.env.OUT).result.structuredContent;
const project = value.projects.find(candidate => candidate.id === 'project-worker');
const roots = project.workspaces[0].roots;
if (roots.length !== 1 || roots[0].branch !== 'main' || !roots[0].path) process.exit(1);
NODE
pass "fm-playbot-lanes: workspace root branches are visible in the global topology"

# The remaining tests exercise Playbot IPC end to end against a hermetic fake
# DevTools endpoint whose window.electronAPI.invoke stub records every call and
# emulates workspace and thread creation against the fixture database.
# The fixture serves the Playbot 0.94.0 surface (threads:launch) by default and
# the pre-0.94 surface (workspace:create plus threads:openThread) when the
# ipc-mode file contains "legacy", so both adapter paths are enforced.
cat > "$FIXTURE_ROOT/fake-cdp.mjs" <<'NODE'
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import vm from 'node:vm';
import { DatabaseSync } from 'node:sqlite';

const desktop = path.join(process.env.FIXTURE_ROOT, 'desktop');
const callsFile = path.join(process.env.FIXTURE_ROOT, 'ipc-calls.jsonl');
const modeFile = path.join(process.env.FIXTURE_ROOT, 'ipc-mode');
let createCounter = 0;
let threadCounter = 0;

function currentMode() {
  try {
    return fs.readFileSync(modeFile, 'utf8').trim() || 'modern';
  } catch {
    return 'modern';
  }
}

function createWorkspaceRows(db, spec) {
  if (spec.strategy !== 'project') throw new Error('fixture implements only the project strategy');
  const project = db.prepare('SELECT id FROM projects WHERE id = ?').get(spec.projectId);
  if (!project) throw new Error(`Unknown project: ${spec.projectId}`);
  createCounter += 1;
  const id = `ws-created-${createCounter}`;
  const branch = spec.branch ?? `generated-${createCounter}`;
  const now = new Date().toISOString();
  db.prepare('INSERT INTO workspaces VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
    .run(id, spec.projectId, spec.name ?? null, 'worktree', 0, 'active', now, now);
  const roots = db.prepare(`
    SELECT pr.id AS root_id, r.path AS repo_path FROM project_roots pr
    JOIN repositories r ON r.id = pr.repository_id WHERE pr.project_id = ?
  `).all(spec.projectId);
  for (const root of roots) {
    db.prepare('INSERT INTO workspace_roots VALUES (?, ?, ?, ?)')
      .run(id, root.root_id, path.join(root.repo_path, '.worktrees', branch), branch);
  }
  return { id, name: spec.name ?? null };
}

function launchThread(db, payload) {
  for (const key of Object.keys(payload)) {
    if (!['activate', 'destination', 'message', 'thread'].includes(key)) throw new Error(`Unrecognized key: ${key}`);
  }
  const thread = payload.thread ?? {};
  for (const key of Object.keys(thread)) {
    if (!['title', 'approvalMode', 'planMode', 'sessionId', 'sessionProviderKey', 'ephemeral', 'draftInput'].includes(key)) {
      throw new Error(`Unrecognized thread key: ${key}`);
    }
  }
  if (typeof thread.title !== 'string' || !thread.title.trim()) throw new Error('thread.title must be a non-empty string');
  if (!['default', 'auto-review', 'full-access'].includes(thread.approvalMode)) throw new Error('thread.approvalMode is invalid');
  if (typeof thread.planMode !== 'boolean') throw new Error('thread.planMode must be a boolean');
  if (payload.message !== undefined) throw new Error('fixture does not implement launch messages');
  const destination = payload.destination ?? {};
  let workspace;
  let createdWorkspace = false;
  if (destination.kind === 'existing-workspace') {
    workspace = db.prepare('SELECT id, name FROM workspaces WHERE id = ?').get(destination.workspaceId);
    if (!workspace) throw new Error(`Workspace not found: ${destination.workspaceId}`);
  } else if (destination.kind === 'new-workspace') {
    workspace = createWorkspaceRows(db, destination.workspace ?? {});
    createdWorkspace = true;
  } else {
    throw new Error("Invalid discriminator value. Expected 'existing-workspace' | 'new-workspace'");
  }
  threadCounter += 1;
  const id = `thread-created-${threadCounter}`;
  const now = new Date().toISOString();
  db.prepare('INSERT INTO workspace_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
    .run(id, workspace.id, thread.title, 0, 1, null, thread.approvalMode, thread.planMode ? 1 : 0, 0, '', null, 'ready', 0, now, now, now, 0);
  const activate = payload.activate !== false;
  return {
    workspace: { id: workspace.id, name: workspace.name ?? null },
    thread: { id, workspaceId: workspace.id, title: thread.title },
    selectedWorkspaceId: activate ? workspace.id : null,
    activate,
    createdWorkspace,
  };
}

async function electronInvoke(channel, payload) {
  fs.appendFileSync(callsFile, `${JSON.stringify({ channel, payload })}\n`);
  const mode = currentMode();
  const db = new DatabaseSync(path.join(desktop, 'playbot.db'));
  try {
    if (channel === 'codex:mcpServers:list' || channel === 'codex:mcpServers:reload') {
      return [{ name: 'playbot_lanes', enabled: true, error: null, toolCount: 13 }];
    }
    if (channel === 'threads:launch') {
      if (mode !== 'modern') throw new Error("No handler registered for 'threads:launch'");
      return launchThread(db, payload);
    }
    if (channel === 'workspace:create') {
      if (mode !== 'legacy') throw new Error("No handler registered for 'workspace:create'");
      return createWorkspaceRows(db, payload);
    }
    if (channel === 'threads:openThread') {
      if (mode !== 'legacy') throw new Error("No handler registered for 'threads:openThread'");
      const now = new Date().toISOString();
      db.prepare('INSERT INTO workspace_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
        .run(payload.id, payload.workspaceId, payload.title, 0, 1, null, payload.approvalMode, payload.planMode ? 1 : 0, 0, '', null, 'ready', 0, now, now, now, 0);
      return null;
    }
    if (channel === 'threads:archiveThread') {
      const changed = db.prepare('UPDATE workspace_threads SET archived = 1 WHERE id = ?').run(payload.threadId);
      if (Number(changed.changes) !== 1) throw new Error(`Thread not found: ${payload.threadId}`);
      return null;
    }
    if (channel === 'threads:send') return null;
    throw new Error(`fixture does not implement channel ${channel}`);
  } finally {
    db.close();
  }
}

function encodeFrame(text) {
  const payload = Buffer.from(text, 'utf8');
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length]);
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  return Buffer.concat([header, payload]);
}

function drainFrames(state, onMessage, onClose) {
  for (;;) {
    const buf = state.buf;
    if (buf.length < 2) return;
    const opcode = buf[0] & 0x0f;
    const masked = (buf[1] & 0x80) !== 0;
    let length = buf[1] & 0x7f;
    let offset = 2;
    if (length === 126) {
      if (buf.length < 4) return;
      length = buf.readUInt16BE(2);
      offset = 4;
    } else if (length === 127) {
      if (buf.length < 10) return;
      length = Number(buf.readBigUInt64BE(2));
      offset = 10;
    }
    const maskLength = masked ? 4 : 0;
    if (buf.length < offset + maskLength + length) return;
    const mask = masked ? buf.subarray(offset, offset + 4) : null;
    const payload = Buffer.from(buf.subarray(offset + maskLength, offset + maskLength + length));
    if (mask) for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
    state.buf = buf.subarray(offset + maskLength + length);
    if (opcode === 1) onMessage(payload.toString('utf8'));
    if (opcode === 8) return onClose();
  }
}

async function handleCdp(message) {
  if (message.method !== 'Runtime.evaluate') return { id: message.id, result: {} };
  try {
    const sandbox = { window: { electronAPI: { invoke: electronInvoke } } };
    const value = await vm.runInNewContext(`(async () => (${message.params.expression}))()`, sandbox);
    return { id: message.id, result: { result: { value } } };
  } catch (error) {
    return { id: message.id, result: { exceptionDetails: { text: error instanceof Error ? error.message : String(error) } } };
  }
}

const server = http.createServer((req, res) => {
  if (req.url === '/json') {
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify([{ type: 'page', webSocketDebuggerUrl: `ws://127.0.0.1:${server.address().port}/page` }]));
    return;
  }
  res.statusCode = 404;
  res.end();
});
server.on('upgrade', (req, socket) => {
  const accept = crypto.createHash('sha1')
    .update(`${req.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  const state = { buf: Buffer.alloc(0) };
  socket.on('data', (chunk) => {
    state.buf = Buffer.concat([state.buf, chunk]);
    drainFrames(state, async (text) => {
      const response = await handleCdp(JSON.parse(text));
      socket.write(encodeFrame(JSON.stringify(response)));
    }, () => {
      socket.write(Buffer.from([0x88, 0x00]));
      socket.end();
    });
  });
  socket.on('error', () => {});
});
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(path.join(desktop, 'DevToolsActivePort'), `${server.address().port}\n`);
});
NODE

node --no-warnings "$FIXTURE_ROOT/fake-cdp.mjs" &
FAKE_CDP_PID=$!
trap 'kill "$FAKE_CDP_PID" 2>/dev/null; fm_test_cleanup' EXIT
for _ in $(seq 1 50); do
  [ -f "$PLAYBOT_DESKTOP_DIR/DevToolsActivePort" ] && break
  sleep 0.1
done
[ -f "$PLAYBOT_DESKTOP_DIR/DevToolsActivePort" ] || fail "fake Playbot DevTools endpoint did not start"

setup_out=$(PLAYBOT_LANES_CONTROLLER_ROOT="$FIXTURE_ROOT/not-a-playbot-project" node --no-warnings "$SCRIPT" setup)
OUT="$setup_out" node --no-warnings <<'NODE' || fail "setup required the external terminal root to be a Playbot project"
const value = JSON.parse(process.env.OUT);
if (value.ready !== true || value.changed !== false) process.exit(1);
if (value.checks.renderer !== true || value.checks.controllerPresent !== false) process.exit(1);
if (!value.checks.hooks.ready || value.checks.toolCount !== 13) process.exit(1);
NODE
pass "fm-playbot-lanes: setup readiness does not require a controller project"

worker_json=$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path")

out=$(node --no-warnings "$SCRIPT" doctor)
OUT="$out" node --no-warnings <<'NODE' || fail "doctor did not detect the modern threads:launch chat-creation API"
const value = JSON.parse(process.env.OUT);
if (value.chatCreation !== 'launch') process.exit(1);
NODE
pass "fm-playbot-lanes: doctor detects the 0.94.0 threads:launch API from the safe capability probe"

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"create_workspace\",\"arguments\":{\"project\":$worker_json,\"name\":\"iso\",\"baseBranch\":\"develop\",\"branch\":\"fm-branch-1\"}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "create_workspace did not launch with the exact new-workspace payload and archive its setup chat"
const fs = require('node:fs');
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (calls.map(call => call.channel).join(',') !== 'threads:launch,threads:launch,threads:archiveThread') process.exit(1);
if (calls[0].payload.destination.kind !== 'fm-capability-probe') process.exit(1);
const payload = calls[1].payload;
if (payload.activate !== false || payload.destination.kind !== 'new-workspace') process.exit(1);
const spec = payload.destination.workspace;
if (Object.keys(spec).sort().join(',') !== 'baseBranch,branch,name,projectId,strategy') process.exit(1);
if (spec.strategy !== 'project' || spec.projectId !== 'project-worker') process.exit(1);
if (spec.name !== 'iso' || spec.baseBranch !== 'develop' || spec.branch !== 'fm-branch-1') process.exit(1);
if (payload.thread.title !== 'Firstmate workspace setup' || payload.thread.approvalMode !== 'default' || payload.thread.planMode !== false) process.exit(1);
if (calls[2].payload.threadId !== 'thread-created-1') process.exit(1);
const workspace = JSON.parse(process.env.OUT).result.structuredContent.workspace;
if (workspace.id !== 'ws-created-1' || workspace.name !== 'iso' || workspace.kind !== 'worktree') process.exit(1);
if (workspace.roots.length !== 1 || workspace.roots[0].branch !== 'fm-branch-1' || !workspace.roots[0].path) process.exit(1);
NODE
FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE' || fail "create_workspace left its setup chat unarchived"
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(path.join(process.env.FIXTURE_ROOT, 'desktop', 'playbot.db'), { readOnly: true });
const row = db.prepare('SELECT archived FROM workspace_threads WHERE id = ?').get('thread-created-1');
db.close();
if (!row || row.archived !== 1) process.exit(1);
NODE
pass "fm-playbot-lanes: create_workspace launches the 0.94.0 new-workspace payload and archives its setup chat"

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"create_workspace\",\"arguments\":{\"project\":$worker_json,\"name\":\"  \"}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "create_workspace did not omit empty optional fields from the strict payload"
const fs = require('node:fs');
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
const spec = calls[1].payload.destination.workspace;
if (Object.keys(spec).sort().join(',') !== 'projectId,strategy') process.exit(1);
const workspace = JSON.parse(process.env.OUT).result.structuredContent.workspace;
if (workspace.id !== 'ws-created-2' || workspace.roots[0].branch !== 'generated-2') process.exit(1);
NODE
pass "fm-playbot-lanes: create_workspace omits blank optional fields so Playbot's strict schema accepts the payload"

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"create_chat\",\"arguments\":{\"project\":$worker_json,\"workspace\":\"ws-worker\",\"title\":\"Direct chat\"}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "create_chat did not launch into the existing workspace without activating it"
const fs = require('node:fs');
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (calls.map(call => call.channel).join(',') !== 'threads:launch,threads:launch') process.exit(1);
const payload = calls[1].payload;
if (payload.destination.kind !== 'existing-workspace' || payload.destination.workspaceId !== 'ws-worker') process.exit(1);
if (payload.thread.title !== 'Direct chat' || payload.thread.approvalMode !== 'full-access' || payload.thread.planMode !== false) process.exit(1);
if (payload.activate !== false) process.exit(1);
const thread = JSON.parse(process.env.OUT).result.structuredContent.thread;
if (thread.id !== 'thread-created-3' || thread.workspaceId !== 'ws-worker' || thread.title !== 'Direct chat') process.exit(1);
NODE
pass "fm-playbot-lanes: create_chat launches with the Playbot-generated thread id and no UI activation"

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
printf '%s\n' '{"session_id":"controller-session","cwd":"fixture-controller","tool_name":"mcp__playbot_lanes__dispatch"}' \
  | node --no-warnings "$SCRIPT" hook-pretool
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dispatch\",\"arguments\":{\"project\":$worker_json,\"newWorkspace\":{\"baseBranch\":\"develop\",\"branch\":\"fm-branch-3\"},\"title\":\"Isolated task\",\"message\":\"Do the isolated work\"}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "dispatch did not create the workspace and worker chat in one launch"
const fs = require('node:fs');
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (calls.map(call => call.channel).join(',') !== 'threads:launch,threads:launch,threads:send') process.exit(1);
const payload = calls[1].payload;
if (payload.destination.kind !== 'new-workspace' || payload.activate !== false) process.exit(1);
if (payload.destination.workspace.baseBranch !== 'develop' || payload.destination.workspace.branch !== 'fm-branch-3') process.exit(1);
if (payload.thread.title !== 'Isolated task') process.exit(1);
if (calls[2].payload.threadId !== 'thread-created-4' || calls[2].payload.text !== 'Do the isolated work') process.exit(1);
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.thread.workspaceId !== 'ws-created-3' || value.lane.worker.workspaceId !== 'ws-created-3') process.exit(1);
if (value.lane.supervisor.id !== 'chat-controller' || !value.lane.active) process.exit(1);
NODE
pass "fm-playbot-lanes: dispatch creates a workspace, creates the worker chat inside it, and delivers the task"

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(PLAYBOT_LANES_CONTROLLER_ROOT="$FIXTURE_ROOT/not-a-playbot-project" rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dispatch\",\"arguments\":{\"project\":$worker_json,\"newWorkspace\":{\"branch\":\"fm-branch-4\"},\"title\":\"Terminal task\",\"message\":\"Do the terminal work\"}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "normal-terminal dispatch did not create and send without a controller chat"
const fs = require('node:fs');
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (calls.map(call => call.channel).join(',') !== 'threads:launch,threads:launch,threads:send') process.exit(1);
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.lane !== null || value.thread.workspaceId !== 'ws-created-4') process.exit(1);
if (value.supervision?.mode !== 'poll') process.exit(1);
if (value.supervision.tools.join(',') !== 'get_thread_status,read_thread') process.exit(1);
NODE
pass "fm-playbot-lanes: normal-terminal dispatch uses explicit polling supervision"

out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dispatch\",\"arguments\":{\"project\":$worker_json,\"workspace\":\"ws-worker\",\"newWorkspace\":{},\"title\":\"Conflict\",\"message\":\"x\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "workspace plus newWorkspace was not rejected"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('not both')) process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dispatch\",\"arguments\":{\"project\":$worker_json,\"newWorkspace\":{},\"thread\":\"Greeting\",\"message\":\"x\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "thread plus newWorkspace was not rejected"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('cannot be combined with newWorkspace')) process.exit(1);
NODE
pass "fm-playbot-lanes: ambiguous workspace targeting fails closed"

out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"workspace\":\"ws-worker\",\"thread\":\"Greeting\",\"message\":\"Plain send\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "existing-workspace targeting changed behavior"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.thread.id !== 'chat-worker' || value.thread.workspaceId !== 'ws-worker') process.exit(1);
NODE
pass "fm-playbot-lanes: existing-workspace selection is unchanged"

# The fake endpoint now serves the pre-0.94 surface, so the same adapter must
# detect the missing threads:launch handler and fall back to the legacy
# workspace:create and threads:openThread channels.
printf 'legacy\n' > "$FIXTURE_ROOT/ipc-mode"

out=$(node --no-warnings "$SCRIPT" doctor)
OUT="$out" node --no-warnings <<'NODE' || fail "doctor did not detect the legacy threads:openThread chat-creation API"
const value = JSON.parse(process.env.OUT);
if (value.chatCreation !== 'openThread') process.exit(1);
NODE
pass "fm-playbot-lanes: doctor detects the pre-0.94 chat-creation API on a legacy Playbot"

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"create_workspace\",\"arguments\":{\"project\":$worker_json,\"name\":\"legacy-iso\",\"branch\":\"fm-legacy-1\"}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "legacy create_workspace did not fall back to workspace:create"
const fs = require('node:fs');
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (calls.map(call => call.channel).join(',') !== 'threads:launch,workspace:create') process.exit(1);
const payload = calls[1].payload;
if (Object.keys(payload).sort().join(',') !== 'branch,name,projectId,strategy') process.exit(1);
if (payload.strategy !== 'project' || payload.name !== 'legacy-iso' || payload.branch !== 'fm-legacy-1') process.exit(1);
const workspace = JSON.parse(process.env.OUT).result.structuredContent.workspace;
if (workspace.id !== 'ws-created-5' || workspace.roots[0].branch !== 'fm-legacy-1') process.exit(1);
NODE
pass "fm-playbot-lanes: create_workspace falls back to workspace:create on a legacy Playbot"

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(PLAYBOT_LANES_CONTROLLER_ROOT="$FIXTURE_ROOT/not-a-playbot-project" rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dispatch\",\"arguments\":{\"project\":$worker_json,\"newWorkspace\":{\"branch\":\"fm-legacy-2\"},\"title\":\"Legacy task\",\"message\":\"Do the legacy work\"}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "legacy dispatch did not fall back to the pre-0.94 create-and-send sequence"
const fs = require('node:fs');
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (calls.map(call => call.channel).join(',') !== 'threads:launch,workspace:create,threads:openThread,threads:send') process.exit(1);
if (calls[2].payload.workspaceId !== 'ws-created-6' || calls[2].payload.title !== 'Legacy task') process.exit(1);
if (!String(calls[2].payload.id).startsWith('chat-lane-')) process.exit(1);
if (calls[3].payload.threadId !== calls[2].payload.id || calls[3].payload.text !== 'Do the legacy work') process.exit(1);
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.lane !== null || value.thread.workspaceId !== 'ws-created-6') process.exit(1);
NODE
pass "fm-playbot-lanes: dispatch falls back to the pre-0.94 channels on a legacy Playbot"

printf 'modern\n' > "$FIXTURE_ROOT/ipc-mode"
