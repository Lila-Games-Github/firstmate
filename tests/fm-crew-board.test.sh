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
  FM_CREW_BOARD_PHONE_QUEUE_ROOT="${FM_CREW_BOARD_PHONE_QUEUE_ROOT:-$home/locks}" \
    FROGPILE_SUITE_LOCK="${FROGPILE_SUITE_LOCK:-$home/locks/frogpile-suite.lock}" \
    FROGPILE_SUITE_LOCK_HOLDER="${FROGPILE_SUITE_LOCK_HOLDER:-$home/locks/suite.holder}" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$BOARD" "$@"
}

run_panels() {
  local home=$1
  FM_CREW_BOARD_PHONE_QUEUE_ROOT="$home/locks" FROGPILE_SUITE_LOCK="$home/locks/frogpile-suite.lock" \
    FROGPILE_SUITE_LOCK_HOLDER="$home/locks/suite.holder" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" python3 "$ROOT/bin/fm-crew-board-panels.py" "$2"
}

# Starts a sleeping process whose working directory is $1 and prints its pid.
sleeper_in() { (cd "$1" && exec sleep 60) >/dev/null 2>&1 & printf '%s\n' "$!"; }

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
  rm -f "$home/data/crew-board-cache.json"
  cat > "$stub/adb" <<'EOF'
#!/usr/bin/env bash
printf 'List of devices attached\n'
EOF
  chmod +x "$stub/adb"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "device-free adb refresh failed"
  assert_equals 0 "$(jq '.panels.phones | length' "$home/state/crew-board.json")" "attached-phone-free adb"
  pass "local adb phones, unavailable states, cache overlay, and missing adb"
}

test_phone_connection_states() {
  local home stub
  home=$(make_home phone_states)
  stub="$home/stub-bin"
  mkdir -p "$stub"
  cat > "$stub/adb" <<'EOF'
#!/usr/bin/env bash
printf 'List of devices attached\nserial-one device product:blue model:Pixel_8 device:blue\nserial-two unauthorized\nserial-three no permissions (user in plugdev group; are your udev rules wrong?); see [http://developer.android.com/tools/device.html]\nserial-four recovery\n* daemon not running; starting now at tcp:5037\n'
EOF
  chmod +x "$stub/adb"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "phone state refresh failed"
  assert_equals 4 "$(jq '.panels.phones | length' "$home/state/crew-board.json")" "every adb device line becomes a row"
  assert_equals 1 "$(jq '[.panels.phones[] | select(.adb == "device")] | length' "$home/state/crew-board.json")" "connected device rows"
  assert_equals 1 "$(jq '[.panels.phones[] | select(.adb == "unauthorized")] | length' "$home/state/crew-board.json")" "unauthorized device rows"
  assert_equals 'unauthorized' "$(jq -r '.panels.phones[] | select(.adb == "unauthorized") | .status' "$home/state/crew-board.json")" "unauthorized row state"
  assert_equals true "$(jq -r '.panels.phones[] | select(.adb == "unauthorized") | .alert' "$home/state/crew-board.json")" "unauthorized row is an alert"
  assert_equals 'no permissions' "$(jq -r '.panels.phones[] | select(.id == "serial-three") | .adb' "$home/state/crew-board.json")" "two-word adb state"
  assert_equals true "$(jq -r '.panels.phones[] | select(.id == "serial-three") | .alert' "$home/state/crew-board.json")" "no permissions row is an alert"
  assert_equals 'serial-three' "$(jq -r '.panels.phones[] | select(.id == "serial-three") | .title' "$home/state/crew-board.json")" "no model falls back to the serial"
  assert_equals 'recovery' "$(jq -r '.panels.phones[] | select(.id == "serial-four") | .adb' "$home/state/crew-board.json")" "unknown adb state is kept"
  assert_equals true "$(jq -r '.panels.phones[] | select(.id == "serial-four") | .alert' "$home/state/crew-board.json")" "unknown state row is an alert"
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
  rm -f "$home/data/crew-board-cache.json"
  cat > "$stub/adb" <<'EOF'
#!/usr/bin/env bash
printf "adb server version (41) doesn't match this client (39); killing...\n* daemon started successfully\nList of devices attached\nserial-one device product:blue model:Pixel_8 device:blue\nserial-five offline\n"
EOF
  chmod +x "$stub/adb"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "banner adb refresh failed"
  assert_equals 2 "$(jq '.panels.phones | length' "$home/state/crew-board.json")" "client banner lines are not devices"
  assert_equals 0 "$(jq '[.panels.phones[] | select(.id == "adb")] | length' "$home/state/crew-board.json")" "version banner became a phone row"
  pass "connected and unauthorized phone rows are told apart and alert the captain"
}

test_phone_adb_fallbacks() {
  local home stub
  home=$(make_home phone_fallbacks)
  stub="$home/stub-bin"
  mkdir -p "$stub" "$home/nohome" "$home/sdk/platform-tools" "$home/sdkroot/platform-tools" \
    "$home/sdkhome/Android/Sdk/platform-tools" "$home/brew/bin"
  write_adb() {
    printf '#!/usr/bin/env bash\nprintf "List of devices attached\\n%s device product:blue model:Pixel_8 device:blue\\n"\n' "$2" > "$1"
    chmod +x "$1"
  }
  write_adb "$stub/adb" serial-path
  write_adb "$home/sdk/platform-tools/adb" serial-android-home
  write_adb "$home/sdkroot/platform-tools/adb" serial-android-sdk-root
  write_adb "$home/sdkhome/Android/Sdk/platform-tools/adb" serial-home-sdk
  write_adb "$home/brew/bin/adb" serial-brew
  PATH="$stub:/usr/bin:/bin" ANDROID_HOME="$home/nohome" ANDROID_SDK_ROOT="$home/nohome" HOME="$home/nohome" HOMEBREW_PREFIX="$home/nohome" \
    run_board "$home" refresh >/dev/null || fail "PATH adb refresh failed"
  assert_equals 'serial-path' "$(jq -r '.panels.phones[0].id' "$home/state/crew-board.json")" "adb on PATH"
  PATH="/usr/bin:/bin" ANDROID_HOME="$home/sdk" ANDROID_SDK_ROOT="$home/sdkroot" HOME="$home/nohome" HOMEBREW_PREFIX="$home/nohome" \
    run_board "$home" refresh >/dev/null || fail "ANDROID_HOME adb refresh failed"
  assert_equals 'serial-android-home' "$(jq -r '.panels.phones[0].id' "$home/state/crew-board.json")" "adb under ANDROID_HOME"
  PATH="/usr/bin:/bin" ANDROID_HOME="$home/nohome" ANDROID_SDK_ROOT="$home/sdkroot" HOME="$home/nohome" HOMEBREW_PREFIX="$home/nohome" \
    run_board "$home" refresh >/dev/null || fail "ANDROID_SDK_ROOT adb refresh failed"
  assert_equals 'serial-android-sdk-root' "$(jq -r '.panels.phones[0].id' "$home/state/crew-board.json")" "adb under ANDROID_SDK_ROOT"
  PATH="/usr/bin:/bin" ANDROID_HOME="$home/nohome" ANDROID_SDK_ROOT="$home/nohome" HOME="$home/sdkhome" HOMEBREW_PREFIX="$home/nohome" \
    run_board "$home" refresh >/dev/null || fail "HOME SDK adb refresh failed"
  assert_equals 'serial-home-sdk' "$(jq -r '.panels.phones[0].id' "$home/state/crew-board.json")" "adb under the home Android SDK"
  PATH="/usr/bin:/bin" ANDROID_HOME="$home/nohome" ANDROID_SDK_ROOT="$home/nohome" HOME="$home/nohome" HOMEBREW_PREFIX="$home/brew" \
    run_board "$home" refresh >/dev/null || fail "Linuxbrew adb refresh failed"
  assert_equals 'serial-brew' "$(jq -r '.panels.phones[0].id' "$home/state/crew-board.json")" "adb in Linuxbrew"
  assert_equals 'device' "$(jq -r '.panels.phones[0].adb' "$home/state/crew-board.json")" "fallback adb reports a device"
  pass "adb resolves from PATH, the Android SDK variables and locations, and Linuxbrew"
}

test_phone_check_unavailable() {
  local home stub
  home=$(make_home phone_unavailable)
  stub="$home/stub-bin"
  mkdir -p "$stub" "$home/nohome"
  PATH="/usr/bin:/bin" ANDROID_HOME="$home/nohome" ANDROID_SDK_ROOT="$home/nohome" HOME="$home/nohome" HOMEBREW_PREFIX="$home/nohome" \
    run_board "$home" refresh >/dev/null || fail "unresolvable adb refresh failed"
  assert_equals 1 "$(jq '.panels.phones | length' "$home/state/crew-board.json")" "one row when adb cannot be found"
  assert_equals 'Phone check' "$(jq -r '.panels.phones[0].title' "$home/state/crew-board.json")" "unanswered check row"
  assert_equals 'unavailable' "$(jq -r '.panels.phones[0].status' "$home/state/crew-board.json")" "unanswered check state"
  assert_equals 'unavailable' "$(jq -r '.panels.phones[0].adb' "$home/state/crew-board.json")" "unanswered check marker"
  assert_equals true "$(jq -r '.panels.phones[0].alert' "$home/state/crew-board.json")" "unanswered check alerts"
  assert_contains "$(jq -r '.panels.phones[0].detail' "$home/state/crew-board.json")" 'adb was not found' "missing adb reason"
  assert_equals 1 "$(jq '[.panels.alerts[] | select(.title == "Phone check")] | length' "$home/state/crew-board.json")" "unanswered check reaches ALERTS"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$stub/adb"
  chmod +x "$stub/adb"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "failing adb refresh failed"
  assert_contains "$(jq -r '.panels.phones[0].detail' "$home/state/crew-board.json")" 'exited 3' "failed adb reason"
  assert_equals 'unavailable' "$(jq -r '.panels.phones[0].adb' "$home/state/crew-board.json")" "failed adb row"
  printf '#!/usr/bin/env bash\nsleep 6\n' > "$stub/adb"
  chmod +x "$stub/adb"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "hanging adb refresh failed"
  assert_contains "$(jq -r '.panels.phones[0].detail' "$home/state/crew-board.json")" 'did not answer within 2s' "timed-out adb reason"
  cat > "$stub/adb" <<'EOF'
#!/usr/bin/env bash
printf 'List of devices attached\n'
EOF
  chmod +x "$stub/adb"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "empty adb refresh failed"
  assert_equals 0 "$(jq '.panels.phones | length' "$home/state/crew-board.json")" "adb that answers with no devices"
  pass "an unanswered phone check alerts with its reason instead of claiming no phones"
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
  assert_equals 5 "$(jq '.panels.allowance | length' "$home/state/crew-board.json")" "last good rows and the cache row kept after a failed attempt"
  assert_equals 0 "$(jq '[.panels.allowance[] | select(.title == "Allowance check")] | length' "$home/state/crew-board.json")" "no check row while a snapshot exists"
  assert_contains "$(jq -r '.panels.allowance[] | select(.title == "claude") | .status' "$home/state/crew-board.json")" 'ago (stale)' "stale age on the last good rows"
  pass "quota allowance uses a slow structured snapshot and keeps the last good result"
}

test_quota_check_unavailable() {
  local home
  home=$(make_home quota_unavailable)
  mkdir -p "$home/nohome" "$home/stub-bin"
  PATH="/usr/bin:/bin" HOMEBREW_PREFIX="$home/nohome" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" python3 "$ROOT/bin/fm-crew-board-panels.py" --refresh-allowance \
    || fail "a missing quota-axi crashed the sampler"
  assert_equals true "$(test -f "$home/state/.crew-board-quota-error" && echo true || echo false)" "sampler failure marker"
  run_board "$home" refresh >/dev/null || fail "failed sampler refresh failed"
  assert_equals 1 "$(jq '.panels.allowance | length' "$home/state/crew-board.json")" "one row when no snapshot exists"
  assert_equals 'Allowance check' "$(jq -r '.panels.allowance[0].title' "$home/state/crew-board.json")" "allowance check row"
  assert_equals 'unavailable' "$(jq -r '.panels.allowance[0].status' "$home/state/crew-board.json")" "allowance check state"
  assert_equals 'unavailable' "$(jq -r '.panels.allowance[0].quota' "$home/state/crew-board.json")" "allowance check marker"
  assert_equals true "$(jq -r '.panels.allowance[0].alert' "$home/state/crew-board.json")" "allowance check alerts"
  assert_contains "$(jq -r '.panels.allowance[0].detail' "$home/state/crew-board.json")" 'quota-axi' "allowance check reason"
  assert_equals 1 "$(jq '[.panels.alerts[] | select(.title == "Allowance check")] | length' "$home/state/crew-board.json")" "allowance check reaches ALERTS"
  cat > "$home/empty.json" <<'EOF'
{"providers":[]}
EOF
  cat > "$home/stub-bin/quota-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${QUOTA_FAIL:-}" = 1 ]; then exit 1; fi
cat "$QUOTA_OUTPUT"
EOF
  chmod +x "$home/stub-bin/quota-axi"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" QUOTA_OUTPUT="$home/empty.json" \
    PATH="$home/stub-bin:/usr/bin:/bin" python3 "$ROOT/bin/fm-crew-board-panels.py" --refresh-allowance \
    || fail "empty quota snapshot failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" QUOTA_FAIL=1 \
    PATH="$home/stub-bin:/usr/bin:/bin" python3 "$ROOT/bin/fm-crew-board-panels.py" --refresh-allowance \
    || fail "a failing quota-axi crashed the sampler"
  run_board "$home" refresh >/dev/null || fail "empty snapshot refresh failed"
  assert_equals 1 "$(jq '.panels.allowance | length' "$home/state/crew-board.json")" "one row for a snapshot without providers"
  assert_not_contains "$(jq -r '.panels.allowance[0].detail' "$home/state/crew-board.json")" 'no quota snapshot' "reason claimed no snapshot while one exists"
  assert_contains "$(jq -r '.panels.allowance[0].detail' "$home/state/crew-board.json")" 'quota-axi attempt failed' "failure age reason"
  pass "a sampler that never succeeded is visible instead of an empty allowance panel"
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

test_questions_without_headings() {
  local home
  home=$(make_home headingless)
  cat > "$home/data/captain-questions.md" <<'EOF'
# Open questions
This preamble is not a question.

- Which release should ship?
  Blocks the Android build.

**OPS. Release timing.** Choose the release window.
The window needs one more line.
EOF
  run_board "$home" refresh >/dev/null || fail "heading-less question refresh failed"
  assert_equals 2 "$(jq '.panels.questions | length' "$home/state/crew-board.json")" "question count before any heading"
  assert_equals 'Which release should ship?' "$(jq -r '.panels.questions[0].title' "$home/state/crew-board.json")" "bullet before any heading"
  assert_equals 'OPS. Release timing.' "$(jq -r '.panels.questions[1].title' "$home/state/crew-board.json")" "bold paragraph before any heading"
  assert_contains "$(jq -r '.panels.questions[0].detail' "$home/state/crew-board.json")" 'Blocks the Android build' "bullet detail before any heading"
  assert_contains "$(jq -r '.panels.questions[1].detail' "$home/state/crew-board.json")" 'The window needs one more line' "bold detail before any heading"
  assert_not_contains "$(jq -r '[.panels.questions[].detail] | join(" ")' "$home/state/crew-board.json")" 'This preamble' "preamble leaked"
  assert_equals 2 "$(jq '.panels.full_questions | length' "$home/state/crew-board.json")" "heading-less registers add no section rows"
  pass "questions count before the first heading and preamble prose is ignored"
}

test_quota_unknown_headroom_and_exhaustion() {
  local home stub source
  home=$(make_home quota_unknown)
  stub="$home/stub-bin"
  mkdir -p "$stub"
  source="$home/quota.json"
  cat > "$source" <<'EOF'
{"providers":[{"provider":"codex","state":{"status":"fresh"},"quotaSemantics":{"status":"unknown","effectiveAvailability":[{"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}]}},{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}},{"provider":"mistral","quotaSemantics":{"status":"unknown","effectiveAvailability":[{"scope":"all_models","status":"unknown","runway":{"status":"through_reset"}}]}},{"provider":"qwen","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70,"runway":{"status":"through_reset"}},{"scope":"model:fable","status":"unknown","runway":{"status":"exhausted_now"}}]}}]}
EOF
  cat > "$stub/quota-axi" <<'EOF'
#!/usr/bin/env bash
cat "$QUOTA_OUTPUT"
EOF
  chmod +x "$stub/quota-axi"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" QUOTA_OUTPUT="$source" PATH="$stub:/usr/bin:/bin" \
    python3 "$ROOT/bin/fm-crew-board-panels.py" --refresh-allowance || fail "quota snapshot failed"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "quota board refresh failed"
  assert_equals 5 "$(jq '.panels.allowance | length' "$home/state/crew-board.json")" "every provider keeps a row"
  assert_equals 'exhausted now' "$(jq -r '.panels.allowance[] | select(.title == "codex") | .status' "$home/state/crew-board.json")" "unknown headroom that is exhausted now"
  assert_equals true "$(jq -r '.panels.allowance[] | select(.title == "codex") | .alert' "$home/state/crew-board.json")" "exhausted unknown headroom alerts"
  assert_equals 'headroom unknown' "$(jq -r '.panels.allowance[] | select(.title == "mistral") | .status' "$home/state/crew-board.json")" "unknown headroom row"
  assert_equals false "$(jq -r '.panels.allowance[] | select(.title == "mistral") | .alert' "$home/state/crew-board.json")" "unknown headroom alone is not an alert"
  assert_contains "$(jq -r '.panels.allowance[] | select(.title == "claude") | .status' "$home/state/crew-board.json")" '0% left' "exhausted scope kept its percent"
  assert_equals true "$(jq -r '.panels.allowance[] | select(.title == "claude") | .alert' "$home/state/crew-board.json")" "exhausted now alerts"
  assert_contains "$(jq -r '.panels.allowance[] | select(.title == "qwen") | .status' "$home/state/crew-board.json")" '70% left' "scoped sibling kept its percent"
  assert_equals false "$(jq -r '.panels.allowance[] | select(.title == "qwen") | .alert' "$home/state/crew-board.json")" "healthy sibling is not an alert"
  assert_equals 'exhausted now' "$(jq -r '.panels.allowance[] | select(.title == "qwen / model:fable") | .status' "$home/state/crew-board.json")" "exhausted scope beside a scoped sibling"
  assert_equals true "$(jq -r '.panels.allowance[] | select(.title == "qwen / model:fable") | .alert' "$home/state/crew-board.json")" "exhausted scope beside a scoped sibling alerts"
  pass "unknown headroom and exhausted_now runways stay visible and alert"
}

test_quota_unresolved_limiting_window() {
  local home stub source
  home=$(make_home quota_window)
  stub="$home/stub-bin"
  mkdir -p "$stub"
  source="$home/quota.json"
  cat > "$source" <<'EOF'
{"providers":[{"provider":"claude","windows":[{"id":"weekly","label":"week","resetsAt":"Friday"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":40,"limitingWindowIds":["weekly","model:fable:7d"],"runway":{"status":"through_reset"}}]}}]}
EOF
  cat > "$stub/quota-axi" <<'EOF'
#!/usr/bin/env bash
cat "$QUOTA_OUTPUT"
EOF
  chmod +x "$stub/quota-axi"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" QUOTA_OUTPUT="$source" PATH="$stub:/usr/bin:/bin" \
    python3 "$ROOT/bin/fm-crew-board-panels.py" --refresh-allowance || fail "quota snapshot failed"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail "quota board refresh failed"
  assert_contains "$(jq -r '.panels.allowance[0].detail' "$home/state/crew-board.json")" 'limit: week, unknown' "unresolved limiting window"
  assert_not_contains "$(jq -r '.panels.allowance[0].detail' "$home/state/crew-board.json")" 'None' "unresolved window rendered as None"
  pass "an unresolved limiting window reads unknown instead of None"
}

test_phone_testing_and_test_queue() {
  local home stub queue holder waiter suite_pid suite_waiter='' blocker='' now
  home=$(make_home test_queue)
  mkdir -p "$home/wt-alpha" "$home/wt-beta" "$home/locks"
  printf 'worktree=%s\n' "$home/wt-alpha" >> "$home/state/alpha.meta"
  printf 'worktree=%s\n' "$home/wt-beta" >> "$home/state/beta.meta"
  stub="$home/stub-bin"
  mkdir -p "$stub"
  cat > "$stub/adb" <<'EOF'
#!/usr/bin/env bash
printf 'List of devices attached\nbusy-one device model:Pixel_8\nidle-two device model:Galaxy_S22\n'
EOF
  chmod +x "$stub/adb"
  holder=$(sleeper_in "$home/wt-alpha")
  waiter=$(sleeper_in "$home/wt-beta")
  suite_pid=$(sleeper_in "$home/wt-beta")
  queue="$home/locks/frogpile-phone-busy-one.queue"
  mkdir -p "$queue/tickets"
  now=$(date -u +%Y-%m-%dT%H:%M:%S.000+00:00)
  printf '{"pid": %s}\n' "$holder" > "$queue/tickets/001-held.json"
  printf '{"pid": %s}\n' "$waiter" > "$queue/tickets/002-wait.json"
  printf '{"pid": 999999999}\n' > "$queue/tickets/003-dead.json"
  {
    printf '{"event": "acquire", "ticket": "000-old", "time": "%s"}\n' "$now"
    printf '{"event": "release", "ticket": "000-old", "time": "%s"}\n' "$now"
    printf '{"event": "request", "ticket": "001-held", "time": "%s"}\n' "$now"
    printf '{"event": "acquire", "ticket": "001-held", "time": "%s"}\n' "$now"
    printf '{"event": "request", "ticket": "002-wait", "time": "%s"}\n' "$now"
  } > "$queue/events.jsonl"
  mkdir -p "$home/locks/frogpile-phone-idle-two.queue/tickets"
  printf 'pid=%s\ncwd=%s\nstarted=%s\nheartbeat=%s\n' "$suite_pid" "$home/wt-beta" "$(( $(date +%s) - 600 ))" "$(date +%s)" \
    > "$home/locks/suite.holder"
  if command -v flock >/dev/null 2>&1 && [ -r /proc/locks ]; then
    : > "$home/locks/frogpile-suite.lock"
    flock "$home/locks/frogpile-suite.lock" sleep 60 >/dev/null 2>&1 &
    blocker=$!
    sleep 0.3
    (cd "$home/wt-alpha" && exec flock "$home/locks/frogpile-suite.lock" true) >/dev/null 2>&1 &
    suite_waiter=$!
    sleep 0.3
  fi
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail 'test queue refresh failed'
  assert_equals testing "$(jq -r '.panels.phones[] | select(.id == "busy-one") | .status' "$home/state/crew-board.json")" 'held phone is testing'
  assert_contains "$(jq -r '.panels.phones[] | select(.id == "busy-one") | .detail' "$home/state/crew-board.json")" \
    'Testing: alpha (sleep) for <1m; 1 waiting' 'phone holder task, held time, and queue length'
  assert_equals idle "$(jq -r '.panels.phones[] | select(.id == "idle-two") | .status' "$home/state/crew-board.json")" 'free phone is idle'
  assert_equals 'Full suite: beta' "$(jq -r '.panels.test_queue[0].title' "$home/state/crew-board.json")" 'running suite task'
  assert_equals 'running 10m' "$(jq -r '.panels.test_queue[0].status' "$home/state/crew-board.json")" 'running suite time'
  if [ -n "$suite_waiter" ]; then
    assert_equals 'Full suite: alpha|waiting #1' \
      "$(jq -r '.panels.test_queue[1] | .title + "|" + .status' "$home/state/crew-board.json")" 'suite waiter in order'
  fi
  assert_equals 'Phone Pixel 8: alpha|running <1m' \
    "$(jq -r '[.panels.test_queue[] | select(.id | startswith("phone-"))][0] | .title + "|" + .status' "$home/state/crew-board.json")" 'phone holder row'
  assert_equals 'Phone Pixel 8: beta|waiting #1' \
    "$(jq -r '[.panels.test_queue[] | select(.id | startswith("phone-"))][1] | .title + "|" + .status' "$home/state/crew-board.json")" 'phone waiter row'
  assert_equals 2 "$(jq '[.panels.test_queue[] | select(.id | startswith("phone-"))] | length' "$home/state/crew-board.json")" 'dead ticket shown'
  kill "$holder" "$waiter" "$suite_pid" ${blocker:+"$blocker"} ${suite_waiter:+"$suite_waiter"} 2>/dev/null
  wait 2>/dev/null
  printf 'pid=1\ncwd=/\nstarted=1\nheartbeat=1\n' > "$home/locks/suite.holder"
  PATH="$stub:/usr/bin:/bin" run_board "$home" refresh >/dev/null || fail 'idle test queue refresh failed'
  assert_equals 0 "$(jq '.panels.test_queue | length' "$home/state/crew-board.json")" 'stale suite heartbeat or dead holders kept'
  assert_equals idle "$(jq -r '.panels.phones[] | select(.id == "busy-one") | .status' "$home/state/crew-board.json")" 'dead holder kept the phone busy'
  pass 'phones show their tester and the test queue lists running and waiting suites and phone reservations'
}

test_daily_routines_from_checks() {
  local home tomorrow
  home=$(make_home routines)
  cat > "$home/state/alpha-daily.check.sh" <<'EOF'
#!/usr/bin/env bash
m="$FM_HOME/state/.alpha-daily-last"
today=$(date +%F); hour=$(date +%H)
[ "$hour" -lt 10 ] && exit 0
EOF
  cat > "$home/state/beta-daily.check.sh" <<'EOF'
#!/usr/bin/env bash
today=$(date +%F); hour=$(date +%H)
[ "$hour" -lt 0 ] && exit 0
EOF
  date +%F > "$home/state/.alpha-daily-last"
  tomorrow=$(python3 -c 'import datetime as d; print(d.date.today() + d.timedelta(days=1))')
  run_board "$home" refresh >/dev/null || fail 'routine refresh failed'
  assert_equals 2 "$(jq '.panels.routines | length' "$home/state/crew-board.json")" 'one row per daily check'
  assert_equals 'alpha-daily|done today' "$(jq -r '.panels.routines[0] | .title + "|" + .status' "$home/state/crew-board.json")" "today's run"
  assert_contains "$(jq -r '.panels.routines[0].detail' "$home/state/crew-board.json")" "Next due: $tomorrow 10:00" 'next due tomorrow'
  assert_equals 'beta-daily|due now' "$(jq -r '.panels.routines[1] | .title + "|" + .status' "$home/state/crew-board.json")" 'missed run is due'
  assert_contains "$(jq -r '.panels.routines[1].detail' "$home/state/crew-board.json")" 'Last run: never' 'never-run routine'
  pass 'daily routines come from registered checks and their last-run markers'
}

test_alerts_and_ready_from_real_state() {
  local home snapshot
  home=$(make_home alerts_ready)
  touch "$home/state/.last-watcher-beat"
  snapshot="$home/snapshot.json"
  cat > "$snapshot" <<'EOF'
{"schema":"fm-fleet-snapshot.v1","tasks":[
 {"id":"waiting","phase":{"name":"paused","note":"store review"}},
 {"id":"stuck","phase":{"name":"blocked","note":"needs a credential"}},
 {"id":"broken","phase":{"name":"failed","note":"build crashed"}},
 {"id":"asking","phase":{"name":"needs-decision","note":"pick A or B"},"backlog":{"hold_kind":null}},
 {"id":"raised","phase":{"name":"needs-decision","note":"already raised"},"backlog":{"hold_kind":"captain"}},
 {"id":"green","phase":{"name":"ready-to-merge"},"backlog":{"title":"Green fix"},"pr":{"url":"https://example.test/pr/1"},
  "current_state":{"state":"done","source":"run-step","detail":"checks green: PR ready for review"}},
 {"id":"early","phase":{"name":"ready-to-merge"},"backlog":{"title":"Unvalidated fix"},"pr":{"url":"https://example.test/pr/2"},
  "current_state":{"state":"working","source":"run-step","detail":"review running"}},
 {"id":"landing","mode":"local-only","backlog":{"title":"Local tidy"},"current_state":{"state":"done","source":"status-log"}},
 {"id":"probe","kind":"scout","backlog":{"title":"Investigate crash"},"hints":{"scout_report_present":true},
  "paths":{"report":{"path":"/reports/probe.md"}}}],
 "backlog":{"records":[
  {"id":"board","state":"in_flight","title":"New board","hold_kind":"captain","hold_reason":"captain preview before merge"},
  {"id":"other","state":"in_flight","title":"Other call","hold_kind":"captain","hold_reason":"choose A or B"}]}}
EOF
  run_panels "$home" "$snapshot" > "$home/panels.json" || fail 'panel projection failed'
  assert_equals 'stuck: blocked|broken: failed|asking: decision not yet raised with you' \
    "$(jq -r '[.alerts[] | select(.id != "") | .title] | join("|")' "$home/panels.json")" 'alert workers'
  assert_contains "$(jq -r '.alerts[] | select(.id == "stuck") | .detail' "$home/panels.json")" 'needs a credential' 'alert reason'
  assert_equals 'Green fix|Local tidy|Investigate crash|New board' \
    "$(jq -r '[.ready[].title] | join("|")' "$home/panels.json")" 'ready rows from real state'
  assert_equals 'https://example.test/pr/1' "$(jq -r '.ready[0].link' "$home/panels.json")" 'ready PR link'
  assert_equals '/reports/probe.md' "$(jq -r '.ready[2].link' "$home/panels.json")" 'ready report link'
  pass 'alerts drop paused workers and ready rows come from green PRs, landings, reports, and preview holds'
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
  assert_equals 'Decisions for the product owner' \
    "$(jq -r '.panels.full_questions[0].title' "$home/state/crew-board.json")" 'question section heading'
  assert_contains "$(jq -r '.panels.full_questions[1].detail' "$home/state/crew-board.json")" \
    'The Android build is waiting.' 'full question text'
  assert_equals 4 "$(jq '.panels.questions | length' "$home/state/crew-board.json")" 'Now page summary count'
  assert_equals 8 "$(jq '.panels.full_backlog | length' "$home/state/crew-board.json")" 'backlog groups and items'
  assert_equals 'Held for the captain' \
    "$(jq -r '.panels.full_backlog[2].title' "$home/state/crew-board.json")" 'captain hold section'
  assert_contains "$(jq -r '.panels.full_backlog[3].title' "$home/state/crew-board.json")" \
    'choose release A or B' 'visible hold reason'
  assert_contains "$(jq -r '.panels.full_backlog[3].detail' "$home/state/crew-board.json")" \
    'Release A is stable; B has the new screen.' 'full backlog note'
  assert_not_contains "$(jq -r '.panels.full_backlog[3].title' "$home/state/crew-board.json")" \
    'beta' 'backlog title leaked its task id'
  assert_equals 'Held (other)' \
    "$(jq -r '.panels.full_backlog[4].title' "$home/state/crew-board.json")" 'other hold section'
  assert_contains "$(jq -r '.panels.full_backlog[5].title' "$home/state/crew-board.json")" \
    'waiting on store review' 'visible non-captain hold reason'
  assert_contains "$(jq -r '.panels.full_backlog[5].detail' "$home/state/crew-board.json")" \
    'Held until: 2026-12-01' 'non-captain hold until-date'
  assert_equals 'Queued' \
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
test_phone_adb_fallbacks
test_phone_check_unavailable
test_bold_question_paragraphs
test_questions_without_headings
test_quota_allowance_snapshot
test_quota_unknown_headroom_and_exhaustion
test_quota_check_unavailable
test_quota_unresolved_limiting_window
test_playbot_lane_projection
test_full_questions_and_backlog
test_phone_testing_and_test_queue
test_daily_routines_from_checks
test_alerts_and_ready_from_real_state
