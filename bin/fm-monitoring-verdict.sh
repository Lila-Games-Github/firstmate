#!/usr/bin/env bash
# Print whether this home's supervision is genuinely down, for the crew board's
# monitoring alert (bin/fm-crew-board-panels.py).
# It applies the same predicate and grace the guards use and invents no rule of
# its own: bin/fm-supervision-lib.sh decides whether the home needs supervision,
# fm_watcher_supervision_verdict (bin/fm-wake-lib.sh) is the model-aware health
# verdict, an open Stop-hook auto-arm claim or a live away-mode daemon with a
# fresh beacon is healthy exactly as bin/fm-turnend-guard.sh treats them.
# Output, one key=value per line:
#   state=ok|down|idle|unavailable   idle: nothing needs supervision;
#                                    unavailable: no beacon was ever written
#   age=<seconds since the last watcher beat, empty when unavailable>
#   afk=none|away|quiet
# Always exits 0; an unreadable state directory reads as unavailable.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

emit() {  # <state> <age>
  local afk=none
  [ -e "$STATE/.afk" ] && afk=$(fm_afk_mode "$STATE")
  printf 'state=%s\nage=%s\nafk=%s\n' "$1" "$2" "$afk"
  exit 0
}

if [ ! -e "$STATE/.last-watcher-beat" ]; then
  fm_supervision_status "$STATE" "$GRACE"
  [ "$FM_SUP_NEEDED" = true ] && emit unavailable ""
  emit idle ""
fi
age=$(fm_path_age "$STATE/.last-watcher-beat")

fm_supervision_status "$STATE" "$GRACE"
[ "$FM_SUP_NEEDED" = true ] || emit idle "$age"

fm_watcher_supervision_verdict "$STATE" "$WATCH" "$GRACE" "$FM_HOME" "$FM_ROOT"
[ "$FM_WATCHER_VERDICT_OK" = true ] && emit ok "$age"
fm_autoarm_claim_open "$STATE" "$GRACE" && emit ok "$age"
AFK_GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
if [ "$age" -lt "$AFK_GRACE" ] && fm_afk_daemon_owns_supervision "$STATE"; then
  emit ok "$age"
fi
emit down "$age"
