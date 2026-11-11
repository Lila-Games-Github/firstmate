#!/usr/bin/env bash
# Deliver one durable producer's message into a Playbot lane's chat.
# Usage: fm-lane-send.sh <lane-meta-file> <text>
#
# A Playbot lane task (state/<id>.meta with kind=lane) has no shell endpoint or
# steering inbox, so a durable producer's notice - today the test service's
# completion, handed over by bin/fm-send.sh under FM_SEND_IDEMPOTENT=1 - goes
# into the lane's own chat through bin/fm-playbot-lanes.mjs send_message,
# addressed only by the lane's recorded playbot_project, playbot_workspace, and
# playbot_thread. A record missing the project or thread is refused, never
# guessed from a title or the selected chat.
#
# Exit contract, matching fm-send's inbox plane for durable producers:
#   0  Playbot has the message: delivered, sending, steering, queued, or an
#      unknown verdict. Queued and unknown are never resent, because a resend
#      only grows Playbot's held queue (docs/playbot-lanes.md owns those
#      verdicts); an unknown verdict also queues one firstmate check wake so the
#      lane chat can be confirmed by hand.
#   1  nothing was confirmed delivered: a failed verdict, an unreadable result,
#      a lane-tool error, or a record missing its identity. A resend is
#      appropriate, so the producer's retry and its own undelivered escalation
#      still apply.
# The exact body of every message Playbot accepted is remembered under
# state/<id>.lane-sent/, so a producer replaying an uncertain send of the same
# frozen body exits 0 without sending it twice. Teardown removes that record.
#
# Environment: FM_HOME (required), FM_STATE_OVERRIDE, and
# FM_PLAYBOT_LANES_TOOL to replace bin/fm-playbot-lanes.mjs (tests only).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -ne 2 ] || [ -z "$2" ]; then
  echo "usage: fm-lane-send.sh <lane-meta-file> <text>" >&2
  exit 1
fi
if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-lane-send refuses to resolve a lane without an explicit firstmate home" >&2
  exit 1
fi
META=$1
MESSAGE=$2
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

ID=${META##*/}
ID=${ID%.meta}
if [ ! -f "$META" ] || [ "$(fm_meta_get "$META" kind)" != lane ]; then
  echo "error: $META is not a Playbot lane record (kind=lane); nothing sent" >&2
  exit 1
fi
PROJECT=$(fm_meta_get "$META" playbot_project)
WORKSPACE=$(fm_meta_get "$META" playbot_workspace)
THREAD=$(fm_meta_get "$META" playbot_thread)
if [ -z "$PROJECT" ] || [ -z "$THREAD" ]; then
  echo "error: lane $ID records no playbot_project or playbot_thread in $META; nothing sent rather than guessing the chat" >&2
  exit 1
fi

SENT_DIR="$STATE/$ID.lane-sent"
DIGEST=$(printf '%s' "$MESSAGE" | cksum | tr ' ' '-')
MARKER="$SENT_DIR/$DIGEST"
if [ -f "$MARKER" ] && cmp -s "$MARKER" <(printf '%s' "$MESSAGE"); then
  echo "lane $ID already holds this exact message; not resending"
  exit 0
fi

TOOL=${FM_PLAYBOT_LANES_TOOL:-$SCRIPT_DIR/fm-playbot-lanes.mjs}
ARGS=$(PROJECT="$PROJECT" WORKSPACE="$WORKSPACE" THREAD="$THREAD" MESSAGE="$MESSAGE" node -e '
const a = { project: process.env.PROJECT, thread: process.env.THREAD, message: process.env.MESSAGE };
if (process.env.WORKSPACE) a.workspace = process.env.WORKSPACE;
process.stdout.write(JSON.stringify(a));')
call_rc=0
RESULT=$(printf '%s' "$ARGS" | node --no-warnings "$TOOL" call send_message - 2>&1) || call_rc=$?
if [ "$call_rc" -ne 0 ]; then
  echo "error: send_message to lane $ID chat $THREAD failed (exit $call_rc): $RESULT" >&2
  exit 1
fi
VERDICT=$(RESULT="$RESULT" node -e '
let state = "";
try { state = JSON.parse(process.env.RESULT).structuredContent.delivery.state || ""; } catch {}
process.stdout.write(String(state));')

case "$VERDICT" in
delivered | sending | steering | queued | unknown) ;;
failed)
  echo "error: Playbot refused the message for lane $ID chat $THREAD: $RESULT" >&2
  exit 1
  ;;
*)
  echo "error: send_message to lane $ID chat $THREAD returned no readable delivery verdict: $RESULT" >&2
  exit 1
  ;;
esac

# Playbot has it from here; recording the body only suppresses a replay.
if mkdir -p "$SENT_DIR" 2>/dev/null; then
  tmp=$(mktemp "$SENT_DIR/.tmp.XXXXXX" 2>/dev/null) &&
    printf '%s' "$MESSAGE" >"$tmp" && mv -f "$tmp" "$MARKER" ||
    echo "warning: lane $ID received the message, but its replay record under $SENT_DIR could not be written" >&2
fi

if [ "$VERDICT" = unknown ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  first_line=${MESSAGE%%$'\n'*}
  fm_wake_append check "lane-delivery-unconfirmed $ID $DIGEST" \
    "lane-delivery-unconfirmed task=$ID thread=$THREAD: Playbot accepted a durable notice but confirmed no delivery; check the lane chat before resending: $first_line" ||
    echo "warning: lane $ID delivery is unconfirmed and its check wake could not be queued" >&2
fi
echo "lane $ID chat $THREAD: delivery $VERDICT"
