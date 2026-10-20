#!/usr/bin/env bash
# Behavior tests for the shipped crew board page
# (.agents/skills/bearings/assets/crew-board-template.html), built through a real
# `fm-crew-board.sh refresh` and run under the minimal DOM shim in
# tests/assets/crew-board-render-harness.mjs. Assertions are on what the page
# renders and on the prompt it queues when the captain points at a row, never on
# the template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-crew-board.sh"
HARNESS="$ROOT/tests/assets/crew-board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-crew-board-render)
# The page measures time in phase against the browser clock; the harness pins
# that clock an hour after the logs were written.
STARTED=$(date +%s)
NOW=$((STARTED + 3600))

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

# A home whose workers cover a reported phase, the waiting states, a log written
# before phases existed, a PR-carrying ready worker, and one that has left.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" id
  mkdir -p "$home/state" "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] spin - Make the widget spin (repo: widget) (kind: ship) (since 2026-10-19)
- [ ] gone - Retire the old gadget (repo: gadget) (kind: ship) (since 2026-10-19)

## Queued

## Done
EOF
  for id in spin legacy decide ready pause gone; do
    printf 'kind=ship\nproject=/x/projects/widget\nharness=claude\n' > "$home/state/$id.meta"
  done
  printf 'phase: fixing - two assertions red\n' > "$home/state/spin.status"
  printf 'working: compiling the release build\n' > "$home/state/legacy.status"
  printf 'phase: building\nneeds-decision: REST or RPC?\n' > "$home/state/decide.status"
  printf 'phase: ready-to-merge - https://github.com/o/r/pull/7\ndone: PR https://github.com/o/r/pull/7 checks green\n' > "$home/state/ready.status"
  printf 'paused: waiting for the release window\n' > "$home/state/pause.status"
  printf 'phase: testing - suite </script><b>x\n' > "$home/state/gone.status"
  for id in spin legacy decide ready pause gone; do
    perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$STARTED" "$home/state/$id.status"
  done
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$BOARD" refresh >/dev/null || fail "the first refresh failed"
  rm -f "$home/state/gone.meta" "$home/state/gone.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$BOARD" refresh >/dev/null || fail "the refresh after a worker left failed"
  printf '%s\n' "$home"
}

render() {  # <home> [task] [note]
  node "$HARNESS" "$1/.lavish/crew-board.html" "$NOW" "${@:2}" || fail "the built crew board could not be rendered"
}

row() {  # <render-json> <task> -> row json
  printf '%s' "$1" | jq -c --arg t "$2" '[.sections[] | .group as $g | .rows[] | select(.task == $t) | . + {group: $g}][0]'
}

test_rows_render_grouped_with_phase_labels() {
  local home out
  home=$(make_home grouped)
  out=$(render "$home")
  assert_equals '' "$(printf '%s' "$out" | jq -r '.error')" "the page reported an error"
  assert_equals '["attention","ready","working","paused","gone"]' \
    "$(printf '%s' "$out" | jq -c '[.sections[].group]')" "section order"
  assert_equals '{"group":"working","badge":"Fixing","title":"Make the widget spin","note":"two assertions red","since":"for 1h 00m"}' \
    "$(row "$out" spin | jq -c '{group,badge,title,note,since}')" "a reported phase row"
  assert_equals '{"group":"working","badge":"Working","note":"compiling the release build"}' \
    "$(row "$out" legacy | jq -c '{group,badge,note}')" "a log without phase lines shows its last known state"
  assert_equals '{"group":"attention","badge":"Waiting on a decision","tone":"danger","note":"REST or RPC?"}' \
    "$(row "$out" decide | jq -c '{group,badge,tone,note}')" "a waiting-on-decision row"
  assert_equals '{"group":"ready","badge":"Ready to merge","pr":"https://github.com/o/r/pull/7"}' \
    "$(row "$out" ready | jq -c '{group,badge,pr}')" "a ready-to-merge row"
  assert_equals '{"group":"paused","badge":"Paused"}' "$(row "$out" pause | jq -c '{group,badge}')" "a paused row"
  assert_equals '{"group":"gone","badge":"Left · was Testing","title":"Retire the old gadget","note":"suite </script><b>x"}' \
    "$(row "$out" gone | jq -c '{group,badge,title,note}')" "a left row keeps its last phase and its text intact"
  assert_contains "$(row "$out" gone | jq -r .since)" "left " "a left row says when it left"
  assert_equals '[5,1,1,2]' "$(printf '%s' "$out" | jq -c '[.stats[].n]')" "stat strip counts"
  pass "workers render grouped by what they need, with their own phase, latest note, and time in phase"
}

test_pointing_queues_exactly_the_row_shown() {
  local home out prompt
  home=$(make_home pointing)
  out=$(render "$home" spin "is this the flaky one?")
  assert_equals 1 "$(printf '%s' "$out" | jq '.prompts | length')" "pointing queued no prompt or several"
  prompt=$(printf '%s' "$out" | jq -c '.prompts[0].options | {tag, text, element, queueKey, task: .data.task, phase: .data.phase, comment: .data.comment, note: .data.note}')
  assert_equals '{"tag":"crew-point","text":"spin | Fixing | for 1h 00m | widget | Make the widget spin | latest: two assertions red","element":"spin","queueKey":"crew-point:spin","task":"spin","phase":"fixing","comment":"is this the flaky one?","note":"two assertions red"}' \
    "$prompt" "the queued prompt does not carry the row as shown"
  assert_contains "$(printf '%s' "$out" | jq -r '.prompts[0].prompt')" "Captain's note: is this the flaky one?" \
    "the prompt text lost the captain's note"
  assert_equals 1 "$(printf '%s' "$out" | jq '.sent')" "send did not hand the queued prompt to Lavish"
  assert_equals true "$(printf '%s' "$out" | jq '.sendBar.hidden')" "the send bar stayed up after sending"
  pass "pointing at a row queues one crew-point prompt carrying the row and note, and send delivers it"
}

test_empty_and_broken_boards() {
  local home out
  home="$TMP_ROOT/empty"
  mkdir -p "$home/state" "$home/data"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$BOARD" refresh >/dev/null || fail "an empty home did not build"
  out=$(render "$home")
  assert_contains "$(printf '%s' "$out" | jq -r '.empty[0]')" "No workers are running" "an empty home did not say so"
  sed -i.bak 's/"schema":"fm-crew-board.v1"/"schema":"other"/' "$home/.lavish/crew-board.html"
  out=$(render "$home")
  assert_contains "$(printf '%s' "$out" | jq -r '.error')" "Unsupported crew board data" "a foreign payload rendered"
  pass "an empty home says so and a foreign payload refuses to render"
}

test_rows_render_grouped_with_phase_labels
test_pointing_queues_exactly_the_row_shown
test_empty_and_broken_boards
