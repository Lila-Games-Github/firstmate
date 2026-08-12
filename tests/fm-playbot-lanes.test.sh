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
if (!value.checks.hooks.ready || value.checks.expectedToolCount !== 12) process.exit(1);
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
