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
  'pr diff') printf '%s\n' 'docs/unrelated.md' ;;
  'run list') printf '%s\n' '[{"databaseId":42,"conclusion":"failure"}]' ;;
  'run rerun') printf '%s\n' "$*" >> "$FM_TEST_RERUN" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$case_dir/bin/gh"
export FM_TEST_VIEW="$case_dir/view.json" FM_TEST_RERUN="$case_dir/rerun.log"
export FM_HOME="$case_dir/home" FM_PR_WAIT_BOUND_SECS=1
export PATH="$case_dir/bin:$PATH"
make_view() {
  printf '{"state":"%s","headRefOid":"%s","mergeable":"%s","statusCheckRollup":[%s]}\n' "$1" "$head" "$2" "$3" > "$FM_TEST_VIEW"
}
red='{"__typename":"CheckRun","name":"portable serial shard 2","status":"COMPLETED","conclusion":"FAILURE"}'
green='{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}'
make_view OPEN MERGEABLE "$red"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-a "$url" > "$case_dir/out"
[ ! -s "$case_dir/out" ] || fail 'fresh red PR woke before the deadline'
[ "$(wc -l < "$FM_TEST_RERUN")" -eq 1 ] || fail 'failed run was not rerun once'
# A later worker working line must not reset the observer's first-red clock.
printf 'working: waiting for CI\n' >> "$state_dir/task-a.status"
awk -F '\t' -v OFS='\t' '{$3=1; print}' "$state_dir/task-a.pr-wait" > "$case_dir/old"
cp "$case_dir/old" "$state_dir/task-a.pr-wait"
"$ROOT/bin/fm-pr-wait.sh" "$state_dir" task-a "$url" > "$case_dir/out"
grep -q 'pr-wait-blocked: blocked: PR https://github.com/o/r/pull/7 waited .*failing check: portable serial shard 2' "$case_dir/out" \
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
printf 'ok - red deadline, working-line independence, one rerun, green and merged silence, parent delivery\n'
