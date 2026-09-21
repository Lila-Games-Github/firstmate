#!/usr/bin/env bash
# fm-jev.sh - bounded TypeSafe AI Jev client and outcome-ledger owner.
#
# Usage:
#   fm-jev.sh mode <accept-check|triage|commit-lint|open-questions>
#   fm-jev.sh status <accept-check|triage|commit-lint|open-questions>
#   fm-jev.sh request-budget <accept-check|triage|commit-lint|open-questions>
#   fm-jev.sh consult <accept-check|triage|commit-lint|open-questions> < envelope.json
#   fm-jev.sh finalize --use <use> --subject <subject> --decision-json <json>
#   fm-jev.sh validate-ledger [ledger.jsonl]
#
# `mode` prints the effective mode only: off, shadow, or active. The built-in
# configuration defaults every use to active; config/jev.json can select shadow
# or off per use or engage the global kill switch.
#
# `status` prints one tab-separated line - effective mode, machine reason,
# `present` or `absent` for the key, and a human explanation - so an explicitly
# invoked adapter can name why it is doing nothing. `request-budget` prints the
# largest request body in bytes this use may send, or 0 when it is unavailable.
#
# `consult` reads one JSON envelope from stdin. Its `request` member is the
# exact state/questions payload; this client pins the model before sending it.
# Its `ledger` member supplies the subject, baseline decision and rationale,
# estimated big-model tokens, and one allowlisted verdict aggregation recipe.
# Every outcome is JSON on stdout and exits zero. Missing configuration, kill
# switch, key, tools, caps, unsafe input, transport failure, and malformed
# responses all return status=unavailable so callers keep their old behavior.
# Only a network attempt creates a ledger row.
#
# `finalize` updates every row without an eventual outcome for one use and
# subject under the ledger lock. It is how an owning lifecycle path records the
# later human or deterministic ground truth without adding a second row.
#
# Configuration is the effective home's gitignored config/jev.json. The schema
# and active built-in defaults live in docs/configuration.md. Each use owns a
# share of the daily budget so no use can starve another. The ledger is
# state/jev-ledger.jsonl. docs/jev.md owns the operator workflow and metrics.
#
# Tokens are counted at four request bytes per input token here and in every
# adapter estimate, so one budget arithmetic applies end to end.
#
# Secret handling: TYPESAFE_API_KEY is copied into one non-exported shell
# variable, removed from the environment, and passed to curl through fd 3.
# It is never an argv value and is never written or logged.
#
# Test seam: FM_JEV_TESTING=1 permits FM_JEV_TEST_ENDPOINT to replace the fixed
# production endpoint. Production ignores that variable.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_FILE="$CONFIG_DIR/jev.json"
LEDGER="${FM_JEV_LEDGER_OVERRIDE:-$STATE/jev-ledger.jsonl}"
MODEL=jev-1.13.0
MODEL_FAMILY=jev-
ENDPOINT=https://api.typesafe.ai/v1/systemone
PRICE_PER_MILLION=0.042
BYTES_PER_TOKEN=4
HTTP_TIMEOUT=5
LOCK_TIMEOUT=5
KNOWN_USES='["accept-check","triage","commit-lint","open-questions"]'
DEFAULT_CONFIG_JSON='{"version":1,"kill_switch":false,"per_call_token_cap":32000,"daily":{"call_cap":100,"spend_usd_cap":0.05},"uses":{"accept-check":{"mode":"active","confidence_floor":0.8,"daily":{"call_cap":25,"spend_usd_cap":0.0125}},"triage":{"mode":"active","confidence_floor":0.65,"daily":{"call_cap":25,"spend_usd_cap":0.0125}},"commit-lint":{"mode":"active","confidence_floor":0.8,"daily":{"call_cap":25,"spend_usd_cap":0.0125}},"open-questions":{"mode":"active","confidence_floor":0.65,"daily":{"call_cap":25,"spend_usd_cap":0.0125}}}}'

CONFIG_STATUS=absent
CONFIG_REASON=config-absent
CONFIG_JSON=
CONFIGURED_MODE=off
EFFECTIVE_MODE=off
CONFIDENCE_FLOOR=1
PER_CALL_TOKEN_CAP=0
DAILY_CALL_CAP=0
DAILY_SPEND_CAP=0
USE_CALL_CAP=0
USE_SPEND_CAP=0
RESPONSE_MODEL=

REQUEST_FILE=
RESPONSE_FILE=
LOCK_PATH=
LOCK_HELD=false

cleanup() {
  local status=$?
  [ -z "$REQUEST_FILE" ] || rm -f -- "$REQUEST_FILE" 2>/dev/null || true
  [ -z "$RESPONSE_FILE" ] || rm -f -- "$RESPONSE_FILE" 2>/dev/null || true
  if [ "$LOCK_HELD" = true ]; then
    fm_lock_release "$LOCK_PATH" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

use_valid() {
  case "$1" in accept-check|triage|commit-lint|open-questions) return 0 ;; esac
  return 1
}

json_available() { command -v jq >/dev/null 2>&1; }

emit_unavailable() { # <use> <reason> [<fallback-json>]
  local use=$1 reason=$2 fallback=${3:-null}
  if json_available && jq empty >/dev/null 2>&1 <<<"$fallback"; then
    jq -cn --arg use "$use" --arg mode "$EFFECTIVE_MODE" \
      --arg configured_mode "$CONFIGURED_MODE" --arg reason "$reason" \
      --argjson fallback "$fallback" \
      '{status:"unavailable", use:$use, mode:$mode, configured_mode:$configured_mode,
        reason:$reason, fallback_decision:$fallback}'
  else
    printf '{"status":"unavailable","use":"%s","mode":"off","configured_mode":"off","reason":"%s","fallback_decision":null}\n' \
      "$use" "$reason"
  fi
}

load_config() {
  local err
  CONFIG_STATUS=absent
  CONFIG_REASON=config-absent
  CONFIG_JSON=
  if [ ! -e "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
    CONFIG_STATUS=ok
    CONFIG_REASON=config-default
    CONFIG_JSON=$DEFAULT_CONFIG_JSON
    return 0
  fi
  if [ ! -f "$CONFIG_FILE" ] || [ ! -r "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    CONFIG_STATUS=invalid
    CONFIG_REASON=config-unreadable
    return 0
  fi
  if ! json_available; then
    CONFIG_STATUS=invalid
    CONFIG_REASON=jq-missing
    return 0
  fi
  CONFIG_JSON=$(cat "$CONFIG_FILE" 2>/dev/null) || {
    CONFIG_STATUS=invalid
    CONFIG_REASON=config-unreadable
    return 0
  }
  err=$(jq -r --argjson known "$KNOWN_USES" '
    def integer: . as $value | type == "number" and floor == $value;
    if type != "object" then "top-level value must be an object"
    elif .version != 1 then "version must be 1"
    elif (.kill_switch | type) != "boolean" then "kill_switch must be boolean"
    elif (.per_call_token_cap | integer | not) or .per_call_token_cap < 1 or .per_call_token_cap > 32000 then "per_call_token_cap must be an integer from 1 through 32000"
    elif (.daily | type) != "object" then "daily must be an object"
    elif (.daily.call_cap | integer | not) or .daily.call_cap < 0 then "daily.call_cap must be a nonnegative integer"
    elif (.daily.spend_usd_cap | type) != "number" or .daily.spend_usd_cap < 0 then "daily.spend_usd_cap must be a nonnegative number"
    elif (.uses | type) != "object" then "uses must be an object"
    elif ((.uses | keys | sort) != ($known | sort)) then "uses must contain exactly accept-check, triage, commit-lint, and open-questions"
    elif any(.uses[]; type != "object") then "each use must be an object"
    elif any(.uses[]; . as $use | ($use.mode | type) != "string" or (["off","shadow","active"] | index($use.mode) | not)) then "each use mode must be off, shadow, or active"
    elif any(.uses[]; (.confidence_floor | type) != "number" or .confidence_floor < 0 or .confidence_floor > 1) then "each confidence_floor must be a number from 0 through 1"
    elif any(.uses[]; has("daily") and (.daily | type) != "object") then "each use daily must be an object"
    elif any(.uses[]; has("daily") and ((.daily.call_cap | integer | not) or .daily.call_cap < 0)) then "each use daily.call_cap must be a nonnegative integer"
    elif any(.uses[]; has("daily") and ((.daily.spend_usd_cap | type) != "number" or .daily.spend_usd_cap < 0)) then "each use daily.spend_usd_cap must be a nonnegative number"
    else empty end
  ' <<<"$CONFIG_JSON" 2>/dev/null) || err='config is not valid JSON'
  if [ -n "$err" ]; then
    CONFIG_STATUS=invalid
    CONFIG_REASON=config-invalid
    return 0
  fi
  CONFIG_STATUS=ok
  CONFIG_REASON=
}

# A use that names no daily budget of its own receives an equal share of the
# global budget, so the shares of the four uses always sum to the global cap and
# a high-volume use can never consume another use's budget.
resolve_use_config() { # <use>
  local use=$1 kill
  CONFIGURED_MODE=off
  EFFECTIVE_MODE=off
  CONFIDENCE_FLOOR=1
  PER_CALL_TOKEN_CAP=0
  DAILY_CALL_CAP=0
  DAILY_SPEND_CAP=0
  USE_CALL_CAP=0
  USE_SPEND_CAP=0
  load_config
  [ "$CONFIG_STATUS" = ok ] || return 0
  kill=$(jq -r '.kill_switch' <<<"$CONFIG_JSON")
  CONFIGURED_MODE=$(jq -r --arg use "$use" '.uses[$use].mode' <<<"$CONFIG_JSON")
  CONFIDENCE_FLOOR=$(jq -r --arg use "$use" '.uses[$use].confidence_floor' <<<"$CONFIG_JSON")
  PER_CALL_TOKEN_CAP=$(jq -r '.per_call_token_cap' <<<"$CONFIG_JSON")
  DAILY_CALL_CAP=$(jq -r '.daily.call_cap' <<<"$CONFIG_JSON")
  DAILY_SPEND_CAP=$(jq -r '.daily.spend_usd_cap' <<<"$CONFIG_JSON")
  USE_CALL_CAP=$(jq -r --argjson known "$KNOWN_USES" --arg use "$use" \
    '.uses[$use].daily.call_cap // ((.daily.call_cap / ($known | length)) | floor)' <<<"$CONFIG_JSON")
  USE_SPEND_CAP=$(jq -r --argjson known "$KNOWN_USES" --arg use "$use" \
    '.uses[$use].daily.spend_usd_cap // (.daily.spend_usd_cap / ($known | length))' <<<"$CONFIG_JSON")
  if [ "$kill" = true ]; then
    CONFIG_REASON='kill-switch'
    return 0
  fi
  EFFECTIVE_MODE=$CONFIGURED_MODE
}

# shellcheck disable=SC2016 # jq program; dollar names belong to jq.
ledger_row_valid_filter='
  . as $row |
  type == "object" and
  .schema_version == 1 and
  (.timestamp | type) == "string" and
  (.date | type) == "string" and
  (.consultation_id | type) == "string" and (.consultation_id | length) > 0 and
  (.use | type) == "string" and (["accept-check","triage","commit-lint","open-questions"] | index($row.use)) != null and
  (.subject | type) == "string" and
  (.mode | type) == "string" and (["shadow","active"] | index($row.mode)) != null and
  (.configured_mode | type) == "string" and (["shadow","active"] | index($row.configured_mode)) != null and
  .network_attempted == true and
  (.available | type) == "boolean" and
  ((.unavailable_reason == null) or ((.unavailable_reason | type) == "string")) and
  (.input_tokens | type) == "number" and .input_tokens >= 0 and
  (.input_tokens_source | type) == "string" and (["reported","estimate"] | index($row.input_tokens_source)) != null and
  ((.confidence == null) or ((.confidence | type) == "number" and .confidence >= 0 and .confidence <= 1)) and
  (.confidence_floor | type) == "number" and .confidence_floor >= 0 and .confidence_floor <= 1 and
  (.latency_ms | type) == "number" and .latency_ms >= 0 and
  (.cost_usd | type) == "number" and .cost_usd >= 0 and
  (.estimated_big_model_tokens | type) == "number" and .estimated_big_model_tokens >= 0 and
  (.request_bytes | type) == "number" and .request_bytes >= 0 and
  ((.response_model == null) or ((.response_model | type) == "string")) and
  ((.truncated == null) or ((.truncated | type) == "boolean")) and
  ((.jev_flagged == null) or ((.jev_flagged | type) == "array")) and
  (.used_jev | type) == "boolean" and
  (.corrected | type) == "boolean" and
  (.jev_answers | type) == "object" and
  ($row | has("jev_verdict")) and
  (.jev_rationale | type) == "string" and (.jev_rationale | length) > 0 and
  (.jev_probabilities | type) == "object" and
  ($row | has("existing_decision")) and
  ($row | has("baseline_decision")) and
  .existing_decision == .baseline_decision and
  (.baseline_rationale | type) == "string" and (.baseline_rationale | length) > 0 and
  ((.agreement == null) or ((.agreement | type) == "boolean")) and
  ($row | has("decision_after_jev")) and
  ($row | has("final_decision")) and
  ($row | has("eventual_outcome")) and
  .final_decision == .eventual_outcome and
  .agreement == (if .jev_verdict == null or .baseline_decision == null then null
                 else .jev_verdict == .baseline_decision end) and
  (if .available then
     .unavailable_reason == null and .jev_verdict != null and
     (.confidence | type) == "number" and (.jev_answers | length) > 0
   else
     (.unavailable_reason | type) == "string" and (.unavailable_reason | length) > 0 and
     .jev_verdict == null and .confidence == null and .used_jev == false and
     (.jev_answers | length) == 0 and (.jev_probabilities | length) == 0
   end) and
  (if .mode == "shadow" then .used_jev == false else true end) and
  (if .eventual_outcome == null then .corrected == false else true end)
'

validate_ledger_file() { # <file>
  local file=$1
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || return 1
  jq -e -s "all(.[]; $ledger_row_valid_filter)" "$file" >/dev/null 2>&1
}

lock_ledger() {
  mkdir -p "$STATE" || return 1
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  LOCK_PATH="$STATE/.jev-ledger.lock"
  fm_lock_acquire_wait_bounded "$LOCK_PATH" "$LOCK_TIMEOUT" || return 1
  LOCK_HELD=true
}

unlock_ledger() {
  if [ "$LOCK_HELD" = true ]; then
    fm_lock_release "$LOCK_PATH" || return 1
    LOCK_HELD=false
  fi
}

append_ledger_row() { # <compact-json>
  local row=$1
  jq -e "$ledger_row_valid_filter" >/dev/null 2>&1 <<<"$row" || return 1
  printf '%s\n' "$row" >> "$LEDGER"
}

envelope_valid() {
  jq -e '
    def question_ok:
      . as $question |
      type == "object" and
      (.type | type) == "string" and
      (["noul","choice","score"] | index($question.type)) != null and
      (.instructions | type) == "string" and (.instructions | length) > 0 and
      (if .type == "choice" then
         (.criteria | type) == "object" and (.criteria | length) >= 2 and (.criteria | length) <= 255 and
         all(.criteria[]; type == "string")
       elif .type == "score" then
         (.criteria | type) == "array" and (.criteria | length) >= 2 and (.criteria | length) <= 10 and all(.criteria[]; type == "string")
       else
         ((has("criteria") | not) or ((.criteria | type) == "object" and all(.criteria[]; type == "string")))
       end);
    def named_questions($names; $questions):
      ($names | type) == "array" and ($names | length) > 0 and
      all($names[]; type == "string" and (. as $name | $questions | has($name)));
    . as $root |
    (.ledger.verdict) as $verdict |
    type == "object" and
    (.request | type) == "object" and
    (.request.state | type) == "object" and
  (.request.questions | type) == "object" and (.request.questions | length) > 0 and
  all(.request.questions[]; question_ok) and
  (.ledger | type) == "object" and
  (.ledger.subject | type) == "string" and
  (.ledger | has("baseline_decision")) and
  (.ledger.baseline_rationale | type) == "string" and (.ledger.baseline_rationale | length) > 0 and
    ((.ledger | has("truncated") | not) or ((.ledger.truncated | type) == "boolean")) and
    (.ledger.estimated_big_model_tokens | type) == "number" and .ledger.estimated_big_model_tokens >= 0 and
    (.ledger.verdict | type) == "object" and
    (.ledger.verdict.strategy | type) == "string" and
    (if (["all_noul","any_noul"] | index($verdict.strategy)) != null then
       named_questions(.ledger.verdict.questions; .request.questions) and
       (.ledger.verdict.positive_label | type) == "string" and
       (.ledger.verdict.negative_label | type) == "string"
     elif .ledger.verdict.strategy == "choice" then
       named_questions([.ledger.verdict.question]; .request.questions)
     elif .ledger.verdict.strategy == "choices" then
       named_questions(.ledger.verdict.questions; .request.questions)
     elif .ledger.verdict.strategy == "risk_nouls" then
       (.ledger.verdict.checks | type) == "array" and (.ledger.verdict.checks | length) > 0 and
       all(.ledger.verdict.checks[];
         . as $check |
         (.question | type) == "string" and (.risk_when | type) == "string" and
         (["yes","no"] | index($check.risk_when)) != null and
         (. as $check | $root.request.questions | has($check.question))) and
       (.ledger.verdict.positive_label | type) == "string" and
       (.ledger.verdict.negative_label | type) == "string"
     else false end)
  ' "$REQUEST_FILE" >/dev/null 2>&1
}

# Any model id in the pinned family answers; a well-formed answer from another
# model is a mismatch the caller records with the returned id, not a generic
# malformed response.
response_valid() { # <api-request-file> <response-file>
  jq -e --arg model "$MODEL_FAMILY" --slurpfile request "$1" '
    . as $root |
    ($request[0].questions) as $questions |
    def answer_ok($question; $answer):
      if $question.type == "noul" then
        ($answer.noul | type) == "number" and $answer.noul >= 0 and $answer.noul <= 1
      elif $question.type == "choice" then
        ($answer.choice | type) == "string" and ($question.criteria | has($answer.choice)) and
        ($answer.confidence | type) == "number" and $answer.confidence >= 0 and $answer.confidence <= 1 and
        ($answer.probabilities | type) == "object" and
        (($answer.probabilities | keys | sort) == ($question.criteria | keys | sort)) and
        all($answer.probabilities[]; type == "number" and . >= 0 and . <= 1) and
        (($answer.probabilities | [.[]] | add) as $sum | $sum >= 0.99 and $sum <= 1.01)
      else
        ($answer.score | type) == "number" and
        ($answer.confidence | type) == "number" and $answer.confidence >= 0 and $answer.confidence <= 1 and
        ($answer.probabilities | type) == "array" and ($answer.probabilities | length) == ($question.criteria | length) and
        all($answer.probabilities[]; type == "number" and . >= 0 and . <= 1) and
        (($answer.probabilities | add) as $sum | $sum >= 0.99 and $sum <= 1.01) and
        $answer.score >= 0 and $answer.score <= (($question.criteria | length) - 1)
      end;
    type == "object" and (.model | type) == "string" and (.model | startswith($model)) and
    (.answers | type) == "object" and ((.answers | keys | sort) == ($questions | keys | sort)) and
    all($questions | to_entries[]; . as $entry | answer_ok($entry.value; $root.answers[$entry.key])) and
    ((has("usage") | not) or
      ((.usage | type) == "object" and
       (.usage.input_tokens | type) == "number" and .usage.input_tokens >= 0 and
       (.usage.output_tokens | type) == "number" and .usage.output_tokens >= 0))
  ' "$2" >/dev/null 2>&1
}

# The model id the service returned, reduced to a bounded identifier-safe token
# so an unexpected value is still safe to record in the ledger and the report.
response_model_id() { # <response-file>
  local id
  id=$(jq -r 'if type == "object" and (.model | type) == "string" then .model else empty end' "$1" 2>/dev/null) || return 0
  printf '%s' "$id" | LC_ALL=C tr -cd 'A-Za-z0-9._:/@-' | cut -c1-64
}

derive_verdict() { # <envelope-file> <response-file>
  jq -cn --argjson floor "$CONFIDENCE_FLOOR" \
    --slurpfile envelope "$1" --slurpfile response "$2" '
    ($envelope[0].ledger.verdict) as $v |
    ($response[0].answers) as $answers |
    if $v.strategy == "all_noul" then
      [$v.questions[] as $q | $answers[$q].noul] as $p |
      ($p | min) as $min |
      [$v.questions[] | select((1 - $answers[.].noul) >= $floor)] as $flagged |
      if all($p[]; . >= $floor) then
        {verdict:$v.positive_label, confidence:$min, flagged:$flagged,
         rationale:"Every named Noul yes probability met the configured confidence floor."}
      else
        {verdict:$v.negative_label, confidence:([$p[] | 1 - .] | max), flagged:$flagged,
         rationale:"At least one named Noul yes probability missed the configured confidence floor."}
      end
    elif $v.strategy == "any_noul" then
      [$v.questions[] as $q | $answers[$q].noul] as $p |
      ($p | max) as $max |
      [$v.questions[] | select($answers[.].noul >= $floor)] as $flagged |
      if any($p[]; . >= $floor) then
        {verdict:$v.positive_label, confidence:$max, flagged:$flagged,
         rationale:"At least one named Noul yes probability met the configured confidence floor."}
      else
        {verdict:$v.negative_label, confidence:(1 - $max), flagged:$flagged,
         rationale:"No named Noul yes probability met the configured confidence floor."}
      end
    elif $v.strategy == "choice" then
      ($answers[$v.question]) as $a |
      {verdict:$a.choice, confidence:$a.confidence, flagged:[],
       rationale:"The returned Choice winner is the Jev decision; confidence is the returned Choice confidence."}
    elif $v.strategy == "choices" then
      (reduce $v.questions[] as $q ({}; . + {($q):$answers[$q].choice})) as $out |
      {verdict:$out, confidence:([$v.questions[] as $q | $answers[$q].confidence] | min), flagged:[],
       rationale:"Each returned Choice winner is retained; aggregate confidence is the lowest returned Choice confidence."}
    elif $v.strategy == "risk_nouls" then
      [$v.checks[] as $check |
        {question:$check.question,
         risk_probability:(if $check.risk_when == "yes" then $answers[$check.question].noul else 1 - $answers[$check.question].noul end)}] as $risks |
      ([$risks[].risk_probability] | max) as $max |
      [$risks[] | select(.risk_probability >= $floor) | .question] as $flagged |
      if any($risks[]; .risk_probability >= $floor) then
        {verdict:$v.positive_label, confidence:$max, risks:$risks, flagged:$flagged,
         rationale:"At least one configured risk probability met the confidence floor."}
      else
        {verdict:$v.negative_label, confidence:(1 - $max), risks:$risks, flagged:$flagged,
         rationale:"No configured risk probability met the confidence floor."}
      end
    else error("unsupported verdict strategy") end
  '
}

record_unavailable_attempt() { # <use> <subject> <reason> <baseline-json> <baseline-rationale> <estimate> <tokens> <latency> <bytes> <truncated>
  local use=$1 subject=$2 reason=$3 baseline=$4 baseline_rationale=$5 estimate=$6 tokens=$7 latency=$8
  local bytes=$9 truncated=${10}
  local now today id cost row
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  today=${now%%T*}
  id="${today//-/}T${now#*T}-$$-${RANDOM:-0}"
  cost=$(jq -cn --argjson tokens "$tokens" --argjson rate "$PRICE_PER_MILLION" '$tokens * $rate / 1000000')
  row=$(jq -cn --arg now "$now" --arg today "$today" --arg id "$id" \
    --arg use "$use" --arg subject "$subject" --arg mode "$EFFECTIVE_MODE" \
    --arg configured_mode "$CONFIGURED_MODE" --arg reason "$reason" --arg baseline_rationale "$baseline_rationale" \
    --argjson input_tokens "$tokens" --argjson floor "$CONFIDENCE_FLOOR" \
    --argjson baseline "$baseline" --argjson latency "$latency" --argjson cost "$cost" \
    --argjson estimate "$estimate" --argjson bytes "$bytes" --argjson truncated "$truncated" \
    --arg response_model "$RESPONSE_MODEL" '
    {schema_version:1,timestamp:$now,date:$today,consultation_id:$id,use:$use,subject:$subject,
     mode:$mode,configured_mode:$configured_mode,network_attempted:true,available:false,
     unavailable_reason:$reason,input_tokens:$input_tokens,input_tokens_source:"estimate",
     jev_verdict:null,jev_rationale:("Jev was unavailable: " + $reason),jev_probabilities:{},
     confidence:null,confidence_floor:$floor,existing_decision:$baseline,
     baseline_decision:$baseline,baseline_rationale:$baseline_rationale,agreement:null,
     decision_after_jev:$baseline,final_decision:null,eventual_outcome:null,corrected:false,latency_ms:$latency,
     cost_usd:$cost,estimated_big_model_tokens:$estimate,request_bytes:$bytes,used_jev:false,
     truncated:$truncated,jev_flagged:[],
     response_model:(if $response_model == "" then null else $response_model end),
     jev_answers:{}}') || return 1
  append_ledger_row "$row" || return 1
  emit_unavailable "$use" "$reason" "$baseline"
}

cmd_mode() {
  local use=${1:-}
  use_valid "$use" || { printf 'off\n'; return 0; }
  resolve_use_config "$use"
  printf '%s\n' "$EFFECTIVE_MODE"
}

# 0 when TYPESAFE_API_KEY resolves from the environment or the effective home's
# .env. The value stays in a local and is never printed, returned, or logged.
key_present() {
  local key=${TYPESAFE_API_KEY:-}
  if [ -z "$key" ]; then
    # shellcheck source=bin/fm-env-lib.sh
    . "$SCRIPT_DIR/fm-env-lib.sh"
    key=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  fi
  [ -n "$key" ]
}

cmd_status() {
  local use=${1:-} reason='' keystate=absent explanation=''
  if ! use_valid "$use"; then
    printf 'off\tinvalid-use\tabsent\t%s is not a Jev use\n' "${use:-(none)}"
    return 0
  fi
  resolve_use_config "$use"
  key_present && keystate=present
  if [ -z "$EFFECTIVE_MODE" ]; then
    EFFECTIVE_MODE=off
    reason=config-unresolved
  fi
  if [ -n "$reason" ]; then
    :
  elif [ "$CONFIG_STATUS" != ok ]; then
    reason=$CONFIG_REASON
  elif [ "$CONFIG_REASON" = kill-switch ]; then
    reason='kill-switch'
  elif [ "$EFFECTIVE_MODE" = off ]; then
    reason=mode-off
  elif [ "$keystate" = absent ]; then
    reason=missing-key
  fi
  case "$reason" in
    '') explanation="$use is $EFFECTIVE_MODE" ;;
    kill-switch) explanation="$CONFIG_FILE sets kill_switch to true" ;;
    mode-off) explanation="$CONFIG_FILE sets $use to off" ;;
    missing-key) explanation="TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env" ;;
    config-invalid) explanation="$CONFIG_FILE is not valid against the version 1 schema" ;;
    config-unreadable) explanation="$CONFIG_FILE is not a readable regular file" ;;
    jq-missing|config-unresolved) explanation='jq is not installed, so no configuration could be resolved' ;;
    *) explanation="$use is unavailable: $reason" ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "$EFFECTIVE_MODE" "${reason:-none}" "$keystate" "$explanation"
}

# The largest request body this use may send, in bytes, so an adapter can size
# bounded material with the same arithmetic the preflight applies.
cmd_request_budget() {
  local use=${1:-}
  use_valid "$use" || { printf '0\n'; return 0; }
  resolve_use_config "$use"
  if [ "$EFFECTIVE_MODE" = off ] || [ "$CONFIG_STATUS" != ok ]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$((PER_CALL_TOKEN_CAP * BYTES_PER_TOKEN))"
}

cmd_consult() {
  local use=${1:-} fallback=null baseline_rationale='' subject='' estimate=0 request_bytes=0 request_tokens=0
  local today counts calls spend use_calls use_spend pre_cost total http=000 t0=0 t1=0 latency=0 actual_tokens=0 cost=0
  local request_json derive row result now id used_jev=false decision_after source=reported
  local probabilities agreement truncated=false reason=''
  local request_api='' TYPESAFE_API_KEY_PRIVATE=''
  use_valid "$use" || { emit_unavailable "${use:-unknown}" invalid-use; return 0; }
  resolve_use_config "$use"
  if [ "$CONFIG_STATUS" != ok ]; then emit_unavailable "$use" "$CONFIG_REASON"; return 0; fi
  if [ "$EFFECTIVE_MODE" = off ]; then emit_unavailable "$use" "${CONFIG_REASON:-mode-off}"; return 0; fi
  if ! json_available; then emit_unavailable "$use" jq-missing; return 0; fi

  REQUEST_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-jev-envelope.XXXXXX") || {
    emit_unavailable "$use" temp-unavailable
    return 0
  }
  command cat > "$REQUEST_FILE" || { emit_unavailable "$use" request-unreadable; return 0; }
  if ! envelope_valid; then emit_unavailable "$use" request-invalid; return 0; fi
  subject=$(jq -r '.ledger.subject' "$REQUEST_FILE")
  fallback=$(jq -c '.ledger.baseline_decision' "$REQUEST_FILE")
  baseline_rationale=$(jq -r '.ledger.baseline_rationale' "$REQUEST_FILE")
  estimate=$(jq -r '.ledger.estimated_big_model_tokens' "$REQUEST_FILE")
  truncated=$(jq -r '.ledger.truncated // false' "$REQUEST_FILE")

  TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
  export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
  unset TYPESAFE_API_KEY
  # shellcheck source=bin/fm-env-lib.sh
  . "$SCRIPT_DIR/fm-env-lib.sh"
  if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
    TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  fi
  if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then emit_unavailable "$use" missing-key "$fallback"; return 0; fi
  command -v curl >/dev/null 2>&1 || { emit_unavailable "$use" curl-missing "$fallback"; return 0; }

  request_json=$(jq -c --arg model "$MODEL" '.request + {model:$model}' "$REQUEST_FILE") || {
    emit_unavailable "$use" request-invalid "$fallback"
    return 0
  }
  request_bytes=$(LC_ALL=C printf '%s' "$request_json" | wc -c | tr -d ' ')
  case "$request_bytes" in ''|*[!0-9]*) emit_unavailable "$use" token-estimate-failed "$fallback"; return 0 ;; esac
  request_tokens=$(( (request_bytes + BYTES_PER_TOKEN - 1) / BYTES_PER_TOKEN ))
  if [ "$request_tokens" -gt "$PER_CALL_TOKEN_CAP" ]; then
    emit_unavailable "$use" per-call-token-cap "$fallback"
    return 0
  fi

  lock_ledger || { emit_unavailable "$use" ledger-busy "$fallback"; return 0; }
  if ! validate_ledger_file "$LEDGER"; then
    unlock_ledger || true
    emit_unavailable "$use" ledger-invalid "$fallback"
    return 0
  fi
  today=$(date -u +%Y-%m-%d)
  if [ -s "$LEDGER" ]; then
    counts=$(jq -s -r --arg today "$today" --arg use "$use" '
      [.[] | select(.date == $today)] as $today_rows |
      [($today_rows | map(select(.network_attempted)) | length),
       ($today_rows | map(.cost_usd) | add // 0),
       ($today_rows | map(select(.use == $use and .network_attempted)) | length),
       ($today_rows | map(select(.use == $use) | .cost_usd) | add // 0)] | @tsv' "$LEDGER")
    IFS=$'\t' read -r calls spend use_calls use_spend <<<"$counts"
    if [ -z "${calls:-}" ] || [ -z "${spend:-}" ] || [ -z "${use_calls:-}" ] || [ -z "${use_spend:-}" ]; then
      unlock_ledger || true
      emit_unavailable "$use" ledger-unreadable "$fallback"
      return 0
    fi
  else
    calls=0
    spend=0
    use_calls=0
    use_spend=0
  fi
  if [ "$calls" -ge "$DAILY_CALL_CAP" ]; then
    unlock_ledger || true
    emit_unavailable "$use" daily-call-cap "$fallback"
    return 0
  fi
  if [ "$use_calls" -ge "$USE_CALL_CAP" ]; then
    unlock_ledger || true
    emit_unavailable "$use" use-daily-call-cap "$fallback"
    return 0
  fi
  pre_cost=$(jq -cn --argjson tokens "$request_tokens" --argjson rate "$PRICE_PER_MILLION" '$tokens * $rate / 1000000')
  total=$(jq -cn --argjson spend "$spend" --argjson cost "$pre_cost" '$spend + $cost')
  if jq -en --argjson total "$total" --argjson cap "$DAILY_SPEND_CAP" '$total > $cap' >/dev/null; then
    unlock_ledger || true
    emit_unavailable "$use" daily-spend-cap "$fallback"
    return 0
  fi
  total=$(jq -cn --argjson spend "$use_spend" --argjson cost "$pre_cost" '$spend + $cost')
  if jq -en --argjson total "$total" --argjson cap "$USE_SPEND_CAP" '$total > $cap' >/dev/null; then
    unlock_ledger || true
    emit_unavailable "$use" use-daily-spend-cap "$fallback"
    return 0
  fi

  RESPONSE_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-jev-response.XXXXXX") || {
    unlock_ledger || true
    emit_unavailable "$use" temp-unavailable "$fallback"
    return 0
  }
  if [ "${FM_JEV_TESTING:-0}" = 1 ] && [ -n "${FM_JEV_TEST_ENDPOINT:-}" ]; then
    ENDPOINT=$FM_JEV_TEST_ENDPOINT
  fi
  # shellcheck source=bin/fm-timing-lib.sh
  . "$SCRIPT_DIR/fm-timing-lib.sh"
  t0=$(fm_timing_now_ms)
  http=$(printf '%s' "$request_json" | curl -sS --max-time "$HTTP_TIMEOUT" -o "$RESPONSE_FILE" -w '%{http_code}' \
    -X POST "$ENDPOINT" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || http=000
  t1=$(fm_timing_now_ms)
  latency=$((t1 - t0))
  RESPONSE_MODEL=$(response_model_id "$RESPONSE_FILE")
  if [ "$http" != 200 ]; then
    record_unavailable_attempt "$use" "$subject" "http-$http" "$fallback" "$baseline_rationale" "$estimate" "$request_tokens" "$latency" "$request_bytes" "$truncated" || {
      unlock_ledger || true
      emit_unavailable "$use" ledger-write-failed "$fallback"
      return 0
    }
    unlock_ledger || true
    return 0
  fi
  request_api=$(mktemp "${TMPDIR:-/tmp}/fm-jev-request.XXXXXX") || request_api=
  if [ -z "$request_api" ] || ! printf '%s\n' "$request_json" > "$request_api"; then
    [ -z "${request_api:-}" ] || rm -f -- "$request_api"
    record_unavailable_attempt "$use" "$subject" response-validation-failed "$fallback" "$baseline_rationale" "$estimate" "$request_tokens" "$latency" "$request_bytes" "$truncated" \
      || emit_unavailable "$use" ledger-write-failed "$fallback"
    unlock_ledger || true
    return 0
  fi
  if ! response_valid "$request_api" "$RESPONSE_FILE"; then
    rm -f -- "$request_api"
    case "$RESPONSE_MODEL" in
      ''|"$MODEL_FAMILY"*) reason=response-malformed ;;
      *) reason=response-model-mismatch ;;
    esac
    record_unavailable_attempt "$use" "$subject" "$reason" "$fallback" "$baseline_rationale" "$estimate" "$request_tokens" "$latency" "$request_bytes" "$truncated" || {
      unlock_ledger || true
      emit_unavailable "$use" ledger-write-failed "$fallback"
      return 0
    }
    unlock_ledger || true
    return 0
  fi
  rm -f -- "$request_api"

  derive=$(derive_verdict "$REQUEST_FILE" "$RESPONSE_FILE") || {
    record_unavailable_attempt "$use" "$subject" verdict-malformed "$fallback" "$baseline_rationale" "$estimate" "$request_tokens" "$latency" "$request_bytes" "$truncated" \
      || emit_unavailable "$use" ledger-write-failed "$fallback"
    unlock_ledger || true
    return 0
  }
  if jq -e 'has("usage")' "$RESPONSE_FILE" >/dev/null 2>&1; then
    actual_tokens=$(jq -r '.usage.input_tokens' "$RESPONSE_FILE")
    source=reported
  else
    actual_tokens=$request_tokens
    source=estimate
  fi
  cost=$(jq -cn --argjson tokens "$actual_tokens" --argjson rate "$PRICE_PER_MILLION" '$tokens * $rate / 1000000')
  probabilities=$(jq -c '
    .answers | with_entries(.value =
      if (.value | has("noul")) then {yes:.value.noul,no:(1 - .value.noul)}
      else .value.probabilities end)
  ' "$RESPONSE_FILE") || probabilities='{}'
  agreement=$(jq -cn --argjson jev "$(jq -c '.verdict' <<<"$derive")" --argjson baseline "$fallback" '
    if $jev == null or $baseline == null then null else $jev == $baseline end
  ')
  if [ "$EFFECTIVE_MODE" = active ] \
    && jq -en --argjson confidence "$(jq -c '.confidence' <<<"$derive")" \
      --argjson floor "$CONFIDENCE_FLOOR" '$confidence >= $floor' >/dev/null; then
    used_jev=true
    decision_after=$(jq -c '.verdict' <<<"$derive")
  else
    used_jev=false
    decision_after=$fallback
  fi
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  id="${today//-/}T${now#*T}-$$-${RANDOM:-0}"
  row=$(jq -cn --arg now "$now" --arg today "$today" --arg id "$id" \
    --arg use "$use" --arg subject "$subject" --arg mode "$EFFECTIVE_MODE" \
    --arg configured_mode "$CONFIGURED_MODE" --arg source "$source" --arg baseline_rationale "$baseline_rationale" \
    --arg jev_rationale "$(jq -r '.rationale' <<<"$derive")" --argjson input_tokens "$actual_tokens" \
    --argjson floor "$CONFIDENCE_FLOOR" --argjson verdict "$(jq -c '.verdict' <<<"$derive")" \
    --argjson confidence "$(jq -c '.confidence' <<<"$derive")" --argjson baseline "$fallback" \
    --argjson agreement "$agreement" --argjson probabilities "$probabilities" \
    --argjson after "$decision_after" --argjson latency "$latency" \
    --argjson cost "$cost" --argjson estimate "$estimate" --argjson bytes "$request_bytes" \
    --argjson truncated "$truncated" --arg response_model "$RESPONSE_MODEL" \
    --argjson flagged "$(jq -c '.flagged // []' <<<"$derive")" \
    --argjson used "$used_jev" --argjson answers "$(jq -c '.answers' "$RESPONSE_FILE")" '
    {schema_version:1,timestamp:$now,date:$today,consultation_id:$id,use:$use,subject:$subject,
     mode:$mode,configured_mode:$configured_mode,network_attempted:true,available:true,
     unavailable_reason:null,input_tokens:$input_tokens,input_tokens_source:$source,
     jev_verdict:$verdict,jev_rationale:$jev_rationale,jev_probabilities:$probabilities,
     confidence:$confidence,confidence_floor:$floor,
     existing_decision:$baseline,baseline_decision:$baseline,baseline_rationale:$baseline_rationale,
     agreement:$agreement,decision_after_jev:$after,final_decision:null,eventual_outcome:null,
     corrected:false,latency_ms:$latency,cost_usd:$cost,
     estimated_big_model_tokens:$estimate,request_bytes:$bytes,used_jev:$used,
     truncated:$truncated,jev_flagged:$flagged,
     response_model:(if $response_model == "" then null else $response_model end),
     jev_answers:$answers}') || {
    unlock_ledger || true
    emit_unavailable "$use" ledger-render-failed "$fallback"
    return 0
  }
  if ! append_ledger_row "$row"; then
    unlock_ledger || true
    emit_unavailable "$use" ledger-write-failed "$fallback"
    return 0
  fi
  unlock_ledger || {
    emit_unavailable "$use" ledger-unlock-failed "$fallback"
    return 0
  }
  result=$(jq -cn --arg id "$id" --arg use "$use" --arg mode "$EFFECTIVE_MODE" \
    --arg configured_mode "$CONFIGURED_MODE" --arg model "${RESPONSE_MODEL:-$MODEL}" \
    --argjson floor "$CONFIDENCE_FLOOR" --argjson derive "$derive" \
    --argjson answers "$(jq -c '.answers' "$RESPONSE_FILE")" \
    --argjson input_tokens "$actual_tokens" --argjson latency "$latency" \
    --argjson cost "$cost" --argjson fallback "$fallback" --arg baseline_rationale "$baseline_rationale" \
    --arg jev_rationale "$(jq -r '.rationale' <<<"$derive")" --argjson probabilities "$probabilities" \
    --argjson truncated "$truncated" \
    --argjson agreement "$agreement" --argjson used "$used_jev" '
    {status:"available",consultation_id:$id,use:$use,mode:$mode,configured_mode:$configured_mode,
     model:$model,confidence_floor:$floor,verdict:$derive.verdict,confidence:$derive.confidence,
     answers:$answers,input_tokens:$input_tokens,latency_ms:$latency,cost_usd:$cost,
     jev_rationale:$jev_rationale,jev_probabilities:$probabilities,truncated:$truncated,
     flagged:($derive.flagged // []),
     fallback_decision:$fallback,baseline_rationale:$baseline_rationale,agreement:$agreement,used_jev:$used}
     + (if $derive.risks then {risks:$derive.risks} else {} end)') || {
    emit_unavailable "$use" result-render-failed "$fallback"
    return 0
  }
  printf '%s\n' "$result"
}

cmd_finalize() {
  local use='' subject='' decision='' tmp updated
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --use) [ $# -ge 2 ] || return 2; use=$2; shift 2 ;;
      --subject) [ $# -ge 2 ] || return 2; subject=$2; shift 2 ;;
      --decision-json) [ $# -ge 2 ] || return 2; decision=$2; shift 2 ;;
      *) return 2 ;;
    esac
  done
  use_valid "$use" || return 2
  [ -n "$subject" ] || return 2
  json_available || return 1
  jq -e . >/dev/null 2>&1 <<<"$decision" || return 2
  lock_ledger || return 1
  validate_ledger_file "$LEDGER" || { unlock_ledger || true; return 1; }
  [ -s "$LEDGER" ] || { unlock_ledger || true; printf '{"updated":0}\n'; return 0; }
  tmp=$(mktemp "$STATE/.jev-ledger.finalize.XXXXXX") || { unlock_ledger || true; return 1; }
  updated=$(jq -s --arg use "$use" --arg subject "$subject" --argjson decision "$decision" '
    [ .[] | select(.use == $use and .subject == $subject and .eventual_outcome == null) ] | length
  ' "$LEDGER") || { rm -f "$tmp"; unlock_ledger || true; return 1; }
  jq -c --arg use "$use" --arg subject "$subject" --argjson decision "$decision" '
    if .use == $use and .subject == $subject and .eventual_outcome == null then
      .final_decision = $decision |
      .eventual_outcome = $decision |
      .corrected = (.decision_after_jev != null and .decision_after_jev != $decision)
    else . end
  ' "$LEDGER" > "$tmp" || { rm -f "$tmp"; unlock_ledger || true; return 1; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; unlock_ledger || true; return 1; }
  mv -f "$tmp" "$LEDGER" || { rm -f "$tmp"; unlock_ledger || true; return 1; }
  unlock_ledger || return 1
  jq -cn --argjson updated "$updated" '{updated:$updated}'
}

cmd_validate_ledger() {
  local file=${1:-$LEDGER}
  validate_ledger_file "$file"
}

case "${1:-}" in
  mode) shift; cmd_mode "$@" ;;
  status) shift; cmd_status "$@" ;;
  request-budget) shift; cmd_request_budget "$@" ;;
  consult) shift; cmd_consult "$@" ;;
  finalize) cmd_finalize "$@" ;;
  validate-ledger) shift; cmd_validate_ledger "$@" ;;
  -h|--help|help|'') sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) printf 'usage: fm-jev.sh mode|status|request-budget|consult|finalize|validate-ledger ...\n' >&2; exit 2 ;;
esac
