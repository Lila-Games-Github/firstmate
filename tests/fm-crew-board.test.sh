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
  assert_equals 0 "$(jq -r '.exit' <<< "$result")" "TUI exit"
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
  assert_equals true "$(jq -r '.workers and .feed and .counts and .input' <<< "$result")" \
    "stacked panels did not retain counts and input"
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
  assert_equals 'S22' "$(jq -r '.panels.phones[0].title' "$home/state/crew-board.json")" "phone cache"
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

test_rows_and_phase_time
test_refresh_and_gone
test_tui_render_and_note
test_narrow_terminal
test_note_without_selection_and_point_without_text
test_panel_projection_and_launcher
