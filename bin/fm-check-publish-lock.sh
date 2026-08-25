#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -ne 2 ]; then
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
cleanup() {
  if [ "$LOCK_HELD" = 1 ]; then
    fm_lock_release "$LOCK"
    LOCK_HELD=0
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

attempts=50
FM_LOCK_REQUIRE_IDENTITY=1
while ! fm_lock_try_acquire "$LOCK"; do
  attempts=$((attempts - 1))
  [ "$attempts" -gt 0 ] || exit 1
  sleep 0.1
done
LOCK_HELD=1
printf 'locked\n'
IFS= read -r _ || true
