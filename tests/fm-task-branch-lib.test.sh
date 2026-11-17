#!/usr/bin/env bash
# Tests for bin/fm-task-branch-lib.sh, the owner of a crewmate task's own branch:
# feat/<slug> or fix/<slug> naming, the brief's "Branch contract:" line, and the
# recorded branch= reader with its legacy fm/<task-id> fallback.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-task-branch-lib.sh
. "$ROOT/bin/fm-task-branch-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-branch-lib)

expect_out() {  # <expected> <description> <command...>
  local expected=$1 description=$2 actual
  shift 2
  actual=$("$@" 2>/dev/null) || fail "$description: command failed"
  [ "$actual" = "$expected" ] || fail "$description: expected '$expected', got '$actual'"
}

test_naming_rules() {
  expect_out feat/shop-layout 'feat compose' fm_task_branch_compose feat shop-layout
  expect_out fix/crash-on-load 'fix compose' fm_task_branch_compose fix crash-on-load
  expect_out branch-naming 'fm- prefix removed' fm_task_branch_default_slug fm-branch-naming firstmate
  expect_out crash-on-load 'project prefix removed' fm_task_branch_default_slug FrogPile-Crash_On.Load frogpile
  expect_out fp-x 'unknown prefix kept' fm_task_branch_default_slug fp-x frogpile
  local bad
  for bad in "feature x" "FEAT x" "feat Bad_Name" "feat -x" "feat x-" "feat a--b" "feat a/b" "feat ''"; do
    # shellcheck disable=SC2086  # each fixture is a kind and a slug
    if eval fm_task_branch_compose $bad >/dev/null 2>&1; then
      fail "compose accepted the known-bad input: $bad"
    fi
  done
  pass "feat/ and fix/ names compose from kebab-case slugs, defaults drop fm- and project prefixes, and bad input is refused"
}

test_brief_contract_parse() {
  local brief="$TMP_ROOT/brief.md"
  printf 'Execution contract: workspace=crewmate\nBranch contract: branch=fix/x1\n' > "$brief"
  expect_out fix/x1 'brief contract' fm_task_branch_from_brief "$brief"
  printf 'Execution contract: workspace=crewmate\n' > "$brief"
  expect_out '' 'legacy brief records no contract' fm_task_branch_from_brief "$brief"
  printf 'Branch contract: branch=feat/a\nBranch contract: branch=feat/b\n' > "$brief"
  fm_task_branch_from_brief "$brief" >/dev/null 2>&1 && fail 'two branch contracts were accepted'
  printf 'Branch contract: branch=main\n' > "$brief"
  fm_task_branch_from_brief "$brief" >/dev/null 2>&1 && fail 'a non-task branch contract was accepted'
  pass "the brief's branch contract parses, a legacy brief yields none, and conflicting or foreign values are refused"
}

test_recorded_branch_and_legacy_fallback() {
  local state="$TMP_ROOT/state"
  mkdir -p "$state"
  printf 'kind=ship\nbranch=feat/new-task\n' > "$state/new-task.meta"
  printf 'kind=ship\n' > "$state/old-task.meta"
  # shellcheck disable=SC2016  # the literal command-substitution text is the known-bad fixture
  printf 'kind=ship\nbranch=$(touch x)\n' > "$state/corrupt-task.meta"
  expect_out feat/new-task 'recorded branch' fm_task_branch "$state/new-task.meta" new-task
  expect_out fm/old-task 'legacy fallback' fm_task_branch "$state/old-task.meta" old-task
  expect_out fm/absent 'absent meta fallback' fm_task_branch "$state/absent.meta" absent
  expect_out fm/corrupt-task 'corrupt value is never used' fm_task_branch "$state/corrupt-task.meta" corrupt-task
  expect_out new-task 'branch to task' fm_task_for_branch "$state" feat/new-task
  expect_out old-task 'legacy branch to task' fm_task_for_branch "$state" fm/old-task
  fm_task_for_branch "$state" fix/nobody >/dev/null 2>&1 && fail 'an unowned branch resolved to a task'
  pass "a recorded branch= wins, tasks without one keep fm/<task-id>, and branches map back to their task"
}

test_naming_rules
test_brief_contract_parse
test_recorded_branch_and_legacy_fallback
printf 'all fm-task-branch-lib tests passed\n'
