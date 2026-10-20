#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-board.sh: rows composed from this home's own
# records only, phase start carried while a phase holds, workers that leave kept
# as such and later expired, a page republished only when a row changes, and the
# open command serving, arming without a keyed-answer binding, printing the
# remote session link, and keeping the board current. The pointed-at-item case
# drives a captured `crew-point` result through the real process-event runner to
# the durable wake queue and reads it back the way firstmate does.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-crew-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A lavish-axi stub in the shapes the shared board library verifies against
# (tests/fm-bearings-board.test.sh owns the liveness edge cases). Its poll blocks
# until `poll-trigger` exists, then returns one queued crew-point prompt in the
# published prompts block shape, the row text and note exactly as the page
# queues them.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data" "$home/lavish-state"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
state=${LAVISH_FAKE_STATE:?}
case "${1-}" in
  --version) printf '0.1.61\n'; exit 0 ;;
  poll)
    limit=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
    while [ ! -e "$state/poll-trigger" ]; do
      [ "$SECONDS" -lt "$limit" ] || exit 75
      sleep 0.05
    done
    rm -f "$state/poll-trigger"
    printf 'session:\n  file: %s\n  status: feedback\n' "$2"
    printf 'prompts[1]{uid,prompt,selector,tag,text}:\n'
    printf '  "1","The captain pointed at worker alpha on the crew board: alpha | Testing | for 5m | widget | Make the widget spin | latest: suite\\nCaptain%ss note: why so slow?",div#cb-row-alpha,crew-point,alpha | Testing | for 5m | widget | Make the widget spin | latest: suite\n' "'"
    exit 0
    ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$state/open" ] || printf '  %s,open,"http://127.0.0.1:4387/session/c0ffee",0\n' "$(cat "$state/open")"
    exit 0
    ;;
  end) : > "$state/open"; exit 0 ;;
esac
real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
printf '%s\n' "$real" > "$state/open"
printf 'session:\n  file: %s\n  url: "http://127.0.0.1:4387/session/c0ffee"\n  status: opened\n' "$real"
SH
  chmod +x "$fakebin/lavish-axi"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] alpha - Make the widget spin (repo: widget) (kind: ship) (since 2026-10-19)

## Queued

## Done
EOF
  printf 'kind=ship\nproject=/x/projects/widget\nharness=claude\n' > "$home/state/alpha.meta"
  printf 'working: setup done\nphase: testing - suite\n' > "$home/state/alpha.status"
  printf 'kind=scout\nproject=/x/projects/gadget\nharness=claude\n' > "$home/state/beta.meta"
  printf 'working: reading the code\n' > "$home/state/beta.status"
  printf '%s\n' "$home"
}

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_FAKE_STATE="$home/lavish-state" FM_CREW_BOARD_INTERVAL=1 FM_CREW_BOARD_FULL_SECS=1 \
    "$BOARD" "$@"
}

rows() { jq -c '[.rows[] | {id, phase, title, project, note, gone}]' "$1/state/crew-board.json"; }
row_field() { jq -r --arg id "$2" --arg f "$3" '.rows[] | select(.id == $id) | .[$f]' "$1/state/crew-board.json"; }
set_mtime() { perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"; }

wait_for() {  # <ticks> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

test_rows_come_from_this_home_only() {
  local home other out
  home=$(make_home own-home)
  other="$TMP_ROOT/other-home"
  mkdir -p "$other/state"
  printf 'kind=ship\nproject=/x/projects/other\n' > "$other/state/foreign.meta"
  printf 'phase: fixing - not ours\n' > "$other/state/foreign.status"
  out=$(run_board "$home" refresh) || fail "refresh failed: $out"
  assert_equals changed "$out" "a first refresh reports a change"
  assert_equals '[{"id":"alpha","phase":"testing","title":"Make the widget spin","project":"widget","note":"suite","gone":false},{"id":"beta","phase":"working","title":"beta","project":"gadget","note":"reading the code","gone":false}]' \
    "$(rows "$home")" "rows"
  assert_present "$home/.lavish/crew-board.html" "the page was not published"
  assert_no_grep foreign "$home/.lavish/crew-board.html" "another home's worker reached the page"
  out=$(run_board "$home" show)
  assert_contains "$out" $'alpha\ttesting\tfor ' "show prints the row the page shows"
  assert_contains "$out" $'Make the widget spin\tsuite' "show prints the title and note"
  pass "rows carry title, project, the worker's own phase and note, from this home's records only"
}

test_phase_start_is_kept_until_the_phase_changes() {
  local home since status
  home=$(make_home phase-since)
  status="$home/state/alpha.status"
  set_mtime 1700000000 "$status"
  run_board "$home" refresh >/dev/null || fail "refresh failed"
  assert_equals 1700000000 "$(row_field "$home" alpha phase_since)" "a newly seen phase starts at its log's time"
  printf 'working: still on the suite\n' >> "$status"
  set_mtime 1700000600 "$status"
  run_board "$home" refresh >/dev/null || fail "refresh failed"
  assert_equals 1700000000 "$(row_field "$home" alpha phase_since)" "an unchanged phase lost its start"
  assert_equals 'still on the suite' "$(row_field "$home" alpha note)" "the latest note did not update"
  printf 'phase: fixing - two red\n' >> "$status"
  set_mtime 1700000900 "$status"
  run_board "$home" refresh >/dev/null || fail "refresh failed"
  since=$(row_field "$home" alpha phase_since)
  assert_equals 1700000900 "$since" "a new phase did not restart the clock"
  pass "time in phase holds while the phase is unchanged and restarts on a new phase"
}

test_unchanged_rows_do_not_republish_the_page() {
  local home page out
  home=$(make_home unchanged)
  run_board "$home" refresh >/dev/null || fail "refresh failed"
  page="$home/.lavish/crew-board.html"
  set_mtime 1700000000 "$page"
  out=$(run_board "$home" refresh) || fail "refresh failed"
  assert_equals unchanged "$out" "an unchanged board reported a change"
  assert_equals 1700000000 "$(perl -e 'print((stat $ARGV[0])[9])' "$page")" "an unchanged board rewrote the page"
  pass "a refresh with no row change leaves the page untouched, so the browser does not reload"
}

test_a_worker_that_leaves_stays_then_expires() {
  local home
  home=$(make_home leaves)
  run_board "$home" refresh >/dev/null || fail "refresh failed"
  rm -f "$home/state/alpha.meta" "$home/state/alpha.status"
  run_board "$home" refresh >/dev/null || fail "refresh failed"
  assert_equals true "$(row_field "$home" alpha gone)" "a cleaned-up worker was not shown as left"
  assert_equals testing "$(row_field "$home" alpha phase)" "a left worker lost its last phase"
  [ "$(row_field "$home" alpha left_at)" -gt 0 ] || fail "a left worker has no time it left"
  assert_contains "$(run_board "$home" show)" $'alpha\tleft(testing)\tleft ' "show did not report the worker as left"
  sleep 2
  FM_CREW_BOARD_GONE_SECS=1 run_board "$home" refresh >/dev/null || fail "refresh failed"
  assert_equals '' "$(row_field "$home" alpha id)" "a left worker outlived its retention"
  pass "a worker whose record disappears is shown as left with its last phase, then expires"
}

test_open_serves_arms_and_keeps_the_board_current() {
  local home out sid
  home=$(make_home open)
  out=$(LAVISH_AXI_ALLOWED_HOSTS='crew.example.ts.net,other.example' run_board "$home" open) \
    || fail "open failed: $out"
  sid=$(PATH="$home/fakebin:$PATH" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$home/.lavish/crew-board.html")
  assert_contains "$out" "board: $home/.lavish/crew-board.html" "open did not name the board"
  assert_contains "$out" "served: $home/.lavish/crew-board.html" "open did not prove the session live"
  assert_contains "$out" "armed: $sid" "open did not arm the board source"
  assert_contains "$out" "url: http://127.0.0.1:4387/session/c0ffee" "open did not print the session url"
  assert_contains "$out" "remote_url: https://crew.example.ts.net/session/c0ffee" "open did not print the remote url"
  assert_contains "$out" "remote_url: https://other.example/session/c0ffee" "open skipped an allowed host"
  assert_contains "$out" "keeper: started" "open did not start the keeper"
  assert_not_contains "$out" "bound:" "the crew board was bound to the keyed-answer intake"
  [ -z "$(ls -A "$home/state/decision-bindings" 2>/dev/null)" ] || fail "the crew board created a decision binding"

  out=$(unset LAVISH_AXI_ALLOWED_HOSTS; run_board "$home" open) || fail "a second open failed: $out"
  assert_contains "$out" "keeper: running" "a second open started a second keeper"
  assert_not_contains "$out" "remote_url:" "an open without allowed hosts printed a remote url"

  printf 'phase: fixing - one red\n' >> "$home/state/alpha.status"
  wait_for 50 grep -sq '"phase":"fixing"' "$home/.lavish/crew-board.html" \
    || fail "the keeper did not republish the page after a phase change"

  out=$(run_board "$home" stop) || fail "stop failed: $out"
  assert_contains "$out" "keeper: stopped" "stop did not stop the keeper"
  assert_absent "$home/state/.crew-board-keeper.lock" "stop left the keeper lock behind"
  pass "open serves and arms the board unbound, prints local and remote links, and its keeper follows phase changes"
}

test_keeper_exits_when_the_session_ends() {
  local home out pid
  home=$(make_home session-ends)
  out=$(run_board "$home" open) || fail "open failed: $out"
  pid=$(cat "$home/state/.crew-board-keeper.lock/pid") || fail "no keeper pid"
  : > "$home/lavish-state/open"
  wait_for 50 eval '! kill -0 '"$pid"' 2>/dev/null' || { kill "$pid" 2>/dev/null; fail "the keeper outlived its ended session"; }
  assert_absent "$home/state/.crew-board-keeper.lock" "an exited keeper left its lock behind"
  pass "the keeper stops on its own once the board's session is no longer open"
}

test_pointed_item_reaches_firstmate_as_a_durable_wake() {
  local home out sid result read_out
  home=$(make_home pointed)
  out=$(run_board "$home" open) || fail "open failed: $out"
  sid=$(PATH="$home/fakebin:$PATH" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$home/.lavish/crew-board.html")
  : > "$home/lavish-state/poll-trigger"
  wait_for 75 grep -sqF "check: procevent lavish $sid 1" "$home/state/.wake-queue" \
    || { run_board "$home" stop >/dev/null; fail "the pointed-at row did not become a durable wake: $(cat "$home/state/.wake-queue" 2>/dev/null)"; }
  run_board "$home" stop >/dev/null
  result="$home/state/procevent-inbox/$sid.1.result"
  assert_present "$result" "the pointed-at row was not captured durably"
  read_out=$("$ROOT/bin/fm-procevent-lavish.sh" read "$result") || fail "the captured result could not be read"
  assert_contains "$read_out" "tag: crew-point" "the read lost the crew-point tag"
  assert_contains "$read_out" "| alpha | Testing | for 5m | widget | Make the widget spin | latest: suite" \
    "the read lost the row exactly as the captain saw it"
  assert_contains "$read_out" "Captain's note: why so slow?" "the read lost the captain's note"
  assert_contains "$read_out" "element_selector: div#cb-row-alpha" "the read lost which row was pointed at"
  assert_equals '' "$("$ROOT/bin/fm-procevent-lavish.sh" answers "$result")" "a pointed row was read as a decision answer"
  pass "a row the captain points at reaches the durable wake queue and reads back exactly as shown"
}

test_rows_come_from_this_home_only
test_phase_start_is_kept_until_the_phase_changes
test_unchanged_rows_do_not_republish_the_page
test_a_worker_that_leaves_stays_then_expires
test_open_serves_arms_and_keeps_the_board_current
test_keeper_exits_when_the_session_ends
test_pointed_item_reaches_firstmate_as_a_durable_wake
