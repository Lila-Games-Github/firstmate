#!/usr/bin/env bash
# fm-crew-board.sh - build and display this home's live terminal crew board.
#
# Usage:
#   fm-crew-board.sh tui       Open the live terminal dashboard (alias: open).
#   fm-crew-board.sh refresh   Update state/crew-board.json from worker reports.
#   fm-crew-board.sh show      Print the rows last built from those reports.
#   fm-crew-board.sh stop      Close a running terminal dashboard.
#
# The TUI is a Go program under bin/fm-crew-board-tui. This command builds it
# into this home's private state/ directory when sources change and runs it.
# bin/firstmate is the one-word launcher; bin/fm-install-firstmate-cli.sh adds
# that launcher to PATH without replacing an unrelated executable.
# In the TUI, 1/2/3/4 switch NOW/TESTING/PLANNING/QUESTIONS, j/k move
# rows and at row edges move vertically between panels, h/l move spatially,
# Tab/Shift-Tab cycle panels, gg/G and Ctrl-u/Ctrl-d jump within a panel, Enter/o expands a row,
# O focuses the selected worker's recorded pane (or prints an attach command),
# za/Space collapses a panel, Alt-1..9 selects a row, / filters,
# i or : focuses the note line,
# Esc leaves input, ? shows help, and q or :q quits.
#
# Each task metadata record is one live row. The phase and note come from the
# fleet snapshot's fold of the worker's own status lines. A missing task remains
# as a gone row for FM_CREW_BOARD_GONE_SECS (default 43200). TUI refreshes every
# 2 seconds; it reads the same payload as show. Optional local panel records
# come from bin/fm-crew-board-panels.py. The TUI sends notes through fm-inbox.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BOARD_SCHEMA=fm-crew-board.v1
PAYLOAD="$STATE/crew-board.json"
GO_DIR="$SCRIPT_DIR/fm-crew-board-tui"
GO_BIN="$STATE/.crew-board-tui-bin"

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
fail() { printf 'fm-crew-board: %s\n' "$*" >&2; exit 1; }

whole_seconds() {
  case "${2:-}" in
    '') printf '%s\n' "$3" ;;
    *[!0-9]*|0) fail "$1 must be a positive whole number of seconds: $2" ;;
    *) printf '%s\n' "$2" ;;
  esac
}

status_mtimes_json() {
  local id f mtime
  jq -r '.tasks[]?.id' "$1" | while IFS= read -r id; do
    case "$id" in ''|*/*) continue ;; esac
    f="$STATE/$id.status"
    [ -f "$f" ] || f="$STATE/$id.meta"
    mtime=$(perl -e '@s = stat($ARGV[0]) or exit 1; print $s[9]' "$f" 2>/dev/null) || continue
    jq -n --arg id "$id" --argjson m "$mtime" '{($id): $m}'
  done | jq -s 'add // {}'
}

compose_payload() {
  jq -n \
    --slurpfile snap "$1" --slurpfile prev "$2" --slurpfile mt "$3" --slurpfile panel "$6" \
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
        rows: (($live | sort_by(.id)) + ($gone | sort_by(.id))),
        panels: $panel[0]
      }'
}

validate_payload() {
  jq -e --arg schema "$BOARD_SCHEMA" '
    def str: type == "string";
    .schema == $schema and (.rows | type == "array") and (.panels | type == "object")
    and ([.rows[] | (.id | str and length > 0) and (.phase | str and length > 0)
          and (.title | str) and (.note | str) and (.gone | type == "boolean")
          and (.phase_since | type == "number")] | all)
  ' "$1" >/dev/null
}

command_refresh() {
  local work snap prev mtimes panels next now keep changed=1
  command -v jq >/dev/null 2>&1 || fail "jq is required"
  [ -d "$STATE" ] || fail "no state directory for this home: $STATE"
  keep=$(whole_seconds FM_CREW_BOARD_GONE_SECS "${FM_CREW_BOARD_GONE_SECS:-}" 43200)
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-board.XXXXXX") || fail "cannot stage the crew board refresh"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$work'" EXIT
  snap="$work/snapshot.json"; prev="$work/previous.json"; mtimes="$work/mtimes.json"; panels="$work/panels.json"; next="$work/next.json"
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$snap" 2>/dev/null \
    || ! jq -e '.tasks | type == "array"' "$snap" >/dev/null 2>&1; then
    fail "cannot read the fleet snapshot for this home"
  fi
  if [ -f "$PAYLOAD" ] && jq -e --arg schema "$BOARD_SCHEMA" '.schema == $schema' "$PAYLOAD" >/dev/null 2>&1; then
    cp -- "$PAYLOAD" "$prev" || fail "cannot read the previous crew board payload"
  else
    printf '{}\n' > "$prev"
  fi
  status_mtimes_json "$snap" > "$mtimes" || fail "cannot read status log times"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    python3 "$SCRIPT_DIR/fm-crew-board-panels.py" "$snap" > "$panels" \
    || fail "cannot compose local crew board panels"
  now=$(date +%s)
  compose_payload "$snap" "$prev" "$mtimes" "$now" "$keep" "$panels" > "$next" \
    || fail "cannot compose the crew board payload"
  validate_payload "$next" || fail "the composed crew board payload does not satisfy $BOARD_SCHEMA"
  if jq -e --slurpfile a "$next" '.rows == $a[0].rows and .panels == $a[0].panels' "$prev" >/dev/null 2>&1; then changed=0; fi
  if [ "$changed" -eq 1 ]; then
    if ! { (umask 077; cp -- "$next" "$PAYLOAD.tmp.$$") && mv -f -- "$PAYLOAD.tmp.$$" "$PAYLOAD"; }; then
      rm -f -- "$PAYLOAD.tmp.$$"
      fail "cannot record the crew board payload"
    fi
    printf 'changed\n'
  else
    printf 'unchanged\n'
  fi
}

command_show() {
  [ -f "$PAYLOAD" ] || fail "no crew board has been built for this home yet; run: fm-crew-board.sh refresh"
  jq -r --argjson now "$(date +%s)" '
    def dur: if . < 60 then "<1m" elif . < 3600 then "\((. / 60) | floor)m"
             elif . < 86400 then "\((. / 3600) | floor)h\(((. % 3600) / 60) | floor)m"
             else "\((. / 86400) | floor)d\(((. % 86400) / 3600) | floor)h" end;
    "crew board \(.home) - built \(.generated)",
    (.rows[] | [
      .id,
      (if .gone then "left(\(.phase))" else .phase end),
      (if .gone then "left \(($now - .left_at) | dur) ago" else "for \(($now - .phase_since) | dur)" end),
      (.project // ""), .title, .note, (.pr_url // "")
    ] | join("\t"))
  ' "$PAYLOAD"
}

build_tui_if_needed() {
  local source tmp
  command -v go >/dev/null 2>&1 || fail "Go 1.27 or newer is required to build the crew board"
  if [ -x "$GO_BIN" ]; then
    for source in "$GO_DIR"/*.go "$GO_DIR/go.mod" "$GO_DIR/go.sum"; do
      [ "$source" -nt "$GO_BIN" ] && break
    done
    [ "$source" -nt "$GO_BIN" ] || return 0
  fi
  tmp="$GO_BIN.tmp.$$"
  (cd "$GO_DIR" && go build -o "$tmp" .) || { rm -f -- "$tmp"; fail "Go crew board build failed"; }
  chmod 0700 "$tmp"
  mv -f -- "$tmp" "$GO_BIN"
}

command_tui() {
  [ -t 0 ] && [ -t 1 ] || fail "tui requires an interactive terminal"
  command_refresh >/dev/null
  build_tui_if_needed
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CODE_ROOT="$FM_ROOT" "$GO_BIN" run
}

case "${1-}" in
  tui|open) command_tui ;;
  refresh) command_refresh ;;
  show) command_show ;;
  stop) if [ -x "$GO_BIN" ]; then FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$GO_BIN" stop; else printf 'tui: not running\n'; fi ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
