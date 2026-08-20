#!/usr/bin/env bash
# Tests for the recorded per-task landing branch:
#   - bin/fm-landing-branch.sh (guarded show/record on an existing task's meta)
#   - bin/fm-spawn.sh --landing-branch flag validation (fail-fast paths only;
#     these refuse before any tmux/treehouse side effect, so no endpoints are
#     created - the same pattern as tests/fm-spawn-batch.test.sh)
# bin/fm-spawn.sh's header owns the landing_branch= field contract, and
# tests/fm-teardown.test.sh proves how bin/fm-teardown.sh consumes it.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

HELPER="$ROOT/bin/fm-landing-branch.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-landing-branch-tests)

# One sandbox per case: a project clone with origin, a worktree, and a state
# dir holding the task meta. Echoes the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  printf '%s\n' "$case_dir"
}

write_meta() {  # <case-dir> <kind>
  local case_dir=$1 kind=$2
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=local-only"
}

run_helper() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" "$HELPER" "$@"
}

run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND=tmux \
    "$SPAWN" "$@" 2>&1
}

test_helper_records_and_shows_landing_branch() {
  local case_dir out
  case_dir=$(make_case record-show)
  write_meta "$case_dir" ship
  git -C "$case_dir/project" branch proto/dev main

  run_helper "$case_dir" task-x1 proto/dev >/dev/null \
    || fail "record-show: helper failed to record an existing local branch"
  out=$(run_helper "$case_dir" task-x1) \
    || fail "record-show: helper show form failed after recording"
  [ "$out" = proto/dev ] || fail "record-show: show printed '$out', expected proto/dev"
  grep -qx 'landing_branch=proto/dev' "$case_dir/state/task-x1.meta" \
    || fail "record-show: meta does not carry the recorded landing_branch line"
  pass "helper records a landing branch on a ship task and shows it back"
}

test_helper_show_without_record_exits_3() {
  local case_dir rc
  case_dir=$(make_case show-absent)
  write_meta "$case_dir" ship

  set +e
  run_helper "$case_dir" task-x1 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "show-absent: expected exit 3 with no recorded branch, got $rc"
  pass "helper show form exits 3 when no landing branch is recorded"
}

test_helper_replaces_existing_value_without_duplicates() {
  local case_dir count
  case_dir=$(make_case replace)
  write_meta "$case_dir" ship
  git -C "$case_dir/project" branch proto/dev main
  git -C "$case_dir/project" branch proto/other main

  run_helper "$case_dir" task-x1 proto/dev >/dev/null \
    || fail "replace: first record failed"
  run_helper "$case_dir" task-x1 proto/other >/dev/null \
    || fail "replace: second record failed"
  count=$(grep -c '^landing_branch=' "$case_dir/state/task-x1.meta")
  [ "$count" -eq 1 ] || fail "replace: expected exactly one landing_branch line, found $count"
  grep -qx 'landing_branch=proto/other' "$case_dir/state/task-x1.meta" \
    || fail "replace: meta does not carry the replacement value"
  pass "helper replaces an existing landing branch without duplicating the line"
}

test_helper_accepts_origin_remote_tracking_branch() {
  local case_dir
  case_dir=$(make_case remote-tracking)
  write_meta "$case_dir" ship
  # The branch exists only as an origin remote-tracking ref, never locally.
  git clone -q "$case_dir/origin.git" "$case_dir/_pusher"
  git -C "$case_dir/_pusher" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "dev tip"
  git -C "$case_dir/_pusher" push -q origin HEAD:refs/heads/proto/dev
  rm -rf "$case_dir/_pusher"
  git -C "$case_dir/project" fetch -q origin

  run_helper "$case_dir" task-x1 proto/dev >/dev/null \
    || fail "remote-tracking: helper refused a branch that resolves as origin remote-tracking"
  pass "helper accepts a landing branch that resolves only as an origin remote-tracking ref"
}

test_helper_refuses_unresolvable_branch() {
  local case_dir rc
  case_dir=$(make_case unresolvable)
  write_meta "$case_dir" ship

  set +e
  run_helper "$case_dir" task-x1 ghost/dev > "$case_dir/out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unresolvable: helper accepted a branch that resolves nowhere"
  grep -q "does not resolve" "$case_dir/out" \
    || fail "unresolvable: error does not explain the resolution failure"
  ! grep -q '^landing_branch=' "$case_dir/state/task-x1.meta" \
    || fail "unresolvable: meta was mutated despite the refusal"
  pass "helper refuses a landing branch that does not resolve in the project clone"
}

test_helper_refuses_invalid_branch_name() {
  local case_dir rc
  case_dir=$(make_case bad-name)
  write_meta "$case_dir" ship

  set +e
  run_helper "$case_dir" task-x1 'bad..name' > "$case_dir/out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "bad-name: helper accepted an invalid git branch name"
  grep -q "not a valid git branch name" "$case_dir/out" \
    || fail "bad-name: error does not name the format failure"
  pass "helper refuses a branch name that fails git check-ref-format"
}

test_helper_refuses_non_ship_task() {
  local case_dir rc
  case_dir=$(make_case non-ship)
  write_meta "$case_dir" scout
  git -C "$case_dir/project" branch proto/dev main

  set +e
  run_helper "$case_dir" task-x1 proto/dev > "$case_dir/out" 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "non-ship: helper accepted a landing branch on a scout task"
  grep -q "applies only to ship tasks" "$case_dir/out" \
    || fail "non-ship: error does not explain the kind refusal"
  pass "helper refuses to record a landing branch on a non-ship task"
}

test_spawn_refuses_landing_branch_on_scout() {
  local out rc
  set +e
  out=$(run_spawn nope-landing-scout-z1 projects/none --scout --landing-branch proto/dev)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "spawn-scout: scout spawn accepted --landing-branch"
  printf '%s\n' "$out" | grep -q 'landing-branch applies only to ship spawns' \
    || fail "spawn-scout: error does not name the ship-only scope: $out"
  pass "fm-spawn refuses --landing-branch on a scout spawn"
}

test_spawn_refuses_landing_branch_on_relaunch() {
  local out rc
  set +e
  out=$(run_spawn nope-landing-relaunch-z2 --relaunch --landing-branch proto/dev)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "spawn-relaunch: relaunch accepted --landing-branch"
  printf '%s\n' "$out" | grep -q 'preserves the task'"'"'s recorded landing branch' \
    || fail "spawn-relaunch: error does not point at the helper path: $out"
  pass "fm-spawn refuses --landing-branch on --relaunch"
}

test_spawn_refuses_invalid_landing_branch_name() {
  local out rc
  set +e
  out=$(run_spawn nope-landing-badname-z3 projects/none --mode local-only --yolo off --landing-branch 'bad..name')
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "spawn-badname: spawn accepted an invalid branch name"
  printf '%s\n' "$out" | grep -q 'not a valid git branch name' \
    || fail "spawn-badname: error does not name the format failure: $out"
  pass "fm-spawn refuses a --landing-branch value that fails git check-ref-format"
}

test_helper_records_and_shows_landing_branch
test_helper_show_without_record_exits_3
test_helper_replaces_existing_value_without_duplicates
test_helper_accepts_origin_remote_tracking_branch
test_helper_refuses_unresolvable_branch
test_helper_refuses_invalid_branch_name
test_helper_refuses_non_ship_task
test_spawn_refuses_landing_branch_on_scout
test_spawn_refuses_landing_branch_on_relaunch
test_spawn_refuses_invalid_landing_branch_name
