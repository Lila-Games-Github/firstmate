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
#   (f) a lane lands the branch checked out in its recorded worktree
#   (g) a detached or unrelated lane worktree refuses without guessing fm/<id>
#   (h) a lane task whose identity never recorded a delivery mode refuses
#   (i) a recorded lane branch takes precedence over the live worktree branch
#   (j) a recorded lane branch lands after Playbot retires the worktree
#   (k) landing a queued car steers its sleeping successor to the front once,
#       and a landing without a train creates no queue state
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  # Mirror a real firstmate home, which always has data/. The captain-hold
  # reader that guards the local-merge path reports a home whose data directory
  # cannot be resolved as indeterminate rather than as "no captain calls
  # recorded", so a data/-less fixture home refuses the merge once
  # bin/fm-merge-local.sh carries that gate from upstream.
  mkdir -p "$case_dir/state" "$case_dir/home" "$case_dir/home/data"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$case_dir/home/data/backlog.md"
  git init -q -b main "$case_dir/project"
  git -C "$case_dir/project" commit -q --allow-empty -m baseline
  printf '%s\n' "$case_dir"
}

write_meta() {
  local case_dir=$1 landing_branch=${2-} mode=${3-}
  local fields=("project=$case_dir/project")
  [ -z "$mode" ] || fields+=("mode=$mode")
  fm_write_meta "$case_dir/state/task-x1.meta" "${fields[@]}"
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
  local case_dir=$1 branch sha receipt
  branch=$(sed -n 's/^lane_branch=//p' "$case_dir/state/task-x1.meta" | tail -1)
  if [ -z "$branch" ] && grep -q '^kind=lane$' "$case_dir/state/task-x1.meta"; then
    branch=$(sed -n 's/^worktree=//p' "$case_dir/state/task-x1.meta" | tail -1)
    branch=$(git -C "$branch" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  fi
  [ -n "$branch" ] || branch=fm/task-x1
  sha=$(git -C "$case_dir/project" rev-parse "refs/heads/$branch" 2>/dev/null || git -C "$case_dir/project" rev-parse HEAD)
  receipt="$case_dir/receipt.txt"
  printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$sha" > "$receipt"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1 --receipt "$receipt"
}

write_receipt() { # <path> <sha> [failure...]
  local path=$1 sha=$2 count
  shift 2
  count=$#
  printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=%s\n' "$sha" "$count" > "$path"
  for failure in "$@"; do printf 'failure=%s\n' "$failure" >> "$path"; done
}

run_merge_with_receipts() { # <case-dir> <candidate> [base]
  local case_dir=$1 candidate=$2
  shift 2
  if [ "$#" -gt 0 ]; then
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
      "$MERGE_LOCAL" task-x1 --receipt "$candidate" --base-receipt "$1"
  else
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
      "$MERGE_LOCAL" task-x1 --receipt "$candidate"
  fi
}

test_known_red_lands_and_opens_one_green_task() {
  local case_dir base candidate base_sha task_sha task_count green_id green_state
  case_dir=$(make_case known-red)
  commit_task_change "$case_dir" main
  write_meta "$case_dir" "" local-only
  base_sha=$(git -C "$case_dir/project" rev-parse main)
  task_sha=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  base="$case_dir/base.receipt"
  candidate="$case_dir/candidate.receipt"
  write_receipt "$base" "$base_sha" test.animation test.catalog
  write_receipt "$candidate" "$task_sha" test.animation
  run_merge_with_receipts "$case_dir" "$candidate" "$base" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "known-red merge refused: $(cat "$case_dir/stderr")"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$task_sha" ] || fail 'known-red candidate did not land'
  assert_grep 'make-it-green task green-' "$case_dir/stdout" 'red landing did not report the repair task'
  task_count=$(grep -c 'Make main green' "$case_dir/home/data/backlog.md")
  [ "$task_count" -eq 1 ] || fail "expected one make-it-green task, found $task_count"
  green_id=$(sed -n 's/.*make-it-green task \(green-[0-9a-f]*\) is open.*/\1/p' "$case_dir/stdout")
  [ -n "$green_id" ] || fail 'red landing did not name its repair task id'
  tasks-axi 'done' "$green_id" --file "$case_dir/home/data/backlog.md" >/dev/null \
    || fail 'could not close the make-it-green fixture task'
  printf 'followup\n' > "$case_dir/task-wt/followup.txt"
  git -C "$case_dir/task-wt" add followup.txt
  git -C "$case_dir/task-wt" commit -qm followup
  task_sha=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  write_receipt "$candidate" "$task_sha" test.animation
  run_merge_with_receipts "$case_dir" "$candidate" > "$case_dir/again.out" 2> "$case_dir/again.err" \
    || fail "second known-red merge refused: $(cat "$case_dir/again.err")"
  task_count=$(grep -c 'Make main green' "$case_dir/home/data/backlog.md")
  [ "$task_count" -eq 1 ] || fail "second red landing duplicated the repair task ($task_count)"
  green_state=$(tasks-axi show "$green_id" --file "$case_dir/home/data/backlog.md" | sed -n 's/^  state: *//p')
  [ "$green_state" = queued ] || fail "second red landing left the repair task in $green_state"
  pass 'known-red work lands and creates or reopens exactly one make-it-green task'
}

test_new_failure_refused() {
  local case_dir base candidate base_sha task_sha rc
  case_dir=$(make_case new-failure)
  commit_task_change "$case_dir" main
  write_meta "$case_dir" "" local-only
  base_sha=$(git -C "$case_dir/project" rev-parse main)
  task_sha=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  base="$case_dir/base.receipt"
  candidate="$case_dir/candidate.receipt"
  write_receipt "$base" "$base_sha" test.old
  write_receipt "$candidate" "$task_sha" test.old test.new
  set +e
  run_merge_with_receipts "$case_dir" "$candidate" "$base" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" 'new failure must refuse'
  assert_grep 'test.new' "$case_dir/stderr" 'new failure was not named'
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base_sha" ] || fail 'new failure moved main'
  pass 'candidate with a new failure refuses without moving the landing tip'
}

test_receipt_missing_or_wrong_sha_refused() {
  local case_dir base_sha task_sha rc
  case_dir=$(make_case receipt-refusal)
  commit_task_change "$case_dir" main
  write_meta "$case_dir" "" local-only
  base_sha=$(git -C "$case_dir/project" rev-parse main)
  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-x1 > "$case_dir/missing.out" 2> "$case_dir/missing.err"
  rc=$?
  set -e
  expect_code 2 "$rc" 'missing receipt must refuse'
  write_receipt "$case_dir/wrong.receipt" "$base_sha"
  set +e
  run_merge_with_receipts "$case_dir" "$case_dir/wrong.receipt" > "$case_dir/wrong.out" 2> "$case_dir/wrong.err"
  rc=$?
  set -e
  expect_code 1 "$rc" 'mismatched SHA must refuse'
  assert_grep 'does not name exact commit' "$case_dir/wrong.err" 'wrong-SHA refusal was unclear'
  task_sha=$(git -C "$case_dir/project" rev-parse fm/task-x1)
  write_receipt "$case_dir/false-green.receipt" "$task_sha"
  printf 'failure=hidden.failure\n' >> "$case_dir/false-green.receipt"
  set +e
  run_merge_with_receipts "$case_dir" "$case_dir/false-green.receipt" > "$case_dir/false.out" 2> "$case_dir/false.err"
  rc=$?
  set -e
  expect_code 1 "$rc" 'a zero count with a failure line must refuse'
  assert_grep 'count does not match' "$case_dir/false.err" 'false-green receipt was not refused'
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$base_sha" ] || fail 'receipt refusal moved main'
  pass 'missing and mismatched-SHA receipts refuse'
}

test_recorded_nondefault_branch_never_merges_default() {
  local case_dir main_before main_after task_tip
  case_dir=$(make_case recorded-target)
  git -C "$case_dir/project" branch proto/dev main
  commit_task_change "$case_dir" proto/dev
  write_meta "$case_dir" proto/dev local-only
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
  write_meta "$case_dir" "" local-only
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
  write_meta "$case_dir" proto/missing local-only
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
  write_meta "$case_dir" proto/dev local-only
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
  write_meta "$case_dir" proto/dev local-only
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

test_lane_uses_recorded_worktree_branch() {
  local case_dir lane_tip
  case_dir=$(make_case lane-branch)
  git -C "$case_dir/project" branch playbot/descriptive main
  git -C "$case_dir/project" worktree add -q "$case_dir/lane-wt" playbot/descriptive
  printf 'lane change\n' > "$case_dir/lane-wt/lane.txt"
  git -C "$case_dir/lane-wt" add lane.txt
  git -C "$case_dir/lane-wt" commit -q -m 'lane change'
  write_meta "$case_dir" "" local-only
  printf 'kind=lane\nworktree=%s\n' "$case_dir/lane-wt" >> "$case_dir/state/task-x1.meta"
  lane_tip=$(git -C "$case_dir/project" rev-parse refs/heads/playbot/descriptive)

  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "lane-branch: merge of worktree branch failed"

  [ "$(git -C "$case_dir/project" rev-parse refs/heads/main)" = "$lane_tip" ] \
    || fail "lane-branch: main did not receive the lane tip"
  assert_grep 'merged playbot/descriptive into local main' "$case_dir/stdout" \
    "lane-branch: success output did not name the lane branch"
  pass "lane task lands the branch checked out in its recorded worktree"
}

test_lane_prefers_recorded_branch() {
  local case_dir recorded_tip
  case_dir=$(make_case lane-recorded-branch)
  git -C "$case_dir/project" branch playbot/recorded main
  git -C "$case_dir/project" worktree add -q "$case_dir/recorded-wt" playbot/recorded
  printf 'recorded change\n' > "$case_dir/recorded-wt/recorded.txt"
  git -C "$case_dir/recorded-wt" add recorded.txt
  git -C "$case_dir/recorded-wt" commit -q -m 'recorded change'
  git -C "$case_dir/project" branch playbot/live main
  git -C "$case_dir/project" worktree add -q "$case_dir/live-wt" playbot/live
  write_meta "$case_dir" "" local-only
  printf 'kind=lane\nworktree=%s\nlane_branch=playbot/recorded\n' "$case_dir/live-wt" >> "$case_dir/state/task-x1.meta"
  recorded_tip=$(git -C "$case_dir/project" rev-parse refs/heads/playbot/recorded)

  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "lane-recorded-branch: merge of recorded branch failed"

  [ "$(git -C "$case_dir/project" rev-parse refs/heads/main)" = "$recorded_tip" ] \
    || fail "lane-recorded-branch: main did not receive the recorded branch tip"
  assert_grep 'merged playbot/recorded into local main' "$case_dir/stdout" \
    "lane-recorded-branch: success output did not name the recorded branch"
  pass "recorded lane branch takes precedence over the live worktree branch"
}

test_lane_recorded_branch_survives_retired_worktree() {
  local case_dir lane_tip
  case_dir=$(make_case lane-retired-worktree)
  git -C "$case_dir/project" branch playbot/retired main
  git -C "$case_dir/project" worktree add -q "$case_dir/lane-wt" playbot/retired
  printf 'lane change\n' > "$case_dir/lane-wt/lane.txt"
  git -C "$case_dir/lane-wt" add lane.txt
  git -C "$case_dir/lane-wt" commit -q -m 'lane change'
  lane_tip=$(git -C "$case_dir/project" rev-parse refs/heads/playbot/retired)
  git -C "$case_dir/project" worktree remove "$case_dir/lane-wt"
  [ ! -e "$case_dir/lane-wt" ] || fail "lane-retired-worktree: fixture worktree still exists"
  write_meta "$case_dir" "" local-only
  printf 'kind=lane\nworktree=%s\nlane_branch=playbot/retired\n' "$case_dir/lane-wt" >> "$case_dir/state/task-x1.meta"

  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "lane-retired-worktree: merge after worktree retirement failed"

  [ "$(git -C "$case_dir/project" rev-parse refs/heads/main)" = "$lane_tip" ] \
    || fail "lane-retired-worktree: main did not receive the retired lane tip"
  pass "recorded lane branch lands after the worktree is retired"
}

test_lane_without_recorded_mode_refuses() {
  local case_dir main_before rc
  case_dir=$(make_case lane-no-mode)
  git -C "$case_dir/project" branch playbot/unmoded main
  git -C "$case_dir/project" worktree add -q "$case_dir/lane-wt" playbot/unmoded
  printf 'lane change\n' > "$case_dir/lane-wt/lane.txt"
  git -C "$case_dir/lane-wt" add lane.txt
  git -C "$case_dir/lane-wt" commit -q -m 'lane change'
  write_meta "$case_dir"
  printf 'kind=lane\nworktree=%s\n' "$case_dir/lane-wt" >> "$case_dir/state/task-x1.meta"
  main_before=$(git -C "$case_dir/project" rev-parse refs/heads/main)

  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lane-no-mode: merge should refuse"
  assert_grep 'is mode=, not local-only' "$case_dir/stderr" \
    "lane-no-mode: refusal did not name the missing recorded mode"
  [ "$(git -C "$case_dir/project" rev-parse refs/heads/main)" = "$main_before" ] \
    || fail "lane-no-mode: main changed despite refusal"
  pass "a lane task whose identity never recorded a delivery mode refuses instead of guessing local-only"
}

test_lane_detached_worktree_refuses() {
  local case_dir main_before rc
  case_dir=$(make_case lane-detached)
  commit_task_change "$case_dir" main
  git -C "$case_dir/task-wt" switch -q --detach
  write_meta "$case_dir" "" local-only
  printf 'kind=lane\nworktree=%s\n' "$case_dir/task-wt" >> "$case_dir/state/task-x1.meta"
  main_before=$(git -C "$case_dir/project" rev-parse refs/heads/main)

  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lane-detached: merge should refuse"
  assert_grep "lane task task-x1 worktree $case_dir/task-wt has no checked-out branch" "$case_dir/stderr" \
    "lane-detached: refusal did not identify the task and worktree"
  [ "$(git -C "$case_dir/project" rev-parse refs/heads/main)" = "$main_before" ] \
    || fail "lane-detached: main changed despite refusal"
  pass "detached lane worktree refuses without falling back to fm/task-x1"
}

test_lane_branch_missing_from_project_refuses() {
  local case_dir main_before rc
  case_dir=$(make_case lane-missing-branch)
  git init -q -b other "$case_dir/unrelated"
  git -C "$case_dir/unrelated" commit -q --allow-empty -m unrelated
  git -C "$case_dir/unrelated" worktree add -q -b playbot/unrelated "$case_dir/unrelated-wt"
  write_meta "$case_dir" "" local-only
  printf 'kind=lane\nworktree=%s\n' "$case_dir/unrelated-wt" >> "$case_dir/state/task-x1.meta"
  main_before=$(git -C "$case_dir/project" rev-parse refs/heads/main)

  set +e
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lane-missing-branch: merge should refuse"
  assert_grep "lane task task-x1 worktree $case_dir/unrelated-wt branch playbot/unrelated does not exist" "$case_dir/stderr" \
    "lane-missing-branch: refusal did not identify the task, worktree, and branch"
  [ "$(git -C "$case_dir/project" rev-parse refs/heads/main)" = "$main_before" ] \
    || fail "lane-missing-branch: main changed despite refusal"
  pass "lane worktree branch missing from project refuses"
}

test_landing_steers_next_queue_car() {
  local case_dir queue_env
  case_dir=$(make_case queue-hook)
  commit_task_change "$case_dir" main
  write_meta "$case_dir" "" local-only
  git -C "$case_dir/project" worktree add -qb fm/task-y2 "$case_dir/next-wt" fm/task-x1
  git -C "$case_dir/next-wt" commit -q --allow-empty -m 'next change'
  fm_write_meta "$case_dir/state/task-y2.meta" 'window=sess:fm-notify' 'kind=ship' 'harness=claude'
  mkdir -p "$case_dir/bin"
  cat > "$case_dir/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$1" in
  display-message) echo fakepane ;;
  list-windows) echo fm-notify ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  send-keys) exit 1 ;;
esac
TMUX
  chmod +x "$case_dir/bin/tmux"
  queue_env=(env PATH="$case_dir/bin:$PATH" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state")
  "${queue_env[@]}" "$ROOT/bin/fm-landing-queue.sh" ready task-x1 --project "$case_dir/project" \
    --branch fm/task-x1 --head "$(git -C "$case_dir/project" rev-parse fm/task-x1)" >/dev/null \
    || fail 'queue-hook: first car could not join'
  "${queue_env[@]}" "$ROOT/bin/fm-landing-queue.sh" ready task-y2 --project "$case_dir/project" \
    --branch fm/task-y2 --head "$(git -C "$case_dir/project" rev-parse fm/task-y2)" >/dev/null \
    || fail 'queue-hook: second car could not join'
  [ ! -e "$case_dir/state/task-y2.inbox" ] || fail 'queue-hook: waiting car was steered before landing'

  PATH="$case_dir/bin:$PATH" run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "queue-hook: merge failed: $(cat "$case_dir/stderr")"

  [ "$(find "$case_dir/state/task-y2.inbox" -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail 'queue-hook: landing did not steer the next car exactly once'
  grep -q 'task=task-y2 is now bottom (place=1)' "$case_dir/state/task-y2.inbox/"*.msg \
    || fail 'queue-hook: front steer did not name the next car'
  ! grep -q 'not reconciled' "$case_dir/stderr" || fail 'queue-hook: reconcile failed after landing'
  pass 'landing a queued car steers its sleeping successor to the front once'
}

test_landing_without_train_creates_no_queue() {
  local case_dir
  case_dir=$(make_case no-train)
  commit_task_change "$case_dir" main
  write_meta "$case_dir" "" local-only
  run_merge "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || fail 'no-train: merge failed'
  [ ! -e "$case_dir/home/data/landing-queue" ] || fail 'no-train: landing created queue state'
  ! grep -q 'not reconciled' "$case_dir/stderr" || fail "no-train: reconcile warned: $(cat "$case_dir/stderr")"
  pass 'a landing without a train creates no queue state'
}

test_recorded_nondefault_branch_never_merges_default
test_absent_landing_branch_keeps_default_behavior
test_unresolved_recorded_branch_refuses_without_fallback
test_checkout_and_cleanliness_guard_resolved_target
test_diverged_landing_branch_still_refuses
test_lane_uses_recorded_worktree_branch
test_lane_prefers_recorded_branch
test_lane_recorded_branch_survives_retired_worktree
test_lane_without_recorded_mode_refuses
test_lane_detached_worktree_refuses
test_lane_branch_missing_from_project_refuses
test_known_red_lands_and_opens_one_green_task
test_new_failure_refused
test_receipt_missing_or_wrong_sha_refused
test_landing_steers_next_queue_car
test_landing_without_train_creates_no_queue

printf 'all fm-merge-local tests passed\n'
