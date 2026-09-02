#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh's landing-target safety contract.
#
# Matrix:
#   (a) a recorded non-default landing branch receives the fast-forward while
#       the default branch remains byte-for-byte untouched
#   (b) absent landing_branch keeps default-branch landing unchanged
#   (c) a recorded landing branch that does not resolve refuses without merging
#   (d) the checkout must be on the resolved landing branch and clean
#   (e) a task branch diverged from the resolved landing branch still refuses
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/home"
  git init -q -b main "$case_dir/project"
  git -C "$case_dir/project" commit -q --allow-empty -m baseline
  printf '%s\n' "$case_dir"
}

write_meta() {
  local case_dir=$1 landing_branch=${2-}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "project=$case_dir/project" \
    "mode=local-only"
  [ -z "$landing_branch" ] \
    || printf 'landing_branch=%s\n' "$landing_branch" >> "$case_dir/state/task-x1.meta"
}

commit_task_change() {
  local case_dir=$1 base=$2
  git -C "$case_dir/project" branch fm/task-x1 "$base"
  git -C "$case_dir/project" worktree add -q "$case_dir/task-wt" fm/task-x1
  printf 'task change\n' > "$case_dir/task-wt/task.txt"
  git -C "$case_dir/task-wt" add task.txt
  git -C "$case_dir/task-wt" commit -q -m 'task change'
}

run_merge() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1
}

test_recorded_nondefault_branch_never_merges_default() {
  local case_dir main_before main_after task_tip
  case_dir=$(make_case recorded-target)
  git -C "$case_dir/project" branch proto/dev main
  commit_task_change "$case_dir" proto/dev
  write_meta "$case_dir" proto/dev
  git -C "$case_dir/project" switch -q proto/dev
  main_before=$(git -C "$case_dir/project" rev-parse refs/heads/main)
  task_tip=$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1)

  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "recorded-target: merge into proto/dev failed"

  [ "$(git -C "$case_dir/project" rev-parse refs/heads/proto/dev)" = "$task_tip" ] \
    || fail "recorded-target: recorded landing branch did not receive the task tip"
  main_after=$(git -C "$case_dir/project" rev-parse refs/heads/main)
  [ "$main_after" = "$main_before" ] \
    || fail "REGRESSION: recorded non-default landing branch changed the default branch"
  assert_grep 'merged fm/task-x1 into local proto/dev' "$case_dir/stdout" \
    "recorded-target: success output did not name the recorded landing branch"
  pass "recorded non-default landing branch is merged and the default branch is untouched"
}

test_absent_landing_branch_keeps_default_behavior() {
  local case_dir task_tip
  case_dir=$(make_case default-target)
  commit_task_change "$case_dir" main
  write_meta "$case_dir"
  task_tip=$(git -C "$case_dir/project" rev-parse refs/heads/fm/task-x1)

  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "default-target: legacy default-branch merge failed"

  [ "$(git -C "$case_dir/project" rev-parse refs/heads/main)" = "$task_tip" ] \
    || fail "default-target: main did not receive the task tip"
  pass "absent landing_branch keeps default-branch fast-forward behavior"
}

test_unresolved_recorded_branch_refuses_without_fallback() {
  local case_dir main_before rc
  case_dir=$(make_case unresolved-target)
  commit_task_change "$case_dir" main
  write_meta "$case_dir" proto/missing
  main_before=$(git -C "$case_dir/project" rev-parse refs/heads/main)

  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unresolved-target: merge should refuse"
  assert_grep 'recorded landing branch proto/missing does not exist' "$case_dir/stderr" \
    "unresolved-target: refusal did not name the missing recorded branch"
  assert_grep 'refusing to fall back to the default branch' "$case_dir/stderr" \
    "unresolved-target: refusal did not make fail-closed behavior explicit"
  [ "$(git -C "$case_dir/project" rev-parse refs/heads/main)" = "$main_before" ] \
    || fail "unresolved-target: default branch changed despite refusal"
  pass "unresolved recorded landing branch refuses without default fallback"
}

test_checkout_and_cleanliness_guard_resolved_target() {
  local case_dir proto_before rc
  case_dir=$(make_case target-preconditions)
  git -C "$case_dir/project" branch proto/dev main
  commit_task_change "$case_dir" proto/dev
  write_meta "$case_dir" proto/dev
  proto_before=$(git -C "$case_dir/project" rev-parse refs/heads/proto/dev)

  set +e
  run_merge "$case_dir" > "$case_dir/wrong-stdout" 2> "$case_dir/wrong-stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "target-preconditions: checkout on main should refuse"
  assert_grep "expected landing branch 'proto/dev'" "$case_dir/wrong-stderr" \
    "target-preconditions: branch guard did not check the resolved landing branch"

  git -C "$case_dir/project" switch -q proto/dev
  printf 'dirty\n' > "$case_dir/project/untracked.txt"
  set +e
  run_merge "$case_dir" > "$case_dir/dirty-stdout" 2> "$case_dir/dirty-stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "target-preconditions: dirty landing checkout should refuse"
  assert_grep 'has a dirty working tree' "$case_dir/dirty-stderr" \
    "target-preconditions: dirty-tree refusal was not clear"
  [ "$(git -C "$case_dir/project" rev-parse refs/heads/proto/dev)" = "$proto_before" ] \
    || fail "target-preconditions: landing branch changed despite precondition refusals"
  pass "branch and clean-tree guards apply to the resolved landing target"
}

test_diverged_landing_branch_still_refuses() {
  local case_dir proto_before rc
  case_dir=$(make_case diverged-target)
  git -C "$case_dir/project" branch proto/dev main
  commit_task_change "$case_dir" proto/dev
  write_meta "$case_dir" proto/dev
  git -C "$case_dir/project" switch -q proto/dev
  git -C "$case_dir/project" commit -q --allow-empty -m 'landing branch diverges'
  proto_before=$(git -C "$case_dir/project" rev-parse refs/heads/proto/dev)

  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "diverged-target: merge should refuse"
  assert_grep 'fm/task-x1 is not a fast-forward of proto/dev' "$case_dir/stderr" \
    "diverged-target: refusal did not name the resolved landing branch"
  [ "$(git -C "$case_dir/project" rev-parse refs/heads/proto/dev)" = "$proto_before" ] \
    || fail "diverged-target: landing branch changed despite divergence refusal"
  pass "diverged task branch still refuses against the resolved landing target"
}

test_recorded_nondefault_branch_never_merges_default
test_absent_landing_branch_keeps_default_behavior
test_unresolved_recorded_branch_refuses_without_fallback
test_checkout_and_cleanliness_guard_resolved_target
test_diverged_landing_branch_still_refuses

printf 'all fm-merge-local tests passed\n'
