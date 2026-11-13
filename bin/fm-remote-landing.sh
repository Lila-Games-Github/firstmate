#!/usr/bin/env bash
# Import a remote local-only worker report into an EXISTING workstation worker.
# Usage: FM_HOME=<main-home> fm-remote-landing.sh import <local-task>
#          --remote-task <remote-task> --branch fm/<remote-task> --head <full-sha>
#        FM_HOME=<main-home> fm-remote-landing.sh rebase <local-task>
#          --remote-task <remote-task> --secondmate <remote-secondmate>
#
# The main worker's existing metadata must name mode=local-only, project,
# worktree and landing_branch. This script neither creates task metadata nor
# changes landing rules: submit the farm from the imported worktree, then use
# fm-landing-queue.sh ready with its receipts and fm-merge-local.sh as usual.
# import fetches ONLY origin's reported task branch and verifies the full head
# before updating the clean workstation worktree's fm/<local-task> branch.
# Existing local work must be an ancestor of the report or equal the last
# imported head in state/<task>.remote-landing-head. Replaced imported heads
# remain under refs/fm-remote-landing/<task>/<sha>; other diverged or dirty work
# is preserved and refused. Repeating an import of that head is safe.
# rebase reads needs-rebase, target_sha and rebase_from from the existing queue;
# it refuses upper cars. On conflict it aborts, publishes only a task-scoped
# fm/<local-task>-landing-target ref, and durably steers the remote secondmate
# with the remote task, fetch ref and target SHA. A failed publish/send exits
# nonzero and may be retried; no failed rebase is acknowledged to the queue.
# Successful rebase acknowledges ready; new evidence still uses the normal farm.
# No landing branch is pushed, and this helper never merges or invents receipts.
set -eu
case "${1:-}" in
  -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:?select the main FM_HOME explicitly}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch 'remote local-only import/rebase'
die() { echo "error: $*" >&2; exit 1; }
[ "$#" -ge 2 ] || die 'expected import|rebase and local task id (see script header)'
ACTION=$1 ID=$2
shift 2
case "$ACTION" in import|rebase) ;; *) die 'expected import or rebase' ;; esac
fm_pr_task_id_valid "$ID" || die 'invalid local task id'
REMOTE_TASK='' BRANCH='' HEAD='' SECONDMATE=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || die "missing value for $1"
  case "$1" in
    --remote-task) REMOTE_TASK=$2 ;;
    --branch) BRANCH=$2 ;;
    --head) HEAD=$2 ;;
    --secondmate) SECONDMATE=$2 ;;
    *) die "unknown option $1" ;;
  esac
  shift 2
done
fm_pr_task_id_valid "$REMOTE_TASK" || die 'invalid remote task id'
LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$LOCK" || die 'could not lock workstation task'
trap 'fm_lock_release "$LOCK"' EXIT
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die 'existing workstation task metadata required'
field() { sed -n "s/^$1=//p" "$META" | tail -1; }
[ "$(field mode)" = local-only ] || die 'workstation task must be local-only'
PROJ=$(field project) WT=$(field worktree) LANDING=$(field landing_branch)
[ -n "$PROJ" ] && [ -n "$WT" ] && [ -n "$LANDING" ] || die 'metadata needs project, worktree and landing_branch'
PROJ=$(cd "$PROJ" && pwd -P) || die 'project unavailable'
WT=$(cd "$WT" && pwd -P) || die 'worktree unavailable'
[ "$PROJ" != "$WT" ] || die 'refusing primary project checkout'
COMMON=$(git -C "$PROJ" rev-parse --git-common-dir)
COMMON=$(cd "$PROJ" && cd "$COMMON" && pwd -P)
WT_COMMON=$(git -C "$WT" rev-parse --git-common-dir)
WT_COMMON=$(cd "$WT" && cd "$WT_COMMON" && pwd -P)
[ "$COMMON" = "$WT_COMMON" ] || die 'worktree does not belong to recorded project'
git check-ref-format "refs/heads/$LANDING" >/dev/null || die 'invalid landing branch'
git -C "$PROJ" rev-parse --verify "refs/heads/$LANDING^{commit}" >/dev/null || die 'landing branch missing'
[ "$LANDING" != "fm/$ID" ] && [ "$LANDING" != "fm/$REMOTE_TASK" ] || die 'task branch equals landing branch'
[ -z "$(git -C "$WT" status --porcelain)" ] || die 'dirty workstation copy; preserve and reconcile its work'
CURRENT_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD || true)
[ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "fm/$ID" ] || die 'worktree owns a different branch'
if [ "$ACTION" = import ]; then
  [ "$BRANCH" = "fm/$REMOTE_TASK" ] || die 'report must name exactly fm/<remote-task>'
  case "$HEAD" in ''|*[!0-9a-f]*) die 'report needs a full lowercase SHA' ;; esac
  [ "${#HEAD}" -eq 40 ] || die 'report needs a full SHA'
  git -C "$WT" fetch --no-tags origin "refs/heads/$BRANCH" || die 'remote task fetch failed'
  FETCHED=$(git -C "$WT" rev-parse 'FETCH_HEAD^{commit}')
  [ "$FETCHED" = "$HEAD" ] || die "report head mismatch: fetched $FETCHED, expected $HEAD"
  OLD=$(git -C "$WT" rev-parse HEAD)
  IMPORT_RECORD="$STATE/$ID.remote-landing-head"
  if ! git -C "$WT" merge-base --is-ancestor HEAD "$HEAD"; then
    [ -f "$IMPORT_RECORD" ] && [ ! -L "$IMPORT_RECORD" ] &&
      [ "$(cat "$IMPORT_RECORD")" = "$OLD" ] || die 'import would discard local commits'
    git -C "$WT" update-ref "refs/fm-remote-landing/$ID/$OLD" "$OLD"
  fi
  if git -C "$WT" show-ref --verify --quiet "refs/heads/fm/$ID"; then
    [ "$(git -C "$WT" rev-parse "refs/heads/fm/$ID")" = "$(git -C "$WT" rev-parse HEAD)" ] || die 'local task branch has other work'
  fi
  git -C "$WT" checkout -q -B "fm/$ID" "$HEAD"
  IMPORT_TMP=$(mktemp "$STATE/.remote-landing-head.XXXXXX")
  printf '%s\n' "$HEAD" > "$IMPORT_TMP"
  mv -f -- "$IMPORT_TMP" "$IMPORT_RECORD"
  printf 'imported: task=%s remote_task=%s branch=%s head=%s worktree=%s\n' "$ID" "$REMOTE_TASK" "$BRANCH" "$HEAD" "$WT"
else
  [ "$CURRENT_BRANCH" = "fm/$ID" ] || die 'rebase requires the imported task branch'
  fm_pr_task_id_valid "$SECONDMATE" || die 'rebase requires --secondmate'
  QUEUE=$("$SCRIPT_DIR/fm-landing-queue.sh" status "$ID" --project "$PROJ" --landing-branch "$LANDING")
  queue_field() { printf '%s\n' "$QUEUE" | sed -n "s/^$1=//p"; }
  [ "$(queue_field status)" = needs-rebase ] || die 'queue has not assigned this car a front rebase'
  TARGET=$(queue_field target_sha) FROM=$(queue_field rebase_from)
  if git -C "$WT" rebase --onto "$TARGET" "$FROM"; then
    "$SCRIPT_DIR/fm-landing-queue.sh" ready "$ID" --project "$PROJ" --landing-branch "$LANDING" \
      --branch "fm/$ID" --head "$(git -C "$WT" rev-parse HEAD)" --target "$TARGET"
  else
    git -C "$WT" rebase --abort || die 'rebase abort failed; preserve workstation state'
    TARGET_BRANCH="fm/$ID-landing-target"
    [ "$LANDING" != "$TARGET_BRANCH" ] || die 'target transport ref equals landing branch'
    git -C "$WT" push origin "$TARGET:refs/heads/$TARGET_BRANCH" || die 'target publication failed; retry conflict handoff'
    "$SCRIPT_DIR/fm-send.sh" "$SECONDMATE" \
      "Remote landing conflict: steer worker $REMOTE_TASK to fetch origin refs/heads/$TARGET_BRANCH, verify target $TARGET, resolve fm/$REMOTE_TASK onto that target, then push only its task branch and report its new full head SHA. Workstation task=$ID; landing=$LANDING."
    echo "conflict: remote_task=$REMOTE_TASK target=$TARGET ref=$TARGET_BRANCH" >&2
    exit 3
  fi
fi
