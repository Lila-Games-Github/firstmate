#!/usr/bin/env bash
# tests/fm-classify-phase.test.sh - the self-reported phase vocabulary and fold
# in bin/fm-classify-lib.sh: which lines are phase lines, how a whole status log
# folds into the phase the crew board shows, and which appended spans the
# watcher may absorb as phase-only. Driven through the library's sourced entry
# points, as tests/fm-watch-triage.test.sh does; the watcher's use of the span
# predicate is covered there.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-phase-tests)

# Fold <lines> written as a status log and print "<phase>|<note>".
fold() {  # <kind> <lines>
  local f
  f="$TMP_ROOT/log.$RANDOM.status"
  printf '%s' "$2" > "$f"
  status_current_phase "$f" "$1" | tr '\t' '|'
}

test_phase_line_parsing() {
  local got
  got=$(status_line_phase 'phase: testing - running the focused suite') || fail "a known phase line was not read"
  assert_equals testing "$got" "phase word"
  status_line_phase 'phase: ready-to-merge' got || fail "a bare known phase line was not read"
  assert_equals ready-to-merge "$got" "phase word into an out-var"
  assert_equals 'running the focused suite' "$(status_line_phase_note 'phase: testing - running the focused suite')" "dash-separated note"
  assert_equals 'one assertion red' "$(status_line_phase_note 'phase: fixing: one assertion red')" "colon-separated note"
  assert_equals '' "$(status_line_phase_note 'phase: building')" "bare phase has no note"
  for got in 'phase: blocked - stuck' 'phase: done' 'phase:' 'working: testing the fix' 'phases: testing'; do
    if status_line_phase "$got" >/dev/null; then
      fail "a line outside the phase vocabulary was read as a phase: $got"
    fi
  done
  pass "only a phase line naming a vocabulary phase is read as one, with its note"
}

test_fold_follows_reported_phases_and_waking_states() {
  assert_equals 'starting|' "$(status_current_phase "$TMP_ROOT/absent.status" ship | tr '\t' '|')" "absent log"
  assert_equals 'working|setup done' "$(fold ship $'working: setup done\n')" \
    "a log without phase lines shows its last known state"
  assert_equals 'testing|running suite' \
    "$(fold ship $'working: setup done\nphase: building - page\nphase: testing - running suite\n')" \
    "latest reported phase"
  assert_equals 'testing|still going' \
    "$(fold ship $'phase: testing - suite\nworking: still going\n')" \
    "a working line keeps the reported phase"
  assert_equals 'paused|waiting for CI window' \
    "$(fold ship $'phase: validating\npaused: waiting for CI window\n')" "paused"
  assert_equals 'validating|window opened' \
    "$(fold ship $'phase: validating\npaused: waiting for CI window\nresolved: window opened\n')" \
    "resolved returns to the reported phase"
  assert_equals 'failed|suite crashed' "$(fold ship $'phase: testing\nfailed: suite crashed\n')" "failed"
  assert_equals 'done|ready in branch' "$(fold ship $'phase: testing\ndone: ready in branch\n')" "done"
  assert_equals 'ready-to-merge|PR https://example.test/pull/1 checks green' \
    "$(fold ship $'phase: ready-to-merge - https://example.test/pull/1\ndone: PR https://example.test/pull/1 checks green\n')" \
    "done confirms ready-to-merge"
  assert_equals 'needs-decision|board owner' "$(fold ship $'phase: fixing\ncaptain-held: board owner\n')" \
    "captain-held shows as waiting on a decision"
  pass "the fold shows the worker's own phase, the waiting states as themselves, and older logs' last state"
}

test_open_decision_outranks_later_phases() {
  assert_equals 'needs-decision|pick A or B' \
    "$(fold ship $'phase: fixing\nneeds-decision [key=a]: pick A or B\nphase: testing - kept going\n')" \
    "an open decision outranks a later phase line"
  assert_equals 'testing|kept going' \
    "$(fold ship $'needs-decision [key=a]: pick A or B\nresolved [key=a]: A\nphase: testing - kept going\n')" \
    "a resolved decision no longer outranks"
  assert_equals 'blocked|daemon down' "$(fold ship $'phase: validating\nblocked: daemon down\n')" "blocked"
  pass "a decision or blocker still open in the keyed fold outranks later phase lines"
}

test_span_phase_only() {
  local f size first
  f="$TMP_ROOT/span.status"
  printf 'working: setup\n' > "$f"
  first=$(LC_ALL=C wc -c < "$f" | tr -d ' ')
  printf 'phase: building - x\n\nphase: testing\n' >> "$f"
  size=$(LC_ALL=C wc -c < "$f" | tr -d ' ')
  status_span_phase_only "$f" "$first" "$size" || fail "a span of phase lines was not phase-only"
  if status_span_phase_only "$f" 0 "$size"; then fail "a span including a working line read as phase-only"; fi
  if status_span_phase_only "$f" "$size" "$size"; then fail "an empty span read as phase-only"; fi
  printf 'phase: blocked - stuck\n' >> "$f"
  if status_span_phase_only "$f" "$size" "$(LC_ALL=C wc -c < "$f" | tr -d ' ')"; then
    fail "an unknown phase word read as phase-only"
  fi
  if status_span_phase_only "$TMP_ROOT/missing.status" 0 10; then fail "a missing log read as phase-only"; fi
  pass "only a non-empty span made entirely of vocabulary phase lines is phase-only"
}

test_phase_lines_are_not_events() {
  local f
  f="$TMP_ROOT/events.status"
  printf 'needs-decision: pick A or B\nphase: testing - kept going\n' > "$f"
  assert_equals 'needs-decision: pick A or B' "$(last_status_line "$f")" "a phase line became the latest event"
  if status_is_captain_relevant 'phase: ready-to-merge - https://example.test/pull/1 checks green'; then
    fail "a phase line read as captain-relevant"
  fi
  pass "a phase line is neither the latest event nor captain-relevant"
}

test_phase_line_parsing
test_fold_follows_reported_phases_and_waking_states
test_open_decision_outranks_later_phases
test_span_phase_only
test_phase_lines_are_not_events
