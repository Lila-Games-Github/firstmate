#!/usr/bin/env bash
# Real Git export/import, refusal and workstation local landing integration.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity remote-test remote@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-remote-landing)
HOME_CASE="$TMP_ROOT/home"
mkdir -p "$HOME_CASE/state" "$HOME_CASE/data" "$HOME_CASE/config"
export FM_HOME="$HOME_CASE"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE
PROJ="$TMP_ROOT/workstation"
REMOTE="$TMP_ROOT/remote"
WT="$TMP_ROOT/landing-worker"
git init -q --bare -b main "$TMP_ROOT/origin.git"
git clone -q "$TMP_ROOT/origin.git" "$PROJ"
printf 'base\n' > "$PROJ/shared.txt"
git -C "$PROJ" add .
git -C "$PROJ" commit -qm baseline
git -C "$PROJ" push -q origin main
BASE=$(git -C "$PROJ" rev-parse HEAD)
git clone -q "$TMP_ROOT/origin.git" "$REMOTE"
git -C "$REMOTE" checkout -qb fm/remote-task
printf 'remote work\n' > "$REMOTE/remote.txt"
git -C "$REMOTE" add .
git -C "$REMOTE" commit -qm 'remote work'
HEAD_SHA=$(git -C "$REMOTE" rev-parse HEAD)
git -C "$REMOTE" push -q origin HEAD:refs/heads/fm/remote-task
git -C "$PROJ" worktree add -qb fm/local-task "$WT" main
fm_write_meta "$HOME_CASE/state/local-task.meta" "project=$PROJ" "worktree=$WT" 'kind=ship' 'mode=local-only' 'landing_branch=main'
import_report() {
  "$BASH" "$ROOT/bin/fm-remote-landing.sh" import local-task --remote-task remote-task --branch fm/remote-task --head "$1"
}
if import_report "$BASE" > "$TMP_ROOT/bad.out" 2>&1; then fail 'mismatched report was accepted'; fi
assert_grep 'report head mismatch' "$TMP_ROOT/bad.out" 'bad report did not explain mismatch'
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail 'bad report moved local branch'
pass 'known-bad report refuses mismatched SHA without moving the local branch'
import_report "$HEAD_SHA" > "$TMP_ROOT/import.out" 2>&1 || fail "import failed: $(cat "$TMP_ROOT/import.out")"
[ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_SHA" ] || fail 'wrong imported head'
[ "$(git -C "$PROJ" rev-parse main)" = "$BASE" ] || fail 'import moved landing'
import_report "$HEAD_SHA" > "$TMP_ROOT/repeat.out" 2>&1 || fail 'idempotent import failed'
pass 'one pushed report imports exact head idempotently into the workstation worker'
printf 'dirty\n' > "$WT/dirty"
if import_report "$HEAD_SHA" > "$TMP_ROOT/dirty.out" 2>&1; then fail 'dirty import accepted'; fi
assert_grep 'dirty workstation' "$TMP_ROOT/dirty.out" 'dirty refusal absent'
rm "$WT/dirty"
pass 'dirty workstation work is preserved and refused'
printf 'local-only\n' > "$WT/local.txt"
git -C "$WT" add .
git -C "$WT" commit -qm 'local unpublished work'
LOCAL_SHA=$(git -C "$WT" rev-parse HEAD)
if import_report "$HEAD_SHA" > "$TMP_ROOT/diverged.out" 2>&1; then fail 'local work overwritten'; fi
[ "$(git -C "$WT" rev-parse HEAD)" = "$LOCAL_SHA" ] || fail 'local work lost'
# Restore through a new worktree, preserving the local commit under its branch.
git -C "$PROJ" branch -m fm/local-task fm/preserved-local
fm_write_meta "$HOME_CASE/state/landing.meta" "project=$PROJ" "worktree=$TMP_ROOT/final-worker" 'kind=ship' 'mode=local-only' 'landing_branch=main'
git -C "$PROJ" worktree add -qb fm/landing "$TMP_ROOT/final-worker" main
"$BASH" "$ROOT/bin/fm-remote-landing.sh" import landing --remote-task remote-task --branch fm/remote-task --head "$HEAD_SHA" > "$TMP_ROOT/final.out" 2>&1
pass 'unpublished workstation commits are retained when a report diverges'

# Generated contracts use the real seeded-home binding, and preserve local DOD.
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"
fm_dod_block local-only remote-task > "$TMP_ROOT/local.dod"
assert_grep 'Do NOT push' "$TMP_ROOT/local.dod" 'ordinary local-only behavior changed'
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$HOME_CASE/.fm-secondmate-parent"
fm_dod_block local-only remote-task > "$TMP_ROOT/remote.dod"
fm_ship_rule_one local-only remote-task > "$TMP_ROOT/remote.rule"
assert_grep 'HEAD:refs/heads/fm/remote-task' "$TMP_ROOT/remote.dod" 'remote export DOD missing'
assert_grep 'Push only your task branch' "$TMP_ROOT/remote.rule" 'remote rule still forbids export'
printf 'route=local\n' >> "$HOME_CASE/.fm-secondmate-parent"
fm_dod_block local-only remote-task > "$TMP_ROOT/corrupt.dod"
assert_grep 'Do NOT push' "$TMP_ROOT/corrupt.dod" 'corrupt binding granted export'
rm "$HOME_CASE/.fm-secondmate-parent"
pass 'remote binding selects branch export while local and corrupt homes keep no-push'

if [ "${FM_SKIP_TESTFARM:-}" = 1 ]; then
  echo 'skip: queue integration requires testfarm compatibility installation'
  exit 0
fi
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$HEAD_SHA" > "$TMP_ROOT/full.receipt"
"$ROOT/bin/fm-landing-queue.sh" ready landing --project "$PROJ" --landing-branch main \
  --branch fm/landing --head "$HEAD_SHA" --target "$BASE" --receipt "$TMP_ROOT/full.receipt" > "$TMP_ROOT/queue.out" 2>&1 \
  || fail "queue refused imported branch: $(cat "$TMP_ROOT/queue.out")"
# A new front car still requires its normal quick evidence, never an import bypass.
assert_grep 'status=needs-quick' "$TMP_ROOT/queue.out" 'queue gates were bypassed'
printf 'schema=fm-quick-check.v1\nsha=%s\ntarget=%s\n' "$HEAD_SHA" "$BASE" > "$TMP_ROOT/quick.receipt"
"$ROOT/bin/fm-landing-queue.sh" receipt landing --project "$PROJ" --landing-branch main \
  --head "$HEAD_SHA" --target "$BASE" --receipt "$TMP_ROOT/quick.receipt" > "$TMP_ROOT/ready.out" 2>&1
assert_grep 'status=ready-to-land' "$TMP_ROOT/ready.out" 'queue did not reach landing gate'
"$ROOT/bin/fm-merge-local.sh" landing --receipt "$TMP_ROOT/quick.receipt" > "$TMP_ROOT/merge.out" 2>&1 \
  || fail "local merge failed: $(cat "$TMP_ROOT/merge.out")"
[ "$(git -C "$PROJ" rev-parse main)" = "$HEAD_SHA" ] || fail 'exact report did not land'
[ "$(git --git-dir="$TMP_ROOT/origin.git" rev-parse main)" = "$BASE" ] || fail 'landing branch pushed to origin'
[ "$(git -C "$PROJ" rev-list --count "$BASE..main")" = 1 ] || fail 'expected exactly one imported commit'
pass 'real queue receipts and merge-local land exactly one remote commit with zero landing pushes'

# Front rebase uses actual queue assignments; only the final send boundary is
# recorded locally so this portable test needs no remote account or harness.
rebase_case() {
  local name=$1 change=$2 sha
  CASE="$TMP_ROOT/$name"
  mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/bin"
  git clone -q "$TMP_ROOT/origin.git" "$CASE/project"
  git -C "$CASE/project" worktree add -qb fm/front "$CASE/worker" main
  fm_write_meta "$CASE/home/state/front.meta" "project=$CASE/project" "worktree=$CASE/worker" 'kind=ship' 'mode=local-only' 'landing_branch=main'
  FM_HOME="$CASE/home" "$BASH" "$ROOT/bin/fm-remote-landing.sh" import front --remote-task remote-task \
    --branch fm/remote-task --head "$HEAD_SHA" > "$CASE/import.out" 2>&1
  printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$HEAD_SHA" > "$CASE/full"
  FM_HOME="$CASE/home" "$ROOT/bin/fm-landing-queue.sh" ready front --project "$CASE/project" --landing-branch main \
    --branch fm/front --head "$HEAD_SHA" --target "$BASE" --receipt "$CASE/full" > "$CASE/queue.out" 2>&1
  printf 'target edit\n' > "$CASE/project/$change"
  git -C "$CASE/project" add .
  git -C "$CASE/project" commit -qm 'new landing target'
  sha=$(git -C "$CASE/project" rev-parse HEAD)
  TARGET_SHA=$sha
}
rebase_case rebase-ok other.txt
FM_HOME="$CASE/home" "$BASH" "$ROOT/bin/fm-remote-landing.sh" rebase front --remote-task remote-task --secondmate remote-mate > "$CASE/rebase.out" 2>&1 \
  || fail "front rebase failed: $(cat "$CASE/rebase.out")"
git -C "$CASE/worker" merge-base --is-ancestor "$TARGET_SHA" HEAD || fail 'front rebase did not use queue target'
assert_grep 'status=needs-quick' "$CASE/rebase.out" 'rebase bypassed fresh evidence'
pass 'front rebase uses the real queue target and still requires farm evidence'

rebase_case rebase-conflict remote.txt
# Copy just the entrypoint; its standard helper dependencies remain real.
cp "$ROOT/bin/fm-remote-landing.sh" "$CASE/bin/fm-remote-landing.sh"
for dep in "$ROOT"/bin/*; do
  [ "${dep##*/}" = fm-remote-landing.sh ] || [ "${dep##*/}" = fm-send.sh ] || ln -s "$dep" "$CASE/bin/${dep##*/}"
done
cat > "$CASE/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_HOME/steer"
SH
chmod +x "$CASE/bin/fm-send.sh"
rc=0
FM_HOME="$CASE/home" "$BASH" "$CASE/bin/fm-remote-landing.sh" rebase front --remote-task remote-task --secondmate remote-mate > "$CASE/conflict.out" 2>&1 || rc=$?
expect_code 3 "$rc" 'conflict handoff exit'
[ "$(git -C "$CASE/worker" rev-parse HEAD)" = "$HEAD_SHA" ] || fail 'conflict did not abort to imported head'
[ -z "$(git -C "$CASE/worker" status --porcelain)" ] || fail 'conflict left partial changes'
assert_grep 'remote-mate' "$CASE/home/steer" 'wrong steer owner'
assert_grep "worker remote-task" "$CASE/home/steer" 'steer omitted remote worker'
assert_grep "target $TARGET_SHA" "$CASE/home/steer" 'steer omitted assigned target'
[ "$(git --git-dir="$TMP_ROOT/origin.git" rev-parse fm/front-landing-target)" = "$TARGET_SHA" ] || fail 'target not fetchable remotely'
[ "$(git --git-dir="$TMP_ROOT/origin.git" rev-parse main)" = "$BASE" ] || fail 'conflict pushed landing branch'
# Resolve in the real remote clone, push its rewritten task branch, then import.
git -C "$REMOTE" fetch -q origin fm/front-landing-target
git -C "$REMOTE" rebase --onto "$TARGET_SHA" "$BASE" > "$CASE/remote-rebase.out" 2>&1 || true
printf 'target edit plus remote resolution\n' > "$REMOTE/remote.txt"
git -C "$REMOTE" add remote.txt
GIT_EDITOR=true git -C "$REMOTE" rebase --continue > "$CASE/resolve.out" 2>&1
RESOLVED_SHA=$(git -C "$REMOTE" rev-parse HEAD)
git -C "$REMOTE" push -q --force-with-lease="refs/heads/fm/remote-task:$HEAD_SHA" origin HEAD:refs/heads/fm/remote-task
FM_HOME="$CASE/home" "$BASH" "$ROOT/bin/fm-remote-landing.sh" import front --remote-task remote-task \
  --branch fm/remote-task --head "$RESOLVED_SHA" > "$CASE/resolved-import.out" 2>&1 \
  || fail "resolved report could not import: $(cat "$CASE/resolved-import.out")"
[ "$(git -C "$CASE/worker" rev-parse HEAD)" = "$RESOLVED_SHA" ] || fail 'resolved head not imported'
[ "$(git -C "$CASE/project" rev-parse "refs/fm-remote-landing/front/$HEAD_SHA")" = "$HEAD_SHA" ] || fail 'old imported work lost'
pass 'conflict aborts, exports exact target, steers remote owner and imports resolution retaining old head'
