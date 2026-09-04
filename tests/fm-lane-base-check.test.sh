#!/usr/bin/env bash
# Behavior tests for bin/fm-lane-base-check.sh, one case per named state in its
# header: current, ahead-only, behind-only (clean tree, allowlisted churn -
# staged included - and modifications outside the allowlist), diverged, an absent
# local landing branch, an unreadable working tree, and for a --publishes lane the
# unpublished-local state, each unresolvable-remote cause - no upstream, a local
# upstream, a configured upstream whose remote-tracking ref is gone, and an
# ambiguous name - plus the remote-ahead state that must NOT block.
# Every case runs the real script against a real temporary repository and asserts
# its exit code and reported line; the verdict contract is the exit code, so these
# assert the code first and read the line only for the evidence it must name.
# The tracked-churn allowlist is owned by bin/fm-playbot-lanes.mjs; one case
# proves this script classifies exactly the paths that owner publishes, so a
# future edit to that list flows through without touching either.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

CHECK="$ROOT/bin/fm-lane-base-check.sh"
OWNER="$ROOT/bin/fm-playbot-lanes.mjs"
TMP_ROOT=$(fm_test_tmproot fm-lane-base-check)

# One sandbox: a repo whose landing branch is `landing/frog-pile`, a bare origin
# with that branch pushed and set as upstream, and a worktree checked out at the
# commit the origin holds - the shape Playbot creates a lane workspace in. Echoes
# the case dir; the caller advances whichever side its state needs.
make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  fm_git_init_commit "$dir/repo"
  mkdir -p "$dir/repo/prototype-game/addons/playbot"
  printf 'config_version=5\n' > "$dir/repo/prototype-game/project.godot"
  printf 'uid://original\n' > "$dir/repo/prototype-game/addons/playbot/plugin.gd.uid"
  printf 'game code\n' > "$dir/repo/app.txt"
  git -C "$dir/repo" add prototype-game app.txt
  git -C "$dir/repo" commit -qm "playbot addon plus game code"
  git -C "$dir/repo" branch -M landing/frog-pile
  fm_git_add_origin "$dir/repo" "$dir/origin.git"
  git -C "$dir/repo" push -q -u origin landing/frog-pile >/dev/null 2>&1
  git -C "$dir/repo" worktree add -q -b task/lane "$dir/wt" landing/frog-pile
  printf '%s\n' "$dir"
}

# Advance the landing branch in the primary repo without pushing it.
land_locally() {
  local dir=$1 message=$2
  printf '%s\n' "$message" > "$dir/repo/landed-$RANDOM.txt"
  git -C "$dir/repo" add -A
  git -C "$dir/repo" commit -qm "$message"
}

run_check() {  # <worktree> [args...]
  local wt=$1
  shift
  (cd "$wt" && "$CHECK" "$@" 2>&1)
}

check_code() {  # <worktree> [args...] -> echoes exit code
  local wt=$1 rc
  shift
  (cd "$wt" && "$CHECK" "$@" >/dev/null 2>&1)
  rc=$?
  printf '%s\n' "$rc"
}

test_usage_is_refused_without_a_landing_branch() {
  local out rc
  out=$("$CHECK" 2>&1); rc=$?
  expect_code 2 "$rc" "a missing landing branch must be a usage error"
  assert_contains "$out" "requires a landing branch" "the usage error does not say what is missing"
  out=$("$CHECK" a b 2>&1); rc=$?
  expect_code 2 "$rc" "two landing branches must be a usage error"
  out=$("$CHECK" main --nope 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown option must be a usage error"
  out=$("$CHECK" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help must succeed"
  assert_contains "$out" "reset-required" "--help does not document the verdicts"
  pass "fm-lane-base-check.sh: usage errors are refused and --help documents the verdicts"
}

test_current_and_ahead_only_proceed_untouched() {
  local dir out
  dir=$(make_case current-ahead)
  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 0 "$(check_code "$dir/wt" landing/frog-pile)" "an equal HEAD must be current"
  assert_contains "$out" "current:" "the equal case does not report current"

  # Ahead only: the landing tip is an ancestor of HEAD, which is what
  # docs/playbot-lanes.md calls current - the lane's own commits, or the newer
  # landing tip the workspace was created from.
  printf 'lane work\n' > "$dir/wt/lane.txt"
  git -C "$dir/wt" add lane.txt
  git -C "$dir/wt" commit -qm "the lane's own commit"
  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 0 "$(check_code "$dir/wt" landing/frog-pile)" "an ahead-only workspace must proceed untouched"
  assert_contains "$out" "ancestor of HEAD" "the ahead-only case does not name why it is safe"
  pass "fm-lane-base-check.sh: an equal or ahead-only workspace proceeds untouched"
}

test_behind_only_with_a_clean_tree_requires_a_reset() {
  local dir out head_before
  dir=$(make_case behind-clean)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  head_before=$(git -C "$dir/wt" rev-parse HEAD)
  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 10 "$(check_code "$dir/wt" landing/frog-pile)" "a behind clean workspace must require a reset"
  assert_contains "$out" "reset-required: refs/heads/landing/frog-pile" \
    "the reset verdict does not name the exact ref to reset onto"
  assert_contains "$out" "churn-paths: " "the reset verdict does not report its churn paths line"
  [ "$(printf '%s\n' "$out" | sed -n 's/^churn-paths: //p')" = "" ] \
    || fail "a clean tree reported churn paths to disclose: $out"
  # The verdict is a report: the script must not have touched the worktree.
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "the check moved HEAD instead of only reporting"
  pass "fm-lane-base-check.sh: a behind clean workspace requires a reset and names the ref"
}

test_behind_with_allowlisted_churn_names_it_for_disclosure() {
  local dir out paths
  dir=$(make_case behind-churn)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  # Staged churn: a bare `git diff` would not show it, so the caller has to be
  # told about it explicitly or the reset would discard it unseen.
  printf 'config_version=5\nfolder_colors={"res://scenes":"red"}\n' > "$dir/wt/prototype-game/project.godot"
  git -C "$dir/wt" add prototype-game/project.godot
  printf 'uid://rewritten\n' > "$dir/wt/prototype-game/addons/playbot/plugin.gd.uid"
  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 10 "$(check_code "$dir/wt" landing/frog-pile)" \
    "a workspace carrying only Playbot churn must require a reset"
  paths=$(printf '%s\n' "$out" | sed -n 's/^churn-paths: //p')
  assert_contains "$paths" "prototype-game/project.godot" \
    "the staged hand-editable settings file is not named for disclosure"
  assert_contains "$paths" "prototype-game/addons/playbot/plugin.gd.uid" \
    "the unstaged churn path is not named for disclosure"
  assert_grep "folder_colors" "$dir/wt/prototype-game/project.godot" \
    "the check discarded the churn it was only supposed to report"
  pass "fm-lane-base-check.sh: allowlisted churn is named for disclosure, staged included"
}

test_modifications_outside_the_allowlist_block() {
  local dir out
  dir=$(make_case behind-dirty)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  printf 'real work\n' > "$dir/wt/app.txt"
  printf 'uid://rewritten\n' > "$dir/wt/prototype-game/addons/playbot/plugin.gd.uid"
  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" \
    "uncommitted work outside the allowlist must block"
  assert_contains "$out" "app.txt" "the block does not name the offending path"
  assert_not_contains "$out" "plugin.gd.uid" "the block blames allowlisted churn"
  assert_grep "real work" "$dir/wt/app.txt" "the check discarded work outside the allowlist"

  # A neighbouring path under the same directory is not churn: the allowlist is
  # literal paths, not a directory prefix.
  dir=$(make_case behind-neighbour)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  printf 'extends Node\n' > "$dir/wt/prototype-game/addons/playbot/plugin.gd"
  git -C "$dir/wt" add prototype-game/addons/playbot/plugin.gd
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" \
    "a neighbouring addons path must not be treated as churn"
  pass "fm-lane-base-check.sh: modifications outside the allowlist block the reset"
}

test_diverged_and_absent_landing_branch_block() {
  local dir out
  dir=$(make_case diverged)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  printf 'lane work\n' > "$dir/wt/lane.txt"
  git -C "$dir/wt" add lane.txt
  git -C "$dir/wt" commit -qm "the lane's own commit"
  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" "a diverged workspace must block"
  assert_contains "$out" "diverged" "the diverged block does not name the state"

  out=$(run_check "$dir/wt" landing/no-such-branch)
  expect_code 20 "$(check_code "$dir/wt" landing/no-such-branch)" \
    "an absent local landing branch must block"
  assert_contains "$out" "landing/no-such-branch is missing" \
    "the absent-branch block does not name the branch"
  pass "fm-lane-base-check.sh: a diverged workspace and an absent landing branch block"
}

# A PR's base is the landing branch as published, so a publishing lane may not
# start from a local landing branch carrying commits the remote tip lacks. The
# reverse - a remote tip ahead of the local branch, which is the state right after
# a PR merges - carries no ride-along risk and must proceed.
test_publishing_lane_requires_a_published_landing_branch() {
  local dir out
  dir=$(make_case publish-local-ahead)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "a publishing lane must block on an unpushed local landing branch"
  assert_contains "$out" "is not published" "the block does not name the state"
  assert_contains "$out" "$(git -C "$dir/repo" rev-parse refs/heads/landing/frog-pile)" \
    "the block does not name the local landing commit"
  assert_contains "$out" "$(git -C "$dir/origin.git" rev-parse refs/heads/landing/frog-pile)" \
    "the block does not name the remote landing commit"
  assert_contains "$out" "push landing/frog-pile before this lane proceeds" \
    "the block does not say to push the landing branch"
  [ "$(git -C "$dir/origin.git" rev-parse refs/heads/landing/frog-pile)" \
    != "$(git -C "$dir/repo" rev-parse refs/heads/landing/frog-pile)" ] \
    || fail "the check pushed the landing branch instead of reporting"

  # The same state is fine for a local-only lane: it publishes nothing, so its
  # local landing branch is the whole truth and the reset is the right answer.
  expect_code 10 "$(check_code "$dir/wt" landing/frog-pile)" \
    "a local-only lane must still reset onto an unpushed local landing branch"

  # Remote ahead of the local landing branch: the post-merge state. The workspace
  # was created from that newer remote tip, so it is ahead of the local branch and
  # must proceed untouched rather than demand a push that cannot succeed.
  dir=$(make_case publish-remote-ahead)
  land_locally "$dir" "merged upstream"
  git -C "$dir/repo" push -q origin landing/frog-pile
  git -C "$dir/wt" reset --hard refs/heads/landing/frog-pile >/dev/null 2>&1
  git -C "$dir/repo" update-ref refs/heads/landing/frog-pile "HEAD~1"
  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  expect_code 0 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "a publishing lane must proceed when only the remote tip is ahead"
  assert_not_contains "$out" "push landing/frog-pile" \
    "the remote-ahead state prescribes a push that could not succeed"
  pass "fm-lane-base-check.sh: a publishing lane blocks only on an unpublished local landing branch"
}

# Absence of remote evidence cannot prove nothing rides along, so a publishing
# lane blocks; a local-only lane makes no remote comparison and is unaffected.
test_unresolvable_remote_tip_blocks_only_a_publishing_lane() {
  local dir out
  dir=$(make_case publish-unresolvable)
  git -C "$dir/repo" branch --unset-upstream landing/frog-pile
  git -C "$dir/repo" update-ref -d refs/remotes/origin/landing/frog-pile
  land_locally "$dir" "sibling lane landed locally, not pushed"
  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "an unresolvable remote tip must block a publishing lane"
  assert_contains "$out" "could not be resolved" "the block does not name the missing evidence"
  assert_contains "$out" "no upstream configured" "the block does not name the cause it observed"
  # No refs/remotes/<remote>/<landing> exists in this state, so --set-upstream-to
  # would fatal rather than fix anything; the remedy has to be a fetch or a push.
  assert_not_contains "$out" "set-upstream-to" \
    "the block prescribes naming an upstream ref that does not exist"
  assert_contains "$out" "git fetch" "the block does not say how to fix it"
  expect_code 10 "$(check_code "$dir/wt" landing/frog-pile)" \
    "a local-only lane must be unaffected by an unresolvable remote tip"

  # Two remotes carrying the same branch name is the ambiguous case: still no
  # single tip to compare against.
  dir=$(make_case publish-ambiguous)
  git -C "$dir/repo" branch --unset-upstream landing/frog-pile
  git clone -q --bare "$dir/repo" "$dir/second.git"
  git -C "$dir/repo" remote add second "file://$dir/second.git"
  git -C "$dir/repo" fetch -q second
  land_locally "$dir" "sibling lane landed locally, not pushed"
  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "an ambiguous remote-tracking name must block a publishing lane"
  assert_contains "$out" "could not be resolved" "the ambiguous block does not name the missing evidence"
  # Here every candidate ref does exist, so naming one is a remedy that works.
  assert_contains "$out" "set-upstream-to" "the ambiguous block does not say how to fix it"
  pass "fm-lane-base-check.sh: an unresolvable or ambiguous remote tip blocks only a publishing lane"
}

# `<branch>@{upstream}` resolves an upstream that names a LOCAL branch - what
# `branch.autoSetupMerge = always` configures routinely - just as happily as a
# remote-tracking one. A local branch publishes nothing, so it is no evidence at
# all and must not satisfy the publishing precondition.
test_a_local_upstream_is_not_evidence_of_publication() {
  local dir out
  dir=$(make_case publish-local-upstream)
  git -C "$dir/repo" update-ref -d refs/remotes/origin/landing/frog-pile
  land_locally "$dir" "sibling lane landed locally, not pushed"
  # A local upstream that already contains the landing tip: comparing against it
  # finds nothing riding along, so taking it as the remote tip passes the
  # precondition while nothing whatever has been published.
  git -C "$dir/repo" branch local-superset refs/heads/landing/frog-pile
  git -C "$dir/repo" config branch.landing/frog-pile.remote .
  git -C "$dir/repo" config branch.landing/frog-pile.merge refs/heads/local-superset
  [ "$(git -C "$dir/repo" rev-parse --symbolic-full-name 'landing/frog-pile@{upstream}')" \
    = "refs/heads/local-superset" ] || fail "the fixture did not configure a local upstream"

  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "a local upstream must not satisfy a publishing lane's precondition"
  assert_contains "$out" "could not be resolved" "the block does not name the missing evidence"
  assert_contains "$out" "is a local branch" "the block does not name the cause it observed"

  # A local-only lane makes no remote comparison, so it is unaffected.
  expect_code 10 "$(check_code "$dir/wt" landing/frog-pile)" \
    "a local-only lane must be unaffected by a local upstream"
  pass "fm-lane-base-check.sh: an upstream naming a local branch is not evidence of publication"
}

# An upstream IS configured and the remote-tracking ref it names is gone: deleted
# upstream and then pruned, or never fetched. The evidence must name that cause,
# and the remedy must be a command that works in that state - telling the operator
# to point --set-upstream-to at a ref that does not exist only fatals.
test_a_configured_upstream_with_no_remote_ref_names_its_own_cause() {
  local dir out remedy rc
  dir=$(make_case publish-pruned-upstream)
  git -C "$dir/repo" update-ref -d refs/remotes/origin/landing/frog-pile
  land_locally "$dir" "sibling lane landed locally, not pushed"
  [ "$(git -C "$dir/repo" config --get branch.landing/frog-pile.remote)" = "origin" ] \
    || fail "the fixture did not leave an upstream configured"

  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "a configured upstream whose remote-tracking ref is absent must block a publishing lane"
  assert_contains "$out" "could not be resolved" "the block does not name the missing evidence"
  assert_contains "$out" "an upstream of origin/landing/frog-pile is configured" \
    "the block does not name the upstream it actually observed"
  assert_not_contains "$out" "set-upstream-to" \
    "the block prescribes naming an upstream ref that does not exist, which fatals"

  # Run the remedy it printed: the point of naming a cause is that its command works.
  remedy=$(printf '%s\n' "$out" | sed -n 's/.*; run \(git fetch [^ ]* [^ ]*\) to pick it up.*/\1/p')
  [ -n "$remedy" ] || fail "the block did not prescribe a fetch of the branch: $out"
  (cd "$dir/repo" && $remedy >/dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "the prescribed remedy '$remedy' failed in the state that prescribed it"
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "the remedy must restore the comparison, leaving only the unpushed-landing block"
  assert_contains "$(run_check "$dir/wt" landing/frog-pile --publishes)" "is not published" \
    "after the remedy the lane no longer blocks on the state it is actually in"
  pass "fm-lane-base-check.sh: a pruned upstream names its own cause and prescribes a working remedy"
}

# A working tree whose state cannot be read must never be reported as clean: a
# clean tree is exactly what authorises the reset, so this read is the one that
# fails open into destruction if its exit status is dropped.
test_an_unreadable_working_tree_blocks_instead_of_authorizing_a_reset() {
  local dir out gitdir
  dir=$(make_case unreadable-tree)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  printf 'work nobody has committed yet\n' > "$dir/wt/app.txt"
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" \
    "the fixture must start from real uncommitted work that already blocks"

  # Corrupting the worktree's index makes `git status` fail for real, exactly as a
  # damaged or concurrently written index would; the ref reads it does not touch.
  gitdir=$(git -C "$dir/wt" rev-parse --absolute-git-dir)
  printf 'not an index\n' > "$gitdir/index"
  git -C "$dir/wt" status --porcelain >/dev/null 2>&1 \
    && fail "the fixture did not actually make git status fail"

  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" \
    "an unreadable working tree must block rather than report a reset as safe"
  assert_contains "$out" "could not be read" "the block does not name what it could not read"
  assert_not_contains "$out" "reset-required" \
    "an unreadable working tree was reported as safe to reset"
  assert_grep "work nobody has committed yet" "$dir/wt/app.txt" \
    "the check discarded work it could not even read"
  pass "fm-lane-base-check.sh: an unreadable working tree blocks instead of authorizing a reset"
}

# The allowlist has one owner. This proves the script classifies exactly the paths
# that owner publishes: every published path is treated as churn, and the count
# matches, so a future edit to the owner's list flows through with no edit here.
test_churn_classification_comes_from_its_owner() {
  local dir published path out paths count
  fm_test_require_node || return 0
  published=$(node "$OWNER" tracked-churn-allowlist) \
    || fail "the allowlist owner does not publish its list"
  count=$(printf '%s\n' "$published" | grep -c .)
  [ "$count" -gt 0 ] || fail "the allowlist owner published an empty list"

  dir=$(make_case churn-owner)
  # Track every published path so each one can carry a modification.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$dir/repo/$(dirname "$path")"
    printf 'owned\n' > "$dir/repo/$path"
  done <<EOF
$published
EOF
  git -C "$dir/repo" add -A
  git -C "$dir/repo" commit -qm "every allowlisted path tracked"
  git -C "$dir/wt" reset --hard refs/heads/landing/frog-pile >/dev/null 2>&1
  land_locally "$dir" "sibling lane landed locally, not pushed"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf 'rewritten by the editor\n' > "$dir/wt/$path"
  done <<EOF
$published
EOF

  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 10 "$(check_code "$dir/wt" landing/frog-pile)" \
    "modifying exactly the owner's published paths must still allow a reset"
  paths=$(printf '%s\n' "$out" | sed -n 's/^churn-paths: //p')
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    assert_contains "$paths" "$path" "the check does not classify the owner's path $path as churn"
  done <<EOF
$published
EOF
  [ "$(printf '%s\n' "$paths" | wc -w | tr -d ' ')" = "$count" ] \
    || fail "the check named $(printf '%s\n' "$paths" | wc -w | tr -d ' ') churn paths for the owner's $count"
  pass "fm-lane-base-check.sh: churn classification is exactly the allowlist its owner publishes"
}

# With the owner unreadable the discard set must not widen: no path counts as
# churn, so the same modification blocks instead of authorizing a reset.
test_unreadable_allowlist_owner_fails_safe() {
  local dir out fake
  dir=$(make_case churn-owner-unreadable)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  printf 'config_version=5\nfolder_colors={"res://scenes":"red"}\n' > "$dir/wt/prototype-game/project.godot"
  expect_code 10 "$(check_code "$dir/wt" landing/frog-pile)" \
    "allowlisted churn must allow a reset while the owner is readable"

  # A node that fails makes the owner unreadable exactly as a missing runtime or a
  # broken owner would, without touching the repository's own files.
  fake=$(fm_fakebin "$dir")
  cat > "$fake/node" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fake/node"
  out=$(cd "$dir/wt" && PATH="$fake:$PATH" "$CHECK" landing/frog-pile 2>&1)
  (cd "$dir/wt" && PATH="$fake:$PATH" "$CHECK" landing/frog-pile >/dev/null 2>&1)
  expect_code 20 "$?" "an unreadable allowlist owner must block rather than widen the discard set"
  assert_contains "$out" "prototype-game/project.godot" \
    "the fail-safe block does not name the modification it refused to discard"
  pass "fm-lane-base-check.sh: an unreadable allowlist owner fails safe and blocks"
}

test_usage_is_refused_without_a_landing_branch
test_current_and_ahead_only_proceed_untouched
test_behind_only_with_a_clean_tree_requires_a_reset
test_behind_with_allowlisted_churn_names_it_for_disclosure
test_modifications_outside_the_allowlist_block
test_diverged_and_absent_landing_branch_block
test_publishing_lane_requires_a_published_landing_branch
test_unresolvable_remote_tip_blocks_only_a_publishing_lane
test_a_local_upstream_is_not_evidence_of_publication
test_a_configured_upstream_with_no_remote_ref_names_its_own_cause
test_an_unreadable_working_tree_blocks_instead_of_authorizing_a_reset
test_churn_classification_comes_from_its_owner
test_unreadable_allowlist_owner_fails_safe
