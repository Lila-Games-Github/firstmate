#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# task's recorded landing branch, or the project's default branch when none is
# recorded, to the crewmate's fm/<id> branch or a lane's recorded or live branch.
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
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# Usage: fm-merge-local.sh <task-id> --receipt <full-suite-receipt> [--base-receipt <full-suite-receipt>]
# The project-agnostic receipt has schema=fm-full-suite.v1, sha=<full SHA>,
# failures=<count>, then one failure=<stable id> line per failure; the complete
# parser contract is owned by bin/fm-landing-health-lib.sh. --receipt must
# name the exact branch SHA to be merged. If the current landing tip is already
# red and has no recorded baseline, --base-receipt names that exact current SHA;
# its failing set is recorded once under data/landing-health/. A red candidate
# lands only when every failure is in that current tip's recorded set. Every red
# tip gets one queued or in-flight make-it-green backlog task for its branch.
# After landing, it runs fm-landing-queue.sh reconcile for that landing branch,
# so the train's next car is steered to the front, including when the landed
# receipt then fails to record and the script exits 3; a failure there only warns.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-landing-health-lib.sh
. "$SCRIPT_DIR/fm-landing-health-lib.sh"
if [ "$#" -lt 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
shift
RECEIPT=
BASE_RECEIPT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --receipt|--base-receipt)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "error: $1 needs a receipt path" >&2; exit 2; }
      if [ "$1" = --receipt ]; then RECEIPT=$2; else BASE_RECEIPT=$2; fi
      shift 2 ;;
    *) echo "error: unknown local merge option $1" >&2; exit 2 ;;
  esac
done
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This precedes reading the task
# record, because the wrong actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
[ -n "$RECEIPT" ] || { echo "error: local merge requires --receipt for the exact branch SHA" >&2; exit 2; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
MERGE_HEALTH_LOCK=
MERGE_RECEIPT_STAGE=
MERGE_BASE_STAGE=
merge_control_cleanup() {
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
  [ -z "$MERGE_HEALTH_LOCK" ] || fm_lock_release "$MERGE_HEALTH_LOCK" || true
  [ -z "$MERGE_RECEIPT_STAGE" ] || rm -f -- "$MERGE_RECEIPT_STAGE"
  [ -z "$MERGE_BASE_STAGE" ] || rm -f -- "$MERGE_BASE_STAGE"
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

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

KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$KIND" = lane ]; then
  WORKTREE=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$WORKTREE" ] || { echo "error: lane task $ID has no worktree path in $META; refusing local merge" >&2; exit 1; }
  if grep -q '^lane_branch=' "$META"; then
    BRANCH=$(grep '^lane_branch=' "$META" | tail -1 | cut -d= -f2-)
    [ -n "$BRANCH" ] || { echo "error: lane task $ID worktree $WORKTREE has an empty recorded lane_branch; refusing local merge" >&2; exit 1; }
  else
    BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ -n "$BRANCH" ] || { echo "error: lane task $ID worktree $WORKTREE has no checked-out branch; refusing local merge" >&2; exit 1; }
  fi
  git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: lane task $ID worktree $WORKTREE branch $BRANCH does not exist in $PROJ" >&2; exit 1; }
else
  BRANCH="fm/$ID"
  git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }
fi

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

hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac

DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
fm_backlog_directory_present "$DATA" "data directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
PROJ_REAL=$(cd "$PROJ" && pwd -P)
HEALTH_KEY=$(fm_health_key "$PROJ_REAL" "$TARGET") || exit 1
MERGE_HEALTH_LOCK="$STATE/.landing-health-$HEALTH_KEY.lock"
fm_lock_acquire_wait "$MERGE_HEALTH_LOCK"
CURRENT_SHA=$(git -C "$PROJ" rev-parse "$TARGET_REF^{commit}") || exit 1
INCOMING_SHA=$(git -C "$PROJ" rev-parse "refs/heads/$BRANCH^{commit}") || exit 1
MERGE_RECEIPT_STAGE=$(mktemp "$STATE/.merge-receipt.XXXXXX") || exit 1
cp -- "$RECEIPT" "$MERGE_RECEIPT_STAGE" || { echo "error: cannot stage full-suite receipt $RECEIPT" >&2; exit 1; }
fm_health_receipt_read "$MERGE_RECEIPT_STAGE" "$INCOMING_SHA" || exit 1
INCOMING_COUNT=$FM_HEALTH_COUNT
INCOMING_SET=$FM_HEALTH_SET
RECORDED_RECEIPT="$DATA/landing-health/$HEALTH_KEY.receipt"
BASELINE_COUNT=0
BASELINE_SET=
BASELINE_PRESENT=0
if [ -f "$RECORDED_RECEIPT" ]; then
  if fm_health_receipt_read "$RECORDED_RECEIPT" "$CURRENT_SHA" 2>/dev/null; then
    BASELINE_PRESENT=1
    BASELINE_COUNT=$FM_HEALTH_COUNT
    BASELINE_SET=$FM_HEALTH_SET
  elif [ -z "$BASE_RECEIPT" ] && [ "$INCOMING_COUNT" -gt 0 ]; then
    echo "error: landing tip $CURRENT_SHA has no current full-suite baseline; supply --base-receipt" >&2
    exit 1
  fi
fi
if [ -n "$BASE_RECEIPT" ]; then
  MERGE_BASE_STAGE=$(mktemp "$STATE/.base-receipt.XXXXXX") || exit 1
  cp -- "$BASE_RECEIPT" "$MERGE_BASE_STAGE" || { echo "error: cannot stage base receipt $BASE_RECEIPT" >&2; exit 1; }
  fm_health_receipt_read "$MERGE_BASE_STAGE" "$CURRENT_SHA" || exit 1
  if [ "$BASELINE_PRESENT" -eq 1 ]; then
    [ "$BASELINE_COUNT" -eq "$FM_HEALTH_COUNT" ] && [ "$BASELINE_SET" = "$FM_HEALTH_SET" ] || {
      echo "error: supplied base receipt conflicts with the failing set already recorded for $CURRENT_SHA" >&2
      exit 1
    }
  else
    BASELINE_COUNT=$FM_HEALTH_COUNT
    BASELINE_SET=$FM_HEALTH_SET
    BASELINE_PRESENT=1
    fm_health_store "$MERGE_BASE_STAGE" "$DATA" "$HEALTH_KEY" || exit 1
  fi
fi
if [ "$INCOMING_COUNT" -gt 0 ] && [ "$BASELINE_COUNT" -gt 0 ]; then
  GREEN_TASK="green-${HEALTH_KEY:0:12}"
  fm_backlog_row_probe "$DATA" "$GREEN_TASK" || true
  case "$FM_BACKLOG_ROW_RESULT" in
    not_found)
      FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" add "$GREEN_TASK" \
        "Make $TARGET green" --kind ship --repo "$(basename "$PROJ_REAL")" --queue \
        --body "Repair the recorded full-suite failures on $TARGET. Current receipt: $RECORDED_RECEIPT. Do not attribute these baseline failures to downstream lanes." >/dev/null || {
          echo "error: could not create make-it-green task $GREEN_TASK; refusing red landing" >&2
          exit 1
        }
      ;;
    found)
      case "$FM_BACKLOG_ROW_STATE" in
        done\ *) FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" reopen "$GREEN_TASK" >/dev/null || exit 1 ;;
      esac
      ;;
    *) echo "error: could not determine make-it-green task $GREEN_TASK: $FM_BACKLOG_ROW_ERROR" >&2; exit 1 ;;
  esac
fi
if [ "$INCOMING_COUNT" -gt 0 ]; then
  [ "$BASELINE_COUNT" -gt 0 ] || {
    echo "error: red candidate $INCOMING_SHA has no recorded failing set on landing tip $CURRENT_SHA; refusing" >&2
    exit 1
  }
  NEW_FAILURES=$(LC_ALL=C comm -23 <(printf '%s\n' "$INCOMING_SET") <(printf '%s\n' "$BASELINE_SET"))
  [ -z "$NEW_FAILURES" ] || {
    printf 'error: red candidate %s introduces failures absent from landing tip %s:\n%s\n' "$INCOMING_SHA" "$CURRENT_SHA" "$NEW_FAILURES" >&2
    exit 1
  }
fi

before=$(git -C "$PROJ" rev-parse --short "$TARGET")
merge_status=0
[ "$(git -C "$PROJ" rev-parse "$TARGET_REF^{commit}")" = "$CURRENT_SHA" ] || {
  echo "error: landing tip moved after full-suite baseline inspection; retry against its new SHA" >&2
  exit 1
}
git -C "$PROJ" merge --ff-only "$INCOMING_SHA" >/dev/null || merge_status=$?
[ "$merge_status" -eq 0 ] || exit "$merge_status"
health_status=0
fm_health_store "$MERGE_RECEIPT_STAGE" "$DATA" "$HEALTH_KEY" || health_status=$?
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
fm_lock_release "$MERGE_HEALTH_LOCK" || true
MERGE_HEALTH_LOCK=
reconcile_landing_queue() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-landing-queue.sh" reconcile "$ID" --project "$PROJ" --landing-branch "$TARGET" \
    || echo "warning: landing SUCCEEDED but the $TARGET landing queue was not reconciled; run bin/fm-landing-queue.sh status for its next car" >&2
}
if [ "$health_status" -ne 0 ]; then
  echo "error: landing SUCCEEDED ($TARGET now at $INCOMING_SHA) but its full-suite receipt could not be recorded; supply --base-receipt for the next landing or re-record the receipt for this tip" >&2
  reconcile_landing_queue
  exit 3
fi
after=$(git -C "$PROJ" rev-parse --short "$TARGET")
echo "merged $BRANCH into local $TARGET ($before -> $after) in $PROJ"
[ "$INCOMING_COUNT" -eq 0 ] || echo "landing tip remains red; make-it-green task $GREEN_TASK is open; baseline receipt $RECORDED_RECEIPT"
reconcile_landing_queue
