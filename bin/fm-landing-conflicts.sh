#!/usr/bin/env bash
# Check this home's unlanded task branches after a landing and report conflicts.
# Usage: fm-landing-conflicts.sh <project> <landing-branch> [--remote]
# --remote reads the newly landed tip from origin in a disposable clone (PR
# merges); without it the current local landing ref is used (local-only merges).
# The checker never changes the project checkout, its refs, or worker worktrees.
# Each changed branch/tip/outcome is reported once through fm-send and the
# existing supervisor wake queue. Missing refs or a failed trial merge are
# reported as unknown. The per-task marker is only a notification receipt.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:?FM_HOME must select the owning home}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo 'usage: fm-landing-conflicts.sh <project> <landing-branch> [--remote]' >&2; exit 2; }
PROJECT=$1 LANDING=$2
REMOTE=${3-}
case "$REMOTE" in ''|--remote) ;; *) echo 'error: unknown option' >&2; exit 2 ;; esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo 'error: state unavailable' >&2; exit 1; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
REPORT=$(mktemp "$STATE/.landing-conflicts.XXXXXX") || exit 1
# shellcheck disable=SC2329 # EXIT trap invokes this function.
cleanup() { rm -f -- "$REPORT"; }
trap cleanup EXIT
if [ "$REMOTE" = --remote ]; then
  python3 "$SCRIPT_DIR/fm-landing-conflicts.py" "$FM_HOME" "$STATE" "$PROJECT" "$LANDING" --remote > "$REPORT" || exit 1
else
  python3 "$SCRIPT_DIR/fm-landing-conflicts.py" "$FM_HOME" "$STATE" "$PROJECT" "$LANDING" > "$REPORT" || exit 1
fi
SEND_BIN=${FM_LANDING_CONFLICT_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}
failed=0
while IFS=$'\t' read -r id branch head tip result paths; do
  [ -n "$id" ] || continue
  event=$(printf '%s\n' "$branch" "$head" "$tip" "$result" "$paths" | git hash-object --stdin) || { failed=1; continue; }
  marker="$STATE/$id.landing-conflict-notified"
  [ ! -L "$marker" ] || { echo "warning: symlink notification marker for $id" >&2; failed=1; continue; }
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$event" ]; then continue; fi
  if [ "$result" = conflict ]; then
    note="Landing trial merge conflict: task=$id branch=$branch head=$head landing=$LANDING tip=$tip paths=$paths. Inspect and resolve the named files before landing; do not rebase automatically."
  else
    note="Landing trial merge unknown: task=$id branch=$branch head=$head landing=$LANDING tip=$tip. A ref or trial merge could not be read; inspect before treating this branch as conflict-free."
  fi
  sent=0 woke=0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 "$SEND_BIN" "$id" "$note" >/dev/null || sent=1
  fm_wake_append check "landing-conflict-$id-$event" "check: $note" || woke=1
  if [ "$sent" -eq 0 ] && [ "$woke" -eq 0 ]; then
    tmp=$(mktemp "$STATE/.landing-conflict-notified.XXXXXX") || { failed=1; continue; }
    printf '%s\n' "$event" > "$tmp"
    mv -f -- "$tmp" "$marker"
  else
    failed=1
    echo "warning: landing trial merge notice for $id was not fully delivered; retry later" >&2
  fi
  printf '%s task=%s branch=%s paths=%s\n' "$result" "$id" "$branch" "$paths"
done < "$REPORT"
exit "$failed"
