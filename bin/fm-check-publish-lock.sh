#!/usr/bin/env bash
# Hold a task's check publication lock until stdin closes.
# Usage: fm-check-publish-lock.sh <state-dir> <task-id> [--task-record]
# --task-record acquires the metadata lock first, matching teardown's ordering,
# so a lane identity and its check can be published against one incarnation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || { [ "$#" -eq 3 ] && [ "$3" != --task-record ]; }; then
  exit 2
fi

STATE=$1
ID=$2
case "$ID" in
  ''|.*|*[!A-Za-z0-9._-]*) exit 2 ;;
esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 2

FM_STATE_OVERRIDE=$STATE
export FM_STATE_OVERRIDE
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

LOCK="$STATE/.$ID.check-publish.lock"
LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
cleanup() {
  if [ "$LOCK_HELD" = 1 ]; then
    fm_lock_release "$LOCK"
    LOCK_HELD=0
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK"
    META_LOCK_HELD=0
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

FM_LOCK_REQUIRE_IDENTITY=1
if [ "${3:-}" = --task-record ]; then
  META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || exit 2
  attempts=50
  while ! fm_lock_try_acquire "$META_LOCK"; do
    attempts=$((attempts - 1))
    [ "$attempts" -gt 0 ] || { echo "timed out waiting for the task metadata lock for state/$ID.meta; retry once the holder finishes" >&2; exit 1; }
    sleep 0.1
  done
  META_LOCK_HELD=1
fi
attempts=50
while ! fm_lock_try_acquire "$LOCK"; do
  attempts=$((attempts - 1))
  [ "$attempts" -gt 0 ] || { echo "timed out waiting for the check publication lock; retry once the holder finishes" >&2; exit 1; }
  sleep 0.1
done
LOCK_HELD=1
printf 'locked\n'
IFS= read -r _ || true
