#!/usr/bin/env bash
# tests/fm-pr-fork-sync-proof.test.sh - real Git-history fixtures for the
# marker-free fork-sync exemption used by Require no-mistakes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROOF="$ROOT/bin/fm-pr-fork-sync-proof.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-fork-sync-proof)
REPO="$TMP_ROOT/repo"
UPSTREAM="$TMP_ROOT/upstream.git"

git init -q --bare "$UPSTREAM"
git --git-dir="$UPSTREAM" symbolic-ref HEAD refs/heads/main
git init -q "$REPO"
fm_git_identity "$REPO"
git -C "$REPO" checkout -q -b main

printf 'root\n' > "$REPO/conflict.txt"
printf 'stable\n' > "$REPO/stable.txt"
git -C "$REPO" add conflict.txt stable.txt
git -C "$REPO" commit -qm root
ROOT_COMMIT=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" remote add upstream "$UPSTREAM"
git -C "$REPO" push -q upstream main

git -C "$REPO" checkout -q -b upstream-work
printf 'upstream\n' > "$REPO/conflict.txt"
printf 'from upstream\n' > "$REPO/upstream-only.txt"
git -C "$REPO" add conflict.txt upstream-only.txt
git -C "$REPO" commit -qm 'upstream change'
UPSTREAM_TIP=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q upstream HEAD:main

git -C "$REPO" checkout -q -b fork-main "$ROOT_COMMIT"
printf 'fork\n' > "$REPO/conflict.txt"
printf 'from fork\n' > "$REPO/fork-only.txt"
git -C "$REPO" add conflict.txt fork-only.txt
git -C "$REPO" commit -qm 'fork-only change'
BASE_COMMIT=$(git -C "$REPO" rev-parse HEAD)

git -C "$REPO" checkout -q -b genuine-sync
if git -C "$REPO" merge --no-ff --no-commit "$UPSTREAM_TIP" >/dev/null 2>&1; then
  fail "genuine fixture unexpectedly merged without the intended conflict"
fi
printf 'resolved fork and upstream\n' > "$REPO/conflict.txt"
git -C "$REPO" add conflict.txt
git -C "$REPO" commit -qm 'Merge upstream/main into fork main'
GENUINE_HEAD=$(git -C "$REPO" rev-parse HEAD)

run_accept() {  # <case-id> <repo> <title> <head> <base> <upstream-url>
  local case_id=$1 repo=$2 title=$3 head=$4 base=$5 upstream_url=$6 output
  output="$TMP_ROOT/$case_id.out"
  if ! (
    cd "$repo" || exit 1
    FM_FORK_SYNC_UPSTREAM_URL="$upstream_url" "$PROOF" \
      --title "$title" --head "$head" --base "$base"
  ) > "$output" 2>&1; then
    cat "$output" >&2
    fail "$case_id should have passed"
  fi
  pass "case-id=$case_id accepted"
}

run_reject() {  # <case-id> <repo> <title> <head> <base> <upstream-url> <diagnostic>
  local case_id=$1 repo=$2 title=$3 head=$4 base=$5 upstream_url=$6 diagnostic=$7 output
  output="$TMP_ROOT/$case_id.out"
  if (
    cd "$repo" || exit 1
    FM_FORK_SYNC_UPSTREAM_URL="$upstream_url" "$PROOF" \
      --title "$title" --head "$head" --base "$base"
  ) > "$output" 2>&1; then
    cat "$output" >&2
    fail "$case_id should have failed closed"
  fi
  assert_grep "$diagnostic" "$output" "$case_id emitted the wrong failure"
  pass "case-id=$case_id rejected"
}

run_accept genuine-conflict-sync "$REPO" \
  'Sync fork with upstream/main (fixture)' "$GENUINE_HEAD" "$BASE_COMMIT" "$UPSTREAM"
run_accept punctuated-title-valid-proof "$REPO" \
  'Sync fork with upstream/main: September' "$GENUINE_HEAD" "$BASE_COMMIT" "$UPSTREAM"

run_reject ordinary-hand-opened "$REPO" \
  'Ordinary hand-opened change' "$GENUINE_HEAD" "$BASE_COMMIT" "$UPSTREAM" \
  "title must start with 'Sync fork with upstream/main'"

git -C "$REPO" checkout -q -b claimed-sync "$BASE_COMMIT"
git -C "$REPO" checkout -q -b handmade-side "$ROOT_COMMIT"
printf 'not upstream\n' > "$REPO/handmade.txt"
git -C "$REPO" add handmade.txt
git -C "$REPO" commit -qm 'handmade non-upstream commit'
HANDMADE_SIDE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q claimed-sync
git -C "$REPO" merge -q --no-ff "$HANDMADE_SIDE" -m 'Claimed upstream sync'
CLAIMED_HEAD=$(git -C "$REPO" rev-parse HEAD)
run_reject claimed-but-not-upstream "$REPO" \
  'Sync fork with upstream/main: September' "$CLAIMED_HEAD" "$BASE_COMMIT" "$UPSTREAM" \
  "second parent is not reachable from upstream/main"

git -C "$REPO" checkout -q -b injected-merge "$BASE_COMMIT"
if git -C "$REPO" merge --no-ff --no-commit "$UPSTREAM_TIP" >/dev/null 2>&1; then
  fail "injected fixture unexpectedly merged without the intended conflict"
fi
printf 'resolved fork and upstream\n' > "$REPO/conflict.txt"
printf 'invented during merge\n' > "$REPO/injected.txt"
git -C "$REPO" add conflict.txt injected.txt
git -C "$REPO" commit -qm 'Merge upstream with unrelated authored content'
INJECTED_HEAD=$(git -C "$REPO" rev-parse HEAD)
run_reject unrelated-merge-authorship "$REPO" \
  'Sync fork with upstream/main (injected)' "$INJECTED_HEAD" "$BASE_COMMIT" "$UPSTREAM" \
  "although upstream did not touch it"

git -C "$REPO" checkout -q -b pathspec-magic-injected "$BASE_COMMIT"
if git -C "$REPO" merge --no-ff --no-commit "$UPSTREAM_TIP" >/dev/null 2>&1; then
  fail "pathspec-magic fixture unexpectedly merged without the intended conflict"
fi
printf 'resolved fork and upstream\n' > "$REPO/conflict.txt"
printf 'invented during merge\n' > "$REPO/:(top)conflict.txt"
git -C "$REPO" --literal-pathspecs add conflict.txt ':(top)conflict.txt'
git -C "$REPO" commit -qm 'Merge upstream with pathspec-magic authored content'
PATHSPEC_MAGIC_HEAD=$(git -C "$REPO" rev-parse HEAD)
run_reject pathspec-magic-merge-authorship "$REPO" \
  'Sync fork with upstream/main: crafted path' "$PATHSPEC_MAGIC_HEAD" "$BASE_COMMIT" "$UPSTREAM" \
  "although upstream did not touch it"

run_reject upstream-unreachable "$REPO" \
  'Sync fork with upstream/main (unreachable)' "$GENUINE_HEAD" "$BASE_COMMIT" \
  "$TMP_ROOT/does-not-exist.git" "upstream/main could not be fetched read-only"

SHALLOW="$TMP_ROOT/shallow"
git clone -q --depth 1 "file://$REPO" "$SHALLOW"
run_reject shallow-history "$SHALLOW" \
  'Sync fork with upstream/main (shallow)' HEAD HEAD "$UPSTREAM" \
  "repository is shallow or its history depth cannot be determined"

echo "# fm-pr-fork-sync-proof.test.sh: all acceptance fixtures passed"
