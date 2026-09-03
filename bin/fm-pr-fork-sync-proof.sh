#!/usr/bin/env bash
# fm-pr-fork-sync-proof.sh - prove that one PR is a narrow fork-sync merge.
#
# This verifier is the second acceptance path for the Require no-mistakes
# workflow after its unchanged deterministic PR-body marker check.
# It accepts only a title beginning with the literal case-sensitive prefix
# "Sync fork with upstream/main", with any suffix permitted, whose head is one
# two-parent merge, whose fork parent is already in the PR base, whose upstream
# parent and every introduced non-merge commit are reachable from the fetched
# upstream main, and whose merge tree invents changes only on paths both sides
# touched.
# Every missing object, fetch failure, shallow repository, ambiguous merge base,
# or indeterminate diff fails closed.
#
# Usage:
#   fm-pr-fork-sync-proof.sh --title <title> --head <sha> --base <sha>
#
# Tests may set FM_FORK_SYNC_UPSTREAM_URL to a local fixture repository.
# Production deliberately defaults to the read-only public upstream URL.
set -eu

UPSTREAM_URL=${FM_FORK_SYNC_UPSTREAM_URL:-https://github.com/kunchenguid/firstmate}
UPSTREAM_BRANCH=main
TITLE=
HEAD_SHA=
BASE_SHA=

usage() {
  sed -n '2,17{s/^# \{0,1\}//;p;}' "$0"
}

fail() {
  printf 'fork-sync proof failed: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)
      [ "$#" -ge 2 ] || fail "--title requires a value"
      TITLE=$2
      shift 2
      ;;
    --head)
      [ "$#" -ge 2 ] || fail "--head requires a commit"
      HEAD_SHA=$2
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || fail "--base requires a commit"
      BASE_SHA=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ -n "$TITLE" ] || fail "the PR title is unavailable"
[ -n "$HEAD_SHA" ] || fail "the PR head commit is unavailable"
[ -n "$BASE_SHA" ] || fail "the PR base commit is unavailable"

case "$TITLE" in
  "Sync fork with upstream/main"*) ;;
  *) fail "the title must start with 'Sync fork with upstream/main'" ;;
esac

[ "$(git rev-parse --is-shallow-repository 2>/dev/null || true)" = false ] \
  || fail "the repository is shallow or its history depth cannot be determined"

HEAD_COMMIT=$(git rev-parse --verify "$HEAD_SHA^{commit}" 2>/dev/null) \
  || fail "the PR head commit is missing or invalid"
BASE_COMMIT=$(git rev-parse --verify "$BASE_SHA^{commit}" 2>/dev/null) \
  || fail "the PR base commit is missing or invalid"

PARENTS=$(git rev-list --parents -n 1 "$HEAD_COMMIT" 2>/dev/null) \
  || fail "the PR head ancestry cannot be read"
# Git prints only hexadecimal object IDs separated by spaces here.
# shellcheck disable=SC2086
set -- $PARENTS
[ "$#" -eq 3 ] || fail "the PR head must be a merge commit with exactly two parents"
FORK_PARENT=$2
UPSTREAM_PARENT=$3

git merge-base --is-ancestor "$FORK_PARENT" "$BASE_COMMIT" 2>/dev/null \
  || fail "the merge's first parent is not already contained in the PR base"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-sync-proof.XXXXXX") \
  || fail "temporary proof storage could not be created"
UPSTREAM_REF="refs/fm-fork-sync-proof/upstream-$$"
cleanup() {
  git update-ref -d "$UPSTREAM_REF" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

git fetch --no-tags --force --quiet -- "$UPSTREAM_URL" \
  "$UPSTREAM_BRANCH:$UPSTREAM_REF" \
  || fail "upstream/main could not be fetched read-only"

git merge-base --is-ancestor "$UPSTREAM_PARENT" "$UPSTREAM_REF" 2>/dev/null \
  || fail "the merge's second parent is not reachable from upstream/main"

git rev-list --no-merges "$BASE_COMMIT..$HEAD_COMMIT" > "$TMP_DIR/non-merge-commits" \
  || fail "the PR commit range cannot be determined"
while IFS= read -r commit; do
  [ -n "$commit" ] || continue
  git merge-base --is-ancestor "$commit" "$UPSTREAM_REF" 2>/dev/null \
    || fail "non-merge commit $commit is not reachable from upstream/main"
done < "$TMP_DIR/non-merge-commits"

git merge-base --all "$FORK_PARENT" "$UPSTREAM_PARENT" > "$TMP_DIR/merge-bases" \
  || fail "the merge base between the two parents cannot be determined"
[ "$(wc -l < "$TMP_DIR/merge-bases" | tr -d '[:space:]')" = 1 ] \
  || fail "the merge parents do not have exactly one merge base"
MERGE_BASE=$(sed -n '1p' "$TMP_DIR/merge-bases")

path_changed_between() {
  local from=$1 to=$2 path=$3 rc
  set +e
  git --literal-pathspecs diff --quiet --no-ext-diff --no-renames \
    "$from" "$to" -- "$path"
  rc=$?
  set -e
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) fail "a required path diff could not be determined" ;;
  esac
}

git diff --name-only -z --no-ext-diff --no-renames \
  "$FORK_PARENT" "$HEAD_COMMIT" > "$TMP_DIR/from-fork" \
  || fail "the merge result cannot be compared with its fork parent"
while IFS= read -r -d '' path; do
  path_changed_between "$MERGE_BASE" "$UPSTREAM_PARENT" "$path" \
    || fail "the merge changes '$path' although upstream did not touch it"
done < "$TMP_DIR/from-fork"

git diff --name-only -z --no-ext-diff --no-renames \
  "$UPSTREAM_PARENT" "$HEAD_COMMIT" > "$TMP_DIR/from-upstream" \
  || fail "the merge result cannot be compared with its upstream parent"
while IFS= read -r -d '' path; do
  path_changed_between "$MERGE_BASE" "$FORK_PARENT" "$path" \
    || fail "the merge changes '$path' although the fork did not touch it"
done < "$TMP_DIR/from-upstream"

printf 'Proved fork-sync merge: head %s merges upstream/main parent %s without unrelated authored changes.\n' \
  "$HEAD_COMMIT" "$UPSTREAM_PARENT"
