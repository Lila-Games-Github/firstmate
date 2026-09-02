#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# task's recorded landing branch, or the project's default branch when none is
# recorded, to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only when the main checkout is clean and already on the
# resolved target. A recorded target must resolve as a local branch; the script
# refuses instead of falling back when it does not. The merge is fast-forward
# only, so a diverged task branch is refused. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
LANDING_BRANCH=$(grep '^landing_branch=' "$META" | tail -1 | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

if [ -n "$LANDING_BRANCH" ]; then
  TARGET=$LANDING_BRANCH
  TARGET_REF="refs/heads/$LANDING_BRANCH"
  git -C "$PROJ" rev-parse --verify --quiet "$TARGET_REF^{commit}" >/dev/null || {
    echo "error: recorded landing branch $LANDING_BRANCH does not exist in $PROJ; refusing to fall back to the default branch" >&2
    exit 1
  }
else
  TARGET=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
  TARGET_REF="refs/heads/$TARGET"
fi

# The project's main checkout must be on its resolved landing branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$TARGET" ] || { echo "error: $PROJ is on '$cur', expected landing branch '$TARGET'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: TARGET must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$TARGET_REF" "refs/heads/$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $TARGET (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $TARGET, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$TARGET_REF")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$TARGET_REF")
echo "merged $BRANCH into local $TARGET ($before -> $after) in $PROJ"
