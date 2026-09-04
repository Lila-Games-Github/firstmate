#!/usr/bin/env bash
# Behavior tests for bin/fm-lane-base-check.sh, one case per named state in its
# header: current, ahead-only, behind-only (clean tree, allowlisted churn -
# staged included, an untracked file at an allowlisted path, a rename, and
# modifications outside the allowlist), diverged, an absent local landing branch,
# an unreadable working tree, and for a --publishes lane the unpublished-local
# state - strictly ahead and diverged, which get different remedies - plus each
# unresolvable-remote cause: no upstream, a local
# upstream, a configured upstream whose remote-tracking ref is gone, and an
# ambiguous name, and an upstream naming a different remote branch - plus the
# remote-ahead state and the ambiguous name an upstream resolves, which must NOT
# block.
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
# The script reads its churn allowlist from its owner through Node, so a missing
# runtime would surface as an unrelated churn-classification failure. Guarded once
# here, before any case runs, as every other Node-dependent suite does.
fm_test_require_node "fm-lane-base-check"

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

# Every byte of both git dirs - the worktree's own and the shared common one -
# hashed together, so any ref update, index rewrite or leftover lock file shows up
# as a difference. The script's contract is that it writes nothing at all.
git_dirs_fingerprint() {  # <worktree>
  local wt=$1 gd common
  gd=$(git -C "$wt" rev-parse --absolute-git-dir)
  common=$(cd "$gd" && git rev-parse --path-format=absolute --git-common-dir)
  find "$gd" "$common" -type f -print0 2>/dev/null \
    | LC_ALL=C sort -z \
    | xargs -0 sha256sum 2>/dev/null \
    | sha256sum
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

# Allowlist membership is a whole-string comparison of the pathname `git status`
# reported, not a pattern or a line match. A pathname may legitimately contain a
# newline, so a path whose SECOND line equals an allowlisted entry is not that
# entry, and treating it as one would authorise discarding a file nobody owns.
test_allowlist_membership_is_a_literal_path_not_a_pattern() {
  local dir out sneaky
  dir=$(make_case behind-newline-path)
  sneaky=$'scratch\nprototype-game/project.godot'
  mkdir -p "$dir/repo/$(dirname -- "$sneaky")"
  printf 'work nobody has committed yet\n' > "$dir/repo/$sneaky"
  git -C "$dir/repo" add -- "$sneaky"
  git -C "$dir/repo" commit -qm "a tracked path whose name contains a newline"
  git -C "$dir/wt" reset --hard refs/heads/landing/frog-pile >/dev/null 2>&1
  land_locally "$dir" "sibling lane landed locally, not pushed"
  printf 'edited by the lane\n' > "$dir/wt/$sneaky"
  [ "$(git -C "$dir/wt" status --porcelain -z | tr -d '\0' | wc -l)" -gt 0 ] \
    || fail "the fixture did not leave the newline path modified"

  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" \
    "a path that merely contains an allowlisted entry must not be treated as churn"
  assert_contains "$out" "outside the Playbot churn allowlist" \
    "the block does not name why the path is not discardable"
  assert_grep "edited by the lane" "$dir/wt/$sneaky" \
    "the check discarded a modification it had no authority over"
  pass "fm-lane-base-check.sh: allowlist membership is a literal path, not a pattern"
}

# Churn is a TRACKED change. The allowlist's owner infers no untracked file to be
# churn, and `git diff HEAD` records nothing for content git does not track, so an
# untracked file at an allowlisted path must block - otherwise the reset would
# discard it and the disclosure line would name it with an empty record behind it.
# The same path, tracked and modified, must still be churn, so the distinction is
# proven from both sides rather than assumed.
test_an_untracked_allowlisted_path_blocks_while_a_tracked_one_is_churn() {
  local dir out churn_path
  churn_path=prototype-game/addons/playbot/playbot_common.gd.uid
  dir=$(make_case behind-untracked-churn)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  # Playbot's editor writes the path into a workspace whose HEAD does not track
  # it, so git sees `?? <path>` rather than a modification.
  printf 'uid://playbot-rewrote-this-locally\n' > "$dir/wt/$churn_path"
  [ -z "$(git -C "$dir/wt" diff HEAD -- "$churn_path")" ] \
    || fail "the fixture's path is tracked, so it could still be disclosed"

  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" \
    "an untracked file at an allowlisted path must block, not count as churn"
  assert_contains "$out" "$churn_path" "the block does not name the untracked path"
  assert_grep "playbot-rewrote-this-locally" "$dir/wt/$churn_path" \
    "the check discarded an untracked file it could not have disclosed"

  # Tracked and modified at the very same path: still churn, still disclosable.
  dir=$(make_case behind-tracked-churn)
  printf 'uid://committed\n' > "$dir/repo/$churn_path"
  git -C "$dir/repo" add -- "$churn_path"
  git -C "$dir/repo" commit -qm "the addon uid becomes tracked"
  git -C "$dir/wt" reset --hard refs/heads/landing/frog-pile >/dev/null 2>&1
  land_locally "$dir" "sibling lane landed locally, not pushed"
  printf 'uid://playbot-rewrote-this-locally\n' > "$dir/wt/$churn_path"
  [ -n "$(git -C "$dir/wt" diff HEAD -- "$churn_path")" ] \
    || fail "the fixture left nothing for the disclosure record to capture"

  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 10 "$(check_code "$dir/wt" landing/frog-pile)" \
    "a tracked modification at an allowlisted path must still require a reset"
  assert_contains "$(printf '%s\n' "$out" | sed -n 's/^churn-paths: //p')" "$churn_path" \
    "the tracked churn path is not named for disclosure"
  pass "fm-lane-base-check.sh: an untracked allowlisted path blocks, a tracked one is churn"
}

# The blocked line is what a human and firstmate act on, so it must name the true
# reason. An untracked file AT an allowlisted path is not "outside the allowlist" -
# the path is one the owner publishes - and a workspace carrying one of each has
# to report both, or one of the two paths goes unexplained.
test_the_block_names_the_true_reason_for_each_path() {
  local dir out churn_path
  churn_path=prototype-game/addons/playbot/playbot_common.gd.uid
  dir=$(make_case reason-untracked)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  printf 'uid://playbot-rewrote-this-locally\n' > "$dir/wt/$churn_path"

  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" \
    "an untracked file at an allowlisted path must block"
  assert_contains "$out" "untracked" "the block does not say the path is untracked"
  assert_not_contains "$out" "outside the Playbot churn allowlist" \
    "the block claims an allowlisted path is outside the allowlist"

  # A path genuinely outside the allowlist keeps the outside reason.
  printf 'real work\n' > "$dir/wt/app.txt"
  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" \
    "one of each kind must still block"
  assert_contains "$out" "outside the Playbot churn allowlist: app.txt" \
    "the block does not name the tracked modification's own reason"
  assert_contains "$out" "untracked" "the block dropped the untracked reason"
  assert_contains "$out" "$churn_path" "the block dropped the untracked path"
  pass "fm-lane-base-check.sh: the block names the true reason for each path"
}

# `status.showUntrackedFiles` lives in the shared config of the common git dir, so
# one setting in the primary repository would otherwise silence the untracked half
# of this gate in every lane worktree - and a silent gate reads as a clean tree,
# which is exactly what authorises the reset.
test_the_untracked_gate_does_not_depend_on_ambient_git_config() {
  local dir out churn_path
  churn_path=prototype-game/addons/playbot/playbot_common.gd.uid
  dir=$(make_case untracked-config-off)
  git -C "$dir/repo" config status.showUntrackedFiles no
  land_locally "$dir" "sibling lane landed locally, not pushed"
  printf 'uid://playbot-rewrote-this-locally\n' > "$dir/wt/$churn_path"
  printf 'work nobody has committed yet\n' > "$dir/wt/untracked-work.txt"
  [ -z "$(git -C "$dir/wt" status --porcelain)" ] \
    || fail "the fixture did not actually silence untracked reporting"

  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" \
    "the untracked gate must hold regardless of status.showUntrackedFiles"
  assert_contains "$out" "$churn_path" "the block does not name the untracked allowlisted path"
  assert_contains "$out" "untracked-work.txt" "the block does not name the untracked file"
  assert_grep "work nobody has committed yet" "$dir/wt/untracked-work.txt" \
    "the check authorised a reset over uncommitted content"
  pass "fm-lane-base-check.sh: the untracked gate does not depend on ambient git config"
}

# The contract is that this script writes nothing and takes no lock, and the
# generated brief repeats that claim to the worker deciding it is safe to run on a
# workspace holding uncommitted work. A lane workspace is concurrently rewritten
# by Playbot's editor, so an index refresh here would race it.
test_the_check_leaves_both_git_dirs_untouched() {
  local dir gd before after state
  for state in clean churn; do
    dir=$(make_case "readonly-$state")
    land_locally "$dir" "sibling lane landed locally, not pushed"
    if [ "$state" = churn ]; then
      printf 'config_version=5\nfolder_colors={"res://scenes":"red"}\n' > "$dir/wt/prototype-game/project.godot"
      git -C "$dir/wt" add prototype-game/project.godot
      printf 'uid://rewritten\n' > "$dir/wt/prototype-game/addons/playbot/plugin.gd.uid"
    fi
    gd=$(git -C "$dir/wt" rev-parse --absolute-git-dir)
    # Settle every stat cache first, then make it stale again, so the run is the
    # only thing that could want to refresh the index.
    git -C "$dir/wt" status --porcelain >/dev/null
    before=$(git_dirs_fingerprint "$dir/wt")
    touch "$dir/wt/app.txt" "$dir/wt/prototype-game/project.godot"

    expect_code 10 "$(check_code "$dir/wt" landing/frog-pile)" \
      "the $state case must still reach its verdict"
    # The publishing path adds the remote-tip and containment reads; it blocks on
    # this fixture's unpushed landing branch, and must write nothing either.
    check_code "$dir/wt" landing/frog-pile --publishes >/dev/null
    after=$(git_dirs_fingerprint "$dir/wt")
    [ "$before" = "$after" ] \
      || fail "the $state run changed the git dirs it only reads: $before vs $after"
    [ ! -e "$gd/index.lock" ] || fail "the $state run left an index lock behind"
  done
  pass "fm-lane-base-check.sh: a full run leaves both git dirs byte-identical"
}

# A rename record is `XY <path>NUL<origPath>NUL` - the source path arrives with no
# status field of its own. If the reader misaligned there, the status carried by
# the next record would be attributed to the wrong path, so a rename standing next
# to real churn is what proves it does not.
test_a_rename_record_does_not_misalign_the_status_field() {
  local dir out outside
  dir=$(make_case behind-rename)
  printf 'game code\n' > "$dir/repo/moved.txt"
  git -C "$dir/repo" add moved.txt
  git -C "$dir/repo" commit -qm "a file that a lane will rename"
  git -C "$dir/wt" reset --hard refs/heads/landing/frog-pile >/dev/null 2>&1
  land_locally "$dir" "sibling lane landed locally, not pushed"
  git -C "$dir/wt" mv moved.txt renamed.txt
  printf 'uid://rewritten\n' > "$dir/wt/prototype-game/addons/playbot/plugin.gd.uid"

  out=$(run_check "$dir/wt" landing/frog-pile)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile)" \
    "a rename outside the allowlist must block even beside allowlisted churn"
  outside=$(printf '%s\n' "$out" | sed -n 's/.*outside the Playbot churn allowlist: //p')
  assert_contains "$outside" "renamed.txt" "the block does not name the rename destination"
  assert_contains "$outside" "moved.txt" "the block does not name the rename source"
  assert_not_contains "$outside" "plugin.gd.uid" \
    "the rename record misaligned the status onto the allowlisted churn path"
  pass "fm-lane-base-check.sh: a rename record does not misalign the status field"
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

# Blocking a diverged landing branch is right; prescribing a push for it is not,
# because that push is rejected as a non-fast-forward. The remedy has to follow
# from what was actually observed, so the two states are checked side by side.
test_a_diverged_landing_branch_is_not_told_to_push() {
  local dir out
  dir=$(make_case publish-diverged)
  # Ahead only first, from the same fixture: pushing IS the right advice there.
  land_locally "$dir" "sibling lane landed locally, not pushed"
  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  assert_contains "$out" "push landing/frog-pile before this lane proceeds" \
    "a strictly-ahead local landing branch must still be told to push it"
  assert_not_contains "$out" "diverged from its remote tip" \
    "a strictly-ahead local landing branch was reported as diverged"

  # Now diverge them: the remote gains a commit the local branch does not have,
  # while the local branch keeps the one the remote lacks.
  git -C "$dir/repo" worktree add -q --detach "$dir/pusher" refs/remotes/origin/landing/frog-pile
  printf 'landed upstream by someone else\n' > "$dir/pusher/upstream.txt"
  git -C "$dir/pusher" add upstream.txt
  git -C "$dir/pusher" commit -qm "an upstream commit the local landing lacks"
  git -C "$dir/pusher" push -q origin HEAD:landing/frog-pile
  git -C "$dir/repo" fetch -q origin
  [ "$(git -C "$dir/repo" rev-list --count refs/remotes/origin/landing/frog-pile..refs/heads/landing/frog-pile)" -gt 0 ] \
    || fail "the fixture left no local-only commit"
  [ "$(git -C "$dir/repo" rev-list --count refs/heads/landing/frog-pile..refs/remotes/origin/landing/frog-pile)" -gt 0 ] \
    || fail "the fixture did not actually diverge the two refs"

  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "a diverged landing branch must still block a publishing lane"
  assert_contains "$out" "diverged from its remote tip" \
    "the block does not name the diverged state it observed"
  assert_contains "$out" "reconcile landing/frog-pile with its remote tip" \
    "the block does not prescribe reconciling before pushing"
  assert_not_contains "$out" "push landing/frog-pile before this lane proceeds" \
    "the diverged block prescribes a push that would be rejected"
  assert_not_contains "$out" "--force" "the block prescribes rewriting published history"
  pass "fm-lane-base-check.sh: a diverged landing branch is told to reconcile, not to push"
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

# A PR's base is the landing branch BY NAME, so the only ref that is evidence
# about what a PR would build on is refs/remotes/<remote>/<landing>. An upstream
# tracking a DIFFERENT remote branch - what `git branch --set-upstream-to=origin/main`
# leaves behind - says nothing about that ref and must not be taken as its tip.
test_an_upstream_for_a_different_branch_is_not_the_published_tip() {
  local dir out
  dir=$(make_case publish-foreign-upstream)
  # origin/main is pushed at the same commit the landing branch will reach, so
  # comparing against it finds nothing riding along while the real PR base -
  # origin/landing/frog-pile - is left a commit behind.
  land_locally "$dir" "sibling lane landed locally, not pushed"
  git -C "$dir/repo" branch main refs/heads/landing/frog-pile
  git -C "$dir/repo" push -q origin main
  git -C "$dir/repo" config branch.landing/frog-pile.merge refs/heads/main
  [ "$(git -C "$dir/repo" rev-parse --symbolic-full-name 'landing/frog-pile@{upstream}')" \
    = "refs/remotes/origin/main" ] || fail "the fixture did not configure a foreign upstream"
  [ "$(git -C "$dir/repo" rev-list --count refs/remotes/origin/landing/frog-pile..refs/heads/landing/frog-pile)" \
    = "1" ] || fail "the fixture left nothing riding along against the real PR base"

  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "an upstream for a different branch must not satisfy a publishing lane's precondition"
  assert_contains "$out" "is not published" \
    "the block does not name the state the real PR base is actually in"
  assert_contains "$out" "refs/remotes/origin/landing/frog-pile" \
    "the block does not name the ref a PR would actually build on"

  # With no ref of the landing branch's own name to fall back on, there is no
  # evidence at all, and the block has to name that cause.
  dir=$(make_case publish-foreign-upstream-only)
  land_locally "$dir" "sibling lane landed locally, not pushed"
  git -C "$dir/repo" branch main refs/heads/landing/frog-pile
  git -C "$dir/repo" push -q origin main
  git -C "$dir/repo" config branch.landing/frog-pile.merge refs/heads/main
  git -C "$dir/repo" update-ref -d refs/remotes/origin/landing/frog-pile
  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "a foreign upstream with no ref of the landing branch's name must block a publishing lane"
  assert_contains "$out" "could not be resolved" "the block does not name the missing evidence"
  assert_contains "$out" "names a different remote branch" \
    "the block does not name the cause it observed"

  # A local-only lane makes no remote comparison, so neither state affects it.
  expect_code 10 "$(check_code "$dir/wt" landing/frog-pile)" \
    "a local-only lane must be unaffected by a foreign upstream"
  pass "fm-lane-base-check.sh: an upstream for a different branch is not the published tip"
}

# An upstream that DOES name the landing branch's own ref still resolves it, and
# is what picks between candidates when more than one remote carries that name.
test_an_upstream_naming_the_landing_ref_resolves_an_ambiguous_name() {
  local dir out
  dir=$(make_case publish-ambiguous-with-upstream)
  git clone -q --bare "$dir/repo" "$dir/second.git"
  git -C "$dir/repo" remote add second "file://$dir/second.git"
  git -C "$dir/repo" fetch -q second
  land_locally "$dir" "sibling lane landed locally, not pushed"
  [ "$(git -C "$dir/repo" rev-parse --symbolic-full-name 'landing/frog-pile@{upstream}')" \
    = "refs/remotes/origin/landing/frog-pile" ] || fail "the fixture lost its upstream"

  out=$(run_check "$dir/wt" landing/frog-pile --publishes)
  expect_code 20 "$(check_code "$dir/wt" landing/frog-pile --publishes)" \
    "the named upstream's tip must still be compared against the local landing branch"
  assert_contains "$out" "is not published" \
    "the upstream that names the landing ref was not used as the published tip"
  assert_not_contains "$out" "ambiguous" \
    "an upstream naming one of the candidates was still called ambiguous"
  pass "fm-lane-base-check.sh: an upstream naming the landing ref resolves an ambiguous name"
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
test_allowlist_membership_is_a_literal_path_not_a_pattern
test_an_untracked_allowlisted_path_blocks_while_a_tracked_one_is_churn
test_the_block_names_the_true_reason_for_each_path
test_the_untracked_gate_does_not_depend_on_ambient_git_config
test_the_check_leaves_both_git_dirs_untouched
test_a_rename_record_does_not_misalign_the_status_field
test_diverged_and_absent_landing_branch_block
test_publishing_lane_requires_a_published_landing_branch
test_a_diverged_landing_branch_is_not_told_to_push
test_unresolvable_remote_tip_blocks_only_a_publishing_lane
test_a_local_upstream_is_not_evidence_of_publication
test_an_upstream_for_a_different_branch_is_not_the_published_tip
test_an_upstream_naming_the_landing_ref_resolves_an_ambiguous_name
test_a_configured_upstream_with_no_remote_ref_names_its_own_cause
test_an_unreadable_working_tree_blocks_instead_of_authorizing_a_reset
test_churn_classification_comes_from_its_owner
test_unreadable_allowlist_owner_fails_safe
