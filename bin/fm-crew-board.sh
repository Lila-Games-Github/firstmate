#!/usr/bin/env bash
# fm-crew-board.sh - the live crew board: one Lavish page showing what every
# worker of THIS home is doing, kept current as workers report their phases.
#
# Usage:
#   fm-crew-board.sh open
#   fm-crew-board.sh refresh
#   fm-crew-board.sh show
#   fm-crew-board.sh stop
#   fm-crew-board.sh path
#
# open       The one command to build, open, and keep the board current.
#            Refresh the board, serve it as a Lavish session, arm its
#            process-event source, and start the keeper that refreshes it while
#            the session stays open. Idempotent: run it again to reopen a board
#            the captain closed or to restart a keeper that stopped. Prints
#              board: <path>
#              (lavish-axi's session output, then the shared serve and listen
#               lines owned by bin/fm-lavish-board-lib.sh)
#              url: <local session url>
#              remote_url: https://<host>/session/<id>   (one per host)
#              keeper: started <pid> | running <pid>
#            A remote_url line is printed for each host named in
#            LAVISH_AXI_ALLOWED_HOSTS (comma-separated), the hosts the Lavish
#            server already admits, for a home that proxies Lavish over https
#            on that host, for example with `tailscale serve`.
# refresh    Recompose the board payload from a fresh bin/fm-fleet-snapshot.sh
#            read and republish the page only when a row changed, so Lavish
#            live-reloads it exactly when a phase, note, or worker changes. Time
#            in phase ticks in the browser. Prints `changed` or `unchanged`.
# show       Print the rows of the payload the page was last built from, the
#            same records the captain sees, as plain text.
# stop       Stop the keeper; the page and its session are left as they are.
# path       Print the stable board path for this home.
#
# WHAT A ROW IS. Every task metadata record of this home is one live row: task,
# project, the backlog title (else the task id), the worker's own phase and its
# latest note, and how long it has been in that phase. The phase is exactly the
# snapshot's `phase`, which bin/fm-classify-lib.sh folds from the worker's own
# status lines (status_current_phase owns the vocabulary and the fold); this
# board infers nothing. A worker whose record disappears - cleaned up after
# landing, or gone for any other reason - stays on the board as a "finished or
# left" row with its last phase for FM_CREW_BOARD_GONE_SECS (default 43200)
# instead of silently dropping. Phase start is the status log's modification
# time when the board first sees that phase, carried forward while the phase is
# unchanged, so a keeper that was not running reports "at least this long".
#
# THE PAGE AND FIRSTMATE READ THE SAME RECORDS. The payload is composed from the
# fleet snapshot (task metadata, status logs, backlog), written to
# state/crew-board.json, and injected into the shipped template
# (.agents/skills/bearings/assets/crew-board-template.html) unchanged; `show`
# prints that same file. Pointing at a row on the page queues a Lavish prompt
# tagged `crew-point` that carries the row exactly as shown plus the captain's
# optional note; the armed source's runner captures it and publishes an ordinary
# `procevent lavish <source-id> <sequence>` check wake, and
# `bin/fm-procevent-lavish.sh read` presents it. Plain Lavish annotations on a
# row arrive the same way. The source is never bound to the keyed-answer intake:
# pointing is attention, not a decision. Handling that wake is the bearings
# skill's "Crew board" section.
#
# THE KEEPER. A single detached loop per home (state/.crew-board-keeper.lock
# holds its pid) that stats this home's task metadata, status logs, and backlog
# every FM_CREW_BOARD_INTERVAL seconds (default 2), refreshes on any change and
# at least every FM_CREW_BOARD_FULL_SECS (default 60), and exits on its own once
# the board's Lavish session is no longer listed open, which is checked on the
# same full cadence. It reads only this home's state; it never reads or shows
# another home's workers.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-lavish-board-lib.sh
. "$SCRIPT_DIR/fm-lavish-board-lib.sh"

TEMPLATE="${FM_CREW_BOARD_TEMPLATE:-$SCRIPT_DIR/../.agents/skills/bearings/assets/crew-board-template.html}"
PLACEHOLDER='__FM_CREW_BOARD_DATA__'
BOARD_SCHEMA=fm-crew-board.v1
PAYLOAD="$STATE/crew-board.json"
KEEPER_LOCK="$STATE/.crew-board-keeper.lock"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-crew-board: %s\n' "$*" >&2
  exit 1
}

board_path() { printf '%s/.lavish/crew-board.html\n' "$FM_HOME"; }

whole_seconds() {  # <name> <value> <default>
  case "${2:-}" in
    '') printf '%s\n' "$3" ;;
    *[!0-9]*|0) fail "$1 must be a positive whole number of seconds: $2" ;;
    *) printf '%s\n' "$2" ;;
  esac
}

# Modification time of each task's status log, else its metadata record, as a
# JSON object keyed by task id: the observed time a newly seen phase began.
status_mtimes_json() {  # <snapshot.json>
  local id f mtime
  jq -r '.tasks[]?.id' "$1" | while IFS= read -r id; do
    case "$id" in ''|*/*) continue ;; esac
    f="$STATE/$id.status"
    [ -f "$f" ] || f="$STATE/$id.meta"
    mtime=$(perl -e '@s = stat($ARGV[0]) or exit 1; print $s[9]' "$f" 2>/dev/null) || continue
    jq -n --arg id "$id" --argjson m "$mtime" '{($id): $m}'
  done | jq -s 'add // {}'
}

# Compose the next payload from a snapshot and the previous payload. Rows keep
# their phase start while the phase is unchanged, a row whose task record is gone
# turns into a "left" row, and a left row older than the retention drops.
compose_payload() {  # <snapshot.json> <previous.json> <mtimes.json> <now> <gone-secs>
  jq -n \
    --slurpfile snap "$1" --slurpfile prev "$2" --slurpfile mt "$3" \
    --argjson now "$4" --argjson keep "$5" --arg home "${FM_HOME##*/}" --arg schema "$BOARD_SCHEMA" '
    ($snap[0]) as $s | ($prev[0] // {}) as $p | ($mt[0] // {}) as $m
    | ([$p.rows[]? | {key: .id, value: .}] | from_entries) as $old
    | [ $s.tasks[]? | . as $t
        | ($old[$t.id] // null) as $o
        | ($t.phase.name // "starting") as $phase
        | {
            id: $t.id,
            kind: ($t.kind // ""),
            project: ($t.backlog.repo // (($t.project // "") | split("/") | last) // ""),
            title: ($t.backlog.title // $t.id),
            phase: $phase,
            phase_since: (if $o != null and ($o.gone | not) and $o.phase == $phase
                          then $o.phase_since else ($m[$t.id] // $now) end),
            note: ($t.phase.note // ""),
            pr_url: ($t.pr.url // null),
            endpoint: ($t.endpoint.status // "unknown"),
            gone: false,
            left_at: null
          } ] as $live
    | ([$live[].id]) as $live_ids
    | [ $p.rows[]?
        | select(.id as $id | $live_ids | index($id) | not)
        | if .gone then . else . + {gone: true, left_at: $now} end
        | select(($now - .left_at) < $keep) ] as $gone
    | {
        schema: $schema,
        home: $home,
        generated: ($now | todate),
        generated_epoch: $now,
        rows: (($live | sort_by(.id)) + ($gone | sort_by(.id)))
      }'
}

validate_payload() {  # <payload.json>
  jq -e --arg schema "$BOARD_SCHEMA" '
    def str: type == "string";
    .schema == $schema and (.rows | type == "array")
    and ([.rows[] | (.id | str and length > 0) and (.phase | str and length > 0)
          and (.title | str) and (.note | str) and (.gone | type == "boolean")
          and (.phase_since | type == "number")] | all)
  ' "$1" >/dev/null
}

# Inject the payload into a fresh copy of the template and publish it
# atomically. `<` is escaped as < so a note can never close the data block.
publish_page() {  # <payload.json>
  local board json tmp extracted
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "crew board template is missing: $TEMPLATE"
  [ "$(grep -cxF "$PLACEHOLDER" "$TEMPLATE")" -eq 1 ] \
    || fail "crew board template does not carry exactly one data slot: $TEMPLATE"
  json=$(jq -c . "$1") || fail "cannot compact the crew board data"
  json=${json//</\\u003c}
  board=$(board_path)
  (umask 077; mkdir -p "${board%/*}") || fail "cannot create ${board%/*}"
  tmp=$(umask 077; mktemp "${board%/*}/.crew-board.XXXXXX") || fail "cannot stage the crew board"
  if ! BOARD_JSON="$json" perl -pe "s/^\\Q$PLACEHOLDER\\E\$/\$ENV{BOARD_JSON}/" "$TEMPLATE" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot inject the crew board data"
  fi
  extracted=$(sed -n '/<script id="crew-board-data" type="application\/json">/,/<\/script>/p' "$tmp" | sed '1d;$d')
  if ! printf '%s\n' "$extracted" | jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' >/dev/null 2>&1; then
    rm -f -- "$tmp"
    fail "the built crew board does not carry a readable $BOARD_SCHEMA payload"
  fi
  if ! { chmod 0600 "$tmp" && mv -f -- "$tmp" "$board"; }; then
    rm -f -- "$tmp"
    fail "cannot publish the crew board"
  fi
}

command_refresh() {
  local work snap prev mtimes next now keep changed=1
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -d "$STATE" ] || fail "no state directory for this home: $STATE"
  keep=$(whole_seconds FM_CREW_BOARD_GONE_SECS "${FM_CREW_BOARD_GONE_SECS:-}" 43200) || exit 1
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-board.XXXXXX") || fail "cannot stage the crew board refresh"
  # shellcheck disable=SC2064 # expand now, while the staging path is set
  trap "rm -rf -- '$work'" EXIT
  snap="$work/snapshot.json"; prev="$work/previous.json"; mtimes="$work/mtimes.json"; next="$work/next.json"
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$snap" 2>/dev/null \
    || ! jq -e '.tasks | type == "array"' "$snap" >/dev/null 2>&1; then
    fail "cannot read the fleet snapshot for this home"
  fi
  if [ -f "$PAYLOAD" ] && jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' "$PAYLOAD" >/dev/null 2>&1; then
    cp -- "$PAYLOAD" "$prev" || fail "cannot read the previous crew board payload"
  else
    printf '{}\n' > "$prev"
  fi
  status_mtimes_json "$snap" > "$mtimes" || fail "cannot read status log times"
  now=$(date +%s)
  compose_payload "$snap" "$prev" "$mtimes" "$now" "$keep" > "$next" \
    || fail "cannot compose the crew board payload"
  validate_payload "$next" || fail "the composed crew board payload does not satisfy $BOARD_SCHEMA"
  if jq -e --slurpfile a "$next" '.rows == $a[0].rows' "$prev" >/dev/null 2>&1 && [ -f "$(board_path)" ]; then
    changed=0
  fi
  if [ "$changed" -eq 1 ]; then
    if ! { (umask 077; cp -- "$next" "$PAYLOAD.tmp.$$") && mv -f -- "$PAYLOAD.tmp.$$" "$PAYLOAD"; }; then
      rm -f -- "$PAYLOAD.tmp.$$"
      fail "cannot record the crew board payload"
    fi
    publish_page "$PAYLOAD"
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

command_show() {
  [ -f "$PAYLOAD" ] || fail "no crew board has been built for this home yet; run: fm-crew-board.sh open"
  jq -r --argjson now "$(date +%s)" '
    def dur: if . < 60 then "<1m" elif . < 3600 then "\((. / 60) | floor)m"
             elif . < 86400 then "\((. / 3600) | floor)h\(((. % 3600) / 60) | floor)m"
             else "\((. / 86400) | floor)d\(((. % 86400) / 3600) | floor)h" end;
    "crew board \(.home) - built \(.generated)",
    (.rows[] | [
      .id,
      (if .gone then "left(\(.phase))" else .phase end),
      (if .gone then "left \(($now - .left_at) | dur) ago" else "for \(($now - .phase_since) | dur)" end),
      (.project // ""),
      .title,
      .note,
      (.pr_url // "")
    ] | join("\t"))
  ' "$PAYLOAD"
}

keeper_pid() {  # prints the live keeper pid, or fails
  local pid args
  pid=$(cat "$KEEPER_LOCK/pid" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case "$args" in *fm-crew-board.sh*keep*) printf '%s\n' "$pid" ;; *) return 1 ;; esac
}

# Clear a lock a dead keeper left behind. Only its own regular pid file is
# removed, so anything foreign keeps the directory and the claim fails.
reclaim_keeper_lock() {
  [ -d "$KEEPER_LOCK" ] && [ ! -L "$KEEPER_LOCK" ] || return 0
  keeper_pid >/dev/null && return 1
  if [ -f "$KEEPER_LOCK/pid" ] && [ ! -L "$KEEPER_LOCK/pid" ]; then rm -f -- "$KEEPER_LOCK/pid"; fi
  rmdir -- "$KEEPER_LOCK" 2>/dev/null
}

session_listed_open() {
  local real
  real=$(board_realpath "$(board_path)") || return 1
  lavish_session_listed_open "$real"
}

tree_signature() {
  perl -e 'for (@ARGV) { my @s = stat($_) or next; print "$_ $s[7] $s[9]\n" }' \
    "$STATE"/*.meta "$STATE"/*.status "$DATA/backlog.md" 2>/dev/null | cksum
}

command_keep() {
  local interval full sig last_sig='' last_full=0 now
  interval=$(whole_seconds FM_CREW_BOARD_INTERVAL "${FM_CREW_BOARD_INTERVAL:-}" 2) || exit 1
  full=$(whole_seconds FM_CREW_BOARD_FULL_SECS "${FM_CREW_BOARD_FULL_SECS:-}" 60) || exit 1
  reclaim_keeper_lock || exit 0
  mkdir -- "$KEEPER_LOCK" 2>/dev/null || exit 0
  printf '%s\n' "$$" > "$KEEPER_LOCK/pid"
  # Releasing the lock must not be re-entered by a repeated stop signal.
  trap 'trap "" TERM INT HUP; rm -f -- "$KEEPER_LOCK/pid"; rmdir -- "$KEEPER_LOCK" 2>/dev/null; exit 0' TERM INT HUP
  while :; do
    now=$(date +%s)
    sig=$(tree_signature)
    if [ "$sig" != "$last_sig" ] || [ $((now - last_full)) -ge "$full" ]; then
      "$SCRIPT_DIR/fm-crew-board.sh" refresh >/dev/null 2>&1 || true
      last_sig=$sig
      if [ $((now - last_full)) -ge "$full" ]; then
        session_listed_open || break
        last_full=$now
      fi
    fi
    sleep "$interval"
  done
  trap '' TERM INT HUP
  rm -f -- "$KEEPER_LOCK/pid"
  rmdir -- "$KEEPER_LOCK" 2>/dev/null
}

start_keeper() {
  local pid i=0
  if pid=$(keeper_pid); then
    printf 'keeper: running %s\n' "$pid"
    return 0
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid "$SCRIPT_DIR/fm-crew-board.sh" keep </dev/null >/dev/null 2>&1 &
  else
    perl -MPOSIX=setsid -e 'fork and exit 0; setsid(); exec @ARGV or exit 1' "$SCRIPT_DIR/fm-crew-board.sh" keep </dev/null >/dev/null 2>&1 &
  fi
  while [ "$i" -lt 50 ]; do
    if pid=$(keeper_pid); then
      printf 'keeper: started %s\n' "$pid"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  fail "the crew board keeper did not start"
}

command_stop() {
  local pid i=0
  if ! pid=$(keeper_pid); then
    reclaim_keeper_lock || true
    printf 'keeper: not running\n'
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then fail "the crew board keeper $pid did not stop"; fi
  printf 'keeper: stopped %s\n' "$pid"
}

command_open() {
  local board sid id host hosts=${LAVISH_AXI_ALLOWED_HOSTS:-}
  command_refresh >/dev/null
  board=$(board_path)
  printf 'board: %s\n' "$board"
  sid=$("$SCRIPT_DIR/fm-procevent-lavish.sh" source-id "$board") \
    || fail "cannot derive the crew board source id"
  fm_lavish_board_serve "$board"
  fm_lavish_board_listen "$board" "$sid"
  if [ -n "${BOARD_SESSION_URL:-}" ]; then
    printf 'url: %s\n' "$BOARD_SESSION_URL"
    id=${BOARD_SESSION_URL##*/session/}
    id=${id%%[/?#]*}
    if [ -n "$id" ] && [ "$id" != "$BOARD_SESSION_URL" ]; then
      for host in ${hosts//,/ }; do
        case "$host" in ''|*[!A-Za-z0-9.:-]*) continue ;; esac
        printf 'remote_url: https://%s/session/%s\n' "$host" "$id"
      done
    fi
  fi
  start_keeper
}

case "${1-}" in
  open) command_open ;;
  refresh) command_refresh ;;
  show) command_show ;;
  stop) command_stop ;;
  keep) command_keep ;;
  path) board_path ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
