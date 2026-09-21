#!/usr/bin/env bash
# fm-jev-report.sh - summarize Jev quality, spend, and token-efficiency evidence.
#
# Usage: fm-jev-report.sh [state/jev-ledger.jsonl]
#
# With no argument it reads the running ledger and every archived month under
# state/jev-ledger/, so monthly rotation never hides evidence. Every pass is
# streaming, one row at a time, so a year of retained evidence costs constant
# memory.
#
# Opens with the effective mode of each use and whether a key is present, so an
# operator reading the metrics can see at once whether the feature is on, and
# names a use whose share of the daily budget is zero. Prints one row per use
# and an overall row over the consultations that reached the network. Agreement,
# false positives, and false negatives use only consultations with a non-null
# Jev verdict and eventual decision, and compare the positive class of the use
# against everything else, because a ground-truth label and a Jev verdict use
# different words for the same negative - a rejected acceptance whose task was
# then discarded agrees. A consultation still waiting for its ground truth is
# counted under `unlabelled` rather than folded into either class. Object
# verdicts (open-question batches) compare matching keys. Spend includes every
# network attempt. Estimated tokens
# avoided includes available, confidence-qualified consultations in both shadow
# and active modes; a batched per-key consultation contributes the share of its
# estimate whose own answers qualified, so nine confident answers out of ten
# still count. Until a use has active rows, that value is a counterfactual
# estimate, not observed savings.
#
# A `refusals:` section names every budget refusal that never reached the
# network, so a day in which a cap or an oversized request stopped the feature
# is visible rather than silent. The report also lists every Jev-versus-baseline
# disagreement with both rationales and the returned typed probabilities; a
# batched per-item verdict is listed as the items that actually diverged, never
# as the whole batch object, so one routine answer among fifty does not bury the
# acceptance and commit-lint disagreements an operator came to read. Rows
# written before the ledger recorded `differing_keys` have theirs derived here
# from the verdict and the baseline, and
# closes with the advisory findings the active adapters recorded, which is where
# an acceptance or commit-lint advisory is surfaced: no adapter writes one to a
# task status file, because a `note:` there would supersede a worker's terminal
# `done:` line. Empty or malformed ledgers exit non-zero with a clear diagnostic.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DEFAULT_LEDGER="${FM_JEV_LEDGER_OVERRIDE:-$STATE/jev-ledger.jsonl}"

LEDGERS=()
if [ "$#" -gt 0 ]; then
  LEDGERS=("$1")
  LABEL=$1
else
  LABEL=$DEFAULT_LEDGER
  ARCHIVE="${DEFAULT_LEDGER%.jsonl}"
  [ "$ARCHIVE" != "$DEFAULT_LEDGER" ] || ARCHIVE="$DEFAULT_LEDGER.d"
  if [ -d "$ARCHIVE" ]; then
    for candidate in "$ARCHIVE"/*.jsonl; do
      [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
      LEDGERS+=("$candidate")
    done
  fi
  [ ! -f "$DEFAULT_LEDGER" ] || LEDGERS+=("$DEFAULT_LEDGER")
fi

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

NONEMPTY=()
for candidate in ${LEDGERS[@]+"${LEDGERS[@]}"}; do
  [ -s "$candidate" ] || continue
  NONEMPTY+=("$candidate")
done
if [ "${#NONEMPTY[@]}" -eq 0 ]; then
  printf 'jev report: ledger is empty: %s\n' "$LABEL" >&2
  exit 1
fi
for candidate in "${NONEMPTY[@]}"; do
  if ! "$SCRIPT_DIR/fm-jev.sh" validate-ledger "$candidate"; then
    printf 'jev report: ledger is malformed: %s\n' "$candidate" >&2
    exit 2
  fi
done

METRICS=$(jq -n -r '
  def positive($use):
    if $use == "accept-check" then "accepted"
    elif $use == "triage" then "actionable"
    elif $use == "commit-lint" then "flagged"
    else "settled" end;
  # A Jev verdict and a ground-truth label do not share one vocabulary: an
  # acceptance row is answered "accepted" or "rejected" and labelled "accepted"
  # or "discarded" by the teardown that observed it. Compare the two classes,
  # so a rejection of work that was then discarded is agreement and not a false
  # negative.
  def cls($use): if . == positive($use) then "positive" else "negative" end;
  def pairs($use):
    if .jev_verdict == null or .eventual_outcome == null then []
    elif (.jev_verdict | type) == "object" and (.eventual_outcome | type) == "object" then
      . as $row |
      [$row.jev_verdict | to_entries[] as $entry |
        select($row.eventual_outcome | has($entry.key)) |
        {pred:($entry.value | cls($use)),
         actual:($row.eventual_outcome[$entry.key] | cls($use))}]
    else [{pred:(.jev_verdict | cls($use)),actual:(.eventual_outcome | cls($use))}] end;
  def avoided:
    . as $row |
    if ($row.available | not) then 0
    elif (($row.jev_confidences // {}) | length) > 0 then
      ([$row.jev_confidences[] | select(. >= $row.confidence_floor)] | length) as $qualified |
      (($row.estimated_big_model_tokens * $qualified / ($row.jev_confidences | length)) | round)
    elif $row.confidence != null and $row.confidence >= $row.confidence_floor then
      $row.estimated_big_model_tokens
    else 0 end;
  def blank:
    {consultations:0,labelled:0,unlabelled:0,agree:0,false_positive:0,false_negative:0,
     spend:0,avoided:0,active:0};
  def render:
    [.use,(.consultations|tostring),(.labelled|tostring),(.unlabelled|tostring),
     (.agree|tostring),
     (if .labelled == 0 then "n/a"
      else ((10000 * .agree / .labelled | round) / 100 | tostring) + "%" end),
     (.false_positive|tostring),(.false_negative|tostring),(.spend|tostring),
     (.avoided|tostring),(.active|tostring)] | @tsv;
  reduce inputs as $row ({};
    if ($row.network_attempted | not) then .
    else
      ($row.use) as $u | ($row | pairs($u)) as $ps |
      .[$u] = ((.[$u] // blank)
        | .consultations += 1
        | .labelled += ($ps | length)
        | .unlabelled += (if $row.jev_verdict != null and $row.eventual_outcome == null
                          then 1 else 0 end)
        | .agree += ([$ps[] | select(.pred == .actual)] | length)
        | .false_positive += ([$ps[] | select(.pred == "positive" and .actual == "negative")] | length)
        | .false_negative += ([$ps[] | select(.pred == "negative" and .actual == "positive")] | length)
        | .spend += $row.cost_usd
        | .avoided += ($row | avoided)
        | .active += (if $row.mode == "active" then 1 else 0 end))
    end)
  | . as $by_use
  | (["accept-check","triage","commit-lint","open-questions"]
     | map(. as $u | ($by_use[$u] // blank) + {use:$u})) as $rows
  | ($rows | reduce .[] as $r (blank + {use:"overall"};
      .consultations += $r.consultations | .labelled += $r.labelled
      | .unlabelled += $r.unlabelled | .agree += $r.agree
      | .false_positive += $r.false_positive | .false_negative += $r.false_negative
      | .spend += $r.spend | .avoided += $r.avoided | .active += $r.active)) as $overall
  | ($rows + [$overall])[] | render
' "${NONEMPTY[@]}") || {
  printf 'jev report: could not compute metrics from %s\n' "$LABEL" >&2
  exit 2
}

printf 'use\tconsultations\tlabelled\tunlabelled\tagree\tagreement\tfalse_positive\tfalse_negative\tjev_spend_usd\testimated_tokens_avoided\tactive_rows\n'
printf '%s\n' "$METRICS"

REFUSALS=$(jq -n -r '
  reduce inputs as $row ({};
    if ($row.network_attempted | not) then
      (($row.use) + "\t" + ($row.unavailable_reason // "unavailable")) as $key
      | .[$key] = ((.[$key] // 0) + 1)
    else . end)
  | to_entries | sort_by(.key)[]
  | (.key | split("\t")) as $parts
  | "- use=\($parts[0]) reason=\($parts[1]) refused=\(.value)"
' "${NONEMPTY[@]}") || REFUSALS=
if [ -z "$REFUSALS" ]; then
  printf 'refusals: none\n'
else
  printf 'refusals:\n%s\n' "$REFUSALS"
fi

DISAGREEMENTS=$(jq -r '
  . as $row |
  def differing:
    if (.differing_keys | type) == "array" then .differing_keys
    elif (.jev_verdict | type) == "object" and (.baseline_decision | type) == "object" then
      ([.jev_verdict | to_entries[] | select(.value != $row.baseline_decision[.key]) | .key] | sort)
    else null end;
  select(.agreement == false) |
  (differing) as $keys |
  "- consultation_id=\(.consultation_id) use=\(.use) subject=\(.subject)\n" +
  (if $keys == null then
     "  jev_decision=\(.jev_verdict | tojson)\n" +
     "  jev_probabilities=\(.jev_probabilities | tojson)\n" +
     "  baseline_decision=\(.baseline_decision | tojson)\n"
   else
     "  differing_items=\($keys | length) of \($row.jev_verdict | length)\n" +
     ([$keys[] |
        "  - item=\(.) jev_choice=\($row.jev_verdict[.] | tojson)" +
        " jev_probabilities=\($row.jev_probabilities[.] | tojson)" +
        " baseline_choice=\($row.baseline_decision[.] | tojson)"] | join("\n")) + "\n"
   end) +
  "  jev_rationale=\(.jev_rationale | tojson)\n" +
  "  baseline_rationale=\(.baseline_rationale | tojson)\n" +
  "  eventual_outcome=\(.eventual_outcome | tojson) label_source=\(.label_source | tojson)"
' "${NONEMPTY[@]}") || DISAGREEMENTS=
if [ -z "$DISAGREEMENTS" ]; then
  printf 'disagreements: none\n'
else
  printf 'disagreements:\n%s\n' "$DISAGREEMENTS"
fi

ADVISORIES=$(jq -r '
  select(.mode == "active" and .available and .used_jev and ((.jev_flagged // []) | length) > 0) |
  "- use=\(.use) subject=\(.subject) consultation_id=\(.consultation_id)" +
  " flagged=\((.jev_flagged // []) | join(","))" +
  (if .truncated then " truncated=true" else "" end)
' "${NONEMPTY[@]}") || ADVISORIES=
if [ -z "$ADVISORIES" ]; then
  printf 'advisories: none\n'
else
  printf 'advisories:\n%s\n' "$ADVISORIES"
fi
