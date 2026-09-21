#!/usr/bin/env bash
# fm-jev.sh - bounded TypeSafe AI Jev client and outcome-ledger owner.
#
# Usage:
#   fm-jev.sh mode <accept-check|triage|commit-lint|open-questions>
#   fm-jev.sh status <accept-check|triage|commit-lint|open-questions>
#   fm-jev.sh request-budget <accept-check|triage|commit-lint|open-questions>
#   fm-jev.sh consult <accept-check|triage|commit-lint|open-questions> < envelope.json
#   fm-jev.sh finalize --use <use> --subject <subject> --decision-json <json> \
#     --label-source <path>
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
# Network attempts and budget refusals create ledger rows when the ledger is writable.
#
# The `choices` recipe is per key: every named question keeps its own returned
# confidence, and `qualified`, `used_jev_keys`, and `decision_after_jev` are
# decided one key at a time against the use's confidence floor. The scalar
# `confidence` on that result and row is the lowest of them, a batch summary
# that gates nothing, so one unconfident answer cannot discard the rest.
#
# The per-call budget is enforced here, for every adapter, so no adapter can
# make an oversized request a silent no-op. An envelope larger than the budget
# has its longest state string shortened, recording truncated=true, and a
# request that cannot fit even then is refused with a ledger row naming
# per-call-token-cap - or question-block-token-cap when the question block plus
# the pinned model already exceeds the cap on its own, which no shortening can
# help. A budget refusal always writes a row, with network_attempted false, so
# the report can show why nothing ran.
#
# An over-budget envelope is split into one request per question group only
# when its verdict is per key and the use is not triage. Triage always keeps
# its combined request, shortening it to preserve the one-call bound.
# An aggregate verdict such as the acceptance
# check's `all_noul` is one claim about every named question, so a part of it
# is not a consultation in its own right: each part would record a row
# asserting the subject's whole verdict over the questions it happened to
# carry, and the report would count one prediction N times. Those envelopes are
# always one shortened request. Where a split is allowed, each part is its own
# subject - `<subject>#<group>` on its row - so finalize matches one row and
# the report counts each subject exactly once.
# A group is one verdict question plus every request question sharing its state
# key. `ledger.context` maps a shared state container to the group field naming
# its referenced entry; {"pages":"page"} retains only pages that group cites.
# If a split partly fails, `answers` contains only answered questions and
# `parts_unavailable` names the missing answers; callers must preserve that absence.
#
# Splitting is taken only when it buys something. Everything a part carries that
# its own group does not own is shared - state copied verbatim plus the
# `ledger.context` entries that group cites - and what the split duplicates is
# those per-part totals less the distinct bytes the parts cover between them. A
# split is refused unless the group-owned material is what makes the envelope
# oversized, so the duplication must be no larger than the group-owned bytes,
# and unless the duplication fits one per-call budget. It is refused again when
# the whole split would not fit the day's remaining calls and spend for this
# use. Declining a split falls back to one shortened request, still subject
# to the per-call and daily caps and transport failures.
#
# Agreement is per key wherever the verdict is: `agreement_keys` answers item by
# item and `differing_keys` names only the items that diverged, so a batch of
# ten with one routine answer is reviewable as that one item rather than as one
# false boolean over the whole batch. The scalar `agreement` is all-keys-agree.
# Rows are schema version 2; version 1 rows without those fields still read.
#
# The ledger is append-only and rotates monthly into state/jev-ledger/YYYY-MM
# .jsonl. `consult` validates only the row it appends and counts the day's
# budget from date-matching lines, so an interactive drain never pays for
# retained history.
#
# `finalize` updates every row without an eventual outcome for one use and
# subject under the ledger lock. It is how an owning lifecycle path records the
# later human or deterministic ground truth without adding a second row. The
# outcome is recorded verbatim, so a caller that discarded the work must say so
# rather than pass the accepted label, and the required `--label-source` names
# the owning path that observed it. `corrected` stays a literal difference
# between the recorded decision and that outcome.
#
# Configuration is the effective home's gitignored config/jev.json. The schema
# and active built-in defaults live in docs/configuration.md. Each use owns a
# share of the daily budget so no use can starve another. The ledger is
# state/jev-ledger.jsonl. docs/jev.md owns the operator workflow and metrics.
#
# Request-budget and preflight use four request bytes per input token.
# Adapter savings estimates are described in docs/jev.md.
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
LAST_ATTEMPT_ID=
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
PARTS_DIR=
PART_STOP=
LOCK_PATH=
LOCK_HELD=false

cleanup() {
  local status=$?
  [ -z "$REQUEST_FILE" ] || rm -f -- "$REQUEST_FILE" 2>/dev/null || true
  [ -z "$RESPONSE_FILE" ] || rm -f -- "$RESPONSE_FILE" 2>/dev/null || true
  [ -z "$PARTS_DIR" ] || rm -rf -- "$PARTS_DIR" 2>/dev/null || true
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

emit_unavailable() { # <use> <reason> [<fallback-json>] [<truncated-keys-json>]
  local use=$1 reason=$2 fallback=${3:-null} shortened=${4:-\{\}}
  if json_available && jq empty >/dev/null 2>&1 <<<"$fallback"; then
    jq empty >/dev/null 2>&1 <<<"$shortened" || shortened='{}'
    jq -cn --arg use "$use" --arg mode "$EFFECTIVE_MODE" \
      --arg configured_mode "$CONFIGURED_MODE" --arg reason "$reason" \
      --argjson fallback "$fallback" --argjson shortened "$shortened" \
      '{status:"unavailable", use:$use, mode:$mode, configured_mode:$configured_mode,
        reason:$reason, fallback_decision:$fallback, truncated_keys:$shortened}'
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

# A use that names no daily budget of its own receives a share of the global
# budget. The remainder of an uneven division is handed out one call at a time
# in use-name order, so the four shares always sum to the global cap exactly and
# a small global cap is never silently rounded down to no budget at all.
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
  USE_CALL_CAP=$(jq -r --argjson known "$KNOWN_USES" --arg use "$use" '
    ($known | sort) as $names | ($names | length) as $n |
    .daily.call_cap as $cap |
    .uses[$use].daily.call_cap //
      (($cap / $n | floor) + (if ($names | index($use)) < ($cap % $n) then 1 else 0 end))' <<<"$CONFIG_JSON")
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
  (.schema_version == 1 or .schema_version == 2) and
  (.timestamp | type) == "string" and
  (.date | type) == "string" and
  (.consultation_id | type) == "string" and (.consultation_id | length) > 0 and
  (.use | type) == "string" and (["accept-check","triage","commit-lint","open-questions"] | index($row.use)) != null and
  (.subject | type) == "string" and
  (.mode | type) == "string" and (["shadow","active"] | index($row.mode)) != null and
  (.configured_mode | type) == "string" and (["shadow","active"] | index($row.configured_mode)) != null and
  (.network_attempted | type) == "boolean" and
  (if .network_attempted then true
   else .available == false and .latency_ms == 0 and .cost_usd == 0 and .input_tokens == 0 end) and
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
  ((.jev_confidences == null) or ((.jev_confidences | type) == "object" and
    all(.jev_confidences[]; type == "number" and . >= 0 and . <= 1))) and
  ((.used_jev_keys == null) or ((.used_jev_keys | type) == "object" and
    all(.used_jev_keys[]; type == "boolean"))) and
  ((.jev_confidences // {} | keys) == (.used_jev_keys // {} | keys)) and
  (if ((.used_jev_keys // {}) | length) > 0
   then .used_jev == any(.used_jev_keys[]; .) and
        .used_jev_keys == (.jev_confidences | map_values(. >= $row.confidence_floor and $row.mode == "active"))
   else true end) and
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
  ((.agreement_keys == null) or ((.agreement_keys | type) == "object" and
    all(.agreement_keys[]; type == "boolean"))) and
  ((.differing_keys == null) or ((.differing_keys | type) == "array" and
    all(.differing_keys[]; type == "string"))) and
  (if .agreement_keys == null then .differing_keys == null
   else .differing_keys ==
     ([$row.agreement_keys | to_entries[] | select(.value | not) | .key] | sort) end) and
  ($row | has("decision_after_jev")) and
  ($row | has("final_decision")) and
  ($row | has("eventual_outcome")) and
  .final_decision == .eventual_outcome and
  ((.label_source == null) or
   ((.label_source | type) == "string" and (.label_source | length) > 0)) and
  (if .eventual_outcome == null then .label_source == null else true end) and
  .agreement == (if .jev_verdict == null or .baseline_decision == null then null
                 elif .agreement_keys != null then all(.agreement_keys[]; .)
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

# Streaming: one row is held at a time, so validating a year of evidence costs
# constant memory. `consult` never calls this - it validates only the row it is
# about to append - so an interactive drain never pays for ledger history.
validate_ledger_file() { # <file>
  local file=$1
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || return 1
  jq -n -e "reduce inputs as \$row (true; . and (\$row | $ledger_row_valid_filter))" "$file" >/dev/null 2>&1
}

# Every archived month plus the current ledger, oldest first. The current file
# holds only the running month; bounded scans and appends stay bounded forever.
ledger_files() {
  local archive="${LEDGER%.jsonl}" candidate
  [ "$archive" != "$LEDGER" ] || archive="$LEDGER.d"
  if [ -d "$archive" ]; then
    for candidate in "$archive"/*.jsonl; do
      [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
      printf '%s\n' "$candidate"
    done
  fi
  [ ! -f "$LEDGER" ] || printf '%s\n' "$LEDGER"
}

# Moves a ledger whose rows predate the running month into
# state/jev-ledger/YYYY-MM.jsonl. Called under the ledger lock before an append.
rotate_ledger() { # <today>
  local today=$1 first archive dir
  [ -s "$LEDGER" ] || return 0
  first=$(head -n 1 "$LEDGER" 2>/dev/null | jq -r 'if (.date | type) == "string" then .date[0:7] else empty end' 2>/dev/null) || return 0
  [ -n "$first" ] || return 0
  [ "$first" != "${today:0:7}" ] || return 0
  dir="${LEDGER%.jsonl}"
  [ "$dir" != "$LEDGER" ] || dir="$LEDGER.d"
  mkdir -p "$dir" || return 1
  archive="$dir/$first.jsonl"
  [ ! -L "$archive" ] || return 1
  cat "$LEDGER" >> "$archive" || return 1
  chmod 0600 "$archive" 2>/dev/null || true
  : > "$LEDGER" || return 1
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
  local row=$1 day
  jq -e "$ledger_row_valid_filter" >/dev/null 2>&1 <<<"$row" || return 1
  day=$(jq -r '.date' <<<"$row") || return 1
  rotate_ledger "$day" || return 1
  printf '%s\n' "$row" >> "$LEDGER"
}

envelope_valid() { # <envelope-file>
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
    ((.ledger | has("context") | not) or
      ((.ledger.context | type) == "object" and
       all(.ledger.context | to_entries[];
         (.value | type) == "string" and
         (.key as $name | ($root.request.state[$name] | type) == "object")))) and
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
       named_questions(.ledger.verdict.questions; .request.questions) and
       (.ledger.baseline_decision | type) == "object" and
       all(.ledger.verdict.questions[]; . as $name | $root.ledger.baseline_decision | has($name))
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
  ' "$1" >/dev/null 2>&1
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
      (reduce $v.questions[] as $q ({}; . + {($q):$answers[$q].confidence})) as $confidences |
      {verdict:$out, confidence:([$confidences[]] | min), confidences:$confidences, flagged:[],
       rationale:"Each returned Choice winner is retained with the confidence Jev returned for it; the row confidence is the lowest of those and summarizes the batch without gating any answer."}
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
  LAST_ATTEMPT_ID=$id
  cost=$(jq -cn --argjson tokens "$tokens" --argjson rate "$PRICE_PER_MILLION" '$tokens * $rate / 1000000')
  row=$(jq -cn --arg now "$now" --arg today "$today" --arg id "$id" \
    --arg use "$use" --arg subject "$subject" --arg mode "$EFFECTIVE_MODE" \
    --arg configured_mode "$CONFIGURED_MODE" --arg reason "$reason" --arg baseline_rationale "$baseline_rationale" \
    --argjson input_tokens "$tokens" --argjson floor "$CONFIDENCE_FLOOR" \
    --argjson baseline "$baseline" --argjson latency "$latency" --argjson cost "$cost" \
    --argjson estimate "$estimate" --argjson bytes "$bytes" --argjson truncated "$truncated" \
    --arg response_model "$RESPONSE_MODEL" '
    {schema_version:2,timestamp:$now,date:$today,consultation_id:$id,use:$use,subject:$subject,
     mode:$mode,configured_mode:$configured_mode,network_attempted:true,available:false,
     unavailable_reason:$reason,input_tokens:$input_tokens,input_tokens_source:"estimate",
     jev_verdict:null,jev_rationale:("Jev was unavailable: " + $reason),jev_probabilities:{},
     confidence:null,confidence_floor:$floor,existing_decision:$baseline,
     baseline_decision:$baseline,baseline_rationale:$baseline_rationale,agreement:null,
     agreement_keys:null,differing_keys:null,
     decision_after_jev:$baseline,final_decision:null,eventual_outcome:null,label_source:null,corrected:false,latency_ms:$latency,
     cost_usd:$cost,estimated_big_model_tokens:$estimate,request_bytes:$bytes,used_jev:false,
     truncated:$truncated,jev_flagged:[],jev_confidences:{},used_jev_keys:{},
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
    reason='mode-off'
  elif [ "$keystate" = absent ]; then
    reason=missing-key
  elif [ "$USE_CALL_CAP" = 0 ] || [ "$DAILY_CALL_CAP" = 0 ]; then
    reason=no-budget
  fi
  case "$reason" in
    '') explanation="$use is $EFFECTIVE_MODE" ;;
    no-budget) explanation="$use is $EFFECTIVE_MODE but its share of daily.call_cap is 0, so every consultation is refused" ;;
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

# One question group is one verdict question plus every request question that
# shares its state key, so a triage item keeps its attention and answer-kind
# Choices together. A state container keyed by the group name is sliced to that
# group; `ledger.context` names a shared container whose entries are pulled in
# by reference, so a part carries only the entries its own group cites.
#
# Only a per-key verdict may be split. An aggregate verdict such as `all_noul`
# is one claim about every named question, so a part of it is not a consultation
# in its own right: each part would append a row asserting the whole subject's
# verdict over the questions it happened to carry, and the report would count
# one prediction N times. Strategies with no per-question state, such as the
# commit lint, are never split either. Every part of a split therefore sets
# `ledger.subject` to its own group, so each row is one subject, finalize
# matches one row, and the report counts each subject exactly once.
#
# Everything a part carries that its group does not own is
# shared: the state keys copied verbatim plus the `ledger.context` entries that
# group cites. Summed over the parts and less the distinct bytes those parts
# cover between them, that is what the split duplicates, and the plan is
# abandoned unless the duplication is both smaller than the group-owned material
# and small enough to fit one per-call budget. Ten questions citing one 20KB
# page fail both, exactly as a 120KB report shared by five short criteria does:
# the group-owned material is not what makes the envelope oversized, and ten
# near-identical requests buy nothing one shortened request would not. Ten
# questions citing ten different pages duplicate nothing and still split.
# shellcheck disable=SC2016 # jq program; dollar names belong to jq.
split_plan_filter='
  def gkey: sub("__.*$"; "");
  . as $env
  | ($env.request.state) as $state
  | ($env.request.questions) as $rq
  | ($env.ledger.verdict) as $v
  | ($env.ledger.context // {}) as $ctx
  | (if $v.strategy == "choices" then ($v.questions // []) else [] end) as $vq
  | ([$vq[] | gkey] | unique) as $gkeys
  | ([$state | to_entries[] | select((.value | type) == "object")]) as $objects
  | ([$gkeys[] as $g | {g:$g, containers:[$objects[] | select(.value | has($g)) | .key]}]) as $bare
  | ([$bare[].containers] | add // [] | unique) as $owned
  | (($state | keys) - $owned) as $shared
  | ([$bare[] as $grp
      | ($grp.g) as $g
      | $grp + {shared: (reduce $shared[] as $k ({};
          if ($ctx | has($k)) and (($state[$k] | type) == "object") then
            ([$grp.containers[] as $c | $state[$c][$g]
               | if type == "object" then .[$ctx[$k]] else empty end]
             | map(select(type == "string")) | unique) as $names
            | . + {($k): (reduce $names[] as $n ({};
                if $state[$k] | has($n) then . + {($n): $state[$k][$n]} else . end))}
          else . + {($k): $state[$k]} end))}]) as $groups
  | ([$groups[].shared | tojson | utf8bytelength] | add // 0) as $shared_sum
  | ((reduce $groups[].shared as $o ({}; . * $o)) | tojson | utf8bytelength) as $shared_distinct
  | ($shared_sum - $shared_distinct) as $duplicated_bytes
  | ((reduce $owned[] as $k ({}; . + {($k): $state[$k]})) | tojson | utf8bytelength) as $owned_bytes
  | if ($groups | length) < 2 or any($groups[]; (.containers | length) == 0)
       or $duplicated_bytes > $owned_bytes
       or $duplicated_bytes > $budget then null
    else
      [ $groups[] as $grp
        | ($grp.g) as $g
        | ([$vq[] | select(gkey == $g)]) as $part_vq
        | (reduce $grp.containers[] as $c ({}; . + {($c): {($g): $state[$c][$g]}})) as $own
        | {request:{state:($grp.shared + $own),
                    questions:($rq | with_entries(select(.key | gkey == $g)))},
           ledger:($env.ledger
             | .subject = ($env.ledger.subject + "#" + $g)
             | .baseline_decision = (if ($env.ledger.baseline_decision | type) == "object"
                 then ($env.ledger.baseline_decision
                       | with_entries(select(.key as $k | $part_vq | index($k) != null)))
                 else $env.ledger.baseline_decision end)
             | .estimated_big_model_tokens =
                 (($env.ledger.estimated_big_model_tokens * ($part_vq | length) / ($vq | length)) | round)
             | .verdict = ($v | .questions = $part_vq))}
      ]
    end
'

# Today's call count and spend, overall and for one use, from the date-matching
# lines only. A day with no rows at all still prints four zeros, so an empty
# string means the scan itself failed - one unparseable line bearing today's
# date is enough - and every caller must refuse rather than read it as an
# unspent budget.
day_usage_counts() { # <use> <day>
  grep -F "\"date\":\"$2\"" "$LEDGER" 2>/dev/null | jq -s -r --arg use "$1" '
    [(map(select(.network_attempted)) | length),
     (map(.cost_usd) | add // 0),
     (map(select(.use == $use and .network_attempted)) | length),
     (map(select(.use == $use) | .cost_usd) | add // 0)] | @tsv' 2>/dev/null
}

# 0 when every question this envelope's verdict names had its own state
# shortened. A question's state is the group its key belongs to, so a criterion
# is judged on a stub when `acceptance_criteria.criterion_2` was shortened, and
# a shortened shared report does not make any single question unjudged.
all_verdict_questions_truncated() { # <envelope-file>
  jq -e '
    def gkey: sub("__.*$"; "");
    (.ledger.verdict.questions // []) as $q
    | ([(.ledger.truncated_keys // {} | keys)[] | split(".")[]] | unique) as $cut
    | ($q | length) > 0 and all($q[]; . as $k | ($cut | index($k | gkey)) != null)
  ' "$1" >/dev/null 2>&1
}

# The pinned model and the question block with no state at all: what a request
# costs before any material is attached. shrink_to_budget can only shorten
# state, so a cap this alone cannot fit is one no shortening will ever satisfy,
# and the refusal says so rather than blaming the material.
question_block_tokens() { # <envelope-file>
  local bytes
  bytes=$(jq -c --arg model "$MODEL" '{model:$model,questions:.request.questions,state:{}}' "$1" 2>/dev/null \
    | LC_ALL=C wc -c | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) printf '0\n'; return 0 ;; esac
  printf '%s\n' "$(( (bytes + BYTES_PER_TOKEN - 1) / BYTES_PER_TOKEN ))"
}

request_body_bytes() { # <envelope-file>
  jq -c --arg model "$MODEL" '.request + {model:$model}' "$1" 2>/dev/null | LC_ALL=C wc -c | tr -d ' '
}

# Rewrites <envelope-file> into one envelope per question group. Prints the part
# count, or returns 1 when this envelope has no per-question state to split on
# or when splitting it would only duplicate shared state across the parts.
plan_split() { # <envelope-file> <parts-dir> <budget-bytes>
  local file=$1 dir=$2 budget=$3 count=0 line
  jq -c --argjson budget "$budget" "$split_plan_filter" "$file" > "$dir/plan.json" 2>/dev/null || return 1
  [ -s "$dir/plan.json" ] || return 1
  case "$(jq -r 'if type == "array" then length else 0 end' "$dir/plan.json" 2>/dev/null)" in
    ''|0|1) return 1 ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" > "$dir/part-$(printf '%04d' "$count").json" || return 1
    count=$((count + 1))
  done < <(jq -c '.[]' "$dir/plan.json" 2>/dev/null)
  [ "$count" -ge 2 ] || return 1
  printf '%s\n' "$count"
}

# An N-part split costs N calls and N request bodies, so a split that would run
# into a call or spend cap partway through leaves the later questions
# unanswered for the rest of the day. Projected here against today's counters so
# a split that cannot complete is never started; consult_one still re-checks
# every cap under the ledger lock before each request, and one shrunk request
# remains the fallback.
split_affordable() { # <use> <parts-dir> <count> <budget-bytes>
  local use=$1 dir=$2 count=$3 budget=$4 index=0 part bytes tokens total=0
  local today counts calls spend use_calls use_spend projected
  while [ "$index" -lt "$count" ]; do
    part="$dir/part-$(printf '%04d' "$index").json"
    index=$((index + 1))
    [ -f "$part" ] || continue
    bytes=$(request_body_bytes "$part")
    case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
    [ "$bytes" -le "$budget" ] || bytes=$budget
    tokens=$(( (bytes + BYTES_PER_TOKEN - 1) / BYTES_PER_TOKEN ))
    total=$((total + tokens))
  done
  today=$(date -u +%Y-%m-%d)
  counts=$(day_usage_counts "$use" "$today") || counts=
  [ -n "$counts" ] || return 1
  IFS=$'\t' read -r calls spend use_calls use_spend <<<"$counts"
  case "${calls:-x}" in ''|*[!0-9]*) return 1 ;; esac
  case "${use_calls:-x}" in ''|*[!0-9]*) return 1 ;; esac
  [ $((calls + count)) -le "$DAILY_CALL_CAP" ] || return 1
  [ $((use_calls + count)) -le "$USE_CALL_CAP" ] || return 1
  projected=$(jq -cn --argjson tokens "$total" --argjson rate "$PRICE_PER_MILLION" \
    '$tokens * $rate / 1000000' 2>/dev/null) || return 1
  jq -en --argjson spend "${spend:-0}" --argjson cost "$projected" --argjson cap "$DAILY_SPEND_CAP" \
    '($spend + $cost) <= $cap' >/dev/null 2>&1 || return 1
  jq -en --argjson spend "${use_spend:-0}" --argjson cost "$projected" --argjson cap "$USE_SPEND_CAP" \
    '($spend + $cost) <= $cap' >/dev/null 2>&1 || return 1
  return 0
}

# Shortens the longest bounded string in a part's state until the part fits the
# per-call budget, marking ledger.truncated so the row records that Jev saw less
# than the adapter gathered. Which strings were shortened, and to how many
# characters each, is recorded in ledger.truncated_keys and carried to the
# caller as truncated_keys: an adapter must be able to tell that the answer it
# got is about a stub rather than about the material it gathered, or it will
# present a judgement of one as a judgement of the other. A part that cannot be
# shrunk enough is left alone for consult_one to refuse and record.
shrink_to_budget() { # <envelope-file> <budget-bytes>
  local file=$1 budget=$2 bytes longest len newlen iter=0 tmp="$1.shrink"
  while :; do
    bytes=$(request_body_bytes "$file")
    case "$bytes" in ''|*[!0-9]*) return 0 ;; esac
    [ "$bytes" -gt "$budget" ] || return 0
    iter=$((iter + 1))
    [ "$iter" -le 32 ] || return 0
    longest=$(jq -c '
      [.request.state | paths(type == "string") as $p | {p:$p, n:(getpath($p) | utf8bytelength)}]
      | max_by(.n) // empty' "$file" 2>/dev/null) || return 0
    [ -n "$longest" ] || return 0
    len=$(jq -r '.n' <<<"$longest" 2>/dev/null) || return 0
    case "$len" in ''|*[!0-9]*) return 0 ;; esac
    [ "$len" -gt 160 ] || return 0
    newlen=$((len - (bytes - budget) - 160))
    [ "$newlen" -ge 32 ] || newlen=32
    jq -c --argjson p "$(jq -c '.p' <<<"$longest")" --argjson n "$newlen" '
      ($p | map(tostring) | join(".")) as $key |
      (.request.state | getpath($p)) as $text |
      (($text | length) * $n / ($text | utf8bytelength) | floor) as $kept |
      .request.state |= setpath($p; ((getpath($p))[0:$kept]) + "\n(truncated to fit the Jev per-call budget)")
      | .ledger.truncated = true
      | .ledger.truncated_keys = ((.ledger.truncated_keys // {}) + {($key): $kept})' \
      "$file" > "$tmp" 2>/dev/null || return 0
    mv -f "$tmp" "$file" 2>/dev/null || return 0
  done
}

# A budget refusal is evidence too: without a row, an operator whose whole day
# was refused sees nothing at all on any surface. These rows never attempted the
# network, so they cost nothing and consume no call budget.
record_refusal_row() { # <use> <envelope-file> <reason> <bytes>
  local use=$1 file=$2 reason=$3 bytes=$4
  local subject baseline baseline_rationale estimate truncated now today id row
  subject=$(jq -r '.ledger.subject' "$file" 2>/dev/null) || return 1
  baseline=$(jq -c '.ledger.baseline_decision' "$file" 2>/dev/null) || return 1
  baseline_rationale=$(jq -r '.ledger.baseline_rationale' "$file" 2>/dev/null) || return 1
  estimate=$(jq -r '.ledger.estimated_big_model_tokens' "$file" 2>/dev/null) || return 1
  truncated=$(jq -r '.ledger.truncated // false' "$file" 2>/dev/null) || return 1
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  today=${now%%T*}
  id="${today//-/}T${now#*T}-$$-${RANDOM:-0}"
  row=$(jq -cn --arg now "$now" --arg today "$today" --arg id "$id" \
    --arg use "$use" --arg subject "$subject" --arg mode "$EFFECTIVE_MODE" \
    --arg configured_mode "$CONFIGURED_MODE" --arg reason "$reason" \
    --arg baseline_rationale "$baseline_rationale" --argjson floor "$CONFIDENCE_FLOOR" \
    --argjson baseline "$baseline" --argjson estimate "$estimate" \
    --argjson bytes "$bytes" --argjson truncated "$truncated" '
    {schema_version:2,timestamp:$now,date:$today,consultation_id:$id,use:$use,subject:$subject,
     mode:$mode,configured_mode:$configured_mode,network_attempted:false,available:false,
     unavailable_reason:$reason,input_tokens:0,input_tokens_source:"estimate",
     jev_verdict:null,jev_rationale:("Jev was not consulted: " + $reason),jev_probabilities:{},
     confidence:null,confidence_floor:$floor,existing_decision:$baseline,
     baseline_decision:$baseline,baseline_rationale:$baseline_rationale,agreement:null,
     agreement_keys:null,differing_keys:null,
     decision_after_jev:$baseline,final_decision:null,eventual_outcome:null,label_source:null,corrected:false,
     latency_ms:0,cost_usd:0,estimated_big_model_tokens:$estimate,request_bytes:$bytes,
     used_jev:false,truncated:$truncated,jev_flagged:[],jev_confidences:{},used_jev_keys:{},
     response_model:null,jev_answers:{}}') || return 1
  append_ledger_row "$row"
}

# Consults Jev for one planned part and prints that part's result JSON. Sets
# PART_STOP when the refusal is a budget one, because every later part of the
# same consultation would be refused for the same reason.
consult_one() { # <use> <envelope-file>
  local use=$1 file=$2
  local fallback baseline_rationale subject estimate truncated truncated_keys
  local today counts calls spend use_calls use_spend pre_cost total
  local http=000 t0=0 t1=0 latency=0 actual_tokens=0 cost=0
  local request_json request_bytes request_tokens derive row result now id
  local used_jev=false decision_after source=reported probabilities agreement reason=''
  local confidences='{}' qualified='{}' used_keys='{}' request_api=''
  local agreement_keys=null differing_keys=null
  subject=$(jq -r '.ledger.subject' "$file")
  fallback=$(jq -c '.ledger.baseline_decision' "$file")
  baseline_rationale=$(jq -r '.ledger.baseline_rationale' "$file")
  estimate=$(jq -r '.ledger.estimated_big_model_tokens' "$file")
  truncated=$(jq -r '.ledger.truncated // false' "$file")
  truncated_keys=$(jq -c '.ledger.truncated_keys // {}' "$file")
  RESPONSE_MODEL=

  request_json=$(jq -c --arg model "$MODEL" '.request + {model:$model}' "$file") || {
    emit_unavailable "$use" request-invalid "$fallback"
    return 0
  }
  request_bytes=$(LC_ALL=C printf '%s' "$request_json" | wc -c | tr -d ' ')
  case "$request_bytes" in ''|*[!0-9]*) emit_unavailable "$use" token-estimate-failed "$fallback"; return 0 ;; esac
  request_tokens=$(( (request_bytes + BYTES_PER_TOKEN - 1) / BYTES_PER_TOKEN ))
  # Crediting the adapter's estimate of material Jev never saw would book a
  # saving that did not happen, so a shortened request is only ever credited
  # the tokens it actually carried.
  [ "$truncated" != true ] || estimate=$request_tokens

  lock_ledger || { emit_unavailable "$use" ledger-busy "$fallback"; return 0; }
  today=$(date -u +%Y-%m-%d)
  if [ "$request_tokens" -gt "$PER_CALL_TOKEN_CAP" ]; then
    reason=per-call-token-cap
    [ "$(question_block_tokens "$file")" -le "$PER_CALL_TOKEN_CAP" ] || reason=question-block-token-cap
    record_refusal_row "$use" "$file" "$reason" "$request_bytes" || true
    unlock_ledger || true
    emit_unavailable "$use" "$reason" "$fallback"
    return 0
  fi
  # Only today's rows can consume today's budget, so the scan is bounded by one
  # day of evidence rather than by the whole retained ledger.
  counts=$(day_usage_counts "$use" "$today") || counts=
  IFS=$'\t' read -r calls spend use_calls use_spend <<<"$counts"
  if [ -z "${calls:-}" ] || [ -z "${spend:-}" ] || [ -z "${use_calls:-}" ] || [ -z "${use_spend:-}" ]; then
    record_refusal_row "$use" "$file" ledger-unreadable "$request_bytes" || true
    PART_STOP=ledger-unreadable
    unlock_ledger || true
    emit_unavailable "$use" ledger-unreadable "$fallback"
    return 0
  fi
  if [ "$calls" -ge "$DAILY_CALL_CAP" ]; then
    record_refusal_row "$use" "$file" daily-call-cap "$request_bytes" || true
    PART_STOP=daily-call-cap
    unlock_ledger || true
    emit_unavailable "$use" daily-call-cap "$fallback"
    return 0
  fi
  if [ "$use_calls" -ge "$USE_CALL_CAP" ]; then
    record_refusal_row "$use" "$file" use-daily-call-cap "$request_bytes" || true
    PART_STOP='use-daily-call-cap'
    unlock_ledger || true
    emit_unavailable "$use" use-daily-call-cap "$fallback"
    return 0
  fi
  pre_cost=$(jq -cn --argjson tokens "$request_tokens" --argjson rate "$PRICE_PER_MILLION" '$tokens * $rate / 1000000')
  total=$(jq -cn --argjson spend "$spend" --argjson cost "$pre_cost" '$spend + $cost')
  if jq -en --argjson total "$total" --argjson cap "$DAILY_SPEND_CAP" '$total > $cap' >/dev/null; then
    record_refusal_row "$use" "$file" daily-spend-cap "$request_bytes" || true
    PART_STOP=daily-spend-cap
    unlock_ledger || true
    emit_unavailable "$use" daily-spend-cap "$fallback"
    return 0
  fi
  total=$(jq -cn --argjson spend "$use_spend" --argjson cost "$pre_cost" '$spend + $cost')
  if jq -en --argjson total "$total" --argjson cap "$USE_SPEND_CAP" '$total > $cap' >/dev/null; then
    record_refusal_row "$use" "$file" use-daily-spend-cap "$request_bytes" || true
    PART_STOP='use-daily-spend-cap'
    unlock_ledger || true
    emit_unavailable "$use" use-daily-spend-cap "$fallback"
    return 0
  fi

  [ -z "$RESPONSE_FILE" ] || rm -f -- "$RESPONSE_FILE" 2>/dev/null || true
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

  # A verdict every one of whose questions was answered from a shortened stub
  # is not a judgement of the material the adapter gathered. Recording it as a
  # scored prediction would put it in the report's agreement and error columns
  # and credit its tokens as avoided, so the row says the consultation could
  # not be scored and the caller keeps its baseline.
  if [ "$truncated" = true ] && all_verdict_questions_truncated "$file"; then
    if ! record_unavailable_attempt "$use" "$subject" questions-truncated "$fallback" "$baseline_rationale" "$estimate" "$request_tokens" "$latency" "$request_bytes" "$truncated" >/dev/null; then
      unlock_ledger || true
      emit_unavailable "$use" ledger-write-failed "$fallback" "$truncated_keys"
      return 0
    fi
    unlock_ledger || true
    jq -cn --arg use "$use" --arg mode "$EFFECTIVE_MODE" --arg cmode "$CONFIGURED_MODE" \
      --arg id "$LAST_ATTEMPT_ID" --argjson floor "$CONFIDENCE_FLOOR" \
      --argjson fallback "$fallback" --argjson shortened "$truncated_keys" \
      '{status:"unavailable",use:$use,mode:$mode,configured_mode:$cmode,
        reason:"questions-truncated",consultation_id:$id,confidence_floor:$floor,
        fallback_decision:$fallback,truncated:true,truncated_keys:$shortened}' \
      || emit_unavailable "$use" questions-truncated "$fallback" "$truncated_keys"
    return 0
  fi

  derive=$(derive_verdict "$file" "$RESPONSE_FILE") || {
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
  # A per-key verdict disagrees per key. Collapsing a batch of ten to one
  # boolean makes the normal case - some items routine - look like a total
  # divergence and hides which item actually differed, so the row carries both.
  agreement_keys=$(jq -cn --argjson jev "$(jq -c '.verdict' <<<"$derive")" --argjson baseline "$fallback" '
    if ($jev | type) == "object" and ($baseline | type) == "object"
    then ($jev | with_entries(.value = (.value == $baseline[.key]))) else null end
  ') || agreement_keys=null
  differing_keys=$(jq -cn --argjson keys "$agreement_keys" '
    if $keys == null then null
    else ([$keys | to_entries[] | select(.value | not) | .key] | sort) end
  ') || differing_keys=null
  agreement=$(jq -cn --argjson jev "$(jq -c '.verdict' <<<"$derive")" --argjson baseline "$fallback" \
    --argjson keys "$agreement_keys" '
    if $jev == null or $baseline == null then null
    elif $keys != null then all($keys[]; .)
    else $jev == $baseline end
  ')
  # A per-key strategy is gated per key: one unconfident answer in a batch of ten
  # must not discard the nine confident ones, and the row's scalar confidence is
  # only a summary. Scalar strategies keep the single all-or-nothing gate.
  confidences=$(jq -c '.confidences // {}' <<<"$derive")
  qualified=$(jq -cn --argjson confidences "$confidences" --argjson floor "$CONFIDENCE_FLOOR" \
    '$confidences | map_values(. >= $floor)') || qualified='{}'
  if [ "$confidences" = '{}' ]; then
    used_keys='{}'
    if [ "$EFFECTIVE_MODE" = active ] \
      && jq -en --argjson confidence "$(jq -c '.confidence' <<<"$derive")" \
        --argjson floor "$CONFIDENCE_FLOOR" '$confidence >= $floor' >/dev/null; then
      used_jev=true
      decision_after=$(jq -c '.verdict' <<<"$derive")
    else
      used_jev=false
      decision_after=$fallback
    fi
  else
    used_keys=$(jq -cn --argjson qualified "$qualified" --arg mode "$EFFECTIVE_MODE" \
      '$qualified | map_values(. and $mode == "active")') || used_keys='{}'
    used_jev=$(jq -r 'any(.[]; .)' <<<"$used_keys")
    decision_after=$(jq -cn --argjson baseline "$fallback" --argjson verdict "$(jq -c '.verdict' <<<"$derive")" \
      --argjson used "$used_keys" '
      reduce ($used | to_entries[]) as $entry ($baseline;
        if $entry.value then . + {($entry.key):$verdict[$entry.key]} else . end)') || {
      confidences='{}'
      qualified='{}'
      used_keys='{}'
      used_jev=false
      decision_after=$fallback
    }
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
    --argjson agreement_keys "$agreement_keys" --argjson differing_keys "$differing_keys" \
    --argjson after "$decision_after" --argjson latency "$latency" \
    --argjson cost "$cost" --argjson estimate "$estimate" --argjson bytes "$request_bytes" \
    --argjson truncated "$truncated" --arg response_model "$RESPONSE_MODEL" \
    --argjson flagged "$(jq -c '.flagged // []' <<<"$derive")" \
    --argjson confidences "$confidences" --argjson used_keys "$used_keys" \
    --argjson used "$used_jev" --argjson answers "$(jq -c '.answers' "$RESPONSE_FILE")" '
    {schema_version:2,timestamp:$now,date:$today,consultation_id:$id,use:$use,subject:$subject,
     mode:$mode,configured_mode:$configured_mode,network_attempted:true,available:true,
     unavailable_reason:null,input_tokens:$input_tokens,input_tokens_source:$source,
     jev_verdict:$verdict,jev_rationale:$jev_rationale,jev_probabilities:$probabilities,
     confidence:$confidence,confidence_floor:$floor,
     existing_decision:$baseline,baseline_decision:$baseline,baseline_rationale:$baseline_rationale,
     agreement:$agreement,agreement_keys:$agreement_keys,differing_keys:$differing_keys,
     decision_after_jev:$after,final_decision:null,eventual_outcome:null,label_source:null,
     corrected:false,latency_ms:$latency,cost_usd:$cost,
     estimated_big_model_tokens:$estimate,request_bytes:$bytes,used_jev:$used,
     truncated:$truncated,jev_flagged:$flagged,jev_confidences:$confidences,used_jev_keys:$used_keys,
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
    --argjson truncated "$truncated" --argjson truncated_keys "$truncated_keys" \
    --argjson confidences "$confidences" \
    --argjson qualified "$qualified" --argjson used_keys "$used_keys" \
    --argjson agreement "$agreement" --argjson used "$used_jev" \
    --argjson agreement_keys "$agreement_keys" --argjson differing_keys "$differing_keys" '
    {status:"available",consultation_id:$id,use:$use,mode:$mode,configured_mode:$configured_mode,
     model:$model,confidence_floor:$floor,verdict:$derive.verdict,confidence:$derive.confidence,
     answers:$answers,input_tokens:$input_tokens,latency_ms:$latency,cost_usd:$cost,
     jev_rationale:$jev_rationale,jev_probabilities:$probabilities,truncated:$truncated,
     truncated_keys:$truncated_keys,
     flagged:($derive.flagged // []),
     confidences:$confidences,qualified:$qualified,used_jev_keys:$used_keys,
     fallback_decision:$fallback,baseline_rationale:$baseline_rationale,agreement:$agreement,
     agreement_keys:$agreement_keys,differing_keys:$differing_keys,used_jev:$used}
     + (if $derive.risks then {risks:$derive.risks} else {} end)') || {
    emit_unavailable "$use" result-render-failed "$fallback"
    return 0
  }
  printf '%s\n' "$result"
}

# Recombines the parts of a split consultation into the single result shape the
# adapters already consume, so splitting is invisible above this boundary. Only
# a per-key verdict is ever split, so there is no aggregate to synthesise here:
# the parts' answers are disjoint key sets and the merged verdict is their
# union.
#
# A part can fail on its own - a five-second timeout, an HTTP error, a malformed
# response - while its siblings answer. A per-key verdict is defined key by key,
# so it keeps the answers it has; `answers` holds exactly the questions Jev
# answered and `parts_unavailable` names why the rest are missing, and no caller
# may read an absent key as an answer.
# shellcheck disable=SC2016 # jq program; dollar names belong to jq.
merge_choice_parts() { # <use> <envelope-file> <results-jsonl>
  local use=$1 envelope=$2 results=$3
  jq -s -c --arg use "$use" --arg mode "$EFFECTIVE_MODE" --arg cmode "$CONFIGURED_MODE" \
    --slurpfile envelope "$envelope" '
    . as $parts
    | ($envelope[0].ledger) as $led
    | ([$parts[] | select(.status == "available")]) as $ok
    | ([$parts[] | select(.status != "available") | .reason // "unavailable"]) as $refused
    | if ($ok | length) == 0 then
        {status:"unavailable", use:$use, mode:$mode, configured_mode:$cmode,
         reason:($refused[0] // "unavailable"), fallback_decision:$led.baseline_decision,
         parts:($parts | length), parts_unavailable:$refused}
      else
        ($ok | map(.answers) | add) as $answers
        | ($ok | map(.confidences // {}) | add) as $confidences
        | ($ok | map(.qualified // {}) | add) as $qualified
        | ($ok | map(.used_jev_keys // {}) | add) as $used_keys
        | ($ok | map(.jev_probabilities // {}) | add) as $probabilities
        | ($ok | map(.verdict) | add) as $verdict
        | (if ($verdict | type) == "object" and ($led.baseline_decision | type) == "object"
           then ($verdict | with_entries(.value = (.value == $led.baseline_decision[.key])))
           else null end) as $agreement_keys
        | (if $agreement_keys == null then null
           else ([$agreement_keys | to_entries[] | select(.value | not) | .key] | sort) end) as $differing_keys
        | {status:"available",
           consultation_id:$ok[0].consultation_id,
           consultation_ids:[$ok[].consultation_id],
           use:$use, mode:$ok[0].mode, configured_mode:$ok[0].configured_mode,
           model:$ok[0].model, confidence_floor:$ok[0].confidence_floor,
           verdict:$verdict, confidence:([$ok[].confidence] | min),
           answers:$answers,
           input_tokens:($ok | map(.input_tokens) | add),
           latency_ms:($ok | map(.latency_ms) | add),
           cost_usd:($ok | map(.cost_usd) | add),
           jev_rationale:($ok[0].jev_rationale + " Answered across " + (($parts | length) | tostring)
             + " budget-sized requests."),
           jev_probabilities:$probabilities,
           truncated:(any($ok[]; .truncated == true)),
           truncated_keys:($ok | map(.truncated_keys // {}) | add),
           flagged:($ok | map(.flagged // []) | add | unique),
           confidences:$confidences, qualified:$qualified, used_jev_keys:$used_keys,
           fallback_decision:$led.baseline_decision, baseline_rationale:$led.baseline_rationale,
           agreement_keys:$agreement_keys, differing_keys:$differing_keys,
           agreement:(if $verdict == null or $led.baseline_decision == null then null
                      elif $agreement_keys != null then all($agreement_keys[]; .)
                      else $verdict == $led.baseline_decision end),
           used_jev:(any($ok[]; .used_jev)),
           parts:($parts | length), parts_unavailable:$refused}
      end' "$results"
}

cmd_consult() {
  local use=${1:-} fallback=null budget=0 bytes=0 parts=0 index=0 part=''
  local TYPESAFE_API_KEY_PRIVATE='' results=''
  PART_STOP=
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
  if ! envelope_valid "$REQUEST_FILE"; then emit_unavailable "$use" request-invalid; return 0; fi
  fallback=$(jq -c '.ledger.baseline_decision' "$REQUEST_FILE")

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

  PARTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-parts.XXXXXX") || {
    emit_unavailable "$use" temp-unavailable "$fallback"
    return 0
  }
  # The budget is enforced here, for every adapter, rather than trusted to each
  # one: an over-budget envelope with a per-key verdict is split per question
  # group and then shortened, any other is shortened as one request, and only a
  # request that still cannot fit is refused - with a row, so it is never a
  # silent no-op.
  budget=$((PER_CALL_TOKEN_CAP * BYTES_PER_TOKEN))
  bytes=$(request_body_bytes "$REQUEST_FILE")
  case "$bytes" in ''|*[!0-9]*) bytes=$((budget + 1)) ;; esac
  parts=0
  if [ "$bytes" -gt "$budget" ] && [ "$use" != triage ]; then
    parts=$(plan_split "$REQUEST_FILE" "$PARTS_DIR" "$budget") || parts=0
    case "$parts" in ''|*[!0-9]*) parts=0 ;; esac
    if [ "$parts" -ge 2 ] && ! split_affordable "$use" "$PARTS_DIR" "$parts" "$budget"; then
      parts=0
    fi
  fi
  case "$parts" in ''|*[!0-9]*) parts=0 ;; esac
  if [ "$parts" -lt 2 ]; then
    parts=1
    cp -- "$REQUEST_FILE" "$PARTS_DIR/part-0000.json" || {
      emit_unavailable "$use" temp-unavailable "$fallback"
      return 0
    }
  fi
  results="$PARTS_DIR/results.jsonl"
  : > "$results"
  index=0
  while [ "$index" -lt "$parts" ]; do
    part="$PARTS_DIR/part-$(printf '%04d' "$index").json"
    index=$((index + 1))
    [ -f "$part" ] || continue
    if [ -n "$PART_STOP" ]; then
      jq -cn --arg use "$use" --arg reason "$PART_STOP" --arg mode "$EFFECTIVE_MODE" \
        --arg cmode "$CONFIGURED_MODE" --argjson fallback "$fallback" \
        '{status:"unavailable",use:$use,mode:$mode,configured_mode:$cmode,reason:$reason,
          fallback_decision:$fallback}' >> "$results"
      continue
    fi
    shrink_to_budget "$part" "$budget"
    consult_one "$use" "$part" >> "$results"
  done
  if [ "$parts" -eq 1 ]; then
    command cat "$results"
    return 0
  fi
  merge_choice_parts "$use" "$REQUEST_FILE" "$results" || {
    emit_unavailable "$use" result-render-failed "$fallback"
    return 0
  }
}

cmd_finalize() {
  local use='' subject='' decision='' label_source='' tmp updated total file
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --use) [ $# -ge 2 ] || return 2; use=$2; shift 2 ;;
      --subject) [ $# -ge 2 ] || return 2; subject=$2; shift 2 ;;
      --decision-json) [ $# -ge 2 ] || return 2; decision=$2; shift 2 ;;
      --label-source) [ $# -ge 2 ] || return 2; label_source=$2; shift 2 ;;
      *) return 2 ;;
    esac
  done
  use_valid "$use" || return 2
  [ -n "$subject" ] || return 2
  [ -n "$label_source" ] || return 2
  json_available || return 1
  jq -e . >/dev/null 2>&1 <<<"$decision" || return 2
  lock_ledger || return 1
  total=0
  # Streaming per row, over the running ledger and every archived month, so a
  # teardown never slurps the retained evidence into memory.
  while IFS= read -r file; do
    [ -s "$file" ] || continue
    validate_ledger_file "$file" || { unlock_ledger || true; return 1; }
    updated=$(jq -n --arg use "$use" --arg subject "$subject" '
      reduce inputs as $row (0;
        if $row.use == $use and $row.subject == $subject and $row.eventual_outcome == null
        then . + 1 else . end)' "$file") || { unlock_ledger || true; return 1; }
    case "$updated" in ''|*[!0-9]*) unlock_ledger || true; return 1 ;; esac
    total=$((total + updated))
    [ "$updated" -gt 0 ] || continue
    tmp=$(mktemp "$STATE/.jev-ledger.finalize.XXXXXX") || { unlock_ledger || true; return 1; }
    jq -c --arg use "$use" --arg subject "$subject" --argjson decision "$decision" \
      --arg label_source "$label_source" '
      if .use == $use and .subject == $subject and .eventual_outcome == null then
        .final_decision = $decision |
        .eventual_outcome = $decision |
        .label_source = $label_source |
        .corrected = (.decision_after_jev != null and .decision_after_jev != $decision)
      else . end
    ' "$file" > "$tmp" || { rm -f "$tmp"; unlock_ledger || true; return 1; }
    chmod 0600 "$tmp" || { rm -f "$tmp"; unlock_ledger || true; return 1; }
    mv -f "$tmp" "$file" || { rm -f "$tmp"; unlock_ledger || true; return 1; }
  done < <(ledger_files)
  unlock_ledger || return 1
  jq -cn --argjson updated "$total" '{updated:$updated}'
}

cmd_validate_ledger() {
  local file
  if [ "$#" -gt 0 ]; then
    validate_ledger_file "$1"
    return "$?"
  fi
  while IFS= read -r file; do
    validate_ledger_file "$file" || return 1
  done < <(ledger_files)
  return 0
}

case "${1:-}" in
  mode) shift; cmd_mode "$@" ;;
  status) shift; cmd_status "$@" ;;
  request-budget) shift; cmd_request_budget "$@" ;;
  consult) shift; cmd_consult "$@" ;;
  finalize) cmd_finalize "$@" ;;
  validate-ledger) shift; cmd_validate_ledger "$@" ;;
  -h|--help|help|'') sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) printf 'usage: fm-jev.sh mode|status|request-budget|consult|finalize|validate-ledger ...\n' >&2; exit 2 ;;
esac
