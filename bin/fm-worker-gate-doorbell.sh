#!/usr/bin/env bash
# Send one durable worker doorbell for each attributed no-mistakes gate.
# Usage: fm-worker-gate-doorbell.sh scan
# The watcher invokes scan on its ordinary poll. bin/fm-crew-state.sh owns run
# attribution; fm-send's idempotent inbox writer owns replay deduplication.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CREW_STATE=${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}

case ${1-} in scan) ;; *) echo 'usage: fm-worker-gate-doorbell.sh scan' >&2; exit 2 ;; esac
failed=0
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
  case $kind in ship|scout) ;; *) continue ;; esac
  task=${meta##*/}
  task=${task%.meta}
  verdict=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$CREW_STATE" "$task" 2>/dev/null) || continue
  case $verdict in 'state: parked · source: run-step · '*' · run: '*) ;; *) continue ;; esac
  run=${verdict##*' · run: '}
  case $run in ''|*[!A-Za-z0-9._-]*) continue ;; esac
  gate=${verdict#*' · parked at '}
  gate=${gate%' · run: '*}
  [ -n "$gate" ] || continue
  message="Automatic no-mistakes gate doorbell for run $run: $gate. Read the gate and respond through no-mistakes."
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 \
    "$SCRIPT_DIR/fm-send.sh" "$task" "$message" >/dev/null 2>&1; then
    printf 'worker gate doorbell delivery failed: %s run %s\n' "$task" "$run" >&2
    failed=1
  fi
done
exit "$failed"
