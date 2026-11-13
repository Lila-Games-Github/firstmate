#!/usr/bin/env bash
# Real Git export/import, refusal and workstation local landing integration.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity remote-test remote@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-remote-landing)
HOME_CASE="$TMP_ROOT/home"
mkdir -p "$HOME_CASE/state" "$HOME_CASE/data" "$HOME_CASE/config"
export FM_HOME="$HOME_CASE"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE
PROJ="$TMP_ROOT/workstation"
REMOTE="$TMP_ROOT/remote"
WT="$TMP_ROOT/landing-worker"
git init -q --bare -b main "$TMP_ROOT/origin.git"
git clone -q "$TMP_ROOT/origin.git" "$PROJ"
printf 'base\n' > "$PROJ/shared.txt"
git -C "$PROJ" add .
git -C "$PROJ" commit -qm baseline
git -C "$PROJ" push -q origin main
BASE=$(git -C "$PROJ" rev-parse HEAD)
git clone -q "$TMP_ROOT/origin.git" "$REMOTE"
git -C "$REMOTE" checkout -qb fm/remote-task
printf 'remote work\n' > "$REMOTE/remote.txt"
git -C "$REMOTE" add .
git -C "$REMOTE" commit -qm 'remote work'
HEAD_SHA=$(git -C "$REMOTE" rev-parse HEAD)
git -C "$REMOTE" push -q origin HEAD:refs/heads/fm/remote-task
git -C "$PROJ" worktree add -qb fm/local-task "$WT" main
fm_write_meta "$HOME_CASE/state/local-task.meta" "project=$PROJ" "worktree=$WT" 'kind=ship' 'mode=local-only' 'landing_branch=main'
import_report() {
  "$BASH" "$ROOT/bin/fm-remote-landing.sh" import local-task --remote-task remote-task --branch fm/remote-task --head "$1"
}
if import_report "$BASE" > "$TMP_ROOT/bad.out" 2>&1; then fail 'mismatched report was accepted'; fi
assert_grep 'report head mismatch' "$TMP_ROOT/bad.out" 'bad report did not explain mismatch'
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail 'bad report moved local branch'
pass 'known-bad report refuses mismatched SHA without moving the local branch'
import_report "$HEAD_SHA" > "$TMP_ROOT/import.out" 2>&1 || fail "import failed: $(cat "$TMP_ROOT/import.out")"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_SHA" ] || fail 'wrong imported head'
[ "$(git -C "$PROJ" rev-parse main)" = "$BASE" ] || fail 'import moved landing'
import_report "$HEAD_SHA" > "$TMP_ROOT/repeat.out" 2>&1 || fail 'idempotent import failed'
pass 'one pushed report imports exact head idempotently into the workstation worker'
printf 'dirty\n' > "$WT/dirty"
if import_report "$HEAD_SHA" > "$TMP_ROOT/dirty.out" 2>&1; then fail 'dirty import accepted'; fi
assert_grep 'dirty workstation' "$TMP_ROOT/dirty.out" 'dirty refusal absent'
rm "$WT/dirty"
pass 'dirty workstation work is preserved and refused'
printf 'local-only\n' > "$WT/local.txt"
git -C "$WT" add .
git -C "$WT" commit -qm 'local unpublished work'
LOCAL_SHA=$(git -C "$WT" rev-parse HEAD)
if import_report "$HEAD_SHA" > "$TMP_ROOT/diverged.out" 2>&1; then fail 'local work overwritten'; fi
[ "$(git -C "$WT" rev-parse HEAD)" = "$LOCAL_SHA" ] || fail 'local work lost'
# Restore through a new worktree, preserving the local commit under its branch.
git -C "$PROJ" branch -m fm/local-task fm/preserved-local
fm_write_meta "$HOME_CASE/state/landing.meta" "project=$PROJ" "worktree=$TMP_ROOT/final-worker" 'kind=ship' 'mode=local-only' 'landing_branch=main'
git -C "$PROJ" worktree add -qb fm/landing "$TMP_ROOT/final-worker" main
"$BASH" "$ROOT/bin/fm-remote-landing.sh" import landing --remote-task remote-task --branch fm/remote-task --head "$HEAD_SHA" > "$TMP_ROOT/final.out" 2>&1
pass 'unpublished workstation commits are retained when a report diverges'

# A Playbot lane records a workspace-owned branch rather than an fm/ task ref.
LANE="$TMP_ROOT/lane"
git clone -q "$TMP_ROOT/origin.git" "$LANE"
git -C "$LANE" checkout -qb frogpile-pond-geometry-landing
mkdir -p "$LANE/prototype-game"
printf 'config_version=5\n' > "$LANE/prototype-game/project.godot"
printf 'lane work\n' > "$LANE/lane.txt"
git -C "$LANE" add lane.txt prototype-game/project.godot
git -C "$LANE" commit -qm 'lane work'
LANE_HEAD=$(git -C "$LANE" rev-parse HEAD)
git -C "$LANE" push -q origin HEAD:refs/heads/frogpile-pond-geometry-landing
git -C "$PROJ" worktree add -qb frogpile-pond-geometry-landing "$TMP_ROOT/lane-worker" main
fm_write_meta "$HOME_CASE/state/lane-task.meta" "project=$PROJ" "worktree=$TMP_ROOT/lane-worker" \
  'kind=lane' 'mode=local-only' 'landing_branch=main' 'playbot_project=pond' 'playbot_workspace=workspace-pond'
export PLAYBOT_DESKTOP_DIR="$TMP_ROOT/playbot-desktop"
mkdir -p "$PLAYBOT_DESKTOP_DIR"
export LANE_WORKTREE="$TMP_ROOT/lane-worker" LANE_PROJECT="$PROJ"
node --no-warnings <<'NODE'
const { DatabaseSync } = require('node:sqlite');
const path = require('node:path');
const db = new DatabaseSync(path.join(process.env.PLAYBOT_DESKTOP_DIR, 'playbot.db'));
db.exec(`CREATE TABLE projects(id TEXT, name TEXT, default_working_root_id TEXT, deletion_state TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE repositories(id TEXT, name TEXT, path TEXT, default_branch TEXT);
CREATE TABLE project_roots(id TEXT, project_id TEXT, repository_id TEXT, position INTEGER);
CREATE TABLE workspaces(id TEXT, project_id TEXT, name TEXT, kind TEXT, is_selected INTEGER, archive_state TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE workspace_roots(workspace_id TEXT, project_root_id TEXT, path TEXT, branch TEXT);`);
db.prepare('INSERT INTO projects VALUES(?,?,?,?,?,?)').run('pond', 'Pond', 'root', 'active', '', '');
db.prepare('INSERT INTO repositories VALUES(?,?,?,?)').run('repo', 'Pond', process.env.LANE_PROJECT, 'main');
db.prepare('INSERT INTO project_roots VALUES(?,?,?,?)').run('root', 'pond', 'repo', 0);
db.prepare('INSERT INTO workspaces VALUES(?,?,?,?,?,?,?,?)').run('workspace-pond', 'pond', 'Landing', 'worktree', 0, 'active', '', '');
db.prepare('INSERT INTO workspace_roots VALUES(?,?,?,?)').run('workspace-pond', 'root', process.env.LANE_WORKTREE, 'frogpile-pond-geometry-landing');
db.close();
NODE
lane_import() {
  "$BASH" "$ROOT/bin/fm-remote-landing.sh" import lane-task --remote-task remote-task \
    --branch "$1" --head "$2"
}
if lane_import fm/remote-task "$LANE_HEAD" > "$TMP_ROOT/lane-refusal.out" 2>&1; then fail 'lane accepted a different remote branch'; fi
assert_grep 'report branch differs' "$TMP_ROOT/lane-refusal.out" 'lane branch identity refusal absent'
if lane_import frogpile-pond-geometry-landing "$BASE" > "$TMP_ROOT/lane-bad-head.out" 2>&1; then fail 'lane accepted mismatched remote head'; fi
assert_grep 'report head mismatch' "$TMP_ROOT/lane-bad-head.out" 'lane exact-head refusal absent'
lane_import frogpile-pond-geometry-landing "$LANE_HEAD" > "$TMP_ROOT/lane-import.out" 2>&1 || fail "lane import failed: $(cat "$TMP_ROOT/lane-import.out")"
[ "$(git -C "$TMP_ROOT/lane-worker" rev-parse HEAD)" = "$LANE_HEAD" ] || fail 'lane imported wrong head'
printf 'unrelated product edit\n' > "$TMP_ROOT/lane-worker/private.txt"
if lane_import frogpile-pond-geometry-landing "$LANE_HEAD" > "$TMP_ROOT/lane-dirty.out" 2>&1; then fail 'lane accepted unrelated dirty product edit'; fi
assert_grep 'private.txt' "$TMP_ROOT/lane-dirty.out" 'lane dirty product refusal absent'
[ -f "$TMP_ROOT/lane-worker/private.txt" ] || fail 'lane dirty product work lost'
rm "$TMP_ROOT/lane-worker/private.txt"
pass 'lane imports recorded workspace branch at exact head and preserves unrelated dirty work on refusal'

# The guarded lane path reads the app bundle and app:metadata. This isolated
# Playbot protocol fixture supplies those facts while Git performs real work.
export PLAYBOT_LANES_APP_RESOURCES="$TMP_ROOT/playbot-resources"
export LANE_BUNDLE="$PLAYBOT_LANES_APP_RESOURCES/app.asar.unpacked/electron/backend/godot-plugin/addons/playbot"
mkdir -p "$LANE_BUNDLE/native" "$PLAYBOT_LANES_APP_RESOURCES/app"
printf '{"version":"0.117.0"}\n' > "$PLAYBOT_LANES_APP_RESOURCES/app/package.json"
printf '[plugin]\nversion="0.7.20"\n' > "$LANE_BUNDLE/plugin.cfg"
printf 'bundled plugin\n' > "$LANE_BUNDLE/plugin.gd"
printf '\001\002\003' > "$LANE_BUNDLE/native/library.so"
cat > "$TMP_ROOT/lane-cdp.mjs" <<'NODE'
import fs from 'node:fs';
import http from 'node:http';
import crypto from 'node:crypto';
import path from 'node:path';
const server = http.createServer((request, response) => response.end(JSON.stringify([
  { type: 'page', webSocketDebuggerUrl: `ws://127.0.0.1:${server.address().port}/page` },
])));
server.on('upgrade', (request, socket) => {
  const accept = crypto.createHash('sha1').update(`${request.headers['sec-websocket-key']}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  let buffered = Buffer.alloc(0);
  socket.on('data', (packet) => {
    buffered = Buffer.concat([buffered, packet]);
    while (buffered.length >= 2) {
    if ((buffered[0] & 15) === 8) { socket.end(); return; }
    const length = buffered[1] & 127;
    const offset = length === 126 ? 4 : 2;
    if (buffered.length < offset) return;
    const size = length === 126 ? buffered.readUInt16BE(2) : length;
    if (buffered.length < offset + 4 + size) return;
    const mask = buffered.subarray(offset, offset + 4);
    const body = Buffer.from(buffered.subarray(offset + 4, offset + 4 + size));
    buffered = buffered.subarray(offset + 4 + size);
    for (let index = 0; index < body.length; index++) body[index] ^= mask[index % 4];
    const message = JSON.parse(body.toString());
    const value = { version: '0.117.0' };
    const output = Buffer.from(JSON.stringify({ id: message.id, result: { result: { value } } }));
    const header = output.length < 126 ? Buffer.from([0x81, output.length]) : Buffer.from([0x81, 126, output.length >> 8, output.length & 255]);
    socket.write(Buffer.concat([header, output]));
    }
  });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(path.join(process.env.PLAYBOT_DESKTOP_DIR, 'DevToolsActivePort'), String(server.address().port)));
NODE
node --no-warnings "$TMP_ROOT/lane-cdp.mjs" &
LANE_CDP_PID=$!
trap 'kill "$LANE_CDP_PID" 2>/dev/null || true; fm_test_cleanup' EXIT
for _ in $(seq 1 50); do
  [ -f "$PLAYBOT_DESKTOP_DIR/DevToolsActivePort" ] && break
  sleep 0.1
done
mkdir -p "$TMP_ROOT/lane-worker/prototype-game/addons"
cp -R "$LANE_BUNDLE" "$TMP_ROOT/lane-worker/prototype-game/addons/playbot"
printf 'injected helper\n' > "$TMP_ROOT/lane-worker/prototype-game/addons/playbot/untracked-helper.gd"
chmod 755 "$TMP_ROOT/lane-worker/prototype-game/addons/playbot/native/library.so"
printf 'second remote change\n' >> "$LANE/lane.txt"
git -C "$LANE" commit -qam 'second lane commit'
LANE_NEXT=$(git -C "$LANE" rev-parse HEAD)
git -C "$LANE" push -q origin HEAD:refs/heads/frogpile-pond-geometry-landing
lane_import frogpile-pond-geometry-landing "$LANE_NEXT" > "$TMP_ROOT/lane-addon-import.out" 2>&1 \
  || fail "lane addon import failed: $(cat "$TMP_ROOT/lane-addon-import.out")"
[ "$(git -C "$TMP_ROOT/lane-worker" rev-parse HEAD)" = "$LANE_NEXT" ] || fail 'addon import did not move to exact head'
cmp "$LANE_BUNDLE/plugin.gd" "$TMP_ROOT/lane-worker/prototype-game/addons/playbot/plugin.gd" || fail 'import changed plugin bytes'
[ "$(cat "$TMP_ROOT/lane-worker/prototype-game/addons/playbot/untracked-helper.gd")" = 'injected helper' ] || fail 'import lost injected helper'
[ "$(node -e 'process.stdout.write(String(require("node:fs").statSync(process.argv[1]).mode & 0o777))' "$TMP_ROOT/lane-worker/prototype-game/addons/playbot/native/library.so")" = 493 ] || fail 'import changed native mode'
pass 'lane import advances with complete injected addon bytes and mode preserved'
rm "$TMP_ROOT/lane-worker/prototype-game/addons/playbot/plugin.gd"
if lane_import frogpile-pond-geometry-landing "$LANE_NEXT" > "$TMP_ROOT/lane-incomplete.out" 2>&1; then fail 'lane accepted incomplete addon'; fi
assert_grep 'incomplete or differs' "$TMP_ROOT/lane-incomplete.out" 'incomplete addon refusal absent'
[ "$(git -C "$TMP_ROOT/lane-worker" rev-parse HEAD)" = "$LANE_NEXT" ] || fail 'incomplete addon moved head'
cp "$LANE_BUNDLE/plugin.gd" "$TMP_ROOT/lane-worker/prototype-game/addons/playbot/plugin.gd"
node --no-warnings <<'NODE'
const { DatabaseSync } = require('node:sqlite');
const path = require('node:path');
const db = new DatabaseSync(path.join(process.env.PLAYBOT_DESKTOP_DIR, 'playbot.db'));
db.prepare('UPDATE workspace_roots SET branch = ? WHERE workspace_id = ?').run('other-lane-branch', 'workspace-pond');
db.close();
NODE
if lane_import frogpile-pond-geometry-landing "$LANE_NEXT" > "$TMP_ROOT/lane-stale.out" 2>&1; then fail 'lane accepted changed Playbot workspace branch'; fi
assert_grep 'worktree owns a different branch' "$TMP_ROOT/lane-stale.out" 'changed workspace branch was not detected'
node --no-warnings <<'NODE'
const { DatabaseSync } = require('node:sqlite');
const path = require('node:path');
const db = new DatabaseSync(path.join(process.env.PLAYBOT_DESKTOP_DIR, 'playbot.db'));
db.prepare('UPDATE workspace_roots SET branch = ? WHERE workspace_id = ?').run('frogpile-pond-geometry-landing', 'workspace-pond');
db.close();
NODE
pass 'incomplete addon and changed workspace identity refuse import without changing its head'

# The queue stub supplies only its front-car assignment and records the ready
# call; the entrypoint performs real Git rebase, addon guard, and target push.
LANE_BIN="$TMP_ROOT/lane-bin"
mkdir -p "$LANE_BIN"
cp "$ROOT/bin/fm-remote-landing.sh" "$LANE_BIN/fm-remote-landing.sh"
for dep in "$ROOT"/bin/*; do
  case "${dep##*/}" in fm-remote-landing.sh|fm-landing-queue.sh|fm-send.sh) ;; *) ln -s "$dep" "$LANE_BIN/${dep##*/}" ;; esac
done
cat > "$LANE_BIN/fm-landing-queue.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = status ]; then
  printf 'status=needs-rebase\ntarget_sha=%s\nrebase_from=%s\n' "$LANE_TARGET" "$LANE_FROM"
elif [ "$1" = ready ]; then
  printf '%s\n' "$*" > "$LANE_READY_OUT"
  printf 'status=needs-quick\n'
else
  exit 2
fi
SH
cat > "$LANE_BIN/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$LANE_STEER_OUT"
SH
chmod +x "$LANE_BIN/fm-landing-queue.sh" "$LANE_BIN/fm-send.sh"
export LANE_FROM="$BASE" LANE_READY_OUT="$TMP_ROOT/lane-ready.out" LANE_STEER_OUT="$TMP_ROOT/lane-steer.out"
printf 'new landing tip\n' > "$PROJ/other.txt"
git -C "$PROJ" add other.txt
git -C "$PROJ" commit -qm 'new lane landing target'
LANE_TARGET=$(git -C "$PROJ" rev-parse HEAD)
export LANE_TARGET
printf 'private rebase edit\n' > "$TMP_ROOT/lane-worker/private.txt"
if FM_HOME="$HOME_CASE" "$BASH" "$LANE_BIN/fm-remote-landing.sh" rebase lane-task \
    --remote-task remote-task --secondmate remote-mate > "$TMP_ROOT/lane-dirty-rebase.out" 2>&1; then fail 'lane rebased over private product work'; fi
assert_grep 'private.txt' "$TMP_ROOT/lane-dirty-rebase.out" 'dirty rebase refusal absent'
[ "$(git -C "$TMP_ROOT/lane-worker" rev-parse HEAD)" = "$LANE_NEXT" ] || fail 'dirty rebase moved head'
rm "$TMP_ROOT/lane-worker/private.txt"
FM_HOME="$HOME_CASE" "$BASH" "$LANE_BIN/fm-remote-landing.sh" rebase lane-task \
  --remote-task remote-task --secondmate remote-mate > "$TMP_ROOT/lane-rebase.out" 2>&1 \
  || fail "lane rebase failed: $(cat "$TMP_ROOT/lane-rebase.out")"
git -C "$TMP_ROOT/lane-worker" merge-base --is-ancestor "$LANE_TARGET" HEAD || fail 'lane rebase missed exact queue target'
assert_grep 'frogpile-pond-geometry-landing' "$LANE_READY_OUT" 'queue did not receive recorded lane branch'
cmp "$LANE_BUNDLE/plugin.gd" "$TMP_ROOT/lane-worker/prototype-game/addons/playbot/plugin.gd" || fail 'rebase changed plugin bytes'
[ "$(cat "$TMP_ROOT/lane-worker/prototype-game/addons/playbot/untracked-helper.gd")" = 'injected helper' ] || fail 'rebase lost injected helper'
pass 'front lane rebase preserves addon bytes and reports recorded branch to queue'

CONFLICT_PROJ="$TMP_ROOT/lane-conflict-project"
git clone -q "$TMP_ROOT/origin.git" "$CONFLICT_PROJ"
git -C "$CONFLICT_PROJ" worktree add -qb frogpile-pond-geometry-landing "$TMP_ROOT/lane-conflict-worker" main
fm_write_meta "$HOME_CASE/state/lane-conflict.meta" "project=$CONFLICT_PROJ" "worktree=$TMP_ROOT/lane-conflict-worker" \
  'kind=lane' 'mode=local-only' 'landing_branch=main' 'playbot_project=pond-conflict' 'playbot_workspace=workspace-conflict' \
  'playbot_branch=frogpile-pond-geometry-landing'
export LANE_CONFLICT_WORKTREE="$TMP_ROOT/lane-conflict-worker" LANE_CONFLICT_PROJECT="$CONFLICT_PROJ"
node --no-warnings <<'NODE'
const { DatabaseSync } = require('node:sqlite');
const path = require('node:path');
const db = new DatabaseSync(path.join(process.env.PLAYBOT_DESKTOP_DIR, 'playbot.db'));
db.prepare('INSERT INTO projects VALUES(?,?,?,?,?,?)').run('pond-conflict', 'Conflict', 'conflict-root', 'active', '', '');
db.prepare('INSERT INTO repositories VALUES(?,?,?,?)').run('repo-conflict', 'Conflict', process.env.LANE_CONFLICT_PROJECT, 'main');
db.prepare('INSERT INTO project_roots VALUES(?,?,?,?)').run('conflict-root', 'pond-conflict', 'repo-conflict', 0);
db.prepare('INSERT INTO workspaces VALUES(?,?,?,?,?,?,?,?)').run('workspace-conflict', 'pond-conflict', 'Conflict', 'worktree', 0, 'active', '', '');
db.prepare('INSERT INTO workspace_roots VALUES(?,?,?,?)').run('workspace-conflict', 'conflict-root', process.env.LANE_CONFLICT_WORKTREE, 'frogpile-pond-geometry-landing');
db.close();
NODE
FM_HOME="$HOME_CASE" "$BASH" "$LANE_BIN/fm-remote-landing.sh" import lane-conflict \
  --remote-task remote-task --branch frogpile-pond-geometry-landing --head "$LANE_NEXT" > "$TMP_ROOT/lane-conflict-import.out" 2>&1 \
  || fail "conflict fixture import failed: $(cat "$TMP_ROOT/lane-conflict-import.out")"
mkdir -p "$TMP_ROOT/lane-conflict-worker/prototype-game/addons"
cp -R "$LANE_BUNDLE" "$TMP_ROOT/lane-conflict-worker/prototype-game/addons/playbot"
printf 'injected conflict helper\n' > "$TMP_ROOT/lane-conflict-worker/prototype-game/addons/playbot/untracked-helper.gd"
printf 'landing side\n' > "$CONFLICT_PROJ/lane.txt"
git -C "$CONFLICT_PROJ" add lane.txt
git -C "$CONFLICT_PROJ" commit -qm 'conflicting landing target'
LANE_TARGET=$(git -C "$CONFLICT_PROJ" rev-parse HEAD)
export LANE_TARGET
rc=0
FM_HOME="$HOME_CASE" "$BASH" "$LANE_BIN/fm-remote-landing.sh" rebase lane-conflict \
  --remote-task remote-task --secondmate remote-mate > "$TMP_ROOT/lane-conflict-rebase.out" 2>&1 || rc=$?
expect_code 3 "$rc" 'lane conflict handoff exit'
[ "$(git -C "$TMP_ROOT/lane-conflict-worker" rev-parse HEAD)" = "$LANE_NEXT" ] || fail 'lane conflict did not abort to imported head'
[ "$(cat "$TMP_ROOT/lane-conflict-worker/prototype-game/addons/playbot/untracked-helper.gd")" = 'injected conflict helper' ] || fail 'lane conflict lost addon bytes'
assert_grep 'resolve frogpile-pond-geometry-landing' "$LANE_STEER_OUT" 'lane conflict steer synthesized fm branch'
[ "$(git --git-dir="$TMP_ROOT/origin.git" rev-parse fm/lane-conflict-landing-target)" = "$LANE_TARGET" ] || fail 'lane conflict target was not published'
pass 'lane rebase conflict aborts, preserves addon bytes, and steers recorded branch'

# Generated contracts use the real seeded-home binding, and preserve local DOD.
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"
fm_dod_block local-only remote-task > "$TMP_ROOT/local.dod"
assert_grep 'Do NOT push' "$TMP_ROOT/local.dod" 'ordinary local-only behavior changed'
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$HOME_CASE/.fm-secondmate-parent"
fm_dod_block local-only remote-task > "$TMP_ROOT/remote.dod"
fm_remote_local_dod remote-task lane > "$TMP_ROOT/remote-lane.dod"
fm_ship_rule_one local-only remote-task > "$TMP_ROOT/remote.rule"
assert_grep 'HEAD:refs/heads/fm/remote-task' "$TMP_ROOT/remote.dod" 'remote export DOD missing'
assert_grep 'HEAD:refs/heads/<workspace-branch>' "$TMP_ROOT/remote-lane.dod" 'remote lane export DOD omitted workspace branch'
assert_no_grep 'HEAD:refs/heads/fm/remote-task' "$TMP_ROOT/remote-lane.dod" 'remote lane export DOD synthesized fm task branch'
assert_grep 'Push only your task branch' "$TMP_ROOT/remote.rule" 'remote rule still forbids export'
printf 'route=local\n' >> "$HOME_CASE/.fm-secondmate-parent"
fm_dod_block local-only remote-task > "$TMP_ROOT/corrupt.dod"
assert_grep 'Do NOT push' "$TMP_ROOT/corrupt.dod" 'corrupt binding granted export'
rm "$HOME_CASE/.fm-secondmate-parent"
pass 'remote binding selects branch export while local and corrupt homes keep no-push'

if [ "${FM_SKIP_TESTFARM:-}" = 1 ]; then
  echo 'skip: queue integration requires testfarm compatibility installation'
  exit 0
fi
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$HEAD_SHA" > "$TMP_ROOT/full.receipt"
"$ROOT/bin/fm-landing-queue.sh" ready landing --project "$PROJ" --landing-branch main \
  --branch fm/landing --head "$HEAD_SHA" --target "$BASE" --receipt "$TMP_ROOT/full.receipt" > "$TMP_ROOT/queue.out" 2>&1 \
  || fail "queue refused imported branch: $(cat "$TMP_ROOT/queue.out")"
# A new front car still requires its normal quick evidence, never an import bypass.
assert_grep 'status=needs-quick' "$TMP_ROOT/queue.out" 'queue gates were bypassed'
printf 'schema=fm-quick-check.v1\nsha=%s\ntarget=%s\n' "$HEAD_SHA" "$BASE" > "$TMP_ROOT/quick.receipt"
"$ROOT/bin/fm-landing-queue.sh" receipt landing --project "$PROJ" --landing-branch main \
  --head "$HEAD_SHA" --target "$BASE" --receipt "$TMP_ROOT/quick.receipt" > "$TMP_ROOT/ready.out" 2>&1
assert_grep 'status=ready-to-land' "$TMP_ROOT/ready.out" 'queue did not reach landing gate'
"$ROOT/bin/fm-merge-local.sh" landing --receipt "$TMP_ROOT/quick.receipt" > "$TMP_ROOT/merge.out" 2>&1 \
  || fail "local merge failed: $(cat "$TMP_ROOT/merge.out")"
[ "$(git -C "$PROJ" rev-parse main)" = "$HEAD_SHA" ] || fail 'exact report did not land'
[ "$(git --git-dir="$TMP_ROOT/origin.git" rev-parse main)" = "$BASE" ] || fail 'landing branch pushed to origin'
[ "$(git -C "$PROJ" rev-list --count "$BASE..main")" = 1 ] || fail 'expected exactly one imported commit'
pass 'real queue receipts and merge-local land exactly one remote commit with zero landing pushes'

# Front rebase uses actual queue assignments; only the final send boundary is
# recorded locally so this portable test needs no remote account or harness.
rebase_case() {
  local name=$1 change=$2 sha
  CASE="$TMP_ROOT/$name"
  mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/bin"
  git clone -q "$TMP_ROOT/origin.git" "$CASE/project"
  git -C "$CASE/project" worktree add -qb fm/front "$CASE/worker" main
  fm_write_meta "$CASE/home/state/front.meta" "project=$CASE/project" "worktree=$CASE/worker" 'kind=ship' 'mode=local-only' 'landing_branch=main'
  FM_HOME="$CASE/home" "$BASH" "$ROOT/bin/fm-remote-landing.sh" import front --remote-task remote-task \
    --branch fm/remote-task --head "$HEAD_SHA" > "$CASE/import.out" 2>&1
  printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$HEAD_SHA" > "$CASE/full"
  FM_HOME="$CASE/home" "$ROOT/bin/fm-landing-queue.sh" ready front --project "$CASE/project" --landing-branch main \
    --branch fm/front --head "$HEAD_SHA" --target "$BASE" --receipt "$CASE/full" > "$CASE/queue.out" 2>&1
  printf 'target edit\n' > "$CASE/project/$change"
  git -C "$CASE/project" add .
  git -C "$CASE/project" commit -qm 'new landing target'
  sha=$(git -C "$CASE/project" rev-parse HEAD)
  TARGET_SHA=$sha
}
rebase_case rebase-ok other.txt
FM_HOME="$CASE/home" "$BASH" "$ROOT/bin/fm-remote-landing.sh" rebase front --remote-task remote-task --secondmate remote-mate > "$CASE/rebase.out" 2>&1 \
  || fail "front rebase failed: $(cat "$CASE/rebase.out")"
git -C "$CASE/worker" merge-base --is-ancestor "$TARGET_SHA" HEAD || fail 'front rebase did not use queue target'
assert_grep 'status=needs-quick' "$CASE/rebase.out" 'rebase bypassed fresh evidence'
pass 'front rebase uses the real queue target and still requires farm evidence'

rebase_case rebase-conflict remote.txt
# Copy just the entrypoint; its standard helper dependencies remain real.
cp "$ROOT/bin/fm-remote-landing.sh" "$CASE/bin/fm-remote-landing.sh"
for dep in "$ROOT"/bin/*; do
  [ "${dep##*/}" = fm-remote-landing.sh ] || [ "${dep##*/}" = fm-send.sh ] || ln -s "$dep" "$CASE/bin/${dep##*/}"
done
cat > "$CASE/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_HOME/steer"
SH
chmod +x "$CASE/bin/fm-send.sh"
rc=0
FM_HOME="$CASE/home" "$BASH" "$CASE/bin/fm-remote-landing.sh" rebase front --remote-task remote-task --secondmate remote-mate > "$CASE/conflict.out" 2>&1 || rc=$?
expect_code 3 "$rc" 'conflict handoff exit'
[ "$(git -C "$CASE/worker" rev-parse HEAD)" = "$HEAD_SHA" ] || fail 'conflict did not abort to imported head'
[ -z "$(git -C "$CASE/worker" status --porcelain)" ] || fail 'conflict left partial changes'
assert_grep 'remote-mate' "$CASE/home/steer" 'wrong steer owner'
assert_grep "worker remote-task" "$CASE/home/steer" 'steer omitted remote worker'
assert_grep "target $TARGET_SHA" "$CASE/home/steer" 'steer omitted assigned target'
[ "$(git --git-dir="$TMP_ROOT/origin.git" rev-parse fm/front-landing-target)" = "$TARGET_SHA" ] || fail 'target not fetchable remotely'
[ "$(git --git-dir="$TMP_ROOT/origin.git" rev-parse main)" = "$BASE" ] || fail 'conflict pushed landing branch'
# Resolve in the real remote clone, push its rewritten task branch, then import.
git -C "$REMOTE" fetch -q origin fm/front-landing-target
git -C "$REMOTE" rebase --onto "$TARGET_SHA" "$BASE" > "$CASE/remote-rebase.out" 2>&1 || true
printf 'target edit plus remote resolution\n' > "$REMOTE/remote.txt"
git -C "$REMOTE" add remote.txt
GIT_EDITOR=true git -C "$REMOTE" rebase --continue > "$CASE/resolve.out" 2>&1
RESOLVED_SHA=$(git -C "$REMOTE" rev-parse HEAD)
git -C "$REMOTE" push -q --force-with-lease="refs/heads/fm/remote-task:$HEAD_SHA" origin HEAD:refs/heads/fm/remote-task
FM_HOME="$CASE/home" "$BASH" "$ROOT/bin/fm-remote-landing.sh" import front --remote-task remote-task \
  --branch fm/remote-task --head "$RESOLVED_SHA" > "$CASE/resolved-import.out" 2>&1 \
  || fail "resolved report could not import: $(cat "$CASE/resolved-import.out")"
[ "$(git -C "$CASE/worker" rev-parse HEAD)" = "$RESOLVED_SHA" ] || fail 'resolved head not imported'
[ "$(git -C "$CASE/project" rev-parse "refs/fm-remote-landing/front/$HEAD_SHA")" = "$HEAD_SHA" ] || fail 'old imported work lost'
pass 'conflict aborts, exports exact target, steers remote owner and imports resolution retaining old head'
