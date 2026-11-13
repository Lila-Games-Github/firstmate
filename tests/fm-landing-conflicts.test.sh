#!/usr/bin/env bash
# Isolated integration tests for post-landing trial merges and notification.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-landing-conflicts-tests)
PROJECT="$TMP_ROOT/project"
OTHER="$TMP_ROOT/other"
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE"
git init -q -b main "$PROJECT"
git -C "$PROJECT" config user.email fmtest@example.invalid
git -C "$PROJECT" config user.name fmtest
printf 'base\n' > "$PROJECT/code.txt"
git -C "$PROJECT" add code.txt
git -C "$PROJECT" commit -qm base
git -C "$PROJECT" branch fm/conflict
git -C "$PROJECT" branch fm/clean
git -C "$PROJECT" branch fm/missing
git -C "$PROJECT" branch fm/alternate
git -C "$PROJECT" branch proto/dev
git -C "$PROJECT" worktree add -q "$TMP_ROOT/conflict-wt" fm/conflict
git -C "$PROJECT" worktree add -q "$TMP_ROOT/clean-wt" fm/clean
printf 'worker\n' > "$TMP_ROOT/conflict-wt/code.txt"
git -C "$TMP_ROOT/conflict-wt" commit -qam 'worker edit'
printf 'new\n' > "$TMP_ROOT/clean-wt/test.txt"
git -C "$TMP_ROOT/clean-wt" add test.txt
git -C "$TMP_ROOT/clean-wt" commit -qm 'clean edit'
printf 'landed\n' > "$PROJECT/code.txt"
git -C "$PROJECT" commit -qam 'landed edit'
git -C "$PROJECT" branch -D fm/missing >/dev/null
git init -q -b main "$OTHER"
for id in conflict clean missing alternate; do
  printf 'project=%s\nkind=ship\n' "$PROJECT" > "$STATE/$id.meta"
done
printf 'landing_branch=proto/dev\n' >> "$STATE/alternate.meta"
printf 'project=%s\nkind=ship\n' "$OTHER" > "$STATE/other.meta"
cat > "$TMP_ROOT/send" <<'EOF'
#!/usr/bin/env bash
printf '%s: %s\n' "$1" "$2" >> "$FM_HOME/sends"
EOF
chmod +x "$TMP_ROOT/send"
before_refs=$(git -C "$PROJECT" show-ref)
before_project=$(git -C "$PROJECT" status --porcelain=v1)
before_worker=$(git -C "$TMP_ROOT/conflict-wt" status --porcelain=v1)
before_index=$(git hash-object "$PROJECT/.git/index")
FM_HOME="$HOME_DIR" FM_LANDING_CONFLICT_SEND_BIN="$TMP_ROOT/send" \
  "$ROOT/bin/fm-landing-conflicts.sh" "$PROJECT" main > "$TMP_ROOT/first.out"
assert_grep 'conflict task=conflict' "$TMP_ROOT/first.out" 'conflict was not reported'
assert_grep 'code.txt' "$HOME_DIR/sends" 'conflicting path missing from worker notice'
assert_grep 'unknown task=missing' "$TMP_ROOT/first.out" 'missing ref was treated as clean'
if grep -Eq '^(clean|alternate|other):' "$HOME_DIR/sends"; then fail 'unaffected or clean branch was notified'; fi
[ "$(grep -c '^' "$HOME_DIR/sends")" -eq 2 ] || fail 'expected exactly conflict and unknown worker notices'
[ "$(grep -c 'landing-conflict' "$STATE/.wake-queue")" -eq 2 ] || fail 'expected two supervisor wakes'
FM_HOME="$HOME_DIR" FM_LANDING_CONFLICT_SEND_BIN="$TMP_ROOT/send" \
  "$ROOT/bin/fm-landing-conflicts.sh" "$PROJECT" main > "$TMP_ROOT/again.out"
[ ! -s "$TMP_ROOT/again.out" ] || fail 'repeat check emitted notifications'
[ "$(grep -c '^' "$HOME_DIR/sends")" -eq 2 ] || fail 'repeat check sent worker notices'
[ "$(grep -c 'landing-conflict' "$STATE/.wake-queue")" -eq 2 ] || fail 'repeat check woke supervisor'
[ "$(git -C "$PROJECT" show-ref)" = "$before_refs" ] || fail 'project refs changed'
[ "$(git -C "$PROJECT" status --porcelain=v1)" = "$before_project" ] || fail 'project working tree changed'
[ "$(git -C "$TMP_ROOT/conflict-wt" status --porcelain=v1)" = "$before_worker" ] || fail 'worker working tree changed'
[ "$(git hash-object "$PROJECT/.git/index")" = "$before_index" ] || fail 'project index changed'
pass 'conflict, clean, unknown, filtering, repeat notices, and Git state preservation'

# The remote mode must use the landed remote tip even while the local landing
# ref is stale. The project and worker refs still remain unchanged.
git clone -q --bare "$PROJECT" "$TMP_ROOT/origin.git"
git -C "$PROJECT" remote add origin "$TMP_ROOT/origin.git"
git -C "$PROJECT" branch fm/remote main
git -C "$PROJECT" worktree add -q "$TMP_ROOT/remote-wt" fm/remote
printf 'worker\n' > "$TMP_ROOT/remote-wt/remote.txt"
git -C "$TMP_ROOT/remote-wt" add remote.txt
git -C "$TMP_ROOT/remote-wt" commit -qm 'remote worker'
printf 'project=%s\nkind=ship\n' "$PROJECT" > "$STATE/remote.meta"
git clone -q "$TMP_ROOT/origin.git" "$TMP_ROOT/landing-wt"
git -C "$TMP_ROOT/landing-wt" config user.email fmtest@example.invalid
git -C "$TMP_ROOT/landing-wt" config user.name fmtest
printf 'landed\n' > "$TMP_ROOT/landing-wt/remote.txt"
git -C "$TMP_ROOT/landing-wt" add remote.txt
git -C "$TMP_ROOT/landing-wt" commit -qm 'remote landing'
git -C "$TMP_ROOT/landing-wt" push -q origin main
before_refs=$(git -C "$PROJECT" show-ref)
FM_HOME="$HOME_DIR" FM_LANDING_CONFLICT_SEND_BIN="$TMP_ROOT/send" \
  "$ROOT/bin/fm-landing-conflicts.sh" "$PROJECT" main --remote > "$TMP_ROOT/remote.out"
assert_grep 'conflict task=remote' "$TMP_ROOT/remote.out" 'remote landed tip was not checked'
assert_grep 'remote.txt' "$TMP_ROOT/remote.out" 'remote conflicting path was not named'
[ "$(git -C "$PROJECT" show-ref)" = "$before_refs" ] || fail 'remote check changed project refs'
pass 'remote landing checks the remote tip without fetching into the project'

# Exercise the real local landing entrypoint, not just the checker interface.
LANDING_PROJECT="$TMP_ROOT/local-landing"
git init -q -b main "$LANDING_PROJECT"
git -C "$LANDING_PROJECT" config user.email fmtest@example.invalid
git -C "$LANDING_PROJECT" config user.name fmtest
printf 'base\n' > "$LANDING_PROJECT/code.txt"
git -C "$LANDING_PROJECT" add code.txt
git -C "$LANDING_PROJECT" commit -qm base
git -C "$LANDING_PROJECT" branch fm/land
git -C "$LANDING_PROJECT" branch fm/other-work
git -C "$LANDING_PROJECT" worktree add -q "$TMP_ROOT/land-wt" fm/land
git -C "$LANDING_PROJECT" worktree add -q "$TMP_ROOT/other-wt" fm/other-work
printf 'landed\n' > "$TMP_ROOT/land-wt/code.txt"
git -C "$TMP_ROOT/land-wt" commit -qam landed
printf 'other\n' > "$TMP_ROOT/other-wt/code.txt"
git -C "$TMP_ROOT/other-wt" commit -qam other
printf 'project=%s\nkind=ship\nmode=local-only\n' "$LANDING_PROJECT" > "$STATE/land.meta"
printf 'project=%s\nkind=ship\nmode=local-only\n' "$LANDING_PROJECT" > "$STATE/other-work.meta"
mkdir -p "$HOME_DIR/data"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
land_sha=$(git -C "$LANDING_PROJECT" rev-parse refs/heads/fm/land)
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$land_sha" > "$TMP_ROOT/land.receipt"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_LANDING_CONFLICT_SEND_BIN="$TMP_ROOT/send" \
  "$ROOT/bin/fm-merge-local.sh" land --receipt "$TMP_ROOT/land.receipt" \
  > "$TMP_ROOT/land.out" 2> "$TMP_ROOT/land.err" \
  || fail "local landing failed: $(cat "$TMP_ROOT/land.err")"
[ "$(git -C "$LANDING_PROJECT" rev-parse main)" = "$land_sha" ] || fail 'local landing did not advance main'
assert_grep 'other-work: Landing trial merge conflict' "$HOME_DIR/sends" 'local landing did not notify the other worker'
assert_grep 'code.txt' "$TMP_ROOT/land.out" 'local landing did not name the conflict path'
pass 'the local landing entrypoint checks and reports the other branch'

# The confirmed PR outcome path also invokes the remote trial merge. A newer
# remote tip changes the event identity and produces a new notice.
printf 'landed again\n' > "$TMP_ROOT/landing-wt/remote.txt"
git -C "$TMP_ROOT/landing-wt" commit -qam 'next remote landing'
git -C "$TMP_ROOT/landing-wt" push -q origin main
printf 'project=%s\nkind=ship\nmode=direct-PR\n' "$PROJECT" > "$STATE/landed-pr.meta"
before_count=$(grep -c '^remote:' "$HOME_DIR/sends")
FM_HOME="$HOME_DIR" FM_LANDING_CONFLICT_SEND_BIN="$TMP_ROOT/send" \
  bash -c '. "$1"; fm_merge_outcome_report "$2" "$3" landed-pr "$4" self' _ \
  "$ROOT/bin/fm-merge-outcome-lib.sh" "$HOME_DIR" "$STATE" \
  https://github.com/example/repo/pull/1 \
  > "$TMP_ROOT/pr.out" 2> "$TMP_ROOT/pr.err" \
  || fail "confirmed PR outcome failed: $(cat "$TMP_ROOT/pr.err")"
[ "$(grep -c '^remote:' "$HOME_DIR/sends")" -eq "$((before_count + 1))" ] \
  || fail 'confirmed PR outcome did not report the new remote-tip conflict'
pass 'confirmed PR outcome checks the newly landed remote tip'
