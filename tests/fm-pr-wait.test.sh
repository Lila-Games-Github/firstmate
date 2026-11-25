#!/usr/bin/env bash
# PR wait deadline and one-rerun regression against a fake home and forge CLI.
set -eu
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
case_dir=$(mktemp -d)
trap 'rm -rf "$case_dir"' EXIT
mkdir -p "$case_dir/home/state" "$case_dir/bin"
state_dir="$case_dir/home/state"
url=https://github.com/o/r/pull/7
head=0123456789abcdef0123456789abcdef01234567
cat > "$case_dir/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'pr view') cat "$FM_TEST_VIEW" ;;
  'run list') cat "$FM_TEST_RUNS" ;;
  'run view') if [[ "$*" == *'--log-failed'* ]]; then cat "$FM_TEST_LOG"; else cat "$FM_TEST_JOBS"; fi ;;
  'run rerun') printf '%s\n' "$*" >> "$FM_TEST_RERUN" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$case_dir/bin/gh"
export FM_TEST_VIEW="$case_dir/view.json" FM_TEST_RERUN="$case_dir/rerun.log" FM_TEST_RUNS="$case_dir/runs.json" FM_TEST_JOBS="$case_dir/jobs.json" FM_TEST_LOG="$case_dir/log.txt"
export FM_HOME="$case_dir/home" FM_PR_WAIT_BOUND_SECS=1
export PATH="$case_dir/bin:$PATH"
make_view() {
  printf '{"state":"%s","headRefOid":"%s","mergeable":"%s","statusCheckRollup":[%s]}\n' "$1" "$head" "$2" "$3" > "$FM_TEST_VIEW"
}
red='{"__typename":"CheckRun","name":"portable serial shard 2","status":"COMPLETED","conclusion":"FAILURE"}'
green='{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}'
make_view OPEN MERGEABLE "$red"
printf '%s\n' '[{"databaseId":42,"conclusion":"failure","status":"completed"}]' > "$FM_TEST_RUNS"
printf '%s\n' '{"jobs":[{"name":"farm suite","conclusion":"failure"}]}' > "$FM_TEST_JOBS"
printf '%s\n' 'farm suite: runner lost communication' > "$FM_TEST_LOG"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-a "$url" > "$case_dir/out"
[ ! -s "$case_dir/out" ] || fail 'fresh red PR printed a deadline wake'
[ "$(wc -l < "$FM_TEST_RERUN")" -eq 1 ] || fail 'classified infrastructure was not rerun once'
grep -q 'class=infrastructure: run 42 job farm suite' "$state_dir/task-a.status" || fail 'infrastructure status lacks evidence'
# Same-head duplicate cancellation mirrors the PR 100 pair: the later run
# was cancelled while the earlier run was still executing.
printf '%s\n' '[{"databaseId":45632493845,"conclusion":"cancelled","status":"completed"},{"databaseId":45632437567,"conclusion":null,"status":"in_progress"}]' > "$FM_TEST_RUNS"
make_view OPEN MERGEABLE '{"__typename":"CheckRun","name":"farm suite and phone","status":"COMPLETED","conclusion":"CANCELLED"},{"__typename":"CheckRun","name":"PR verdict","status":"COMPLETED","conclusion":"FAILURE"}'
reruns_before=$(wc -l < "$FM_TEST_RERUN")
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-sibling "$url" > "$case_dir/out"
[ "$(wc -l < "$FM_TEST_RERUN")" -eq "$reruns_before" ] || fail 'cancelled duplicate was rerun'
grep -q 'class=sibling:.*45632437567' "$state_dir/task-sibling.status" || fail 'sibling run id missing from status'
# A real test failure must route the first failing line and never rerun.
printf '%s\n' '[{"databaseId":43,"conclusion":"failure","status":"completed"}]' > "$FM_TEST_RUNS"
printf '%s\n' '{"jobs":[{"name":"farm suite","conclusion":"failure"}]}' > "$FM_TEST_JOBS"
printf '%s\n' 'FAIL: tests/player_jump.test.sh expected 2 got 3' > "$FM_TEST_LOG"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-real "$url" > "$case_dir/out"
[ "$(wc -l < "$FM_TEST_RERUN")" -eq "$reruns_before" ] || fail 'real test failure was rerun'
grep -q 'class=genuine:.*tests/player_jump.test.sh expected 2 got 3' "$state_dir/task-real.status" || fail 'first failing test line missing'
# A description rule is also a genuine failure, even when the job is named CI.
printf '%s\n' 'Error: PR description rule failed: missing testing section' > "$FM_TEST_LOG"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-rule "$url" > "$case_dir/out"
[ "$(wc -l < "$FM_TEST_RERUN")" -eq "$reruns_before" ] || fail 'description rule failure was rerun'
grep -q 'class=genuine:.*PR description rule failed: missing testing section' "$state_dir/task-rule.status" || fail 'description rule text missing'
# Unknown evidence also fails closed and names the run and job.
printf '%s\n' 'unrecognized failure output' > "$FM_TEST_LOG"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-unknown "$url" > "$case_dir/out"
[ "$(wc -l < "$FM_TEST_RERUN")" -eq "$reruns_before" ] || fail 'unknown failure was rerun'
grep -q 'class=unknown: run 43 job farm suite' "$state_dir/task-unknown.status" || fail 'unknown status lacks evidence'
# A malformed authoritative run list must be rejected before any rerun.
printf '%s\n' '{"runs":"bad"}' > "$FM_TEST_RUNS"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-bad "$url" > "$case_dir/out"
[ "$(wc -l < "$FM_TEST_RERUN")" -eq "$reruns_before" ] || fail 'malformed run list was rerun'
grep -q 'class=unknown:.*same-head run list unavailable' "$state_dir/task-bad.status" || fail 'malformed run list was not rejected'
printf '%s\n' '[{"databaseId":43,"conclusion":"failure","status":"completed"}]' > "$FM_TEST_RUNS"
printf '%s\n' 'farm suite: runner lost communication' > "$FM_TEST_LOG"
# A later worker working line must not reset the observer's first-red clock.
printf 'working: waiting for CI\n' >> "$state_dir/task-a.status"
awk -F '\t' -v OFS='\t' '{$3=1; print}' "$state_dir/task-a.pr-wait" > "$case_dir/old"
cp "$case_dir/old" "$state_dir/task-a.pr-wait"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-a "$url" > "$case_dir/out"
grep -q 'pr-wait-blocked: blocked: PR https://github.com/o/r/pull/7 waited .*infrastructure: run 43 job farm suite' "$case_dir/out" \
  || fail 'known-bad red PR did not wake past the deadline'
[ "$(wc -l < "$FM_TEST_RERUN")" -eq 1 ] || fail 'red head reran more than once'
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-a "$url" > "$case_dir/out"
[ ! -s "$case_dir/out" ] || fail 'deadline woke twice for the same condition'
make_view OPEN MERGEABLE "$green"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-b "$url" > "$case_dir/out"
[ ! -s "$case_dir/out" ] || fail 'fresh green PR woke'
# A green PR that remains open past the bound also emits its own notice.
awk -F '\t' -v OFS='\t' '{$3=1; print}' "$state_dir/task-b.pr-wait" > "$case_dir/old"
cp "$case_dir/old" "$state_dir/task-b.pr-wait"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-b "$url" > "$case_dir/out"
grep -q 'green but unmerged' "$case_dir/out" || fail 'green unmerged PR missed the deadline'
make_view OPEN CONFLICTING "$green"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-d "$url" > "$case_dir/out"
awk -F '\t' -v OFS='\t' '{$3=1; print}' "$state_dir/task-d.pr-wait" > "$case_dir/old"
cp "$case_dir/old" "$state_dir/task-d.pr-wait"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-d "$url" > "$case_dir/out"
grep -q 'merge-conflict' "$case_dir/out" || fail 'conflicted PR missed the deadline'
make_view MERGED MERGEABLE "$green"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-c "$url" > "$case_dir/out"
[ ! -s "$case_dir/out" ] && [ ! -e "$state_dir/task-c.pr-wait" ] || fail 'merged PR woke or retained wait state'
# A conflict becoming red is one continuous blocked wait on the same head.
make_view OPEN CONFLICTING "$green"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-g "$url" > "$case_dir/out"
awk -F '\t' -v OFS='\t' '{$3=1; print}' "$state_dir/task-g.pr-wait" > "$case_dir/old"
cp "$case_dir/old" "$state_dir/task-g.pr-wait"
make_view OPEN MERGEABLE "$red"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-g "$url" > "$case_dir/out"
grep -q 'infrastructure: run 43 job farm suite' "$case_dir/out" \
  || fail 'conflict-to-red transition reset the blocked wait clock'
# A newer green run supersedes an older failure of the same check name.
old_failed='{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-11-13T19:52:00Z"}'
new_green='{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-11-13T19:53:00Z"}'
make_view OPEN MERGEABLE "$old_failed,$new_green"
reruns_before=$(wc -l < "$FM_TEST_RERUN")
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-f "$url" > "$case_dir/out"
[ ! -s "$case_dir/out" ] && [ "$(wc -l < "$FM_TEST_RERUN")" -eq "$reruns_before" ] \
  || fail 'superseded failure was treated as red'
# A secondmate's deadline reaches the existing parent reply channel.
printf 'mate-a\n' > "$case_dir/home/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$case_dir/home/.fm-secondmate-parent"
make_view OPEN MERGEABLE "$red"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-e "$url" > "$case_dir/out"
awk -F '\t' -v OFS='\t' '{$3=1; print}' "$state_dir/task-e.pr-wait" > "$case_dir/old"
cp "$case_dir/old" "$state_dir/task-e.pr-wait"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-e "$url" > "$case_dir/out"
grep -q 'blocked: PR https://github.com/o/r/pull/7' "$state_dir/parent-replies.status" \
  || fail 'secondmate deadline did not reach the parent channel'
printf 'ok - four classes, red deadline, one rerun, green and merged silence, parent delivery\n'
