#!/usr/bin/env bash
# fm-jev-accept-check.sh - observe one worker report against brief acceptance material.
#
# Usage: fm-jev-accept-check.sh <task-id>
#
# Reads data/<id>/brief.md and data/<id>/report.md, falling back to the newest
# `done:` status line when no report exists. Only the exact level-two sections
# "Captain's intent" and "Firstmate spec" own criterion extraction: done-when
# paragraphs in the former, including a list introduced by a done-when lead-in,
# and numbered requirements in the latter become Nouls, preserving
# continuation, nested content, and deeper subheadings. A promoted brief's
# level-one "Current ship Firstmate spec" replaces the scout-time Firstmate
# spec. Generated scaffold sections never supply criteria; a brief without
# task criteria is a no-op.
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
CRITERIA_LINES="$TMP_DIR/criteria-lines"
CRITERIA_JSON="$TMP_DIR/criteria.json"
ENVELOPE="$TMP_DIR/envelope.json"
RESULT="$TMP_DIR/result.json"
REPORT_MATERIAL="$TMP_DIR/report.txt"
: > "$REPORT_MATERIAL"

awk '
  function keep(value) {
    if (section == "intent") intent[++intents]=value
    else if (section == "spec") spec[++specs]=value
    else current[++currents]=value
  }
  function flush() {
    sub(/\n+$/, "", text)
    if (section == "intent") {
      if (match(tolower(text), /done[[:space:]-]+when([[:space:]:]|$)/))
        keep(substr(text, RSTART))
    } else if (section != "" && item && text ~ /[^[:space:]]/)
      keep(text)
    text=""; item=0; blank=0; leadin=0
  }
  function lead_in(rest) {
    rest=tolower(text)
    if (!match(rest, /done[[:space:]-]+when([[:space:]:]|$)/)) return 0
    rest=substr(rest, RSTART)
    return rest ~ /:[[:space:]]*$/ || rest ~ /^done[[:space:]-]+when[[:space:]]*$/
  }
  function append(line) { text=text (text == "" ? "" : "\n") line }
  function indent(line, prefix) {
    prefix=line; sub(/[^[:space:]].*$/, "", prefix)
    gsub(/\t/, "    ", prefix)
    return length(prefix)
  }
  {
    line=$0
    if (fence != "") {
      if (in_section) append(line)
      trimmed=line; sub(/^[[:space:]]*/, "", trimmed)
      run=trimmed; sub(/[^`~].*$/, "", run)
      if (substr(run,1,1) == fence && length(run) >= fence_length &&
          trimmed ~ /^[`~]+[[:space:]]*$/) fence=""
      next
    }
    trimmed=line; sub(/^[[:space:]]*/, "", trimmed)
    if (trimmed ~ /^```|^~~~/) {
      fence=substr(trimmed,1,1)
      run=trimmed; sub(/[^`~].*$/, "", run); fence_length=length(run)
      if (in_section) append(line)
      next
    }
    if (line ~ /^#{1,6}[[:space:]]/) {
      heading=line; sub(/[^#].*$/, "", heading); level=length(heading)
      title=line; sub(/^#+[[:space:]]+/, "", title)
      flush()
      if (in_section && level > section_level) next
      in_section=0; section=""
      sub(/[[:space:]]+#+[[:space:]]*$/, "", title)
      if (level == 2 && tolower(title) == "captain\047s intent") {
        in_section=1; section="intent"; section_level=level
      } else if (level == 2 && tolower(title) == "firstmate spec") {
        in_section=1; section="spec"; section_level=level
      } else if (level == 1 && tolower(title) == "current ship firstmate spec") {
        in_section=1; section="current"; section_level=level; promoted=1
      }
      next
    }
    if (!in_section) next
    if (line ~ /^[[:space:]]*$/) {
      if (item || leadin) { append(""); blank=1 } else flush()
      next
    }
    depth=indent(line)
    if (leadin) {
      if (blank && depth == 0 && line !~ /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/) flush()
      else { append(line); blank=0; next }
    }
    if (line ~ /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/) {
      if (section == "intent" && !item && lead_in()) {
        leadin=1; append(line); blank=0; next
      }
      if (!item || depth <= item_depth) {
        flush()
        if (section != "intent" && line !~ /^[[:space:]]*[0-9]+[.)][[:space:]]+/) next
        item=1; item_depth=depth
        sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/, "", line)
      }
    } else if (item && blank && depth <= item_depth) flush()
    append(line); blank=0
  }
  END {
    flush()
    for (i=1; i<=intents; i++) printf "%s%c", intent[i], 0
    if (promoted) for (i=1; i<=currents; i++) printf "%s%c", current[i], 0
    else for (i=1; i<=specs; i++) printf "%s%c", spec[i], 0
  }
' "$BRIEF" > "$CRITERIA_LINES"
[ -s "$CRITERIA_LINES" ] || exit 0
jq -Rsc 'split("\u0000") | map(select(length > 0))' < "$CRITERIA_LINES" > "$CRITERIA_JSON" || exit 0

if [ -f "$REPORT" ] && [ -r "$REPORT" ] && [ ! -L "$REPORT" ]; then
  cp -- "$REPORT" "$REPORT_MATERIAL" || exit 0
elif [ -f "$STATUS_FILE" ] && [ -r "$STATUS_FILE" ] && [ ! -L "$STATUS_FILE" ]; then
  awk '/^[[:space:]]*done[[:space:]]*:/ { line=$0 } END { print line }' "$STATUS_FILE" > "$REPORT_MATERIAL"
fi
[ -s "$REPORT_MATERIAL" ] || exit 0

ESTIMATE=$(( ($(wc -c < "$REPORT_MATERIAL") + $(wc -c < "$CRITERIA_JSON") + 3) / 4 ))
jq -n --rawfile report "$REPORT_MATERIAL" --arg subject "$ID" --argjson estimate "$ESTIMATE" \
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
STATUS=$(jq -r '.status // "unavailable"' "$RESULT" 2>/dev/null) || STATUS=unavailable
REASON=$(jq -r '.reason // ""' "$RESULT" 2>/dev/null) || REASON=
case "$STATUS:$REASON" in
  available:*|unavailable:questions-truncated) ;;
  *) exit 0 ;;
esac

OUT="$DATA/$ID/acceptance.json"
OUT_TMP="$DATA/$ID/.acceptance.json.tmp.$$"
mkdir -p "$DATA/$ID" || exit 0
jq -n --arg task "$ID" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg mode "$MODE" \
  --slurpfile criteria "$CRITERIA_JSON" --slurpfile result "$RESULT" '
  ($result[0]) as $r |
  ($criteria[0] | to_entries | map({key:("criterion_" + ((.key + 1) | tostring)), value:.value}) | from_entries) as $named |
  ($r.truncated_keys // {}) as $shortened |
  [$named | to_entries[] |
    ($shortened["acceptance_criteria." + .key]) as $judged |
    {id:.key,text:.value,probability:$r.answers[.key].noul,
     truncated:($judged != null),
     judged_characters:(if $judged == null then (.value | length) else $judged end),
     met:(if $judged != null then null
          elif $r.answers[.key].noul >= $r.confidence_floor then true
          elif (1 - $r.answers[.key].noul) >= $r.confidence_floor then false
          else null end)}] as $criteria_rows |
  ([$criteria_rows[] | select(.met == false) | .id]) as $unmet |
  ([$criteria_rows[] | select(.truncated) | .id]) as $unjudged |
  {schema_version:1,task_id:$task,generated_at:$generated,consultation_id:$r.consultation_id,
   mode:$r.mode,model:$r.model,
   verdict:(if ($unjudged | length) == ($criteria_rows | length) then "unjudged" else $r.verdict end),
   confidence:(if ($unjudged | length) == ($criteria_rows | length) then null else $r.confidence end),
   confidence_floor:$r.confidence_floor,
   truncated:(($r.truncated // false) or ($unjudged | length) > 0),
   criteria:$criteria_rows,
   unmet_criteria:$unmet,
   unjudged_criteria:$unjudged,
   advisory:(if $mode == "active" and (($unmet | length) > 0 or ($unjudged | length) > 0) then
       (if ($unmet | length) > 0 then
          "Jev acceptance check flagged unmet criteria: " + ($unmet | join(", "))
        else "Jev acceptance check flagged no unmet criterion" end)
       + (if ($unjudged | length) > 0 then
            "; " + (($unjudged | length) | tostring)
            + " criteria went unjudged because their text was shortened to fit the per-call budget: "
            + ($unjudged | join(", "))
          else "" end)
       + " (advisory only; completion remains a human decision)"
     else null end)}
' > "$OUT_TMP" || { rm -f "$OUT_TMP"; exit 0; }
chmod 0600 "$OUT_TMP" || { rm -f "$OUT_TMP"; exit 0; }
mv -f "$OUT_TMP" "$OUT" || { rm -f "$OUT_TMP"; exit 0; }
exit 0
