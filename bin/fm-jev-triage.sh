#!/usr/bin/env bash
# fm-jev-triage.sh - classify already-narrowed supervision inputs in one request.
#
# Usage:
#   printf '%s\n' <item> | fm-jev-triage.sh --kind status|wake|review-answer
#   fm-jev-triage.sh --batch [--admitted-lines <file>] < "<kind><TAB><item>" lines
# --admitted-lines writes input line numbers with answers, regardless of confidence.
#
# Both forms make at most one network call, so one drain or one Lavish read
# costs one consultation no matter how many items it presented. Each item gets
# one routine-or-actionable Choice; review answers get a second ruling,
# question, or instruction Choice.
#
# --kind prints "<attention>" or "<attention> <review_kind>" for its one item.
# --batch prints "<input-line-number><TAB><attention>[<TAB><review_kind>]" for
# each item whose returned confidence met the configured floor. That gate is per
# item and belongs to the client, so an unconfident answer costs only its own
# item and the ledger records the same item-by-item outcome.
# Callers may inspect that output, but existing presentation remains
# authoritative in every mode because a mistaken routine verdict must never make
# a wake disappear. This hook is a silent observer: off or unavailable mode
# prints nothing and exits zero, because it runs inside presentation paths where
# a diagnostic line would be noise.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUESTIONS="$SCRIPT_DIR/jev-questions/triage.json"
MAX_ITEM_CHARS=1500
PER_ITEM_OVERHEAD=2200
ENVELOPE_OVERHEAD=1024
MAX_ITEMS_CEILING=50

ADMITTED_LINES=
if [ "$#" -eq 3 ] && [ "$1" = --batch ] && [ "$2" = --admitted-lines ]; then
  ADMITTED_LINES=$3
  : > "$ADMITTED_LINES" || exit 0
  set -- --batch
fi
MODE_FLAG=
KIND=
if [ "${1:-}" = --kind ] && [ $# -eq 2 ]; then
  MODE_FLAG=single
  KIND=$2
  case "$KIND" in status|wake|review-answer) ;; *) exit 0 ;; esac
elif [ "${1:-}" = --batch ] && [ $# -eq 1 ]; then
  MODE_FLAG='batch'
else
  exit 0
fi

MODE=$("$SCRIPT_DIR/fm-jev.sh" mode triage 2>/dev/null || printf 'off\n')
[ "$MODE" != off ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
BUDGET=$("$SCRIPT_DIR/fm-jev.sh" request-budget triage 2>/dev/null || printf '0\n')
case "$BUDGET" in ''|*[!0-9]*) exit 0 ;; esac
[ "$BUDGET" -gt "$ENVELOPE_OVERHEAD" ] || exit 0
MAX_ITEMS=$(( (BUDGET - ENVELOPE_OVERHEAD) / PER_ITEM_OVERHEAD ))
[ "$MAX_ITEMS" -ge 1 ] || MAX_ITEMS=1
[ "$MAX_ITEMS" -le "$MAX_ITEMS_CEILING" ] || MAX_ITEMS=$MAX_ITEMS_CEILING

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-triage.XXXXXX") || exit 0
trap 'rm -rf -- "$TMP_DIR"' EXIT
ITEMS="$TMP_DIR/items.jsonl"
ENVELOPE="$TMP_DIR/envelope.json"
RESULT="$TMP_DIR/result.json"
: > "$ITEMS"

INDEX=0
LINE_NO=0
stage_item() { # <line-number> <kind> <text>
  local line_no=$1 kind=$2 text=$3
  case "$kind" in status|wake|review-answer) ;; *) return 0 ;; esac
  [ -n "$text" ] || return 0
  [ "$INDEX" -lt "$MAX_ITEMS" ] || return 0
  text=${text:0:$MAX_ITEM_CHARS}
  INDEX=$((INDEX + 1))
  jq -cn --arg key "item_$INDEX" --arg kind "$kind" --arg text "$text" --argjson line "$line_no" \
    '{key:$key,kind:$kind,text:$text,line:$line}' >> "$ITEMS" || return 1
}

if [ "$MODE_FLAG" = single ]; then
  ITEM=$(cat) || exit 0
  stage_item 1 "$KIND" "$ITEM" || exit 0
else
  while IFS= read -r line || [ -n "$line" ]; do
    LINE_NO=$((LINE_NO + 1))
    [ -n "$line" ] || continue
    stage_item "$LINE_NO" "${line%%$'\t'*}" "${line#*$'\t'}" || exit 0
  done
fi
[ "$INDEX" -gt 0 ] || exit 0

ESTIMATE=$(( ($(wc -c < "$ITEMS") + 3) / 4 ))
jq -n --slurpfile items "$ITEMS" --argjson estimate "$ESTIMATE" \
  --slurpfile template "$QUESTIONS" '
  def attention_key: .key + "__attention";
  def review_key: .key + "__review_kind";
  ($items | map(.key as $k | {key:$k,value:{kind:.kind,item:.text}}) | from_entries) as $state |
  ($items | map(attention_key)) as $attention_keys |
  (reduce $items[] as $item ({};
     . + {($item | attention_key):$template[0].attention}
     + (if $item.kind == "review-answer" then {($item | review_key):$template[0].review_kind} else {} end)
   )) as $questions |
  (reduce $attention_keys[] as $key ({}; . + {($key):"actionable"})) as $baseline |
  ([$items[].kind] | unique | join("+")) as $subject |
  {request:{state:{items:$state},questions:$questions},
   ledger:{subject:$subject,baseline_decision:$baseline,
     baseline_rationale:"The existing presentation path surfaces every narrowed supervision item and never suppresses it.",
     estimated_big_model_tokens:$estimate,
     verdict:{strategy:"choices",questions:$attention_keys}}}
' > "$ENVELOPE" || exit 0

"$SCRIPT_DIR/fm-jev.sh" consult triage < "$ENVELOPE" > "$RESULT" 2>/dev/null || exit 0
[ "$(jq -r '.status // "unavailable"' "$RESULT" 2>/dev/null)" = available ] || exit 0

if [ -n "$ADMITTED_LINES" ]; then
  jq -r --slurpfile items "$ITEMS" '
    . as $r | $items[] |
    select($r.answers[.key + "__attention"] != null) | .line
  ' "$RESULT" > "$ADMITTED_LINES" || exit 0
fi

# The client owns the per-item confidence gate and records the same per-key
# decision on the ledger row, so printed classifications and recorded evidence
# cannot disagree item by item.
if [ "$MODE_FLAG" = single ]; then
  jq -r --slurpfile items "$ITEMS" '
    . as $r |
    ($items[0]) as $item |
    select($r.qualified[$item.key + "__attention"]) |
    [$r.answers[$item.key + "__attention"].choice,
     (if $item.kind == "review-answer" then $r.answers[$item.key + "__review_kind"].choice else empty end)]
    | join(" ")
  ' "$RESULT"
else
  jq -r --slurpfile items "$ITEMS" '
    . as $r |
    $items[] |
    . as $item |
    select($r.qualified[$item.key + "__attention"]) |
    [($item.line | tostring), $r.answers[$item.key + "__attention"].choice,
     (if $item.kind == "review-answer" then $r.answers[$item.key + "__review_kind"].choice else empty end)]
    | @tsv
  ' "$RESULT"
fi
exit 0
