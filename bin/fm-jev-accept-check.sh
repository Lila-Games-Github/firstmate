#!/usr/bin/env bash
# fm-jev-accept-check.sh - observe one worker report against brief acceptance material.
#
# Usage: fm-jev-accept-check.sh <task-id>
#
# Reads data/<id>/brief.md and data/<id>/report.md, falling back to the newest
# `done:` status line when no report exists. Markdown sections whose headings
# contain "acceptance" or "definition of done" own criterion extraction; each
# list item in those sections becomes one Noul in one Jev request. If such a
# section has prose but no list, the section is one criterion.
#
# When Jev is available, writes data/<id>/acceptance.json atomically. Shadow
# mode records the criterion verdicts only. Active mode additionally records an
# `advisory` naming the criteria Jev found unmet above the configured confidence
# floor, which bin/fm-jev-report.sh also surfaces from the ledger.
#
# No Jev adapter ever writes a task's status file: a `note:` there is a status
# event that would supersede the worker's terminal `done:` line and change
# supervision classification, and this observer never changes task lifecycle.
#
# Off or unavailable mode names the reason on stderr and exits zero without
# writing anything or printing on stdout.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
QUESTIONS="$SCRIPT_DIR/jev-questions/accept-check.json"

case "${1:-}" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
[ "$#" -eq 1 ] || exit 0
ID=$1
# shellcheck source=bin/fm-jev-adapter-lib.sh
. "$SCRIPT_DIR/fm-jev-adapter-lib.sh"
fm_jev_adapter_ready accept-check || exit 0
MODE=$FM_JEV_ADAPTER_MODE
command -v jq >/dev/null 2>&1 || exit 0

BRIEF="$DATA/$ID/brief.md"
REPORT="$DATA/$ID/report.md"
STATUS_FILE="$STATE/$ID.status"
[ -f "$BRIEF" ] && [ -r "$BRIEF" ] && [ ! -L "$BRIEF" ] || exit 0

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-accept.XXXXXX") || exit 0
trap 'rm -rf -- "$TMP_DIR"' EXIT
MATERIAL="$TMP_DIR/material"
CRITERIA_LINES="$TMP_DIR/criteria-lines"
CRITERIA_JSON="$TMP_DIR/criteria.json"
ENVELOPE="$TMP_DIR/envelope.json"
RESULT="$TMP_DIR/result.json"
REPORT_TEXT=

awk '
  function heading_level(line, copy) { copy=line; sub(/[^#].*$/, "", copy); return length(copy) }
  function lower(s) { return tolower(s) }
  /^#{1,6}[[:space:]]/ {
    level=heading_level($0)
    title=$0; sub(/^#+[[:space:]]+/, "", title)
    if (in_section && level <= section_level) in_section=0
    if (lower(title) ~ /acceptance|definition of done/) {
      in_section=1
      section_level=level
      print ""
    }
    next
  }
  in_section { print }
' "$BRIEF" > "$MATERIAL"
[ -s "$MATERIAL" ] || exit 0

awk '
  /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/ {
    line=$0
    sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/, "", line)
    if (line ~ /[^[:space:]]/) print line
  }
' "$MATERIAL" > "$CRITERIA_LINES"
if [ ! -s "$CRITERIA_LINES" ]; then
  awk 'NF { if (out != "") out=out " "; out=out $0 } END { if (out != "") print out }' \
    "$MATERIAL" > "$CRITERIA_LINES"
fi
[ -s "$CRITERIA_LINES" ] || exit 0
jq -Rsc 'split("\n") | map(select(length > 0))' < "$CRITERIA_LINES" > "$CRITERIA_JSON" || exit 0

if [ -f "$REPORT" ] && [ -r "$REPORT" ] && [ ! -L "$REPORT" ]; then
  REPORT_TEXT=$(cat "$REPORT") || exit 0
elif [ -f "$STATUS_FILE" ] && [ -r "$STATUS_FILE" ] && [ ! -L "$STATUS_FILE" ]; then
  REPORT_TEXT=$(awk '/^[[:space:]]*done[[:space:]]*:/ { line=$0 } END { print line }' "$STATUS_FILE")
fi
[ -n "$REPORT_TEXT" ] || exit 0

ESTIMATE=$(( (${#REPORT_TEXT} + $(wc -c < "$MATERIAL") + 3) / 4 ))
jq -n --arg report "$REPORT_TEXT" --arg subject "$ID" --argjson estimate "$ESTIMATE" \
  --slurpfile criteria "$CRITERIA_JSON" --slurpfile template "$QUESTIONS" '
  ($criteria[0] | to_entries | map({key:("criterion_" + ((.key + 1) | tostring)), value:.value}) | from_entries) as $named |
  ($named | keys) as $keys |
  {request:{
     state:{acceptance_criteria:$named, report:$report},
     questions:(reduce $keys[] as $key ({};
       . + {($key):($template[0].criterion
         | .instructions |= gsub("\\{criterion_key\\}"; $key))}))
   },
   ledger:{subject:$subject,baseline_decision:null,
     baseline_rationale:"The existing completion path performs human review and has no automatic acceptance decision.",
     estimated_big_model_tokens:$estimate,
     verdict:{strategy:"all_noul",questions:$keys,positive_label:"accepted",negative_label:"rejected"}}}
' > "$ENVELOPE" || exit 0

"$SCRIPT_DIR/fm-jev.sh" consult accept-check < "$ENVELOPE" > "$RESULT" 2>/dev/null || exit 0
[ "$(jq -r '.status // "unavailable"' "$RESULT" 2>/dev/null)" = available ] || exit 0

OUT="$DATA/$ID/acceptance.json"
OUT_TMP="$DATA/$ID/.acceptance.json.tmp.$$"
mkdir -p "$DATA/$ID" || exit 0
jq -n --arg task "$ID" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg mode "$MODE" \
  --slurpfile criteria "$CRITERIA_JSON" --slurpfile result "$RESULT" '
  ($result[0]) as $r |
  ($criteria[0] | to_entries | map({key:("criterion_" + ((.key + 1) | tostring)), value:.value}) | from_entries) as $named |
  [$named | to_entries[] |
    {id:.key,text:.value,probability:$r.answers[.key].noul,
     met:(if $r.answers[.key].noul >= $r.confidence_floor then true
          elif (1 - $r.answers[.key].noul) >= $r.confidence_floor then false
          else null end)}] as $criteria_rows |
  ([$criteria_rows[] | select(.met == false) | .id]) as $unmet |
  {schema_version:1,task_id:$task,generated_at:$generated,consultation_id:$r.consultation_id,
   mode:$r.mode,model:$r.model,verdict:$r.verdict,confidence:$r.confidence,
   confidence_floor:$r.confidence_floor,
   criteria:$criteria_rows,
   unmet_criteria:$unmet,
   advisory:(if $mode == "active" and ($unmet | length) > 0 then
       "Jev acceptance check flagged unmet criteria: " + ($unmet | join(", "))
       + " (advisory only; completion remains a human decision)"
     else null end)}
' > "$OUT_TMP" || { rm -f "$OUT_TMP"; exit 0; }
chmod 0600 "$OUT_TMP" || { rm -f "$OUT_TMP"; exit 0; }
mv -f "$OUT_TMP" "$OUT" || { rm -f "$OUT_TMP"; exit 0; }
exit 0
