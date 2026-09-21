#!/usr/bin/env bash
# fm-jev-report.sh - summarize Jev quality, spend, and token-efficiency evidence.
#
# Usage: fm-jev-report.sh [state/jev-ledger.jsonl]
#
# Opens with the effective mode of each use and whether a key is present, so an
# operator reading the metrics can see at once whether the feature is on.
# Prints one row per use and an overall row. Agreement, false positives, and
# false negatives use only consultations with a non-null Jev verdict and eventual
# decision. Object verdicts (open-question batches) compare matching keys. Spend
# includes every network attempt. Estimated tokens avoided includes available,
# confidence-qualified consultations in both shadow and active modes; until a
# use has active rows, that value is a counterfactual estimate, not observed
# savings. The report also lists every Jev-versus-baseline disagreement with both
# rationales and the returned typed probabilities. It closes with the advisory
# findings the active adapters recorded, which is where an acceptance or
# commit-lint advisory is surfaced: no adapter writes one to a task status file,
# because a `note:` there would supersede a worker's terminal `done:` line.
# Empty or malformed ledgers exit non-zero with a clear diagnostic.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER=${1:-${FM_JEV_LEDGER_OVERRIDE:-$STATE/jev-ledger.jsonl}}

MODES=
KEY_STATE=absent
for use in accept-check triage commit-lint open-questions; do
  STATUS=$("$SCRIPT_DIR/fm-jev.sh" status "$use" 2>/dev/null) || STATUS=
  IFS=$'\t' read -r USE_MODE USE_REASON USE_KEY _ <<<"$STATUS"
  [ "${USE_KEY:-absent}" != present ] || KEY_STATE=present
  case "${USE_REASON:-none}" in
    none|'') MODES="$MODES $use=${USE_MODE:-off}" ;;
    *) MODES="$MODES $use=${USE_MODE:-off}($USE_REASON)" ;;
  esac
done
printf 'jev configuration:%s TYPESAFE_API_KEY=%s\n' "$MODES" "$KEY_STATE"

if [ ! -s "$LEDGER" ]; then
  printf 'jev report: ledger is empty: %s\n' "$LEDGER" >&2
  exit 1
fi
if ! "$SCRIPT_DIR/fm-jev.sh" validate-ledger "$LEDGER"; then
  printf 'jev report: ledger is malformed: %s\n' "$LEDGER" >&2
  exit 2
fi

METRICS=$(jq -s -r '
  def positive($use):
    if $use == "accept-check" then "accepted"
    elif $use == "triage" then "actionable"
    elif $use == "commit-lint" then "flagged"
    else "settled" end;
  def pairs:
    if .jev_verdict == null or .eventual_outcome == null then []
    elif (.jev_verdict | type) == "object" and (.eventual_outcome | type) == "object" then
      . as $row |
      [$row.jev_verdict | to_entries[] as $entry |
        select($row.eventual_outcome | has($entry.key)) |
        {pred:$entry.value,actual:$row.eventual_outcome[$entry.key]}]
    else [{pred:.jev_verdict,actual:.eventual_outcome}] end;
  def metrics($rows; $name):
    [$rows[] | . as $row | pairs[] | . + {use:$row.use}] as $pairs |
    ($pairs | length) as $labelled |
    ($pairs | map(select(.pred == .actual)) | length) as $agree |
    {use:$name,
     consultations:($rows | length),
     labelled:$labelled,
     agreement:$agree,
     agreement_pct:(if $labelled == 0 then "n/a" else ((10000 * $agree / $labelled | round) / 100 | tostring) + "%" end),
     false_positive:($pairs | map(select(.pred == positive(.use) and .actual != positive(.use))) | length),
     false_negative:($pairs | map(select(.pred != positive(.use) and .actual == positive(.use))) | length),
     spend:($rows | map(.cost_usd) | add // 0),
     estimated_tokens_avoided:($rows | map(select(.available and .confidence != null and .confidence >= .confidence_floor) | .estimated_big_model_tokens) | add // 0),
     active_rows:($rows | map(select(.mode == "active")) | length)};
  . as $all |
  (["accept-check","triage","commit-lint","open-questions"][] as $use |
    metrics([$all[] | select(.use == $use)]; $use)),
  metrics($all; "overall") |
  [.use,.consultations,.labelled,(.agreement|tostring),.agreement_pct,
   (.false_positive|tostring),(.false_negative|tostring),(.spend|tostring),
   (.estimated_tokens_avoided|tostring),(.active_rows|tostring)] | @tsv
' "$LEDGER") || {
  printf 'jev report: could not compute metrics from %s\n' "$LEDGER" >&2
  exit 2
}

printf 'use\tconsultations\tlabelled\tagree\tagreement\tfalse_positive\tfalse_negative\tjev_spend_usd\testimated_tokens_avoided\tactive_rows\n'
printf '%s\n' "$METRICS"

jq -s -r '
  [.[] | select(.agreement == false)] as $rows |
  if ($rows | length) == 0 then "disagreements: none"
  else
    "disagreements:\n" +
    ($rows | map(
      "- consultation_id=\(.consultation_id) use=\(.use) subject=\(.subject)\n" +
      "  jev_decision=\(.jev_verdict | tojson)\n" +
      "  jev_rationale=\(.jev_rationale | tojson)\n" +
      "  jev_probabilities=\(.jev_probabilities | tojson)\n" +
      "  baseline_decision=\(.baseline_decision | tojson)\n" +
      "  baseline_rationale=\(.baseline_rationale | tojson)"
    ) | join("\n"))
  end
' "$LEDGER"

jq -s -r '
  [.[] | select(.mode == "active" and .available and .used_jev and ((.jev_flagged // []) | length) > 0)] as $rows |
  if ($rows | length) == 0 then "advisories: none"
  else
    "advisories:\n" +
    ($rows | map(
      "- use=\(.use) subject=\(.subject) consultation_id=\(.consultation_id)" +
      " flagged=\((.jev_flagged // []) | join(","))" +
      (if .truncated then " truncated=true" else "" end)
    ) | join("\n"))
  end
' "$LEDGER"
