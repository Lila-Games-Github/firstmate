#!/usr/bin/env bash
# Behavior tests for the live board payload, terminal rendering, and inbox notes.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-crew-board.sh"
HARNESS="$ROOT/tests/assets/crew-board-tui-harness.py"
TMP_ROOT=$(fm_test_tmproot fm-crew-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] alpha - Make the widget spin (repo: widget) (kind: ship) (since 2026-10-19)
- [ ] beta - Fix the gadget (repo: gadget) (kind: ship) (since 2026-10-19)

## Queued

## Done
EOF
  printf 'kind=ship\nproject=/x/projects/widget\nharness=claude\n' > "$home/state/alpha.meta"
  printf 'phase: testing - suite\n' > "$home/state/alpha.status"
  printf 'kind=ship\nproject=/x/projects/gadget\nharness=claude\n' > "$home/state/beta.meta"
  printf 'phase: fixing - investigating\n' > "$home/state/beta.status"
  printf '%s\n' "$home"
}

run_board() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$BOARD" "$@"
}

row_field() { jq -r --arg id "$2" --arg f "$3" '.rows[] | select(.id == $id) | .[$f]' "$1/state/crew-board.json"; }
set_mtime() { perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"; }

test_rows_and_phase_time() {
  local home out
  home=$(make_home rows)
  set_mtime 1700000000 "$home/state/alpha.status"
  out=$(run_board "$home" refresh) || fail "refresh failed: $out"
  assert_equals changed "$out" "first refresh"
  assert_equals testing "$(row_field "$home" alpha phase)" "worker's testing phase"
  assert_equals 'Make the widget spin' "$(row_field "$home" alpha title)" "worker title"
  assert_equals 1700000000 "$(row_field "$home" alpha phase_since)" "phase start"
  printf 'working: still running tests\n' >> "$home/state/alpha.status"
  run_board "$home" refresh >/dev/null || fail "refresh failed"
  assert_equals 1700000000 "$(row_field "$home" alpha phase_since)" "same phase keeps its time"
  assert_equals 'still running tests' "$(row_field "$home" alpha note)" "latest status note"
  printf 'phase: fixing - red test\n' >> "$home/state/alpha.status"
  set_mtime 1700000900 "$home/state/alpha.status"
  run_board "$home" refresh >/dev/null || fail "refresh failed"
  assert_equals fixing "$(row_field "$home" alpha phase)" "changed phase"
  assert_equals 1700000900 "$(row_field "$home" alpha phase_since)" "new phase resets its time"
  assert_contains "$(run_board "$home" show)" $'alpha\tfixing\tfor ' "show reports the payload row"
  pass "payload uses worker reports and keeps time in the current phase"
}

test_refresh_and_gone() {
  local home out
  home=$(make_home gone)
  run_board "$home" refresh >/dev/null || fail "refresh failed"
  set_mtime 1700000000 "$home/state/crew-board.json"
  out=$(run_board "$home" refresh) || fail "refresh failed"
  assert_equals unchanged "$out" "unchanged rows"
  assert_equals 1700000000 "$(perl -e 'print((stat $ARGV[0])[9])' "$home/state/crew-board.json")" "unchanged payload rewritten"
  rm -f "$home/state/alpha.meta" "$home/state/alpha.status"
  run_board "$home" refresh >/dev/null || fail "refresh failed"
  assert_equals true "$(row_field "$home" alpha gone)" "left worker stays visible in payload"
  pass "refresh preserves unchanged payloads and retains a departed worker"
}

test_tui_render_and_note() {
  local home result
  home=$(make_home tui)
  result=$(python3 "$HARNESS" "$BOARD" "$home") || fail "terminal harness failed: $result"
  assert_equals 0 "$(jq -r '.exit' <<< "$result")" "TUI exit: $(jq -c '.errors' <<< "$result")"
  assert_equals true "$(jq -r '.workers and .feed and .row and .phase' <<< "$result")" "worker/feed rendering"
  assert_equals true "$(jq -r '.counts' <<< "$result")" "phase counts"
  assert_equals true "$(jq -r '.input' <<< "$result")" "note input rendering"
  assert_contains "$(jq -r '.note' <<< "$result")" 'Crew board item: alpha | widget / Make the widget spin | testing' "selected row not in note"
  assert_contains "$(jq -r '.note' <<< "$result")" 'Note: why so slow?' "typed note lost"
  assert_contains "$(jq -r '.wake' <<< "$result")" 'check: captain inbox note' "firstmate was not woken"
  assert_contains "$(jq -r '.stop' <<< "$result")" 'tui: stopped' "stop did not close the dashboard"
  assert_equals true "$(jq -r '.pid_removed' <<< "$result")" "stop left the pid record"
  assert_contains "$(env -u FM_HOME FM_STATE_OVERRIDE="$home/state" "$BOARD" stop)" 'tui: not running' \
    "direct stop without FM_HOME failed"
  pass "terminal renders rows and phase counts, typed notes reach the captain inbox, and stop closes it"
}

test_narrow_terminal() {
  local home result
  home=$(make_home narrow)
  result=$(TUI_TEST_WIDTH=55 TUI_TEST_HEIGHT=18 python3 "$HARNESS" "$BOARD" "$home") \
    || fail "narrow terminal harness failed: $result"
  assert_equals true "$(jq -r '.workers and .counts and .input' <<< "$result")" \
    "narrow active panel did not retain counts and input"
  assert_contains "$(jq -r '.note' <<< "$result")" 'Note: why so slow?' "narrow note input lost text"
  pass "a narrow terminal stacks both panels and retains note input"
}

test_note_without_selection_and_point_without_text() {
  local home result
  home=$(make_home plain-note)
  result=$(TUI_TEST_KEYS='ilook at the backlog\r' python3 "$HARNESS" "$BOARD" "$home") \
    || fail "plain note harness failed: $result"
  assert_contains "$(jq -r '.note' <<< "$result")" 'look at the backlog' "plain note lost"
  assert_not_contains "$(jq -r '.note' <<< "$result")" 'Crew board item:' "plain note got an unwanted worker"
  home=$(make_home point-only)
  result=$(TUI_TEST_KEYS='ji\r' python3 "$HARNESS" "$BOARD" "$home") \
    || fail "point-only harness failed: $result"
  assert_contains "$(jq -r '.note' <<< "$result")" 'Crew board item: alpha' "selected worker was not pointed out"
  assert_not_contains "$(jq -r '.note' <<< "$result")" 'Note:' "pointing added an empty note"
  pass "plain notes and worker-only pointing reach the same captain inbox"
}

test_panel_projection_and_launcher() {
  local home install_dir result
  home=$(make_home panels)
  cat > "$home/data/captain-questions.md" <<'EOF'
# Open questions

## Decisions
- Which release should ship?
  Blocks the Android build.
EOF
  cat > "$home/data/crew-board-cache.json" <<'EOF'
{"schema":"fm-crew-board-cache.v1","observed_at":"2026-10-21T06:00:00Z","phones":[{"title":"S22","status":"locked","detail":"held by alpha"}],"bugs":[{"title":"Rocketboard login bug","status":"in progress"}],"allowance":[{"title":"Claude","status":"45% remaining"}],"routines":[{"title":"Tip health","status":"green"}]}
EOF
  run_board "$home" refresh >/dev/null || fail "panel refresh failed"
  assert_equals 1 "$(jq '.panels.questions | length' "$home/state/crew-board.json")" "question count"
  assert_contains "$(jq -r '.panels.questions[0].detail' "$home/state/crew-board.json")" 'Blocks the Android build' "question blocker"
  assert_equals 1 "$(jq '[.panels.phones[] | select(.title == "S22")] | length' "$home/state/crew-board.json")" "phone cache"
  assert_equals 2 "$(jq '.panels.backlog.in_flight' "$home/state/crew-board.json")" "in-flight count from tasks-axi"
  assert_equals 'Rocketboard login bug' "$(jq -r '.panels.bugs[0].title' "$home/state/crew-board.json")" "bug cache"
  install_dir="$home/local-bin"
  "$ROOT/bin/fm-install-firstmate-cli.sh" "$install_dir" >/dev/null || fail "launcher install failed"
  assert_equals "$(cd "$ROOT/bin" && pwd -P)/firstmate" "$(readlink "$install_dir/firstmate")" "launcher target"
  "$ROOT/bin/fm-install-firstmate-cli.sh" "$install_dir" >/dev/null || fail "launcher reinstall failed"
  result=$(PATH="$install_dir:$PATH" command -v firstmate)
  assert_equals "$install_dir/firstmate" "$result" "launcher not on test PATH"
  pass "local panel cache, captain questions, tasks-axi backlog, and one-word launcher"
}

test_local_phones_and_cache_overlay() {
  local home stub
  home=$(make_home phones)
  stub="$home/stub-bin"
  mkdir -p "$stub"
  cat > "$stub/adb" <<'EOF'
#!/usr/bin/env bash
printf 'List of devices attached\nserial-one device product:blue model:Pixel_8 device:blue\nserial-two device product:red model:Galaxy_S22 device:red\nserial-three unauthorized\nserial-four offline\n'
EOF
  chmod +x "$stub/adb"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "phone refresh failed"
  assert_equals 4 "$(jq '.panels.phones | length' "$home/state/crew-board.json")" "adb phone count"
  assert_equals 'Pixel 8' "$(jq -r '.panels.phones[] | select(.id == "serial-one") | .title' "$home/state/crew-board.json")" "adb model"
  assert_equals 'serial-one' "$(jq -r '.panels.phones[] | select(.id == "serial-one") | .detail' "$home/state/crew-board.json")" "adb serial detail"
  assert_equals 'unauthorized' "$(jq -r '.panels.phones[] | select(.id == "serial-three") | .status' "$home/state/crew-board.json")" "unauthorized state"
  assert_equals 'offline' "$(jq -r '.panels.phones[] | select(.id == "serial-four") | .status' "$home/state/crew-board.json")" "offline state"
  cat > "$home/data/crew-board-cache.json" <<'EOF'
{"schema":"fm-crew-board-cache.v1","phones":[{"id":"serial-one","title":"Old title","status":"locked","detail":"held by worker"},{"title":"Galaxy_S22","status":"busy","detail":"reserved"},{"title":"Cache only","status":"ready","detail":"manual"}]}
EOF
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "phone overlay refresh failed"
  assert_equals 5 "$(jq '.panels.phones | length' "$home/state/crew-board.json")" "merged phone count"
  assert_equals 4 "$(jq '[.panels.phones[] | select(.adb != null)] | length' "$home/state/crew-board.json")" "attached device rows"
  assert_equals 1 "$(jq '[.panels.phones[] | select(.adb == null)] | length' "$home/state/crew-board.json")" "cache-only phone rows"
  assert_equals 'locked' "$(jq -r '.panels.phones[] | select(.id == "serial-one") | .status' "$home/state/crew-board.json")" "serial overlay"
  assert_equals 'held by worker' "$(jq -r '.panels.phones[] | select(.id == "serial-one") | .detail' "$home/state/crew-board.json")" "overlay detail"
  assert_equals 'busy' "$(jq -r '.panels.phones[] | select(.id == "serial-two") | .status' "$home/state/crew-board.json")" "normalized title overlay"
  assert_equals 0 "$(jq '[.panels.phones[] | select(.title == "Cache only" and .adb != null)] | length' "$home/state/crew-board.json")" "cache-only row marked attached"
  rm "$stub/adb" "$home/data/crew-board-cache.json"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "missing adb refresh failed"
  assert_equals 0 "$(jq '.panels.phones | length' "$home/state/crew-board.json")" "missing adb phone count"
  pass "local adb phones, unavailable states, cache overlay, and missing adb"
}

test_phone_connection_states() {
  local home stub
  home=$(make_home phone_states)
  stub="$home/stub-bin"
  mkdir -p "$stub"
  cat > "$stub/adb" <<'EOF'
#!/usr/bin/env bash
printf 'List of devices attached\nserial-one device product:blue model:Pixel_8 device:blue\nserial-two unauthorized\n'
EOF
  chmod +x "$stub/adb"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "phone state refresh failed"
  assert_equals 1 "$(jq '[.panels.phones[] | select(.adb == "device")] | length' "$home/state/crew-board.json")" "connected device rows"
  assert_equals 1 "$(jq '[.panels.phones[] | select(.adb == "unauthorized")] | length' "$home/state/crew-board.json")" "unauthorized device rows"
  assert_equals 'unauthorized' "$(jq -r '.panels.phones[] | select(.adb == "unauthorized") | .status' "$home/state/crew-board.json")" "unauthorized row state"
  assert_equals true "$(jq -r '.panels.phones[] | select(.adb == "unauthorized") | .alert' "$home/state/crew-board.json")" "unauthorized row is an alert"
  assert_equals 1 "$(jq '[.panels.alerts[] | select(.title == "Phone serial-two unauthorized")] | length' "$home/state/crew-board.json")" "unauthorized phone alert"
  assert_contains "$(jq -r '.panels.alerts[] | select(.title == "Phone serial-two unauthorized") | .detail' "$home/state/crew-board.json")" 'adb reports unauthorized' "unauthorized alert reason"
  cat > "$home/data/crew-board-cache.json" <<'EOF'
{"schema":"fm-crew-board-cache.v1","phones":[{"id":"serial-two","title":"Galaxy S22","status":"locked","detail":"held by worker"}]}
EOF
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "unauthorized overlay refresh failed"
  assert_equals 1 "$(jq '[.panels.alerts[] | select(.title == "Phone serial-two unauthorized" and .status == "unauthorized")] | length' "$home/state/crew-board.json")" "unauthorized alert under a cache status"
  assert_contains "$(jq -r '.panels.alerts[] | select(.title == "Phone serial-two unauthorized") | .detail' "$home/state/crew-board.json")" 'adb reports unauthorized' "unauthorized reason under a cache status"
  assert_equals 1 "$(jq '[.panels.alerts[] | select(.title == "Phone serial-two locked" and .detail == "held by worker")] | length' "$home/state/crew-board.json")" "cache lock alert kept"
  cat > "$stub/adb" <<'EOF'
#!/usr/bin/env bash
printf 'List of devices attached\nserial-one device product:blue model:Pixel_8 device:blue\nserial-two offline\n'
EOF
  chmod +x "$stub/adb"
  cat > "$home/data/crew-board-cache.json" <<'EOF'
{"schema":"fm-crew-board-cache.v1","phones":[{"id":"serial-two","title":"Galaxy S22","status":"busy","detail":"reserved"}]}
EOF
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "offline overlay refresh failed"
  assert_equals 'offline' "$(jq -r '.panels.phones[] | select(.id == "serial-two") | .adb' "$home/state/crew-board.json")" "offline adb state kept under a cache status"
  assert_equals 1 "$(jq '[.panels.alerts[] | select(.title == "Phone serial-two offline" and .status == "offline")] | length' "$home/state/crew-board.json")" "offline alert under a cache status"
  assert_equals 0 "$(jq '[.panels.alerts[] | select(.title == "Phone serial-two busy")] | length' "$home/state/crew-board.json")" "busy cache status is not an alert"
  pass "connected and unauthorized phone rows are told apart and alert the captain"
}

test_bold_question_paragraphs() {
  local home
  home=$(make_home bold_questions)
  cat > "$home/data/captain-questions.md" <<'EOF'
# Open questions
This preamble is not a question.

---

## Your decisions
**UIX. Prototype vs Claude Design UI: four calls.** Source: design review.
The full decision needs a longer explanation on its own line.

**OPS. Release timing.** Choose the release window.

---

## For Tarun
- Can we use the staging phone?
  Production stays locked.
EOF
  run_board "$home" refresh >/dev/null || fail "bold question refresh failed"
  assert_equals 3 "$(jq '.panels.questions | length' "$home/state/crew-board.json")" "bold and bullet questions"
  assert_equals 'UIX. Prototype vs Claude Design UI: four calls.' "$(jq -r '.panels.questions[0].title' "$home/state/crew-board.json")" "bold label title"
  assert_contains "$(jq -r '.panels.questions[0].detail' "$home/state/crew-board.json")" 'The full decision needs a longer explanation' "full question paragraph"
  assert_equals 5 "$(jq '.panels.full_questions | length' "$home/state/crew-board.json")" "section rows and questions"
  assert_not_contains "$(jq -r '[.panels.questions[].detail] | join(" ")' "$home/state/crew-board.json")" 'This preamble' "preamble leaked"
  pass "bold-led question paragraphs and bullet questions are readable"
}

test_quota_allowance_snapshot() {
  local home stub source
  home=$(make_home quota)
  stub="$home/stub-bin"
  mkdir -p "$stub"
  source="$home/quota.json"
  cat > "$source" <<'EOF'
{"providers":[{"provider":"claude","windows":[{"id":"seven_day","label":"week","resetsAt":"tomorrow"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":70,"limitingWindowIds":["seven_day"],"runway":{"status":"through_reset"}}]}},{"provider":"codex","windows":[{"id":"weekly","label":"week","resetsAt":"Friday"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":17,"limitingWindowIds":["weekly"],"runway":{"status":"projected_exhaustion"}}]}},{"provider":"openrouter","credits":{"remaining":27.3,"unit":"usd"},"quotaSemantics":{"effectiveAvailability":[]}},{"provider":"cursor","state":{"status":"auth_required"},"quotaSemantics":{"effectiveAvailability":[]}}]}
EOF
  cat > "$stub/quota-axi" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$FM_HOME/quota-calls"
if [ "${QUOTA_FAIL:-}" = 1 ]; then exit 1; fi
cat "$QUOTA_OUTPUT"
EOF
  chmod +x "$stub/quota-axi"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" QUOTA_OUTPUT="$source" PATH="$stub:/usr/bin:/bin" \
    python3 "$ROOT/bin/fm-crew-board-panels.py" --refresh-allowance || fail "quota snapshot failed"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "quota board refresh failed"
  assert_equals 1 "$(wc -l < "$home/quota-calls")" "fast refresh called quota"
  assert_equals 4 "$(jq '.panels.allowance | length' "$home/state/crew-board.json")" "allowance provider rows"
  assert_equals true "$(jq -r '.panels.allowance[] | select(.title == "codex") | .alert' "$home/state/crew-board.json")" "projected exhaustion alert"
  assert_contains "$(jq -r '.panels.allowance[] | select(.title == "claude") | .detail' "$home/state/crew-board.json")" 'reset: tomorrow' "quota reset"
  assert_contains "$(jq -r '.panels.allowance[] | select(.title == "openrouter") | .status' "$home/state/crew-board.json")" '27.3 usd' "credit balance"
  assert_contains "$(jq -r '.panels.allowance[] | select(.title == "openrouter") | .detail' "$home/state/crew-board.json")" 'runway: unknown' "credit runway"
  assert_contains "$(jq -r '.panels.allowance[] | select(.status == "unavailable") | .detail' "$home/state/crew-board.json")" 'cursor: auth_required' "unavailable provider"
  cat > "$home/data/crew-board-cache.json" <<'EOF'
{"schema":"fm-crew-board-cache.v1","allowance":[{"title":"Claude","status":"45% remaining","detail":"hand written"},{"title":"Mistral","status":"12% remaining"}]}
EOF
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "allowance overlay refresh failed"
  assert_equals 5 "$(jq '.panels.allowance | length' "$home/state/crew-board.json")" "allowance counted each provider once"
  assert_equals 0 "$(jq '[.panels.allowance[] | select(.title == "Claude")] | length' "$home/state/crew-board.json")" "cached provider duplicate survived"
  assert_contains "$(jq -r '.panels.allowance[] | select(.title == "claude") | .detail' "$home/state/crew-board.json")" 'reset: tomorrow' "live quota row lost to cache"
  assert_equals '12% remaining' "$(jq -r '.panels.allowance[] | select(.title == "Mistral") | .status' "$home/state/crew-board.json")" "supplementary cache row kept"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" QUOTA_FAIL=1 PATH="$stub:/usr/bin:/bin" \
    python3 "$ROOT/bin/fm-crew-board-panels.py" --refresh-allowance || fail "quota failure crashed"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "stale quota refresh failed"
  assert_contains "$(jq -r '.panels.allowance[] | select(.title == "claude") | .detail' "$home/state/crew-board.json")" 'stale' "last good quota not marked stale"
  pass "quota allowance uses a slow structured snapshot and keeps the last good result"
}

test_playbot_lane_projection() {
  local home
  command -v node >/dev/null 2>&1 || { echo "skip: node unavailable for Playbot lane projection"; return; }
  home=$(make_home playbot_lanes)
  mkdir -p "$home/playbot"
  python3 - "$home" <<'PY'
import hashlib, pathlib, sqlite3, sys
home = pathlib.Path(sys.argv[1])
db = sqlite3.connect(home / "playbot" / "playbot.db")
db.executescript("""
CREATE TABLE projects (id TEXT, name TEXT);
CREATE TABLE workspaces (id TEXT, project_id TEXT, name TEXT, kind TEXT, is_selected INTEGER, archive_state TEXT);
CREATE TABLE workspace_threads (id TEXT, title TEXT, workspace_id TEXT, session_id TEXT, agent_status TEXT,
 pending_queue_json TEXT, has_unread INTEGER, is_active INTEGER, archived INTEGER, approval_mode TEXT,
 plan_mode TEXT, last_user_activity_at TEXT, created_at TEXT, updated_at TEXT, position INTEGER);
INSERT INTO projects VALUES ('project-live', 'rocketboard');
INSERT INTO workspaces VALUES ('space-live', 'project-live', 'Workspace', 'normal', 0, 'active');
INSERT INTO workspace_threads VALUES ('thread-live', 'Implement launch', 'space-live', '', 'working', '[]', 0, 1, 0, '', '', '', '', '2026-10-21T09:00:00Z', 0);
INSERT INTO workspace_threads VALUES ('thread-stale', 'Finished work', 'space-live', '', 'ready', '[]', 0, 1, 0, '', '', '', '', '2026-10-21T09:00:00Z', 1);
""")
db.commit()
db.close()
for task, thread, armed in [('lane-live', 'thread-live', True), ('lane-stale', 'thread-stale', True), ('lane-orphan', 'thread-live', False)]:
    key = 'sha256:' + hashlib.sha256(thread.encode()).hexdigest()
    (home / 'state' / f'{task}.lane-poll').write_text(f'fm-playbot-lane-poll-v8\nworking\n2026-10-21T09:00:00Z\ndelivered\n' + 'a'*32 + f'\nnone\nnone\n{key}\n')
    if armed:
        check = b'#!/usr/bin/env bash\n# fm-playbot-lane-supervision-poll v1\n'
        (home / 'state' / f'{task}.check.sh').write_bytes(check)
        (home / 'state' / f'{task}.check-trust').write_text('fm-custom-check-v1\n' + hashlib.sha256(check).hexdigest() + '\n')
PY
  PLAYBOT_DESKTOP_DIR="$home/playbot" run_board "$home" refresh >/dev/null || fail "Playbot lane refresh failed"
  PLAYBOT_DESKTOP_DIR="$home/playbot" run_board "$home" refresh >/dev/null || fail "second Playbot lane refresh failed"
  assert_equals 1 "$(jq '[.rows[] | select(.kind == "playbot" and (.gone | not))] | length' "$home/state/crew-board.json")" "live Playbot lane count"
  assert_equals 'rocketboard' "$(jq -r '.rows[] | select(.kind == "playbot" and (.gone | not)) | .project' "$home/state/crew-board.json")" "Playbot project"
  assert_contains "$(jq -r '.rows[] | select(.kind == "playbot" and (.gone | not)) | .title' "$home/state/crew-board.json")" '[Playbot]' "Playbot marker"
  pass "armed live Playbot lane joins ordinary workers without stale sidecars"
}

test_full_questions_and_backlog() {
  local home
  home=$(make_home full_page)
  cat > "$home/data/captain-questions.md" <<'EOF'
# Open questions

## Decisions for the product owner
- Which release should ship?
  The Android build is waiting.

## For Tarun
- Can we use the staging phone?
  The production phone stays locked.

## For Arshnoor
- Which color should launch?

## For Aleksandra
- Is the copy approved?
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

- [ ] alpha - Build widget (repo: widget) (kind: ship) (since 2026-10-21)
  Finish the widget animation.

- [ ] beta - Pick release (repo: widget) (kind: captain) (since 2026-10-21) (hold: choose release A or B) (hold-kind: captain)
  Release A is stable; B has the new screen.

- [ ] delta - Ship patch (repo: widget) (kind: ship) (since 2026-10-21) (hold: waiting on store review) (hold-kind: external) (hold-until: 2026-12-01)
  Store review usually takes two days.

## Queued

- [ ] gamma - Write tests (repo: gadget) (kind: ship)
  Cover the startup path.

## Done
EOF
  run_board "$home" refresh >/dev/null || fail 'full page refresh failed'
  assert_equals 8 "$(jq '.panels.full_questions | length' "$home/state/crew-board.json")" 'question section and entry count'
  assert_equals 'DECISIONS FOR THE PRODUCT OWNER' \
    "$(jq -r '.panels.full_questions[0].title' "$home/state/crew-board.json")" 'question section heading'
  assert_contains "$(jq -r '.panels.full_questions[1].detail' "$home/state/crew-board.json")" \
    'The Android build is waiting.' 'full question text'
  assert_equals 4 "$(jq '.panels.questions | length' "$home/state/crew-board.json")" 'Now page summary count'
  assert_equals 8 "$(jq '.panels.full_backlog | length' "$home/state/crew-board.json")" 'backlog groups and items'
  assert_equals 'HELD FOR THE CAPTAIN' \
    "$(jq -r '.panels.full_backlog[2].title' "$home/state/crew-board.json")" 'captain hold section'
  assert_contains "$(jq -r '.panels.full_backlog[3].title' "$home/state/crew-board.json")" \
    'choose release A or B' 'visible hold reason'
  assert_contains "$(jq -r '.panels.full_backlog[3].detail' "$home/state/crew-board.json")" \
    'Release A is stable; B has the new screen.' 'full backlog note'
  assert_not_contains "$(jq -r '.panels.full_backlog[3].title' "$home/state/crew-board.json")" \
    'beta' 'backlog title leaked its task id'
  assert_equals 'HELD (OTHER)' \
    "$(jq -r '.panels.full_backlog[4].title' "$home/state/crew-board.json")" 'other hold section'
  assert_contains "$(jq -r '.panels.full_backlog[5].title' "$home/state/crew-board.json")" \
    'waiting on store review' 'visible non-captain hold reason'
  assert_contains "$(jq -r '.panels.full_backlog[5].detail' "$home/state/crew-board.json")" \
    'Held until: 2026-12-01' 'non-captain hold until-date'
  assert_equals 'QUEUED' \
    "$(jq -r '.panels.full_backlog[6].title' "$home/state/crew-board.json")" 'queued section after holds'
  pass 'full questions and backlog parsers retain grouped entries, hold reasons, and notes'
}

test_rows_and_phase_time
test_refresh_and_gone
test_tui_render_and_note
test_narrow_terminal
test_note_without_selection_and_point_without_text
test_panel_projection_and_launcher
test_local_phones_and_cache_overlay
test_phone_connection_states
test_bold_question_paragraphs
test_quota_allowance_snapshot
test_playbot_lane_projection
test_full_questions_and_backlog
