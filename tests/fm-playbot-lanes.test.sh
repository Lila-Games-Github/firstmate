#!/usr/bin/env bash
# Hermetic behavior tests for bin/fm-playbot-lanes.mjs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# This suite is entirely Node-driven, so a missing runtime used to make it
# print one ok line and exit 0 - a green run that proved nothing. Resolve a real
# runtime even when PATH lacks it, and fail loudly when there genuinely is none.
fm_test_require_node "fm-playbot-lanes"
pass "fm-playbot-lanes: node $("$FM_TEST_NODE_BIN" -p 'process.versions.node') resolved at $FM_TEST_NODE_BIN"

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
// A second ACTIVE but NOT selected workspace in the worker project, holding the
// only chat that is parked on a question card. Thread resolution and parked
// detection both have to reach it without an explicit workspace selector.
app.prepare('INSERT INTO workspaces VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
  .run('ws-worker-alt', 'project-worker', 'alt', 'worktree', 0, 'active', now, now);
app.prepare('INSERT INTO workspace_roots VALUES (?, ?, ?, ?)')
  .run('ws-worker-alt', 'root-worker', path.join(root, 'worker', '.worktrees', 'alt'), 'alt');

// An ARCHIVED workspace in the same project holding a chat whose title is
// identical to an active one. Nothing may resolve to it without an explicit
// workspace, and it must not make the active chat's title ambiguous.
const older = '2026-07-28T12:00:00.000Z';
app.prepare('INSERT INTO workspaces VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
  .run('ws-worker-archived', 'project-worker', 'retired', 'worktree', 0, 'archived', older, older);
app.prepare('INSERT INTO workspace_roots VALUES (?, ?, ?, ?)')
  .run('ws-worker-archived', 'root-worker', path.join(root, 'worker', '.worktrees', 'retired'), 'retired');

const insertThread = app.prepare('INSERT INTO workspace_threads VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
insertThread.run('chat-controller', 'ws-controller', 'Firstmate', 0, 1, 'controller-session', 'full-access', 0, 0, '', null, 'working', 0, now, now, now, 0);
insertThread.run('chat-worker', 'ws-worker', 'Greeting', 0, 1, 'worker-session', 'full-access', 0, 0, '', null, 'ready', 0, now, now, now, 0);
insertThread.run('chat-worker-alt', 'ws-worker-alt', 'Alt greeting', 0, 1, 'worker-alt-session', 'full-access', 0, 0, '', null, 'pending_input', 0, now, now, now, 0);
insertThread.run('chat-worker-archived', 'ws-worker-archived', 'Greeting', 0, 0, 'worker-archived-session', 'full-access', 0, 0, '', null, 'ready', 0, older, older, older, 0);
// A chat in that same ARCHIVED workspace which persisted state still calls
// pending_input. The parked detector must not offer it, because the confirming
// read it hands back cannot resolve a chat outside the default thread scope.
insertThread.run('chat-worker-retired-parked', 'ws-worker-archived', 'Retired parked', 1, 0, 'worker-retired-session', 'full-access', 0, 0, '', null, 'pending_input', 0, older, older, older, 0);
// A chat in an ACTIVE workspace which persisted state still calls
// pending_input, archived at the THREAD level. The detector must not offer it
// either, for the same reason: get_thread_card cannot resolve an archived chat
// and exposes no parameter that would widen its read to match.
insertThread.run('chat-worker-archived-parked', 'ws-worker', 'Archived parked', 2, 0, 'worker-archived-parked-session', 'full-access', 0, 0, '', null, 'pending_input', 0, older, older, older, 1);
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

# Resolving the workspace before the thread made every request without an
# explicit workspace fall back to the UI-selected workspace and then scope the
# lookup to it, so a named chat living anywhere else reported "Thread not found".
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_status\",\"arguments\":{\"project\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path"),\"thread\":\"chat-worker-alt\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a thread in a non-selected workspace did not resolve without an explicit workspace"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
const thread = value.result.structuredContent.thread;
if (thread.id !== 'chat-worker-alt' || thread.workspaceId !== 'ws-worker-alt') process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"read_thread\",\"arguments\":{\"project\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path"),\"thread\":\"Alt greeting\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a title in a non-selected workspace did not resolve without an explicit workspace"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
if (value.result.structuredContent.thread.id !== 'chat-worker-alt') process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_status\",\"arguments\":{\"project\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path"),\"workspace\":\"ws-worker\",\"thread\":\"chat-worker-alt\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "an explicit wrong workspace did not still fail closed"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('Thread not found in workspace ws-worker')) process.exit(1);
NODE
pass "fm-playbot-lanes: a named thread resolves project-wide, and an explicit workspace still narrows it"

# Resolving project-wide must still apply the active-workspace filter the
# explicit-workspace path applies: a chat in an ARCHIVED workspace stays out of
# the default scope entirely, so it is never sent to or answered, and its title
# cannot collide with an active chat's.
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_status\",\"arguments\":{\"project\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path"),\"thread\":\"Greeting\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "an identically titled chat in an archived workspace made an active chat's title ambiguous"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
const thread = value.result.structuredContent.thread;
if (thread.id !== 'chat-worker' || thread.workspaceId !== 'ws-worker') process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_status\",\"arguments\":{\"project\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$worker_path"),\"thread\":\"chat-worker-archived\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a chat in an archived workspace resolved inside the default project-wide scope"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('Thread not found in project project-worker')) process.exit(1);
NODE
pass "fm-playbot-lanes: an archived workspace's chats stay out of the default thread scope"

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
if (!value.checks.hooks.ready || value.checks.expectedToolCount !== 18) process.exit(1);
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
const snapshotFile = path.join(process.env.FIXTURE_ROOT, 'snapshots.json');
const versionFile = path.join(process.env.FIXTURE_ROOT, 'app-version');
const missingFile = path.join(process.env.FIXTURE_ROOT, 'ipc-missing');
const reconcileFile = path.join(process.env.FIXTURE_ROOT, 'send-reconciles');
const metadataFlakyFile = path.join(process.env.FIXTURE_ROOT, 'metadata-flaky');
const metadataVersionlessFile = path.join(process.env.FIXTURE_ROOT, 'metadata-versionless');
const sendDropFile = path.join(process.env.FIXTURE_ROOT, 'send-drop-key');
const steerResponseFile = path.join(process.env.FIXTURE_ROOT, 'steer-response');
const refreshFailureFile = path.join(process.env.FIXTURE_ROOT, 'refresh-failure');
// The same drop mechanism aimed at the snapshot Playbot returns WITH a completed
// write, so the post-action reads can be driven without touching the pre-action
// read in the same tool call.
const afterDropFile = path.join(process.env.FIXTURE_ROOT, 'after-drop-key');
const sendFailsFile = path.join(process.env.FIXTURE_ROOT, 'send-fails');
// A modern Playbot whose send path returns something that is not a snapshot at
// all: the verdict is unknown for the same reason a legacy Playbot's is, but on
// a version that can report one, so the two have to be told apart.
const sendNonObjectFile = path.join(process.env.FIXTURE_ROOT, 'send-non-object');
// A Playbot that ACCEPTS the chat-creation capability probe instead of rejecting
// it: the adapter refuses to guess which API it is talking to, so the detection
// itself throws while the send that came before it already succeeded.
const probeAcceptedFile = path.join(process.env.FIXTURE_ROOT, 'launch-accepts-probe');
let createCounter = 0;
let threadCounter = 0;
let sendCounter = 0;
let metadataFailures = 0;
let metadataVersionlessReads = 0;

function currentMode() {
  try {
    return fs.readFileSync(modeFile, 'utf8').trim() || 'modern';
  } catch {
    return 'modern';
  }
}

function readFileOr(file, fallback) {
  try {
    const text = fs.readFileSync(file, 'utf8').trim();
    return text || fallback;
  } catch {
    return fallback;
  }
}

function missingChannels() {
  return readFileOr(missingFile, '').split(/\s+/).filter(Boolean);
}

function emptySnapshot(threadId) {
  return {
    threadId,
    phase: { kind: 'ready', threadId: `session-${threadId}` },
    agentStatus: 'ready',
    userInputRequests: [],
    approvalRequests: [],
    mcpElicitationRequests: [],
    respondingRequestIds: [],
    pendingMessages: [],
    outboundMessages: [],
  };
}

// A projection can be REMOVED or arrive as null; both are unreadable shapes and
// both must refuse, so the drop knobs take "<key>" or "<key>:null".
function applyDropSpec(snapshot, spec) {
  const [key, mode] = spec.split(':');
  const partial = { ...snapshot };
  if (mode === 'null') partial[key] = null;
  else delete partial[key];
  return partial;
}

function loadSnapshots() {
  try {
    return JSON.parse(fs.readFileSync(snapshotFile, 'utf8'));
  } catch {
    return {};
  }
}

function saveSnapshots(store) {
  fs.writeFileSync(snapshotFile, `${JSON.stringify(store, null, 2)}\n`);
}

function snapshotFor(threadId) {
  const store = loadSnapshots();
  return store[threadId] ?? emptySnapshot(threadId);
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
  if (missingChannels().includes(channel)) throw new Error(`No handler registered for '${channel}'`);
  const db = new DatabaseSync(path.join(desktop, 'playbot.db'));
  try {
    if (channel === 'app:metadata') {
      // One transient failure, then healthy again: a version read must recover
      // inside the same long-lived server process.
      if (readFileOr(metadataFlakyFile, '') && metadataFailures === 0) {
        metadataFailures += 1;
        throw new Error('Playbot window is not available');
      }
      // A read that RESOLVES but carries no version string is the same bad
      // moment reached through the other branch, and must recover the same way.
      if (readFileOr(metadataVersionlessFile, '') && metadataVersionlessReads === 0) {
        metadataVersionlessReads += 1;
        return { name: 'Playbot' };
      }
      return { name: 'Playbot', version: readFileOr(versionFile, '0.95.0') };
    }
    if (channel === 'threads:getSnapshot') {
      const snapshot = snapshotFor(payload.threadId);
      const drop = readFileOr(path.join(process.env.FIXTURE_ROOT, 'snapshot-drop-key'), '');
      if (drop) return applyDropSpec(snapshot, drop);
      return snapshot;
    }
    if (channel === 'threads:respondToUserInput') {
      const store = loadSnapshots();
      const snapshot = store[payload.threadId] ?? emptySnapshot(payload.threadId);
      const index = (snapshot.userInputRequests ?? []).findIndex((request) => String(request.id) === String(payload.requestId));
      if (index < 0) throw new Error(`No pending user input request with id ${payload.requestId}`);
      snapshot.userInputRequests.splice(index, 1);
      snapshot.agentStatus = snapshot.userInputRequests.length > 0 ? 'pending_input' : 'working';
      store[payload.threadId] = snapshot;
      saveSnapshots(store);
      const afterDrop = readFileOr(afterDropFile, '');
      return afterDrop ? applyDropSpec(snapshot, afterDrop) : snapshot;
    }
    if (channel === 'threads:recallMessage') {
      const store = loadSnapshots();
      const snapshot = store[payload.threadId] ?? emptySnapshot(payload.threadId);
      const index = (snapshot.pendingMessages ?? []).findIndex((message) => message.id === payload.messageId);
      // The knob is read on BOTH outcomes: an unreadable projection has to be
      // reachable alongside not-recallable, not only alongside a recall.
      const afterDrop = readFileOr(afterDropFile, '');
      const projected = (value) => (afterDrop ? applyDropSpec(value, afterDrop) : value);
      if (index < 0) return { outcome: 'not-recallable', snapshot: projected(snapshot) };
      const [message] = snapshot.pendingMessages.splice(index, 1);
      store[payload.threadId] = snapshot;
      saveSnapshots(store);
      return {
        outcome: 'recalled',
        message: { id: message.id, input: { text: message.text } },
        snapshot: projected(snapshot),
      };
    }
    if (channel === 'codex:mcpServers:list' || channel === 'codex:mcpServers:reload') {
      return [{ name: 'playbot_lanes', enabled: true, error: null, toolCount: 18 }];
    }
    if (channel === 'threads:launch') {
      if (mode !== 'modern') throw new Error("No handler registered for 'threads:launch'");
      if (readFileOr(probeAcceptedFile, '') && (payload.destination ?? {}).kind === 'fm-capability-probe') {
        return { thread: { id: 'thread-probe-accepted' } };
      }
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
    if (channel === 'threads:steerMessage') {
      const store = loadSnapshots();
      const snapshot = store[payload.threadId] ?? emptySnapshot(payload.threadId);
      const message = (snapshot.pendingMessages ?? []).find((candidate) => candidate.id === payload.messageId);
      if (snapshot.phase?.kind === 'prompting' && snapshot.phase.turnId && message && message.steering !== true) {
        message.steering = true;
      }
      store[payload.threadId] = snapshot;
      saveSnapshots(store);
      if (readFileOr(refreshFailureFile, '') === 'steer') {
        db.prepare('UPDATE workspace_threads SET archived = 1 WHERE id = ?').run(payload.threadId);
      }
      const responseMode = readFileOr(steerResponseFile, '');
      if (responseMode === 'omit') {
        return {
          ...snapshot,
          pendingMessages: snapshot.pendingMessages.filter((candidate) => candidate.id !== payload.messageId),
          outboundMessages: snapshot.outboundMessages.filter((candidate) => candidate.id !== payload.messageId),
        };
      }
      if (responseMode === 'substitute') {
        return {
          ...snapshot,
          pendingMessages: snapshot.pendingMessages.map((candidate) => candidate.id === payload.messageId
            ? { ...candidate, id: `substitute-${payload.messageId}` }
            : candidate),
          outboundMessages: snapshot.outboundMessages.map((candidate) => candidate.id === payload.messageId
            ? { ...candidate, id: `substitute-${payload.messageId}` }
            : candidate),
        };
      }
      return snapshot;
    }
    if (channel === 'threads:send') {
      // A legacy Playbot returns nothing here, which is what leaves delivery
      // unconfirmed; a modern one returns the thread snapshot and holds the
      // message whenever the chat is parked on a card or already has a queue.
      if (mode !== 'modern') return null;
      if (readFileOr(sendNonObjectFile, '')) return 'accepted';
      const store = loadSnapshots();
      const snapshot = store[payload.threadId] ?? emptySnapshot(payload.threadId);
      sendCounter += 1;
      if (!readFileOr(reconcileFile, '')) {
        const held = (snapshot.userInputRequests ?? []).length > 0 || (snapshot.pendingMessages ?? []).length > 0;
        // Playbot's queued projection carries no createdAtMs; its outbound one does.
        if (readFileOr(sendFailsFile, '')) {
          snapshot.outboundMessages.push({ id: `msg-sent-${sendCounter}`, text: payload.text, status: 'failed', reason: 'Message not sent', createdAtMs: 1000 + sendCounter });
        } else if (held) snapshot.pendingMessages.push(payload.text === 'Idless force'
          ? { text: payload.text }
          : { id: `msg-sent-${sendCounter}`, text: payload.text });
        else snapshot.outboundMessages.push({ id: `msg-sent-${sendCounter}`, text: payload.text, status: 'sending', createdAtMs: 1000 + sendCounter });
      }
      store[payload.threadId] = snapshot;
      saveSnapshots(store);
      if (readFileOr(refreshFailureFile, '') === 'send') {
        db.prepare('UPDATE workspace_threads SET archived = 1 WHERE id = ?').run(payload.threadId);
      }
      const sendDrop = readFileOr(sendDropFile, '');
      if (sendDrop) return applyDropSpec(snapshot, sendDrop);
      return snapshot;
    }
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
if (!value.checks.hooks.ready || value.checks.toolCount !== 18) process.exit(1);
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
if (value.supervision.tools.join(',') !== 'get_thread_status,read_thread,get_thread_card') process.exit(1);
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

# ---------------------------------------------------------------------------
# Question cards, answering, and the pending-message queue.
# ---------------------------------------------------------------------------

FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
fs.writeFileSync(path.join(process.env.FIXTURE_ROOT, 'snapshots.json'), `${JSON.stringify({
  'chat-worker-alt': {
    threadId: 'chat-worker-alt',
    phase: { kind: 'prompting', threadId: 'worker-alt-session', turnId: 'turn-alt-1' },
    agentStatus: 'pending_input',
    userInputRequests: [{
      id: 10,
      method: 'item/tool/requestUserInput',
      params: {
        threadId: 'worker-alt-session',
        turnId: 'turn-alt-1',
        itemId: 'call_alt_1',
        questions: [{
          id: 'gate_ruling',
          header: 'Gate ruling',
          question: 'Keep payout at 0.0?',
          isOther: true,
          isSecret: false,
          options: [
            { label: 'Proceed (Recommended)', description: 'Apply the two narrow fixes.' },
            { label: 'Keep current commit', description: 'Approve what is there.' },
          ],
        }],
      },
    }],
    approvalRequests: [],
    mcpElicitationRequests: [],
    respondingRequestIds: [],
    pendingMessages: [
      { id: 'msg-1', text: 'First steer' },
      { id: 'msg-2', text: 'Superseding steer' },
    ],
    outboundMessages: [{ id: 'msg-0', text: 'Rejected steer', status: 'failed', reason: 'Message not sent', createdAtMs: 0 }],
  },
}, null, 2)}\n`);
NODE

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
# The detector and its own confirming read share one scope, so every candidate it
# offers is resolvable by the get_thread_card pointer it hands back: the parked
# chat in the ARCHIVED workspace is out of scope for both, and the parked chat in
# an active-but-unselected workspace is in scope for both.
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"list_parked_threads\",\"arguments\":{\"project\":$worker_json}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "list_parked_threads did not report the parked candidate with a confirm pointer"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.candidates.length !== 1) process.exit(1);
if (value.candidates[0].id !== 'chat-worker-alt' || value.candidates[0].workspaceId !== 'ws-worker-alt') process.exit(1);
if (value.candidates[0].status !== 'pending_input' || value.candidates[0].queuedCount !== 0) process.exit(1);
if (value.candidates.some(candidate => candidate.id === 'chat-worker-retired-parked')) process.exit(1);
if (value.confirmWith !== 'get_thread_card' || !value.note.includes('confirm each candidate')) process.exit(1);
NODE
[ -f "$FIXTURE_ROOT/ipc-calls.jsonl" ] && fail "list_parked_threads talked to Playbot instead of staying a persisted read"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-retired-parked\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "the confirming read resolved a chat the detector must therefore never offer"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('Thread not found in project project-worker')) process.exit(1);
NODE
pass "fm-playbot-lanes: list_parked_threads detects candidates from persisted state without touching Playbot"

# The detector advertises no parameter that widens its scope, because
# get_thread_card has none to match, and it ignores one if a client sends it
# anyway: a thread-level archived chat is outside the confirming read's scope,
# so offering it would hand back a candidate that pointer refuses to resolve.
rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"list_parked_threads\",\"arguments\":{\"project\":$worker_json,\"includeArchived\":true}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "the parked detector offered an archived chat its own confirming read cannot resolve"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.candidates.length !== 1 || value.candidates[0].id !== 'chat-worker-alt') process.exit(1);
if (value.candidates.some(candidate => candidate.id === 'chat-worker-archived-parked')) process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-archived-parked\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "the confirming read resolved an archived chat, so the detector's scope is not the one it points at"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('Thread not found in project project-worker')) process.exit(1);
NODE
out=$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
OUT="$out" node --no-warnings <<'NODE' || fail "list_parked_threads advertises a scope-widening parameter get_thread_card cannot match"
const tools = JSON.parse(process.env.OUT).result.tools;
const detector = tools.find(tool => tool.name === 'list_parked_threads');
if (!detector) process.exit(1);
if (JSON.stringify(Object.keys(detector.inputSchema.properties)) !== '["project"]') process.exit(1);
NODE
pass "fm-playbot-lanes: the parked detector cannot be widened past its confirming read's scope"

out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "get_thread_card did not enumerate the card's questions and options"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.parked !== true || value.status !== 'pending_input') process.exit(1);
if (value.playbot.version !== '0.95.0' || !value.playbot.verifiedVersions) process.exit(1);
if (value.cards.length !== 1) process.exit(1);
const card = value.cards[0];
if (card.requestId !== 10 || card.kind !== 'question' || card.answerable !== true) process.exit(1);
if (card.sessionId !== 'worker-alt-session' || card.turnId !== 'turn-alt-1' || card.itemId !== 'call_alt_1') process.exit(1);
const question = card.questions[0];
if (question.id !== 'gate_ruling' || question.header !== 'Gate ruling') process.exit(1);
if (question.isOther !== true || question.freeTextOnly !== false) process.exit(1);
if (question.options.map(option => option.label).join('|') !== 'Proceed (Recommended)|Keep current commit') process.exit(1);
if (value.queue.queued.map(message => message.id).join(',') !== 'msg-1,msg-2') process.exit(1);
if (value.queue.failed.length !== 1 || value.queue.failed[0].reason !== 'Message not sent') process.exit(1);
NODE
pass "fm-playbot-lanes: get_thread_card enumerates a named chat's card without focusing it"

out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"requestId\":999999,\"answers\":{\"gate_ruling\":\"Proceed (Recommended)\"}}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "answer_thread_card accepted a requestId that is not pending on the named chat"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('No pending request 999999')) process.exit(1);
if (!value.error.message.includes('10 (question)')) process.exit(1);
NODE
# Playbot resolves a request id against one process-wide registry, so an id that
# is genuinely pending on ANOTHER chat must be refused here rather than answering
# that other worker's card.
rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker\",\"requestId\":10,\"answers\":{\"gate_ruling\":\"Proceed (Recommended)\"}}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a request id pending on another chat was not refused on the named chat"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('No pending request 10 on this chat and it holds no pending card at all')) process.exit(1);
NODE
CALLS_AFTER="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "a refused answer still wrote to Playbot"
const fs = require('node:fs');
let calls = [];
try {
  calls = fs.readFileSync(process.env.CALLS_AFTER, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
} catch {
  calls = [];
}
if (calls.some(call => call.channel === 'threads:respondToUserInput')) process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"requestId\":10,\"answers\":{\"not_a_question\":\"x\"}}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "answer_thread_card accepted an answer for a question the card does not ask"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('Question not on request 10: not_a_question')) process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"requestId\":10,\"expectTurnId\":\"turn-alt-0\",\"answers\":{\"gate_ruling\":\"Proceed (Recommended)\"}}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "answer_thread_card ignored a turn id that had moved"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('belongs to turn turn-alt-1, not turn-alt-0')) process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"requestId\":10,\"skip\":true,\"answers\":{\"gate_ruling\":\"Proceed (Recommended)\"}}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "answer_thread_card accepted skip together with an answer"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('omit answers')) process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"requestId\":10,\"answers\":{}}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "an empty answers object was silently treated as a skip"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('pass skip=true')) process.exit(1);
NODE
pass "fm-playbot-lanes: answer_thread_card refuses a borrowed request id, an unknown question, a moved turn, and an implicit skip"

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"requestId\":10,\"expectTurnId\":\"turn-alt-1\",\"expectItemId\":\"call_alt_1\",\"answers\":{\"gate_ruling\":\"Proceed (Recommended)\"}}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "answer_thread_card did not send the option label Playbot itself reported"
const fs = require('node:fs');
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
const respond = calls.filter(call => call.channel === 'threads:respondToUserInput');
if (respond.length !== 1) process.exit(1);
if (respond[0].payload.threadId !== 'chat-worker-alt' || respond[0].payload.requestId !== 10) process.exit(1);
if (JSON.stringify(respond[0].payload.response) !== JSON.stringify({ answers: { gate_ruling: { answers: ['Proceed (Recommended)'] } } })) process.exit(1);
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.answered !== true || value.skipped !== false || value.requestId !== 10) process.exit(1);
if (value.cardsRemaining.length !== 0 || value.statusAfter !== 'working') process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"requestId\":10,\"answers\":{\"gate_ruling\":\"Keep current commit\"}}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "answering an already-answered card was not reported as no longer pending"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('No pending request 10')) process.exit(1);
if (!value.error.message.includes('holds no pending card at all')) process.exit(1);
NODE
pass "fm-playbot-lanes: answer_thread_card answers the card once and reports a second attempt as already answered"

out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a persisted pending_input with no live card was not flagged as a false candidate"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.parked !== false || value.cards.length !== 0) process.exit(1);
if (value.warnings.length !== 1 || !value.warnings[0].includes('treat it as not parked')) process.exit(1);
NODE
pass "fm-playbot-lanes: get_thread_card contradicts a persisted pending_input that holds no live card"

out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"list_queued_messages\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "list_queued_messages did not separate queued from failed messages"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.queued.map(message => `${message.id}:${message.text}`).join(',') !== 'msg-1:First steer,msg-2:Superseding steer') process.exit(1);
if (value.sending.length !== 0 || value.failed.map(message => message.id).join(',') !== 'msg-0') process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"drop_queued_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"messageId\":\"msg-1\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "drop_queued_message did not recall the superseded steer"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.outcome !== 'recalled' || value.recalled.id !== 'msg-1') process.exit(1);
if (value.queueAfter.queued.map(message => message.id).join(',') !== 'msg-2') process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"drop_queued_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"messageId\":\"msg-1\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "an already-delivered message was reported as an error instead of not-recallable"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
if (value.result.structuredContent.outcome !== 'not-recallable') process.exit(1);
NODE
pass "fm-playbot-lanes: queued messages are listable and one can be dropped instead of resent"

printf 'threads:getSnapshot\n' > "$FIXTURE_ROOT/ipc-missing"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a renamed Playbot channel did not fail loudly with the channel and version"
const value = JSON.parse(process.env.OUT);
if (!value.error) process.exit(1);
if (!value.error.message.includes("does not register the 'threads:getSnapshot' channel")) process.exit(1);
if (!value.error.message.includes('Playbot 0.95.0')) process.exit(1);
if (!value.error.message.includes('re-verify the channel names')) process.exit(1);
NODE
printf '0.99.0\n' > "$FIXTURE_ROOT/app-version"
printf 'threads:recallMessage\n' > "$FIXTURE_ROOT/ipc-missing"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"drop_queued_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"messageId\":\"msg-2\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a missing recall channel did not name the upgraded Playbot version"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('Playbot 0.99.0')) process.exit(1);
if (!value.error.message.includes("does not register the 'threads:recallMessage' channel")) process.exit(1);
NODE
rm -f "$FIXTURE_ROOT/ipc-missing" "$FIXTURE_ROOT/app-version"
printf 'userInputRequests\n' > "$FIXTURE_ROOT/snapshot-drop-key"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a changed snapshot shape was not refused by name"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('without userInputRequests')) process.exit(1);
if (!value.error.message.includes('re-verify the snapshot shape')) process.exit(1);
NODE
printf 'userInputRequests:null\n' > "$FIXTURE_ROOT/snapshot-drop-key"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a null card projection read as no card instead of refusing by name"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('without userInputRequests')) process.exit(1);
if (!value.error.message.includes('re-verify the snapshot shape')) process.exit(1);
NODE
rm -f "$FIXTURE_ROOT/snapshot-drop-key"
pass "fm-playbot-lanes: a renamed channel or changed snapshot shape refuses and names what is missing"

# serve is one long-lived process, so a single unreadable version read must not
# pin the provenance stamp to null for the rest of its life - neither when the
# read fails nor when it resolves carrying no version string.
printf 'yes\n' > "$FIXTURE_ROOT/metadata-flaky"
card_request_one="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\"}}}"
card_request_two="{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\"}}}"
out=$(printf '%s\n%s\n' "$card_request_one" "$card_request_two" | node --no-warnings "$SCRIPT" serve)
OUT="$out" node --no-warnings <<'NODE' || fail "a transient version read failure was cached for the life of the server process"
const responses = process.env.OUT.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
if (responses.length !== 2) process.exit(1);
const first = responses.find(response => response.id === 1);
const second = responses.find(response => response.id === 2);
if (first.error || second.error) process.exit(1);
if (first.result.structuredContent.playbot.version !== null) process.exit(1);
if (second.result.structuredContent.playbot.version !== '0.95.0') process.exit(1);
NODE
rm -f "$FIXTURE_ROOT/metadata-flaky"
printf 'yes\n' > "$FIXTURE_ROOT/metadata-versionless"
out=$(printf '%s\n%s\n' "$card_request_one" "$card_request_two" | node --no-warnings "$SCRIPT" serve)
OUT="$out" node --no-warnings <<'NODE' || fail "a version read that resolved without a version string was cached for the life of the server process"
const responses = process.env.OUT.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
if (responses.length !== 2) process.exit(1);
const first = responses.find(response => response.id === 1);
const second = responses.find(response => response.id === 2);
if (first.error || second.error) process.exit(1);
if (first.result.structuredContent.playbot.version !== null) process.exit(1);
if (second.result.structuredContent.playbot.version !== '0.95.0') process.exit(1);
NODE
rm -f "$FIXTURE_ROOT/metadata-versionless"
pass "fm-playbot-lanes: a version read that failed or carried no version recovers instead of sticking at unreadable"

# ---------------------------------------------------------------------------
# Delivery verdicts: a message Playbot only holds must never read as delivered.
# ---------------------------------------------------------------------------

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"message\":\"Held steer\"}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "a send onto an existing queue was not reported as held"
const fs = require('node:fs');
const value = JSON.parse(process.env.OUT).result.structuredContent;
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (value.thread.id !== 'chat-worker-alt') process.exit(1);
if (value.delivery.state !== 'queued') process.exit(1);
if (!value.delivery.messageId || value.delivery.queuedTotal !== 2 || value.delivery.queuedAhead !== 1) process.exit(1);
if (!value.delivery.note.includes('has not seen it')) process.exit(1);
if (!value.delivery.note.includes('Do not resend')) process.exit(1);
if (calls.map(call => call.channel).join(',') !== 'threads:send') process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"workspace\":\"ws-worker\",\"thread\":\"Greeting\",\"message\":\"Live steer\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a dispatched send was not reported as in flight"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.delivery.state !== 'sending' || !value.delivery.messageId || value.delivery.queuedTotal !== 0) process.exit(1);
if (value.delivery.note !== undefined) process.exit(1);
NODE
printf 'yes\n' > "$FIXTURE_ROOT/send-reconciles"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"workspace\":\"ws-worker\",\"thread\":\"Greeting\",\"message\":\"Accepted steer\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "an accepted send was not reported as delivered"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.delivery.state !== 'delivered') process.exit(1);
NODE
rm -f "$FIXTURE_ROOT/send-reconciles"
pass "fm-playbot-lanes: send_message reports held, in-flight, and delivered separately"

# force=true uses Playbot's own exact-message steering action only after the
# ordinary send response proves that specific message is held. The response
# snapshot must then mark that same id as steering before the MCP reports it as
# such. No selected chat or workspace participates in either lookup or action.
out=$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
OUT="$out" node --no-warnings <<'NODE' || fail "the steering surfaces did not advertise the explicit force flag"
const tools = JSON.parse(process.env.OUT).result.tools;
for (const name of ['send_message', 'dispatch']) {
  const tool = tools.find(candidate => candidate.name === name);
  if (!tool || tool.inputSchema.properties.force?.type !== 'boolean') process.exit(1);
  if (tool.inputSchema.properties.force.default !== false) process.exit(1);
}
NODE

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"message\":\"Immediate steer\",\"force\":true}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "force=true did not promote the exact held message into the active turn"
const fs = require('node:fs');
const value = JSON.parse(process.env.OUT).result.structuredContent;
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (calls.map(call => call.channel).join(',') !== 'threads:send,threads:steerMessage') process.exit(1);
if (calls[0].payload.threadId !== 'chat-worker-alt' || calls[1].payload.threadId !== 'chat-worker-alt') process.exit(1);
if (calls[0].payload.text !== 'Immediate steer' || calls[1].payload.messageId !== value.delivery.messageId) process.exit(1);
if (value.thread.id !== 'chat-worker-alt' || value.thread.workspaceId !== 'ws-worker-alt') process.exit(1);
if (value.delivery.state !== 'steering' || value.force.state !== 'applied') process.exit(1);
if (value.force.mechanism !== 'threads:steerMessage' || value.force.activeTurn !== 'continues') process.exit(1);
if (!value.force.evidence.includes('steering=true')) process.exit(1);
if (calls.some(call => ['threads:setActiveThread', 'workspace:select', 'threads:stop', 'threads:archiveThread'].includes(call.channel))) process.exit(1);
NODE

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(PLAYBOT_LANES_CONTROLLER_ROOT="$FIXTURE_ROOT/not-a-playbot-project" rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dispatch\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"message\":\"Immediate dispatch steer\",\"force\":true}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "dispatch did not expose the same force semantics for an existing busy thread"
const fs = require('node:fs');
const value = JSON.parse(process.env.OUT).result.structuredContent;
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (calls.map(call => call.channel).join(',') !== 'threads:send,threads:steerMessage') process.exit(1);
if (calls.some(call => call.channel === 'threads:launch')) process.exit(1);
if (calls[1].payload.messageId !== value.delivery.messageId) process.exit(1);
if (value.thread.id !== 'chat-worker-alt' || value.delivery.state !== 'steering') process.exit(1);
if (value.force.state !== 'applied' || value.supervision.mode !== 'poll') process.exit(1);
NODE
pass "fm-playbot-lanes: force steers the exact queued message without interrupting or retargeting another chat"

for failure_phase in send steer; do
  printf '%s\n' "$failure_phase" > "$FIXTURE_ROOT/refresh-failure"
  rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
  out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"message\":\"$failure_phase refresh failure\",\"force\":true}}}")
  rm -f "$FIXTURE_ROOT/refresh-failure"
  FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(path.join(process.env.FIXTURE_ROOT, 'desktop', 'playbot.db'));
db.prepare('UPDATE workspace_threads SET archived = 0 WHERE id = ?').run('chat-worker-alt');
db.close();
NODE
  OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "a $failure_phase-time local refresh prevented or hid exact-message steering"
const fs = require('node:fs');
const response = JSON.parse(process.env.OUT);
const value = response.result?.structuredContent;
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (!value || response.error) process.exit(1);
if (calls.map(call => call.channel).join(',') !== 'threads:send,threads:steerMessage') process.exit(1);
if (calls[1].payload.messageId !== value.delivery.messageId) process.exit(1);
if (value.thread.id !== 'chat-worker-alt' || value.thread.workspaceId !== 'ws-worker-alt') process.exit(1);
if (value.delivery.state !== 'steering' || value.force.state !== 'applied') process.exit(1);
NODE
done
pass "fm-playbot-lanes: local refresh failures cannot prevent or hide exact-message steering"

# A force action happens after Playbot has accepted the ordinary send. If the
# steering response cannot be observed, the result must remain unknown rather
# than claiming either immediate steering or ordinary delivery.
printf 'threads:steerMessage\n' > "$FIXTURE_ROOT/ipc-missing"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"message\":\"Unconfirmed force\",\"force\":true}}}")
rm -f "$FIXTURE_ROOT/ipc-missing"
OUT="$out" node --no-warnings <<'NODE' || fail "an unconfirmed force response was reported as delivered"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.delivery.state !== 'unknown' || value.force.state !== 'unknown') process.exit(1);
if (!value.force.reason.includes("No handler registered for 'threads:steerMessage'")) process.exit(1);
if (!value.delivery.note.includes('Immediate steering is unconfirmed')) process.exit(1);
NODE

for response_mode in omit substitute; do
  printf '%s\n' "$response_mode" > "$FIXTURE_ROOT/steer-response"
  rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
  out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"message\":\"$response_mode force evidence\",\"force\":true}}}")
  OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "force with a $response_mode exact message id was reported as delivered"
const fs = require('node:fs');
const value = JSON.parse(process.env.OUT).result.structuredContent;
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (calls.map(call => call.channel).join(',') !== 'threads:send,threads:steerMessage') process.exit(1);
if (!value.delivery.messageId || calls[1].payload.messageId !== value.delivery.messageId) process.exit(1);
if (value.delivery.state !== 'unknown' || value.force.state !== 'not-applied') process.exit(1);
if (!value.delivery.note.includes('exact queued message id')) process.exit(1);
if (!value.force.evidence.includes('did not contain the exact queued message id')) process.exit(1);
NODE
done
rm -f "$FIXTURE_ROOT/steer-response"

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"message\":\"Idless force\",\"force\":true}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "force guessed at a held message Playbot returned without an exact id"
const fs = require('node:fs');
const value = JSON.parse(process.env.OUT).result.structuredContent;
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (value.delivery.state !== 'queued' || value.delivery.messageId !== null) process.exit(1);
if (value.force.state !== 'not-applied' || !value.force.reason.includes('no exact queued message id')) process.exit(1);
if (calls.map(call => call.channel).join(',') !== 'threads:send') process.exit(1);
NODE
pass "fm-playbot-lanes: force never claims delivery without Playbot confirmation"

# A send snapshot that IS returned but has lost the queue projection is a
# renamed shape, not a legacy Playbot, so it must refuse by name instead of
# masquerading as an unconfirmed send forever.
printf 'pendingMessages\n' > "$FIXTURE_ROOT/send-drop-key"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"workspace\":\"ws-worker\",\"thread\":\"Greeting\",\"message\":\"Unreadable steer\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a send snapshot missing the queue projection degraded quietly instead of naming the field"
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('without pendingMessages')) process.exit(1);
if (!value.error.message.includes('Playbot 0.95.0')) process.exit(1);
if (!value.error.message.includes('re-verify the snapshot shape')) process.exit(1);
NODE
printf 'pendingMessages:null\n' > "$FIXTURE_ROOT/send-drop-key"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"workspace\":\"ws-worker\",\"thread\":\"Greeting\",\"message\":\"Unreadable null steer\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a null queue projection was reported as delivered instead of refusing by name"
const value = JSON.parse(process.env.OUT);
if (value.result) process.exit(1);
if (!value.error || !value.error.message.includes('without pendingMessages')) process.exit(1);
if (!value.error.message.includes('re-verify the snapshot shape')) process.exit(1);
NODE
rm -f "$FIXTURE_ROOT/send-drop-key"
pass "fm-playbot-lanes: a send snapshot whose queue projection is missing or unreadable refuses by name"

# That refusal lands AFTER Playbot accepted the send, so dispatch must not read
# it as a failed send: the task may already be with the worker, and an inactive
# lane silently loses every later wake for it. Only a send that never reached
# Playbot may tear the lane down. Both halves drive the same lane, so the only
# difference between them is where the failure happened.
printf '%s\n' '{"session_id":"controller-session","cwd":"fixture-controller","tool_name":"mcp__playbot_lanes__register_lane"}' \
  | node --no-warnings "$SCRIPT" hook-pretool
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"register_lane\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\"}}}")
alt_lane=$(OUT="$out" node -e 'process.stdout.write(JSON.parse(process.env.OUT).result.structuredContent.lane.id)')
[ -n "$alt_lane" ] || fail "could not register a lane onto the parked worker"

printf 'pendingMessages\n' > "$FIXTURE_ROOT/send-drop-key"
printf '%s\n' '{"session_id":"controller-session","cwd":"fixture-controller","tool_name":"mcp__playbot_lanes__dispatch"}' \
  | node --no-warnings "$SCRIPT" hook-pretool
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dispatch\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"message\":\"Unreadable dispatch\"}}}")
rm -f "$FIXTURE_ROOT/send-drop-key"
OUT="$out" LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$alt_lane.json" node --no-warnings <<'NODE' || fail "an unreadable verdict on an accepted send tore the dispatch lane down"
const fs = require('node:fs');
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes('without pendingMessages')) process.exit(1);
const route = JSON.parse(fs.readFileSync(process.env.LANE_FILE, 'utf8'));
if (route.active !== true || route.error !== undefined) process.exit(1);
NODE
pass "fm-playbot-lanes: an unreadable verdict refuses without deactivating the lane it was dispatched on"

printf 'threads:send\n' > "$FIXTURE_ROOT/ipc-missing"
printf '%s\n' '{"session_id":"controller-session","cwd":"fixture-controller","tool_name":"mcp__playbot_lanes__dispatch"}' \
  | node --no-warnings "$SCRIPT" hook-pretool
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dispatch\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"message\":\"Undelivered dispatch\"}}}")
rm -f "$FIXTURE_ROOT/ipc-missing"
OUT="$out" LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$alt_lane.json" node --no-warnings <<'NODE' || fail "a dispatch whose send never reached Playbot left the lane active"
const fs = require('node:fs');
const value = JSON.parse(process.env.OUT);
if (!value.error || !value.error.message.includes("No handler registered for 'threads:send'")) process.exit(1);
const route = JSON.parse(fs.readFileSync(process.env.LANE_FILE, 'utf8'));
if (route.active !== false) process.exit(1);
if (!String(route.error).includes("threads:send")) process.exit(1);
NODE
pass "fm-playbot-lanes: a dispatch whose send never reached Playbot deactivates the lane"

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(PLAYBOT_LANES_CONTROLLER_ROOT="$FIXTURE_ROOT/not-a-playbot-project" rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"dispatch\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"message\":\"Held task\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "dispatch reported a task Playbot is only holding as delivered"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.thread.id !== 'chat-worker-alt') process.exit(1);
if (value.delivery.state !== 'queued') process.exit(1);
if (value.supervision.tools.join(',') !== 'get_thread_status,read_thread,get_thread_card') process.exit(1);
NODE
pass "fm-playbot-lanes: dispatch onto a parked worker reports the task as held, not delivered"

printf 'legacy\n' > "$FIXTURE_ROOT/ipc-mode"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"workspace\":\"ws-worker\",\"thread\":\"Greeting\",\"message\":\"Unconfirmed steer\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a send with no snapshot back was reported as delivered instead of unconfirmed"
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.delivery.state !== 'unknown' || value.delivery.messageId !== null) process.exit(1);
if (!value.delivery.note.includes('delivery is unconfirmed')) process.exit(1);
NODE
rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"send_message\",\"arguments\":{\"project\":$worker_json,\"workspace\":\"ws-worker\",\"thread\":\"Greeting\",\"message\":\"Unconfirmed legacy force\",\"force\":true}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "force on a Playbot with no send snapshot guessed that a queued message existed"
const fs = require('node:fs');
const value = JSON.parse(process.env.OUT).result.structuredContent;
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
if (value.delivery.state !== 'unknown' || value.force.state !== 'unknown') process.exit(1);
if (!value.force.evidence.includes('no exact queued message was available')) process.exit(1);
if (calls.map(call => call.channel).join(',') !== 'threads:send') process.exit(1);
NODE
printf 'modern\n' > "$FIXTURE_ROOT/ipc-mode"
pass "fm-playbot-lanes: a Playbot that returns no send snapshot leaves delivery explicitly unconfirmed"

# ---------------------------------------------------------------------------
# The persisted queue count: an unreadable ledger must never read as empty.
# ---------------------------------------------------------------------------

FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(path.join(process.env.FIXTURE_ROOT, 'desktop', 'playbot.db'));
const update = db.prepare('UPDATE workspace_threads SET pending_queue_json = ? WHERE id = ?');
update.run(JSON.stringify({ messages: [{ id: 'held-1', text: 'First steer' }, { id: 'held-2', text: 'Second steer' }] }), 'chat-worker');
update.run(JSON.stringify({ queueVersion: 2, entries: [{ id: 'held-1' }] }), 'chat-controller');
update.run(JSON.stringify({ messages: [] }), 'chat-worker-alt');
db.close();
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_status\",\"arguments\":{\"project\":$worker_json,\"thread\":\"Greeting\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "a recognized two-message ledger was not counted"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
if (value.result.structuredContent.thread.queuedCount !== 2) process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_status\",\"arguments\":{\"project\":\"firstmate\",\"thread\":\"Firstmate\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "an unrecognized queue ledger was reported as an empty queue"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
if (value.result.structuredContent.thread.queuedCount !== null) process.exit(1);
NODE
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_thread_status\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\"}}}")
OUT="$out" node --no-warnings <<'NODE' || fail "an empty ledger was not counted as zero"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
if (value.result.structuredContent.thread.queuedCount !== 0) process.exit(1);
NODE
pass "fm-playbot-lanes: an unreadable persisted queue reads as unknown, never as empty"

# ---------------------------------------------------------------------------
# Answering: verbatim values, partial answers, and an in-flight response.
# ---------------------------------------------------------------------------

FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const file = path.join(process.env.FIXTURE_ROOT, 'snapshots.json');
const store = JSON.parse(fs.readFileSync(file, 'utf8'));
// A two-question card whose first option label carries surrounding whitespace,
// and whose request Playbot already has a response in flight for.
store['chat-worker-alt'] = {
  threadId: 'chat-worker-alt',
  phase: { kind: 'prompting', threadId: 'worker-alt-session', turnId: 'turn-alt-2' },
  agentStatus: 'pending_input',
  userInputRequests: [{
    id: 11,
    method: 'item/tool/requestUserInput',
    params: {
      threadId: 'worker-alt-session',
      turnId: 'turn-alt-2',
      itemId: 'call_alt_2',
      questions: [
        { id: 'payout', header: 'Payout', question: 'Keep it?', isOther: false, isSecret: false,
          options: [{ label: '  Keep 0.0 (Recommended)  ', description: 'Padded on purpose.' }, { label: 'Fix now', description: '' }] },
        { id: 'comments', header: 'Comments', question: 'Where?', isOther: false, isSecret: false,
          options: [{ label: 'Block', description: '' }, { label: 'Inline', description: '' }] },
      ],
    },
  }],
  approvalRequests: [],
  mcpElicitationRequests: [],
  respondingRequestIds: [11],
  pendingMessages: [],
  outboundMessages: [],
};
fs.writeFileSync(file, `${JSON.stringify(store, null, 2)}\n`);
NODE

rm -f "$FIXTURE_ROOT/ipc-calls.jsonl"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"requestId\":11,\"answers\":{\"payout\":\"  Keep 0.0 (Recommended)  \"}}}}")
OUT="$out" CALLS="$FIXTURE_ROOT/ipc-calls.jsonl" node --no-warnings <<'NODE' || fail "a partial answer with a padded option label was not sent verbatim and reported as partial"
const fs = require('node:fs');
const calls = fs.readFileSync(process.env.CALLS, 'utf8').trim().split('\n').map(JSON.parse);
const respond = calls.filter(call => call.channel === 'threads:respondToUserInput');
if (respond.length !== 1) process.exit(1);
// Playbot uses the option label as the answer value, so the padding must survive.
if (JSON.stringify(respond[0].payload.response) !== JSON.stringify({ answers: { payout: { answers: ['  Keep 0.0 (Recommended)  '] } } })) process.exit(1);
const value = JSON.parse(process.env.OUT).result.structuredContent;
if (value.answered !== true || value.partial !== true) process.exit(1);
if (value.answeredQuestions.join(',') !== 'payout') process.exit(1);
if (value.unansweredQuestions.join(',') !== 'comments') process.exit(1);
if (value.alreadyResponding !== true) process.exit(1);
if (!value.warnings.some(warning => warning.includes('response in flight'))) process.exit(1);
if (!value.warnings.some(warning => warning.includes('Partial answer'))) process.exit(1);
NODE
pass "fm-playbot-lanes: a partial answer sends its option label verbatim and reports what went unanswered"

# ---------------------------------------------------------------------------
# A write that already succeeded must never be reported as a failure, and the
# snapshot Playbot returns with it must never read as an empty queue or a
# cleared card when that projection is unreadable.
# ---------------------------------------------------------------------------

FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const file = path.join(process.env.FIXTURE_ROOT, 'snapshots.json');
const store = JSON.parse(fs.readFileSync(file, 'utf8'));
store['chat-worker-alt'] = {
  threadId: 'chat-worker-alt',
  phase: { kind: 'prompting', threadId: 'worker-alt-session', turnId: 'turn-alt-3' },
  agentStatus: 'pending_input',
  userInputRequests: [{
    id: 12,
    method: 'item/tool/requestUserInput',
    params: {
      threadId: 'worker-alt-session',
      turnId: 'turn-alt-3',
      itemId: 'call_alt_3',
      questions: [{ id: 'ruling', header: 'Ruling', question: 'Proceed?', isOther: false, isSecret: false,
        options: [{ label: 'Proceed', description: '' }] }],
    },
  }],
  approvalRequests: [],
  mcpElicitationRequests: [],
  respondingRequestIds: [],
  pendingMessages: [{ id: 'msg-9', text: 'Held steer to recall' }],
  outboundMessages: [],
};
fs.writeFileSync(file, `${JSON.stringify(store, null, 2)}\n`);
NODE

printf 'pendingMessages:null\n' > "$FIXTURE_ROOT/after-drop-key"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"drop_queued_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"messageId\":\"msg-9\"}}}")
rm -f "$FIXTURE_ROOT/after-drop-key"
OUT="$out" node --no-warnings <<'NODE' || fail "a recall that succeeded reported an unreadable queue as empty or failed outright"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
const result = value.result.structuredContent;
if (result.outcome !== 'recalled' || result.recalled.id !== 'msg-9') process.exit(1);
if (result.queueAfter.queued !== null) process.exit(1);
if (!Array.isArray(result.queueAfter.sending) || !Array.isArray(result.queueAfter.failed)) process.exit(1);
if (!result.warnings.some(warning => warning.includes('pendingMessages'))) process.exit(1);
if (!result.warnings.some(warning => warning.includes('null rather than empty'))) process.exit(1);
NODE

printf 'userInputRequests:null\n' > "$FIXTURE_ROOT/after-drop-key"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"requestId\":12,\"answers\":{\"ruling\":\"Proceed\"}}}}")
rm -f "$FIXTURE_ROOT/after-drop-key"
OUT="$out" node --no-warnings <<'NODE' || fail "an answer that succeeded reported an unreadable card projection as cleared or failed outright"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
const result = value.result.structuredContent;
if (result.answered !== true || result.requestId !== 12) process.exit(1);
if (result.cardsRemaining !== null) process.exit(1);
if (!result.warnings.some(warning => warning.includes('userInputRequests'))) process.exit(1);
if (!result.warnings.some(warning => warning.includes('cardsRemaining is null rather than empty'))) process.exit(1);
NODE
pass "fm-playbot-lanes: a completed answer or recall reports an unreadable projection as null, never as empty"

# A recall Playbot did NOT apply must not be warned about as if it had been, and
# an unreadable projection must still not read as empty on that path either.
printf 'pendingMessages:null\n' > "$FIXTURE_ROOT/after-drop-key"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"drop_queued_message\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"messageId\":\"msg-9\"}}}")
rm -f "$FIXTURE_ROOT/after-drop-key"
OUT="$out" node --no-warnings <<'NODE' || fail "a recall Playbot never applied was warned about as applied"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
const result = value.result.structuredContent;
if (result.outcome !== 'not-recallable' || result.recalled !== null) process.exit(1);
if (result.queueAfter.queued !== null) process.exit(1);
if (result.warnings.length !== 1) process.exit(1);
if (result.warnings.some(warning => warning.includes('The recall was applied'))) process.exit(1);
if (!result.warnings[0].includes('NOT applied')) process.exit(1);
if (!result.warnings[0].includes('not-recallable')) process.exit(1);
if (!result.warnings[0].includes('pendingMessages')) process.exit(1);
NODE

# An unreadable respondingRequestIds alone leaves cardsRemaining populated and
# correct, so nothing may claim it is null: each card reports responding: null.
FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const file = path.join(process.env.FIXTURE_ROOT, 'snapshots.json');
const store = JSON.parse(fs.readFileSync(file, 'utf8'));
store['chat-worker-alt'] = {
  threadId: 'chat-worker-alt',
  phase: { kind: 'prompting', threadId: 'worker-alt-session', turnId: 'turn-alt-4' },
  agentStatus: 'pending_input',
  userInputRequests: [{
    id: 13,
    method: 'item/tool/requestUserInput',
    params: {
      threadId: 'worker-alt-session',
      turnId: 'turn-alt-4',
      itemId: 'call_alt_4',
      questions: [{ id: 'ruling', header: 'Ruling', question: 'Proceed?', isOther: false, isSecret: false,
        options: [{ label: 'Proceed', description: '' }] }],
    },
  }],
  // Survives the answer, so cardsRemaining is populated afterwards.
  approvalRequests: [{
    id: 20,
    method: 'item/tool/requestApproval',
    params: { threadId: 'worker-alt-session', turnId: 'turn-alt-4', itemId: 'call_alt_5', questions: [] },
  }],
  mcpElicitationRequests: [],
  respondingRequestIds: [],
  pendingMessages: [],
  outboundMessages: [],
};
fs.writeFileSync(file, `${JSON.stringify(store, null, 2)}\n`);
NODE

printf 'respondingRequestIds:null\n' > "$FIXTURE_ROOT/after-drop-key"
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"answer_thread_card\",\"arguments\":{\"project\":$worker_json,\"thread\":\"chat-worker-alt\",\"requestId\":13,\"answers\":{\"ruling\":\"Proceed\"}}}}")
rm -f "$FIXTURE_ROOT/after-drop-key"
OUT="$out" node --no-warnings <<'NODE' || fail "a readable cardsRemaining was reported as null because a sibling projection was unreadable"
const value = JSON.parse(process.env.OUT);
if (value.error) process.exit(1);
const result = value.result.structuredContent;
if (result.answered !== true || result.requestId !== 13) process.exit(1);
if (!Array.isArray(result.cardsRemaining) || result.cardsRemaining.length !== 1) process.exit(1);
if (result.cardsRemaining[0].requestId !== 20 || result.cardsRemaining[0].kind !== 'approval') process.exit(1);
if (result.cardsRemaining.some(card => card.responding !== null)) process.exit(1);
if (result.warnings.some(warning => warning.includes('cardsRemaining is null'))) process.exit(1);
NODE
pass "fm-playbot-lanes: a post-action warning never contradicts the payload it ships with"

# ---------------------------------------------------------------------------
# The Stop-hook wake must not record a rejected wake as notified.
# ---------------------------------------------------------------------------

printf '%s\n' '{"session_id":"controller-session","cwd":"fixture-controller","tool_name":"mcp__playbot_lanes__register_lane"}' \
  | node --no-warnings "$SCRIPT" hook-pretool
out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"register_lane\",\"arguments\":{\"project\":$worker_json,\"workspace\":\"ws-worker\",\"thread\":\"Greeting\"}}}")
wake_lane=$(OUT="$out" node -e 'process.stdout.write(JSON.parse(process.env.OUT).result.structuredContent.lane.id)')
[ -n "$wake_lane" ] || fail "could not register a lane for the wake-delivery test"

FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const rollout = path.join(process.env.FIXTURE_ROOT, 'harness', 'worker-rollout.jsonl');
const at = '2026-07-29T12:05:00.000Z';
fs.appendFileSync(rollout, [
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'agent_message', message: 'THIRD ACK', phase: 'final_answer' } }),
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'task_complete', turn_id: 'turn-worker-3', last_agent_message: 'THIRD ACK', completed_at: 1785326520, duration_ms: 100 } }),
].join('\n') + '\n');
NODE

rm -f "$PLAYBOT_LANES_STATE_DIR/last-hook-error.json"
printf 'yes\n' > "$FIXTURE_ROOT/send-fails"
printf '%s\n' '{"session_id":"worker-session","stop_hook_active":false}' \
  | node --no-warnings "$SCRIPT" hook-stop >/dev/null
LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$wake_lane.json" ERR_FILE="$PLAYBOT_LANES_STATE_DIR/last-hook-error.json" node --no-warnings <<'NODE' || fail "a rejected lane wake was recorded as notified and left no trace"
const fs = require('node:fs');
const route = JSON.parse(fs.readFileSync(process.env.LANE_FILE, 'utf8'));
// Advancing this would suppress the retry forever, and nothing throws on a rejection.
if (route.lastNotifiedTurnId === 'turn-worker-3') process.exit(1);
const error = JSON.parse(fs.readFileSync(process.env.ERR_FILE, 'utf8'));
if (error.turnId !== 'turn-worker-3' || error.delivery.state !== 'failed') process.exit(1);
if (!error.error.includes('Playbot rejected the lane wake')) process.exit(1);
NODE
rm -f "$FIXTURE_ROOT/send-fails"
printf '%s\n' '{"session_id":"worker-session","stop_hook_active":false}' \
  | node --no-warnings "$SCRIPT" hook-stop >/dev/null
LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$wake_lane.json" node --no-warnings <<'NODE' || fail "the retried wake did not land once Playbot accepted it"
const fs = require('node:fs');
const route = JSON.parse(fs.readFileSync(process.env.LANE_FILE, 'utf8'));
if (route.lastNotifiedTurnId !== 'turn-worker-3') process.exit(1);
if (route.lastNotifiedDelivery !== 'sending' && route.lastNotifiedDelivery !== 'delivered') process.exit(1);
NODE
pass "fm-playbot-lanes: a rejected lane wake stays eligible for retry and is recorded, then lands on retry"

# An accepted send whose verdict cannot be read is NOT a rejected send: Playbot
# has the message. Leaving the turn unnotified would resend the identical wake on
# the next hook run and grow the very invisible queue this surface exposes, so
# the wake counts as notified and the unreadable verdict is recorded instead.
FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const rollout = path.join(process.env.FIXTURE_ROOT, 'harness', 'worker-rollout.jsonl');
const at = '2026-07-29T12:06:00.000Z';
fs.appendFileSync(rollout, [
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'agent_message', message: 'FOURTH ACK', phase: 'final_answer' } }),
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'task_complete', turn_id: 'turn-worker-4', last_agent_message: 'FOURTH ACK', completed_at: 1785326580, duration_ms: 100 } }),
].join('\n') + '\n');
NODE

rm -f "$PLAYBOT_LANES_STATE_DIR/last-hook-error.json"
printf 'pendingMessages\n' > "$FIXTURE_ROOT/send-drop-key"
printf '%s\n' '{"session_id":"worker-session","stop_hook_active":false}' \
  | node --no-warnings "$SCRIPT" hook-stop >/dev/null
rm -f "$FIXTURE_ROOT/send-drop-key"
LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$wake_lane.json" ERR_FILE="$PLAYBOT_LANES_STATE_DIR/last-hook-error.json" node --no-warnings <<'NODE' || fail "an accepted wake with an unreadable verdict was left eligible for a duplicate resend"
const fs = require('node:fs');
const route = JSON.parse(fs.readFileSync(process.env.LANE_FILE, 'utf8'));
if (route.lastNotifiedTurnId !== 'turn-worker-4') process.exit(1);
if (route.lastNotifiedDelivery !== 'unreadable' || !route.lastNotifiedError) process.exit(1);
const error = JSON.parse(fs.readFileSync(process.env.ERR_FILE, 'utf8'));
if (error.turnId !== 'turn-worker-4' || error.sendReachedPlaybot !== true) process.exit(1);
NODE
# Re-running the hook must not send that wake a second time.
before=$(cksum "$PLAYBOT_LANES_STATE_DIR/routes/$wake_lane.json")
printf '%s\n' '{"session_id":"worker-session","stop_hook_active":false}' \
  | node --no-warnings "$SCRIPT" hook-stop >/dev/null
after=$(cksum "$PLAYBOT_LANES_STATE_DIR/routes/$wake_lane.json")
[ "$before" = "$after" ] || fail "an accepted-but-unreadable wake was resent on the next hook run"
pass "fm-playbot-lanes: an accepted wake with an unreadable verdict counts as notified and is never resent"

# An "unknown" verdict means opposite things on the two Playbot generations, and
# the wake is classified with the chat-creation detection the adapter already has.
# On a Playbot whose send path CAN report a verdict, no snapshot back is a real
# anomaly, and advancing the turn would lose the wake silently; on a pre-0.94
# Playbot threads:send returns nothing by design, so unknown carries no
# information and the wake must still land. The same turn drives both halves, so
# the only difference between them is the Playbot generation.
FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const rollout = path.join(process.env.FIXTURE_ROOT, 'harness', 'worker-rollout.jsonl');
const at = '2026-07-29T12:07:00.000Z';
fs.appendFileSync(rollout, [
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'agent_message', message: 'FIFTH ACK', phase: 'final_answer' } }),
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'task_complete', turn_id: 'turn-worker-5', last_agent_message: 'FIFTH ACK', completed_at: 1785326640, duration_ms: 100 } }),
].join('\n') + '\n');
NODE

rm -f "$PLAYBOT_LANES_STATE_DIR/last-hook-error.json"
printf 'yes\n' > "$FIXTURE_ROOT/send-non-object"
printf '%s\n' '{"session_id":"worker-session","stop_hook_active":false}' \
  | node --no-warnings "$SCRIPT" hook-stop >/dev/null
rm -f "$FIXTURE_ROOT/send-non-object"
LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$wake_lane.json" ERR_FILE="$PLAYBOT_LANES_STATE_DIR/last-hook-error.json" node --no-warnings <<'NODE' || fail "an unconfirmed wake on a verdict-reporting Playbot was recorded as notified"
const fs = require('node:fs');
const route = JSON.parse(fs.readFileSync(process.env.LANE_FILE, 'utf8'));
if (route.lastNotifiedTurnId === 'turn-worker-5') process.exit(1);
// The route still describes the previous turn's accepted-but-unreadable wake,
// untouched, so the next hook run resends this one.
if (route.lastNotifiedDelivery !== 'unreadable' || !route.lastNotifiedError) process.exit(1);
const error = JSON.parse(fs.readFileSync(process.env.ERR_FILE, 'utf8'));
if (error.turnId !== 'turn-worker-5' || error.delivery.state !== 'unknown') process.exit(1);
if (!error.error.includes('delivery is unconfirmed')) process.exit(1);
NODE
printf 'legacy\n' > "$FIXTURE_ROOT/ipc-mode"
printf '%s\n' '{"session_id":"worker-session","stop_hook_active":false}' \
  | node --no-warnings "$SCRIPT" hook-stop >/dev/null
printf 'modern\n' > "$FIXTURE_ROOT/ipc-mode"
LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$wake_lane.json" node --no-warnings <<'NODE' || fail "a wake to a pre-0.94 Playbot was withheld because its send path cannot report a verdict"
const fs = require('node:fs');
const route = JSON.parse(fs.readFileSync(process.env.LANE_FILE, 'utf8'));
if (route.lastNotifiedTurnId !== 'turn-worker-5' || route.lastNotifiedDelivery !== 'unknown') process.exit(1);
NODE
LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$wake_lane.json" node --no-warnings <<'NODE' || fail "a successful wake still carried the previous notification's error"
const fs = require('node:fs');
const route = JSON.parse(fs.readFileSync(process.env.LANE_FILE, 'utf8'));
if (route.lastNotifiedError !== undefined) process.exit(1);
NODE
pass "fm-playbot-lanes: an unconfirmed wake advances only on a Playbot whose send path cannot report a verdict"

# The detection that classifies an unknown verdict runs AFTER threads:send has
# returned, so a Playbot that accepts the capability probe - which the adapter
# refuses to guess from - must not turn a send that reached Playbot into a record
# claiming it never did. The conservative default still holds: an unclassifiable
# unknown does not advance.
FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const rollout = path.join(process.env.FIXTURE_ROOT, 'harness', 'worker-rollout.jsonl');
const at = '2026-07-29T12:08:00.000Z';
fs.appendFileSync(rollout, [
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'agent_message', message: 'SIXTH ACK', phase: 'final_answer' } }),
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'task_complete', turn_id: 'turn-worker-6', last_agent_message: 'SIXTH ACK', completed_at: 1785326700, duration_ms: 100 } }),
].join('\n') + '\n');
NODE

rm -f "$PLAYBOT_LANES_STATE_DIR/last-hook-error.json"
printf 'yes\n' > "$FIXTURE_ROOT/send-non-object"
printf 'yes\n' > "$FIXTURE_ROOT/launch-accepts-probe"
printf '%s\n' '{"session_id":"worker-session","stop_hook_active":false}' \
  | node --no-warnings "$SCRIPT" hook-stop >/dev/null
rm -f "$FIXTURE_ROOT/send-non-object" "$FIXTURE_ROOT/launch-accepts-probe"
LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$wake_lane.json" ERR_FILE="$PLAYBOT_LANES_STATE_DIR/last-hook-error.json" node --no-warnings <<'NODE' || fail "a probe failure after a completed send was recorded as a send that never reached Playbot"
const fs = require('node:fs');
const route = JSON.parse(fs.readFileSync(process.env.LANE_FILE, 'utf8'));
if (route.lastNotifiedTurnId === 'turn-worker-6') process.exit(1);
const error = JSON.parse(fs.readFileSync(process.env.ERR_FILE, 'utf8'));
if (error.turnId !== 'turn-worker-6') process.exit(1);
// The verdict the send DID produce has to be in the record, and nothing in it
// may claim the send never reached Playbot.
if (!error.delivery || error.delivery.state !== 'unknown') process.exit(1);
if (error.sendReachedPlaybot === false) process.exit(1);
if (!error.error.includes('capability probe')) process.exit(1);
NODE
pass "fm-playbot-lanes: a chat-creation probe that fails after the send does not mislabel the wake as undelivered"

# A routed worker is addressed by exact thread id, so it stays wakeable wherever
# its chat lives - including a project Playbot no longer marks active, which
# rowForSession already resolves the caller from. And a route that cannot be
# processed at all must not stop the routes behind it in the same hook run.
FIXTURE_ROOT="$FIXTURE_ROOT" PLAYBOT_LANES_STATE_DIR="$PLAYBOT_LANES_STATE_DIR" node --no-warnings <<'NODE'
const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const rollout = path.join(process.env.FIXTURE_ROOT, 'harness', 'worker-rollout.jsonl');
const at = '2026-07-29T12:09:00.000Z';
fs.appendFileSync(rollout, [
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'agent_message', message: 'SEVENTH ACK', phase: 'final_answer' } }),
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'task_complete', turn_id: 'turn-worker-7', last_agent_message: 'SEVENTH ACK', completed_at: 1785326760, duration_ms: 100 } }),
].join('\n') + '\n');
const db = new DatabaseSync(path.join(process.env.FIXTURE_ROOT, 'desktop', 'playbot.db'));
db.prepare("UPDATE projects SET deletion_state = 'pending_deletion' WHERE id = ?").run('project-worker');
db.close();
// A persisted route, the adapter's own state file, pointing at a supervisor chat
// that no longer exists. It sorts ahead of the live lane, so a route the hook
// cannot process is reached first.
fs.writeFileSync(path.join(process.env.PLAYBOT_LANES_STATE_DIR, 'routes', 'lane-orphan-supervisor.json'), `${JSON.stringify({
  version: 1,
  id: 'lane-orphan-supervisor',
  active: true,
  supervisor: { id: 'chat-that-no-longer-exists' },
  worker: { id: 'chat-worker' },
  createdAt: at,
  updatedAt: '2030-01-01T00:00:00.000Z',
  lastNotifiedTurnId: null,
  lastNotifiedAt: null,
}, null, 2)}\n`);
NODE

printf '%s\n' '{"session_id":"worker-session","stop_hook_active":false}' \
  | node --no-warnings "$SCRIPT" hook-stop >/dev/null
FIXTURE_ROOT="$FIXTURE_ROOT" node --no-warnings <<'NODE'
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync(path.join(process.env.FIXTURE_ROOT, 'desktop', 'playbot.db'));
db.prepare("UPDATE projects SET deletion_state = 'active' WHERE id = ?").run('project-worker');
db.close();
NODE
LANE_FILE="$PLAYBOT_LANES_STATE_DIR/routes/$wake_lane.json" ORPHAN="$PLAYBOT_LANES_STATE_DIR/routes/lane-orphan-supervisor.json" node --no-warnings <<'NODE' || fail "a worker outside an active project, behind an unprocessable route, lost its wake"
const fs = require('node:fs');
const route = JSON.parse(fs.readFileSync(process.env.LANE_FILE, 'utf8'));
if (route.lastNotifiedTurnId !== 'turn-worker-7') process.exit(1);
if (route.lastNotifiedDelivery !== 'sending' && route.lastNotifiedDelivery !== 'delivered') process.exit(1);
const orphan = JSON.parse(fs.readFileSync(process.env.ORPHAN, 'utf8'));
if (orphan.lastNotifiedTurnId !== null) process.exit(1);
NODE
rm -f "$PLAYBOT_LANES_STATE_DIR/routes/lane-orphan-supervisor.json"
pass "fm-playbot-lanes: a worker in a project Playbot no longer marks active still wakes its supervisor"

# ---------------------------------------------------------------------------
# The shared node resolver must name what it rejected.
#
# An explicit FM_TEST_NODE stays authoritative and never falls back to another
# runtime, so when it names something unusable the refusal has to point at that
# path - naming FM_TEST_NODE alone points the operator at the variable they
# just set. Driven through fm_test_require_node in a child shell, because it
# exits the shell it refuses in.
# ---------------------------------------------------------------------------

node_probe_refusal() {
  FM_TEST_NODE="$1" bash -c '. "$1"; fm_test_require_node "probe suite"' _ "$ROOT/tests/lib.sh" 2>&1
}

not_a_runtime="$TMP_ROOT/not-a-node"
printf '#!/bin/sh\nexit 0\n' > "$not_a_runtime"
chmod +x "$not_a_runtime"
refusal=$(node_probe_refusal "$not_a_runtime") && fail "an FM_TEST_NODE that is not a Node runtime was accepted"
case "$refusal" in
  *"$not_a_runtime"*"not a Node runtime"*) ;;
  *) fail "the FM_TEST_NODE refusal did not name the rejected path and why: $refusal" ;;
esac

# An executable that is not Node but still prints something: `node -p ...` run
# against `echo` echoes the probe's own arguments back, and a runtime accepted on
# that basis cannot run a single check in this suite.
noisy_runtime="$TMP_ROOT/noisy-not-node"
printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$noisy_runtime"
chmod +x "$noisy_runtime"
refusal=$(node_probe_refusal "$noisy_runtime") && fail "an FM_TEST_NODE that printed non-version output was accepted as a Node runtime"
case "$refusal" in
  *"$noisy_runtime"*"not a Node runtime"*) ;;
  *) fail "the non-version FM_TEST_NODE refusal did not name the rejected path and why: $refusal" ;;
esac

old_runtime="$TMP_ROOT/old-node"
printf '#!/bin/sh\nprintf "18.20.4\\n"\n' > "$old_runtime"
chmod +x "$old_runtime"
refusal=$(node_probe_refusal "$old_runtime") && fail "an FM_TEST_NODE older than the minimum was accepted"
case "$refusal" in
  *"$old_runtime"*"18.20.4"*) ;;
  *) fail "the too-old FM_TEST_NODE refusal did not name the path and the version it reported: $refusal" ;;
esac
pass "fm-playbot-lanes: an unusable FM_TEST_NODE is refused by path and reason"
