#!/usr/bin/env bash
# Show or record a task's landing branch under the task meta lock.
# landing_branch= marks the project branch a ship task's work is expected to
# land on instead of the default branch; bin/fm-spawn.sh's header owns the
# field's contract and bin/fm-teardown.sh consumes it in the landed-work test.
# This helper exists for the task that only learns its landing branch after
# spawn (or was spawned before the field existed): it records or corrects the
# field on an EXISTING task without hand-editing state/<id>.meta.
# Usage: fm-landing-branch.sh <task-id>            # print the recorded branch
#        fm-landing-branch.sh <task-id> <branch>   # record/replace the branch
# The show form prints the recorded value and exits 0, or prints nothing and
# exits 3 when no landing branch is recorded.
# The record form refuses a non-ship task (only ship work has a landing
# target), a branch name that fails git check-ref-format, and a branch that
# does not resolve in the recorded project clone as a local branch or an
# origin remote-tracking branch - the same fail-closed validation fm-spawn
# applies to --landing-branch. The meta rewrite is atomic (same-directory
# tmp file plus rename) and holds the task's meta lock throughout, so a
# concurrent relaunch or teardown never reads a half-written record.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || ! fm_task_id_path_safe "$1"; then
  echo "usage: fm-landing-branch.sh <task-id> [<branch>]" >&2
  exit 2
fi
ID=$1
BRANCH=${2-}

META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: no meta for task $ID at $META" >&2
  exit 1
fi

if [ "$#" -eq 1 ]; then
  RECORDED=$(fm_meta_get "$META" landing_branch)
  [ -n "$RECORDED" ] || exit 3
  printf '%s\n' "$RECORDED"
  exit 0
fi

[ -n "$BRANCH" ] || { echo "error: the landing branch must be non-empty" >&2; exit 2; }
git check-ref-format "refs/heads/$BRANCH" >/dev/null 2>&1 || {
  echo "error: '$BRANCH' is not a valid git branch name" >&2
  exit 1
}

META_LOCK=$(fm_meta_lock_path "$META") || { echo "error: cannot derive meta lock for $ID" >&2; exit 1; }
META_LOCK_HELD=0
release_meta_lock() {
  local status=$?
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  return "$status"
}
trap release_meta_lock EXIT
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

KIND=$(fm_meta_get "$META" kind)
[ -n "$KIND" ] || KIND=ship
if [ "$KIND" != ship ]; then
  echo "error: task $ID is kind=$KIND; a landing branch applies only to ship tasks" >&2
  exit 1
fi

PROJ=$(fm_meta_get "$META" project)
if [ -z "$PROJ" ] || [ ! -d "$PROJ" ]; then
  echo "error: task $ID records no usable project clone to validate the branch against" >&2
  exit 1
fi
if ! git -C "$PROJ" rev-parse --quiet --verify "refs/heads/$BRANCH^{commit}" >/dev/null 2>&1 \
  && ! git -C "$PROJ" rev-parse --quiet --verify "refs/remotes/origin/$BRANCH^{commit}" >/dev/null 2>&1; then
  echo "error: '$BRANCH' does not resolve in $PROJ as a local branch or an origin remote-tracking branch" >&2
  exit 1
fi

TMP="$META.landing.tmp.$$"
grep -v '^landing_branch=' "$META" > "$TMP" || true
printf 'landing_branch=%s\n' "$BRANCH" >> "$TMP"
mv -f -- "$TMP" "$META"
printf 'recorded landing_branch=%s for task %s\n' "$BRANCH" "$ID"
