#!/usr/bin/env bash
# Windows/Playbot session-lock identity and stale-thread regression tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-playbot-session-lock)
PROJECT="$TMP_ROOT/project"
HOME_DIR="$TMP_ROOT/home"
DESKTOP_DIR="$TMP_ROOT/playbot-desktop"
PLAYBOT_DB="$DESKTOP_DIR/playbot.db"
FAKEBIN="$TMP_ROOT/fakebin"
REAL_PATH=$PATH
SESSION_HELPER="$ROOT/bin/fm-playbot-session-lock.mjs"

mkdir -p "$PROJECT" "$HOME_DIR/state" "$DESKTOP_DIR" "$FAKEBIN"

PLAYBOT_DB="$PLAYBOT_DB" PROJECT_PATH="$PROJECT" node --no-warnings --input-type=module - <<'EOF'
import { DatabaseSync } from "node:sqlite";
const db = new DatabaseSync(process.env.PLAYBOT_DB);
db.exec(`
  CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT, deletion_state TEXT);
  CREATE TABLE workspaces (id TEXT PRIMARY KEY, project_id TEXT, archive_state TEXT);
  CREATE TABLE workspace_roots (workspace_id TEXT, path TEXT);
  CREATE TABLE workspace_threads (id TEXT PRIMARY KEY, workspace_id TEXT, session_id TEXT, archived INTEGER);
`);
db.prepare("INSERT INTO projects VALUES (?, ?, ?)").run("project-a", "firstmate", "active");
db.prepare("INSERT INTO workspaces VALUES (?, ?, ?)").run("workspace-a", "project-a", "active");
db.prepare("INSERT INTO workspace_roots VALUES (?, ?)").run("workspace-a", process.env.PROJECT_PATH);
db.prepare("INSERT INTO workspace_threads VALUES (?, ?, ?, ?)").run("thread-a", "workspace-a", "session-a", 0);
db.prepare("INSERT INTO workspace_threads VALUES (?, ?, ?, ?)").run("thread-b", "workspace-a", "session-b", 0);
db.close();
EOF

cat > "$FAKEBIN/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' MINGW64_NT-10.0
EOF
cat > "$FAKEBIN/powershell.exe" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" ancestry "*) printf '%s\n' "${FM_TEST_WINDOWS_RECORD:-987654321 codex playbot}" ;;
  *" alive "*) [ "${FM_TEST_WINDOWS_ALIVE:-1}" = 1 ] ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/uname" "$FAKEBIN/powershell.exe"

playbot_env() {
  env PATH="$FAKEBIN:$REAL_PATH" PLAYBOT_DESKTOP_DIR="$DESKTOP_DIR" \
    PLAYBOT_APP_RUN_ID=run-a FM_ROOT_OVERRIDE="$PROJECT" "$@"
}

test_session_helper() {
  local out status=0
  out=$(PLAYBOT_DESKTOP_DIR="$DESKTOP_DIR" PLAYBOT_APP_RUN_ID=run-a \
    CODEX_THREAD_ID=session-a node --no-warnings "$SESSION_HELPER" identity "$PROJECT") || status=$?
  expect_code 0 "$status" "Playbot current-session identity"
  [ "$out" = session-a ] || fail "Playbot identity returned '$out'"

  PLAYBOT_DESKTOP_DIR="$DESKTOP_DIR" node --no-warnings "$SESSION_HELPER" \
    alive session-a "$PROJECT" || fail "live Playbot session was rejected"
  status=0
  PLAYBOT_DESKTOP_DIR="$DESKTOP_DIR" node --no-warnings "$SESSION_HELPER" \
    alive missing-session "$PROJECT" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing Playbot session"
  pass "Playbot session-lock helper binds identity to one active project root"
}

test_windows_harness_fallback() {
  local out
  out=$(playbot_env CODEX_THREAD_ID=session-a "$ROOT/bin/fm-harness.sh")
  [ "$out" = codex ] || fail "Windows Playbot harness resolved '$out', expected codex"

  # shellcheck disable=SC2016
  out=$(playbot_env CODEX_THREAD_ID=session-a bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid' "$ROOT")
  [ "$out" = 987654321 ] || fail "Windows Playbot lock pid resolved '$out'"

  if playbot_env CODEX_THREAD_ID=missing-session "$ROOT/bin/fm-harness.sh" | grep -qx codex; then
    fail "unpersisted Playbot session was accepted as codex"
  fi
  pass "Windows harness fallback requires a validated Playbot thread"
}

test_lock_distinguishes_shared_codex_threads() {
  local out status=0
  out=$(playbot_env CODEX_THREAD_ID=session-a FM_HOME="$HOME_DIR" "$ROOT/bin/fm-lock.sh") || status=$?
  expect_code 0 "$status" "first Playbot lock acquisition"
  assert_contains "$out" "session session-a" "lock acquisition omitted exact Playbot session"
  [ "$(cat "$HOME_DIR/state/.lock")" = 987654321 ] || fail "lock pid was not published"
  [ "$(cat "$HOME_DIR/state/.lock-session")" = session-a ] || fail "lock session was not published"

  status=0
  playbot_env CODEX_THREAD_ID=session-b FM_HOME="$HOME_DIR" "$ROOT/bin/fm-lock.sh" \
    >/dev/null 2>"$TMP_ROOT/session-b.err" || status=$?
  expect_code 1 "$status" "second Playbot thread lock refusal"
  assert_contains "$(cat "$TMP_ROOT/session-b.err")" "another live firstmate session" \
    "second Playbot thread was not refused as a distinct live owner"
  [ "$(cat "$HOME_DIR/state/.lock-session")" = session-a ] || fail "refused thread replaced lock session"

  PLAYBOT_DB="$PLAYBOT_DB" node --no-warnings --input-type=module - <<'EOF'
import { DatabaseSync } from "node:sqlite";
const db = new DatabaseSync(process.env.PLAYBOT_DB);
db.prepare("UPDATE workspace_threads SET archived = 1 WHERE session_id = ?").run("session-a");
db.close();
EOF

  out=$(playbot_env CODEX_THREAD_ID=session-b FM_HOME="$HOME_DIR" "$ROOT/bin/fm-lock.sh") \
    || fail "archived prior Playbot thread did not release the lock"
  assert_contains "$out" "session session-b" "replacement lock omitted new Playbot session"
  [ "$(cat "$HOME_DIR/state/.lock-session")" = session-b ] || fail "archived owner was not replaced"
  pass "one Codex app-server cannot collapse two Playbot threads into one lock owner"
}

test_uncertain_session_liveness_fails_closed() {
  local status=0
  PLAYBOT_DESKTOP_DIR="$TMP_ROOT/missing-desktop" FM_ROOT_OVERRIDE="$PROJECT" \
    PATH="$FAKEBIN:$REAL_PATH" bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; fm_session_lock_holder_alive "$1"' \
    "$ROOT" "$HOME_DIR/state" || status=$?
  expect_code 0 "$status" "unreadable Playbot session liveness"
  pass "Playbot session-liveness uncertainty keeps the recorded holder live"
}

test_msys_directory_lock_preserves_owner_generation() {
  local state lockdir out
  state="$TMP_ROOT/msys-lock-state"
  lockdir="$state/.generation.lock"
  mkdir -p "$state"
  out=$(PATH="$FAKEBIN:$REAL_PATH" FM_STATE_OVERRIDE="$state" FM_LOCK_STALE_AFTER=0 bash -c '
    . "$1"
    owner1=$(fm_lock_owner_dir "$2") || exit 20
    fm_lock_prepare_owner "$owner1" || exit 21
    mkdir "$2" || exit 22
    printf "%s\n" 99999999 > "$2/pid" || exit 23
    printf "%s\n" "$owner1" > "$2/owner" || exit 24
    touch -t 200001010000 "$2" 2>/dev/null || true
    fm_lock_try_acquire "$2" || exit 25
    before=$(cat "$2/pid")
    current_owner=$(cat "$2/owner")
    if fm_lock_claim "$2" "$owner1"; then late=won; else late=lost; fi
    after=$(cat "$2/pid")
    printf "late=%s before=%s after=%s owner_changed=%s\n" "$late" "$before" "$after" \
      "$([ "$current_owner" != "$owner1" ] && echo yes || echo no)"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lockdir") || fail "MSYS generation fixture failed"
  assert_contains "$out" "late=lost" "late MSYS directory claimant replaced a recreated lock"
  assert_contains "$out" "owner_changed=yes" "MSYS directory lock did not publish a new generation"
  before=${out#*before=}; before=${before%% *}
  after=${out#*after=}; after=${after%% *}
  [ -n "$before" ] && [ "$before" = "$after" ] || fail "late MSYS claimant changed the new pid: $out"
  pass "MSYS directory locks retain unique owner generations across stale recovery"
}

test_session_helper
test_windows_harness_fallback
test_lock_distinguishes_shared_codex_threads
test_uncertain_session_liveness_fails_closed
test_msys_directory_lock_preserves_owner_generation

echo "# all fm-playbot-session-lock tests passed"
