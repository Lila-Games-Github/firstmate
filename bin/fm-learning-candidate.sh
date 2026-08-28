#!/usr/bin/env bash
# fm-learning-candidate.sh - deterministic private learning-candidate lifecycle.
#
# This command owns the exact record schema, validation, lifecycle mechanics,
# and bounded read surfaces for incidents that may deserve reusable prevention.
# The semantic intake and routing policy is owned by
# .agents/skills/learning-candidate-lifecycle/SKILL.md; this command accepts only
# the qualifying signal classes that policy defines and never guesses whether an
# incident is meaningful.
#
# Records live as versioned JSON files under
# state/learning-candidates/<candidate-id>.json in the active FM_HOME. That
# directory is outside task-scoped state, so fm-teardown.sh never removes it.
# Mutations use the home-local state/.learning-candidates.lock and atomic rename.
# Capture makes one non-waiting lock attempt and reports temporary unavailability
# without changing candidate records; curator mutations retain the waiting lock.
# Exact repeat capture is idempotent: the candidate id is the first 24 hex digits
# of the SHA-256 digest of the canonical incident object, excluding timestamps.
# A digest collision with different content is refused.
#
# Usage:
#   fm-learning-candidate.sh capture
#     --task <origin-task> --project <project> --signal <signal-type>
#     --impact <user-visible-impact> --root-cause <root-cause>
#     --escaped-contract <contract-or-validation-rule>
#     --missing-check <missing-test-or-review-step>
#     --consumer <affected-consumer>
#     --prevention <proposed-prevention> --evidence <evidence>
#     --proposed-owner <owner-or-scope> --counterfactual <counterfactual>
#
#   fm-learning-candidate.sh get <candidate-id>
#   fm-learning-candidate.sh list [--status <state>|--all] [--limit <1..500>]
#   fm-learning-candidate.sh batch [--limit <1..100>]
#   fm-learning-candidate.sh summary [--limit <0..5>]
#
#   fm-learning-candidate.sh classify <candidate-id>
#     --curator <curator-id> --route <feature|project|firstmate|tool>
#     --owner <one-owner> --surface <surface> --recommendation <proposal>
#     --rationale <routing-rationale>
#     [skill gate options]
#
#   fm-learning-candidate.sh disposition <candidate-id>
#     --curator <curator-id>
#     --status <dismissed|documented|promoted|follow-up>
#     --note <reason> [--reference <document-pr-or-follow-up>]
#
#   fm-learning-candidate.sh dedupe <duplicate-id> --into <canonical-id>
#     --curator <curator-id> --reason <reason>
#
# Signal types are exactly:
#   captain-correction
#   review-rejection
#   escaped-defect
#   workflow-gap-blocker
#   substantive-no-mistakes-correction
#
# Classification assigns exactly one route, one owner, and one compatible
# destination surface:
#   feature   documentation | contract | tests
#   project   skill | instructions | tooling
#   firstmate pipeline
#   tool      tool-repository
# It records a recommendation only. It never edits the destination, creates a
# follow-up, pushes, merges, or otherwise exercises that owner's authority.
# The --curator identity must differ from the originating task, keeping curation
# conceptually separate from the implementation lane.
#
# A project skill classification additionally requires all of:
#   --skill-statement <feature-neutral-general-rule>
#   --skill-feature-neutral-evidence <why-the-statement-has-no-feature-nouns>
#   --skill-task-type <task-type> repeated for at least two distinct types,
#     or --skill-feature-agnostic-evidence <why-it-is-feature-agnostic>
#   --skill-procedure <repeatable-procedure>
#   --skill-load-trigger <precise-trigger>
#   --skill-counterfactual <how-it-would-have-prevented-or-exposed-this-incident>
# The executable preserves this evidence and enforces its presence; the curator
# remains responsible for the semantic truth of the evidence.
#
# `list` and `batch` default to unresolved candidates, oldest first. `list` is a
# concise tab-separated surface; `batch` emits a JSON array with complete records
# for independent curation. `summary` reads only the fixed-size `.summary.json`
# index and an optional `.summary-pending.json` commit probe, so its memory and
# read work do not grow with the store. Mutations maintain that index under the
# lifecycle lock; a missing legacy index is rebuilt only by a curator mutation.
# `summary` is silent when no candidate is unresolved and otherwise emits at most
# five capped detail lines plus one remainder line. `get` emits one complete JSON
# record.
#
# Lifecycle states are unresolved, dismissed, documented, promoted, follow-up,
# and duplicate. Dismissal may precede classification. Documented, promoted, and
# follow-up dispositions require a classification and a reference. Dedupe leaves
# the canonical candidate unresolved and marks only the duplicate; a canonical
# that already owns duplicates cannot itself become a duplicate. The duplicate
# disposition is authoritative and its canonical backlink is derived. Exact
# retries repair a missing backlink and remain idempotent; conflicting retries
# are refused.
#
# FM_HOME selects the private operational home. FM_STATE_OVERRIDE overrides its
# state directory. FM_LEARNING_NOW may provide one non-empty timestamp for a
# deterministic fixture; otherwise UTC RFC3339 time is used. jq is required for
# every lifecycle command; capture additionally requires shasum or sha256sum.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CANDIDATE_DIR="$STATE/learning-candidates"
MUTATION_LOCK="$STATE/.learning-candidates.lock"
SUMMARY_INDEX="$CANDIDATE_DIR/.summary.json"
SUMMARY_PENDING="$CANDIDATE_DIR/.summary-pending.json"
MAX_TEXT_BYTES=8192

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() {
  printf 'fm-learning-candidate: %s\n' "$*" >&2
  exit 2
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
}

require_hash_tool() {
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
    || die "shasum or sha256sum is required"
}

validate_slug() { # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) die "$label must be a non-empty privacy-safe slug" ;;
  esac
}

validate_candidate_id() { # <value>
  local value=$1 suffix
  case "$value" in lc-*) ;; *) die "invalid candidate id: $value" ;; esac
  suffix=${value#lc-}
  [ "${#suffix}" -eq 24 ] || die "invalid candidate id: $value"
  case "$suffix" in *[!0-9a-f]*) die "invalid candidate id: $value" ;; esac
}

validate_text() { # <label> <value> [max-bytes]
  local label=$1 value=$2 max=${3:-$MAX_TEXT_BYTES} bytes
  [ -n "$value" ] || die "$label must not be empty"
  bytes=$(printf '%s' "$value" | LC_ALL=C wc -c | tr -d ' ')
  [ "$bytes" -le "$max" ] || die "$label exceeds $max bytes"
}

validate_nonblank_text() { # <label> <value> [max-bytes]
  local label=$1 value=$2 max=${3:-$MAX_TEXT_BYTES} compact
  validate_text "$label" "$value" "$max"
  compact=$(printf '%s' "$value" | LC_ALL=C tr -d '[:space:]')
  [ -n "$compact" ] || die "$label must contain non-whitespace text"
}

validate_one_line() { # <label> <value> [max-bytes]
  local label=$1 value=$2 max=${3:-512}
  validate_text "$label" "$value" "$max"
  case "$value" in *$'\n'*|*$'\r'*) die "$label must be one line" ;; esac
}

validate_signal() {
  case "$1" in
    captain-correction|review-rejection|escaped-defect|workflow-gap-blocker|substantive-no-mistakes-correction) ;;
    *) die "invalid signal type: $1" ;;
  esac
}

validate_lifecycle_state() {
  case "$1" in
    unresolved|dismissed|documented|promoted|follow-up|duplicate) ;;
    *) die "invalid lifecycle state: $1" ;;
  esac
}

validate_positive_limit() { # <value> <max>
  case "$1" in ''|*[!0-9]*) die "limit must be an integer from 1 to $2" ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le "$2" ] || die "limit must be an integer from 1 to $2"
}

validate_summary_limit() {
  case "$1" in ''|*[!0-9]*) die "summary limit must be an integer from 0 to 5" ;; esac
  [ "$1" -le 5 ] || die "summary limit must be an integer from 0 to 5"
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

now_rfc3339() {
  if [ -n "${FM_LEARNING_NOW:-}" ]; then
    validate_one_line FM_LEARNING_NOW "$FM_LEARNING_NOW" 128
    printf '%s\n' "$FM_LEARNING_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

ensure_store() {
  if [ -L "$STATE" ] || { [ -e "$STATE" ] && [ ! -d "$STATE" ]; }; then
    die "state path must be a real directory: $STATE"
  fi
  mkdir -p "$STATE"
  if [ -L "$CANDIDATE_DIR" ] || { [ -e "$CANDIDATE_DIR" ] && [ ! -d "$CANDIDATE_DIR" ]; }; then
    die "candidate store must be a real directory: $CANDIDATE_DIR"
  fi
  mkdir -p "$CANDIDATE_DIR"
  chmod 700 "$CANDIDATE_DIR"
}

store_available_read_only() {
  [ -e "$CANDIDATE_DIR" ] || return 1
  [ -d "$CANDIDATE_DIR" ] && [ ! -L "$CANDIDATE_DIR" ] \
    || die "candidate store must be a real directory: $CANDIDATE_DIR"
}

LOCK_HELD=0
TEMP_FILE=
cleanup() {
  [ -z "$TEMP_FILE" ] || rm -f -- "$TEMP_FILE" 2>/dev/null || true
  if [ "$LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$MUTATION_LOCK" || true
    LOCK_HELD=0
  fi
}
trap cleanup EXIT

acquire_mutation_lock() {
  ensure_store
  fm_lock_acquire_wait "$MUTATION_LOCK"
  LOCK_HELD=1
}

acquire_capture_lock() {
  ensure_store
  fm_lock_try_acquire "$MUTATION_LOCK" \
    || die "capture is temporarily unavailable while learning-candidate curation is active"
  LOCK_HELD=1
}

record_path() {
  printf '%s/%s.json\n' "$CANDIDATE_DIR" "$1"
}

validate_record_json() { # <json> [expected-id]
  local json=$1 expected=${2:-}
  printf '%s\n' "$json" | jq -e --arg expected "$expected" '
    .schema == 1
    and (.id | type == "string")
    and ($expected == "" or .id == $expected)
    and (.capture_digest | type == "string" and test("^[0-9a-f]{64}$"))
    and .id == ("lc-" + .capture_digest[0:24])
    and (.captured_at | type == "string" and length > 0)
    and (.lifecycle_state | IN("unresolved", "dismissed", "documented", "promoted", "follow-up", "duplicate"))
    and (.incident | type == "object")
    and ([.incident.origin_task, .incident.project, .incident.signal_type,
          .incident.user_visible_impact, .incident.root_cause,
          .incident.escaped_contract, .incident.missing_check,
          .incident.affected_consumer, .incident.proposed_prevention,
          .incident.evidence, .incident.proposed_owner,
          .incident.counterfactual] | all(type == "string" and length > 0))
    and (.incident.signal_type | IN("captain-correction", "review-rejection",
      "escaped-defect", "workflow-gap-blocker", "substantive-no-mistakes-correction"))
    and (.classification == null or (
      (.classification | type == "object")
      and ([.classification.at, .classification.curator,
            .classification.route, .classification.owner,
            .classification.surface, .classification.recommendation,
            .classification.rationale] | all(type == "string" and length > 0))
      and ((.classification.route + ":" + .classification.surface) |
        IN("feature:documentation", "feature:contract", "feature:tests",
           "project:skill", "project:instructions", "project:tooling",
           "firstmate:pipeline", "tool:tool-repository"))
      and (if .classification.surface == "skill" then
        (.classification.skill_gate | type == "object")
        and ([.classification.skill_gate.general_statement,
              .classification.skill_gate.feature_neutral_evidence,
              .classification.skill_gate.repeatable_procedure,
              .classification.skill_gate.load_trigger,
              .classification.skill_gate.counterfactual] |
             all(type == "string" and length > 0))
        and (.classification.skill_gate.task_types | type == "array")
        and (.classification.skill_gate.task_types | all(type == "string" and length > 0))
        and ((.classification.skill_gate.task_types | unique | length) >= 2
          or (.classification.skill_gate.feature_agnostic_evidence |
              type == "string" and length > 0))
      else .classification.skill_gate == null end)
    ))
    and (.disposition == null or (
      (.disposition | type == "object")
      and ([.disposition.at, .disposition.curator, .disposition.outcome,
            .disposition.note] | all(type == "string" and length > 0))
      and (.disposition.outcome | IN("dismissed", "documented", "promoted", "follow-up", "duplicate"))
      and (.disposition.reference == null or
           (.disposition.reference | type == "string" and length > 0))
      and (if .disposition.outcome == "dismissed" then true
           else (.disposition.reference | type == "string" and length > 0) end)
    ))
    and (if .lifecycle_state == "unresolved" then .disposition == null
         else .disposition.outcome == .lifecycle_state end)
    and (.duplicates | type == "array" and all(type == "string" and test("^lc-[0-9a-f]{24}$")))
    and (.history | type == "array" and all(
      type == "object"
      and (.at | type == "string" and length > 0)
      and (.event | type == "string" and length > 0)
      and (.actor | type == "string" and length > 0)))
  ' >/dev/null || die "invalid candidate record${expected:+: $expected}"
}

load_record() { # <candidate-id>; sets RECORD_JSON and RECORD_PATH
  local id=$1
  validate_candidate_id "$id"
  store_available_read_only || die "candidate not found: $id"
  RECORD_PATH=$(record_path "$id")
  [ -f "$RECORD_PATH" ] && [ ! -L "$RECORD_PATH" ] || die "candidate not found: $id"
  RECORD_JSON=$(cat "$RECORD_PATH")
  validate_record_json "$RECORD_JSON" "$id"
}

ensure_curator_separate_from_cluster() { # <canonical-json> <curator> [label]
  local canonical_json=$1 curator=$2 label=${3:-curator} origin duplicate_id duplicate_json
  origin=$(printf '%s\n' "$canonical_json" | jq -r '.incident.origin_task')
  [ "$origin" != "$curator" ] \
    || die "$label must differ from the originating task and every originating task in the candidate cluster"
  while IFS= read -r duplicate_id; do
    [ -n "$duplicate_id" ] || continue
    duplicate_json=$(record_json_by_id "$duplicate_id")
    origin=$(printf '%s\n' "$duplicate_json" | jq -r '.incident.origin_task')
    [ "$origin" != "$curator" ] \
      || die "$label must differ from the originating task and every originating task in the candidate cluster"
  done < <(printf '%s\n' "$canonical_json" | jq -r '.duplicates[]')
}

record_json_by_id() { # <candidate-id>
  local id=$1 path json
  validate_candidate_id "$id"
  store_available_read_only || die "candidate not found: $id"
  path=$(record_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || die "candidate not found: $id"
  json=$(cat "$path")
  validate_record_json "$json" "$id"
  printf '%s\n' "$json"
}

write_record() { # <path> <json>
  local path=$1 json=$2 id
  id=$(printf '%s\n' "$json" | jq -r '.id')
  validate_record_json "$json" "$id"
  TEMP_FILE=$(mktemp "$CANDIDATE_DIR/.candidate.XXXXXX") || die "could not create candidate temporary file"
  printf '%s\n' "$json" > "$TEMP_FILE"
  chmod 600 "$TEMP_FILE"
  mv -f -- "$TEMP_FILE" "$path"
  TEMP_FILE=
}

validate_summary_index_json() {
  local json=$1
  printf '%s\n' "$json" | jq -e '
    .schema == 1
    and (.unresolved_count | type == "number" and . >= 0 and floor == .)
    and (.sample | type == "array" and length <= 5)
    and (.sample | all(
      type == "object"
      and ([.id, .captured_at, .project, .signal_type, .user_visible_impact] |
        all(type == "string" and length > 0))
      and (.id | test("^lc-[0-9a-f]{24}$"))))
    and .unresolved_count >= (.sample | length)
    and (.sample == (.sample | sort_by(.captured_at, .id)))
    and (([.sample[].id] | unique | length) == (.sample | length))
  ' >/dev/null || die "invalid learning-candidate summary index"
}

validate_summary_pending_json() {
  local json=$1 after
  printf '%s\n' "$json" | jq -e '
    .schema == 1
    and (.operation | IN("capture", "disposition", "dedupe"))
    and (.probe | type == "object")
    and (.probe.id | type == "string" and test("^lc-[0-9a-f]{24}$"))
    and (.probe.lifecycle_state |
      IN("unresolved", "dismissed", "documented", "promoted", "follow-up", "duplicate"))
    and (.probe.capture_digest == null or
      (.probe.capture_digest | type == "string" and test("^[0-9a-f]{64}$")))
    and (.probe.reference == null or
      (.probe.reference | type == "string" and test("^lc-[0-9a-f]{24}$")))
    and (.after | type == "object")
  ' >/dev/null || die "invalid learning-candidate summary transaction"
  after=$(printf '%s\n' "$json" | jq -cS '.after')
  validate_summary_index_json "$after"
}

write_summary_json() {
  local path=$1 prefix=$2 json=$3
  TEMP_FILE=$(mktemp "$CANDIDATE_DIR/.$prefix.XXXXXX") \
    || die "could not create learning-candidate summary temporary file"
  printf '%s\n' "$json" > "$TEMP_FILE"
  chmod 600 "$TEMP_FILE"
  mv -f -- "$TEMP_FILE" "$path"
  TEMP_FILE=
}

write_summary_index() {
  validate_summary_index_json "$1"
  write_summary_json "$SUMMARY_INDEX" summary "$1"
}

write_summary_pending() {
  validate_summary_pending_json "$1"
  write_summary_json "$SUMMARY_PENDING" summary-pending "$1"
}

summary_projection() {
  printf '%s\n' "$1" | jq -cS '
    {id, captured_at, project:.incident.project,
     signal_type:.incident.signal_type,
     user_visible_impact:.incident.user_visible_impact}'
}

build_summary_index() {
  records_stream | jq -csS '
    [.[] | select(.lifecycle_state == "unresolved")]
    | sort_by(.captured_at, .id)
    | {schema:1, unresolved_count:length,
       sample:(.[:5] | map(
         {id, captured_at, project:.incident.project,
          signal_type:.incident.signal_type,
          user_visible_impact:.incident.user_visible_impact}))}'
}

summary_probe_committed() {
  local pending=$1 id path record
  id=$(printf '%s\n' "$pending" | jq -r '.probe.id')
  path=$(record_path "$id")
  if [ ! -e "$path" ]; then
    return 1
  fi
  [ -f "$path" ] && [ ! -L "$path" ] \
    || die "candidate not found during summary recovery: $id"
  record=$(cat "$path")
  validate_record_json "$record" "$id"
  printf '%s\n' "$record" | jq -e --argjson pending "$pending" '
    .lifecycle_state == $pending.probe.lifecycle_state
    and ($pending.probe.capture_digest == null
      or .capture_digest == $pending.probe.capture_digest)
    and ($pending.probe.reference == null
      or .disposition.reference == $pending.probe.reference)
  ' >/dev/null
}

read_summary_index_file() {
  local index
  [ -f "$SUMMARY_INDEX" ] && [ ! -L "$SUMMARY_INDEX" ] \
    || die "learning-candidate summary index is missing; run a mutating lifecycle command to rebuild it"
  index=$(cat "$SUMMARY_INDEX")
  validate_summary_index_json "$index"
  printf '%s\n' "$index"
}

read_summary_pending_file() {
  local pending
  [ -e "$SUMMARY_PENDING" ] || return 1
  if [ -L "$SUMMARY_PENDING" ] || [ ! -f "$SUMMARY_PENDING" ]; then
    [ -e "$SUMMARY_PENDING" ] || return 1
    return 2
  fi
  if ! pending=$(cat "$SUMMARY_PENDING"); then
    [ -e "$SUMMARY_PENDING" ] || return 1
    return 2
  fi
  printf '%s\n' "$pending"
}

effective_summary_index() {
  local attempt index index_after pending pending_after pending_status committed
  attempt=1
  while [ "$attempt" -le 3 ]; do
    index=$(read_summary_index_file)
    if pending=$(read_summary_pending_file); then
      validate_summary_pending_json "$pending"
      committed=0
      if summary_probe_committed "$pending"; then
        committed=1
      fi
      index_after=$(read_summary_index_file)
      if pending_after=$(read_summary_pending_file); then
        validate_summary_pending_json "$pending_after"
        if [ "$index" = "$index_after" ] && [ "$pending" = "$pending_after" ]; then
          if [ "$committed" -eq 1 ]; then
            index=$(printf '%s\n' "$pending" | jq -cS '.after')
          fi
          printf '%s\n' "$index"
          return 0
        fi
      else
        pending_status=$?
        [ "$pending_status" -eq 1 ] \
          || die "learning-candidate summary transaction must be a readable regular file"
      fi
    else
      pending_status=$?
      [ "$pending_status" -eq 1 ] \
        || die "learning-candidate summary transaction must be a readable regular file"
      index_after=$(read_summary_index_file)
      if [ "$index" = "$index_after" ] && [ ! -e "$SUMMARY_PENDING" ]; then
        printf '%s\n' "$index"
        return 0
      fi
    fi
    attempt=$((attempt + 1))
  done
  index=$(read_summary_index_file)
  printf '%s\n' "$index"
}

load_summary_index_for_mutation() {
  if [ -e "$SUMMARY_PENDING" ]; then
    SUMMARY_INDEX_JSON=$(effective_summary_index)
    write_summary_index "$SUMMARY_INDEX_JSON"
    rm -f -- "$SUMMARY_PENDING"
  elif [ -e "$SUMMARY_INDEX" ]; then
    [ -f "$SUMMARY_INDEX" ] && [ ! -L "$SUMMARY_INDEX" ] \
      || die "learning-candidate summary index must be a regular file"
    SUMMARY_INDEX_JSON=$(cat "$SUMMARY_INDEX")
    validate_summary_index_json "$SUMMARY_INDEX_JSON"
  else
    SUMMARY_INDEX_JSON=$(build_summary_index)
    validate_summary_index_json "$SUMMARY_INDEX_JSON"
    write_summary_index "$SUMMARY_INDEX_JSON"
  fi
}

load_summary_index_for_capture() {
  local first_record
  if [ -e "$SUMMARY_PENDING" ]; then
    SUMMARY_INDEX_JSON=$(effective_summary_index)
    write_summary_index "$SUMMARY_INDEX_JSON"
    rm -f -- "$SUMMARY_PENDING"
  elif [ -e "$SUMMARY_INDEX" ]; then
    [ -f "$SUMMARY_INDEX" ] && [ ! -L "$SUMMARY_INDEX" ] \
      || die "learning-candidate summary index must be a regular file"
    SUMMARY_INDEX_JSON=$(cat "$SUMMARY_INDEX")
    validate_summary_index_json "$SUMMARY_INDEX_JSON"
  else
    first_record=$(find "$CANDIDATE_DIR" -maxdepth 1 -name 'lc-*.json' -print -quit)
    [ -z "$first_record" ] \
      || die "learning-candidate summary index is missing; run a curator mutation to rebuild it"
    SUMMARY_INDEX_JSON='{"sample":[],"schema":1,"unresolved_count":0}'
    write_summary_index "$SUMMARY_INDEX_JSON"
  fi
}

summary_index_add() {
  local entry
  entry=$(summary_projection "$2")
  jq -cnS --argjson index "$1" --argjson entry "$entry" '
    $index
    | .unresolved_count += 1
    | .sample = ((.sample + [$entry]) | sort_by(.captured_at, .id) | .[:5])
  '
}

summary_index_remove() {
  local index=$1 id=$2 count sample
  count=$(printf '%s\n' "$index" | jq '.unresolved_count')
  [ "$count" -gt 0 ] || die "learning-candidate summary index underflow"
  sample=$(records_stream | jq -csS --arg id "$id" '
    [.[] | select(.lifecycle_state == "unresolved" and .id != $id)]
    | sort_by(.captured_at, .id)
    | .[:5]
    | map({id, captured_at, project:.incident.project,
           signal_type:.incident.signal_type,
           user_visible_impact:.incident.user_visible_impact})
  ')
  jq -cnS --argjson index "$index" --argjson count "$((count - 1))" \
    --argjson sample "$sample" \
    '$index | .unresolved_count=$count | .sample=$sample'
}

begin_summary_transaction() {
  local operation=$1 id=$2 lifecycle_state=$3 digest=$4 reference=$5 after=$6 pending
  pending=$(jq -cnS --arg operation "$operation" --arg id "$id" \
    --arg lifecycle_state "$lifecycle_state" --arg digest "$digest" \
    --arg reference "$reference" --argjson after "$after" \
    '{schema:1, operation:$operation,
      probe:{id:$id, lifecycle_state:$lifecycle_state,
        capture_digest:(if $digest == "" then null else $digest end),
        reference:(if $reference == "" then null else $reference end)},
      after:$after}')
  write_summary_pending "$pending"
}

finish_summary_transaction() {
  write_summary_index "$1"
  rm -f -- "$SUMMARY_PENDING"
  SUMMARY_INDEX_JSON=$1
}

records_stream() {
  local path json id
  store_available_read_only || return 0
  for path in "$CANDIDATE_DIR"/*.json; do
    [ -e "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || die "candidate store contains a non-regular record: $path"
    id=$(basename "$path" .json)
    validate_candidate_id "$id"
    json=$(cat "$path")
    validate_record_json "$json" "$id"
    printf '%s\n' "$json" | jq -cS .
  done
}

records_array() {
  records_stream | jq -s 'sort_by(.captured_at, .id)'
}

capture_command() {
  local task='' project='' signal='' impact='' root_cause='' escaped_contract='' missing_check=''
  local consumer='' prevention='' evidence='' proposed_owner='' counterfactual='' payload digest id path timestamp record existing summary_after
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || die "--task requires a value"; task=$2; shift 2 ;;
      --project) [ "$#" -ge 2 ] || die "--project requires a value"; project=$2; shift 2 ;;
      --signal) [ "$#" -ge 2 ] || die "--signal requires a value"; signal=$2; shift 2 ;;
      --impact) [ "$#" -ge 2 ] || die "--impact requires a value"; impact=$2; shift 2 ;;
      --root-cause) [ "$#" -ge 2 ] || die "--root-cause requires a value"; root_cause=$2; shift 2 ;;
      --escaped-contract) [ "$#" -ge 2 ] || die "--escaped-contract requires a value"; escaped_contract=$2; shift 2 ;;
      --missing-check) [ "$#" -ge 2 ] || die "--missing-check requires a value"; missing_check=$2; shift 2 ;;
      --consumer) [ "$#" -ge 2 ] || die "--consumer requires a value"; consumer=$2; shift 2 ;;
      --prevention) [ "$#" -ge 2 ] || die "--prevention requires a value"; prevention=$2; shift 2 ;;
      --evidence) [ "$#" -ge 2 ] || die "--evidence requires a value"; evidence=$2; shift 2 ;;
      --proposed-owner) [ "$#" -ge 2 ] || die "--proposed-owner requires a value"; proposed_owner=$2; shift 2 ;;
      --counterfactual) [ "$#" -ge 2 ] || die "--counterfactual requires a value"; counterfactual=$2; shift 2 ;;
      *) die "unknown capture argument: $1" ;;
    esac
  done

  validate_slug task "$task"
  validate_one_line project "$project" 512
  validate_signal "$signal"
  validate_text impact "$impact"
  validate_text root-cause "$root_cause"
  validate_text escaped-contract "$escaped_contract"
  validate_text missing-check "$missing_check"
  validate_text consumer "$consumer"
  validate_text prevention "$prevention"
  validate_text evidence "$evidence"
  validate_text proposed-owner "$proposed_owner"
  validate_text counterfactual "$counterfactual"

  payload=$(jq -cnS \
    --arg task "$task" --arg project "$project" --arg signal "$signal" \
    --arg impact "$impact" --arg root_cause "$root_cause" \
    --arg escaped_contract "$escaped_contract" --arg missing_check "$missing_check" \
    --arg consumer "$consumer" --arg prevention "$prevention" \
    --arg evidence "$evidence" --arg proposed_owner "$proposed_owner" \
    --arg counterfactual "$counterfactual" \
    '{origin_task:$task, project:$project, signal_type:$signal,
      user_visible_impact:$impact, root_cause:$root_cause,
      escaped_contract:$escaped_contract, missing_check:$missing_check,
      affected_consumer:$consumer, proposed_prevention:$prevention,
      evidence:$evidence, proposed_owner:$proposed_owner,
      counterfactual:$counterfactual}')
  digest=$(sha256_text "$payload")
  id="lc-${digest:0:24}"
  timestamp=$(now_rfc3339)
  record=$(jq -cnS --arg id "$id" --arg digest "$digest" --arg at "$timestamp" \
    --argjson incident "$payload" \
    '{schema:1, id:$id, capture_digest:$digest, captured_at:$at,
      lifecycle_state:"unresolved", incident:$incident, classification:null,
      disposition:null, duplicates:[], history:[{at:$at,event:"captured",actor:$incident.origin_task}]}')

  acquire_capture_lock
  path=$(record_path "$id")
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || die "candidate id collision with non-regular path: $id"
    existing=$(cat "$path")
    validate_record_json "$existing" "$id"
    printf '%s\n' "$existing" | jq -e --arg digest "$digest" --argjson payload "$payload" '
      .capture_digest == $digest and .incident == $payload
    ' >/dev/null \
      || die "candidate digest collision: $id"
    printf '%s\n' "$id"
    return 0
  fi
  load_summary_index_for_capture
  summary_after=$(summary_index_add "$SUMMARY_INDEX_JSON" "$record")
  begin_summary_transaction capture "$id" unresolved "$digest" '' "$summary_after"
  write_record "$path" "$record"
  finish_summary_transaction "$summary_after"
  printf '%s\n' "$id"
}

get_command() {
  [ "$#" -eq 2 ] || die "get requires one candidate id"
  load_record "$2"
  printf '%s\n' "$RECORD_JSON" | jq -S .
}

list_command() {
  local filter=unresolved limit=50 array
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) filter=all; shift ;;
      --status) [ "$#" -ge 2 ] || die "--status requires a value"; filter=$2; shift 2 ;;
      --limit) [ "$#" -ge 2 ] || die "--limit requires a value"; limit=$2; shift 2 ;;
      *) die "unknown list argument: $1" ;;
    esac
  done
  [ "$filter" = all ] || validate_lifecycle_state "$filter"
  validate_positive_limit "$limit" 500
  array=$(records_array)
  printf '%s\n' "$array" | jq -r --arg filter "$filter" --argjson limit "$limit" '
    def terminal_safe: gsub("[[:cntrl:]]+"; "");
    def compact: gsub("[\\r\\n\\t]+"; " ") | terminal_safe | if length > 160 then .[:157] + "..." else . end;
    [.[] | select($filter == "all" or .lifecycle_state == $filter)][: $limit][] |
    [(.id | terminal_safe), (.lifecycle_state | terminal_safe),
     (.incident.project | terminal_safe), (.incident.signal_type | terminal_safe),
     (.incident.user_visible_impact | compact)] | @tsv
  '
}

batch_command() {
  local limit=20 array
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit) [ "$#" -ge 2 ] || die "--limit requires a value"; limit=$2; shift 2 ;;
      *) die "unknown batch argument: $1" ;;
    esac
  done
  validate_positive_limit "$limit" 100
  array=$(records_array)
  printf '%s\n' "$array" | jq --argjson limit "$limit" '[.[] | select(.lifecycle_state == "unresolved")][: $limit]'
}

summary_command() {
  local limit=3 index
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit) [ "$#" -ge 2 ] || die "--limit requires a value"; limit=$2; shift 2 ;;
      *) die "unknown summary argument: $1" ;;
    esac
  done
  validate_summary_limit "$limit"
  store_available_read_only || return 0
  index=$(effective_summary_index)
  printf '%s\n' "$index" | jq -r --argjson limit "$limit" '
    def terminal_safe: gsub("[[:cntrl:]]+"; "");
    def compact: gsub("[\\r\\n\\t]+"; " ") | terminal_safe | if length > 120 then .[:117] + "..." else . end;
    .unresolved_count as $count |
    if $count == 0 then empty else
      "LEARNING CANDIDATES: \($count) unresolved",
      (.sample[:$limit][] |
       {id:(.id | terminal_safe), project:(.project | terminal_safe),
        signal_type:(.signal_type | terminal_safe), impact:(.user_visible_impact | compact)} |
       "- \(.id) [\(.project)/\(.signal_type)] \(.impact)"),
      (if $count > $limit then "- ... \($count - $limit) more; run bin/fm-learning-candidate.sh batch" else empty end)
    end
  '
}

validate_route_surface() {
  local route=$1 surface=$2
  case "$route:$surface" in
    feature:documentation|feature:contract|feature:tests|project:skill|project:instructions|project:tooling|firstmate:pipeline|tool:tool-repository) ;;
    *) die "surface '$surface' is not valid for route '$route'" ;;
  esac
}

classify_command() {
  local id=${2:-} curator='' route='' owner='' surface='' recommendation='' rationale=''
  local skill_statement='' skill_feature_neutral='' skill_feature_agnostic='' skill_procedure=''
  local skill_load_trigger='' skill_counterfactual='' skill_task_types='' task_types_json count timestamp
  local skill_gate classification existing comparable updated
  [ -n "$id" ] || die "classify requires a candidate id"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --curator) [ "$#" -ge 2 ] || die "--curator requires a value"; curator=$2; shift 2 ;;
      --route) [ "$#" -ge 2 ] || die "--route requires a value"; route=$2; shift 2 ;;
      --owner) [ "$#" -ge 2 ] || die "--owner requires a value"; owner=$2; shift 2 ;;
      --surface) [ "$#" -ge 2 ] || die "--surface requires a value"; surface=$2; shift 2 ;;
      --recommendation) [ "$#" -ge 2 ] || die "--recommendation requires a value"; recommendation=$2; shift 2 ;;
      --rationale) [ "$#" -ge 2 ] || die "--rationale requires a value"; rationale=$2; shift 2 ;;
      --skill-statement) [ "$#" -ge 2 ] || die "--skill-statement requires a value"; skill_statement=$2; shift 2 ;;
      --skill-feature-neutral-evidence) [ "$#" -ge 2 ] || die "--skill-feature-neutral-evidence requires a value"; skill_feature_neutral=$2; shift 2 ;;
      --skill-feature-agnostic-evidence) [ "$#" -ge 2 ] || die "--skill-feature-agnostic-evidence requires a value"; skill_feature_agnostic=$2; shift 2 ;;
      --skill-task-type)
        [ "$#" -ge 2 ] || die "--skill-task-type requires a value"
        validate_slug skill-task-type "$2"
        skill_task_types="${skill_task_types}${skill_task_types:+$'\n'}$2"
        shift 2
        ;;
      --skill-procedure) [ "$#" -ge 2 ] || die "--skill-procedure requires a value"; skill_procedure=$2; shift 2 ;;
      --skill-load-trigger) [ "$#" -ge 2 ] || die "--skill-load-trigger requires a value"; skill_load_trigger=$2; shift 2 ;;
      --skill-counterfactual) [ "$#" -ge 2 ] || die "--skill-counterfactual requires a value"; skill_counterfactual=$2; shift 2 ;;
      *) die "unknown classify argument: $1" ;;
    esac
  done

  validate_candidate_id "$id"
  validate_slug curator "$curator"
  validate_one_line route "$route" 32
  validate_one_line owner "$owner" 512
  validate_one_line surface "$surface" 64
  validate_text recommendation "$recommendation"
  validate_text rationale "$rationale"
  validate_route_surface "$route" "$surface"

  task_types_json=$(printf '%s\n' "$skill_task_types" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
  count=$(printf '%s\n' "$task_types_json" | jq 'length')
  if [ "$surface" = skill ]; then
    validate_nonblank_text skill-statement "$skill_statement"
    validate_nonblank_text skill-feature-neutral-evidence "$skill_feature_neutral"
    validate_nonblank_text skill-procedure "$skill_procedure"
    validate_nonblank_text skill-load-trigger "$skill_load_trigger"
    validate_nonblank_text skill-counterfactual "$skill_counterfactual"
    if [ "$count" -lt 2 ]; then
      validate_nonblank_text skill-feature-agnostic-evidence "$skill_feature_agnostic"
    elif [ -n "$skill_feature_agnostic" ]; then
      validate_nonblank_text skill-feature-agnostic-evidence "$skill_feature_agnostic"
    fi
    skill_gate=$(jq -cnS --arg statement "$skill_statement" \
      --arg feature_neutral "$skill_feature_neutral" \
      --arg feature_agnostic "$skill_feature_agnostic" \
      --argjson task_types "$task_types_json" --arg procedure "$skill_procedure" \
      --arg load_trigger "$skill_load_trigger" --arg counterfactual "$skill_counterfactual" \
      '{general_statement:$statement, feature_neutral_evidence:$feature_neutral,
        task_types:$task_types, feature_agnostic_evidence:
          (if $feature_agnostic == "" then null else $feature_agnostic end),
        repeatable_procedure:$procedure, load_trigger:$load_trigger,
        counterfactual:$counterfactual}')
  else
    [ -z "$skill_statement$skill_feature_neutral$skill_feature_agnostic$skill_task_types$skill_procedure$skill_load_trigger$skill_counterfactual" ] \
      || die "skill gate evidence is valid only for the project skill surface"
    skill_gate=null
  fi

  acquire_mutation_lock
  load_summary_index_for_mutation
  load_record "$id"
  ensure_curator_separate_from_cluster "$RECORD_JSON" "$curator"
  comparable=$(jq -cnS --arg curator "$curator" --arg route "$route" --arg owner "$owner" \
    --arg surface "$surface" --arg recommendation "$recommendation" --arg rationale "$rationale" \
    --argjson skill_gate "$skill_gate" \
    '{curator:$curator, route:$route, owner:$owner, surface:$surface,
      recommendation:$recommendation, rationale:$rationale, skill_gate:$skill_gate}')
  existing=$(printf '%s\n' "$RECORD_JSON" | jq -cS '.classification // null')
  if [ "$existing" != null ]; then
    if printf '%s\n' "$existing" | jq -e --argjson wanted "$comparable" 'del(.at) == $wanted' >/dev/null; then
      printf '%s\n' "$id"
      return 0
    fi
    die "candidate already has a different classification: $id"
  fi
  [ "$(printf '%s\n' "$RECORD_JSON" | jq -r '.lifecycle_state')" = unresolved ] \
    || die "only an unresolved candidate can be classified"
  timestamp=$(now_rfc3339)
  classification=$(printf '%s\n' "$comparable" | jq -cS --arg at "$timestamp" '. + {at:$at}')
  updated=$(printf '%s\n' "$RECORD_JSON" | jq -cS --argjson classification "$classification" \
    --arg at "$timestamp" --arg curator "$curator" --arg route "$route" \
    '.classification=$classification |
     .history += [{at:$at,event:"classified",actor:$curator,detail:$route}]')
  write_record "$RECORD_PATH" "$updated"
  printf '%s\n' "$id"
}

disposition_command() {
  local id=${2:-} curator='' outcome='' note='' reference='' timestamp disposition existing comparable updated summary_after
  [ -n "$id" ] || die "disposition requires a candidate id"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --curator) [ "$#" -ge 2 ] || die "--curator requires a value"; curator=$2; shift 2 ;;
      --status) [ "$#" -ge 2 ] || die "--status requires a value"; outcome=$2; shift 2 ;;
      --note) [ "$#" -ge 2 ] || die "--note requires a value"; note=$2; shift 2 ;;
      --reference) [ "$#" -ge 2 ] || die "--reference requires a value"; reference=$2; shift 2 ;;
      *) die "unknown disposition argument: $1" ;;
    esac
  done
  validate_candidate_id "$id"
  validate_slug curator "$curator"
  case "$outcome" in dismissed|documented|promoted|follow-up) ;; *) die "invalid disposition status: $outcome" ;; esac
  validate_text note "$note"
  if [ "$outcome" != dismissed ]; then
    validate_text reference "$reference"
  elif [ -n "$reference" ]; then
    validate_text reference "$reference"
  fi

  acquire_mutation_lock
  load_summary_index_for_mutation
  load_record "$id"
  ensure_curator_separate_from_cluster "$RECORD_JSON" "$curator"
  comparable=$(jq -cnS --arg curator "$curator" --arg outcome "$outcome" \
    --arg note "$note" --arg reference "$reference" \
    '{curator:$curator, outcome:$outcome, note:$note,
      reference:(if $reference == "" then null else $reference end)}')
  existing=$(printf '%s\n' "$RECORD_JSON" | jq -cS '.disposition // null')
  if [ "$existing" != null ]; then
    if printf '%s\n' "$existing" | jq -e --argjson wanted "$comparable" 'del(.at) == $wanted' >/dev/null; then
      printf '%s\n' "$id"
      return 0
    fi
    die "candidate already has a different disposition: $id"
  fi
  [ "$(printf '%s\n' "$RECORD_JSON" | jq -r '.lifecycle_state')" = unresolved ] \
    || die "only an unresolved candidate can receive a disposition"
  if [ "$outcome" != dismissed ]; then
    [ "$(printf '%s\n' "$RECORD_JSON" | jq -r '.classification != null')" = true ] \
      || die "$outcome requires a recorded classification"
  fi
  timestamp=$(now_rfc3339)
  disposition=$(printf '%s\n' "$comparable" | jq -cS --arg at "$timestamp" '. + {at:$at}')
  updated=$(printf '%s\n' "$RECORD_JSON" | jq -cS --argjson disposition "$disposition" \
    --arg at "$timestamp" --arg curator "$curator" --arg outcome "$outcome" \
    '.lifecycle_state=$outcome | .disposition=$disposition |
     .history += [{at:$at,event:"disposed",actor:$curator,detail:$outcome}]')
  summary_after=$(summary_index_remove "$SUMMARY_INDEX_JSON" "$id")
  begin_summary_transaction disposition "$id" "$outcome" '' '' "$summary_after"
  write_record "$RECORD_PATH" "$updated"
  finish_summary_transaction "$summary_after"
  printf '%s\n' "$id"
}

derive_canonical_link() {
  local canonical_json=$1 duplicate=$2 timestamp=$3 curator=$4 reason=$5
  printf '%s\n' "$canonical_json" | jq -cS --arg duplicate "$duplicate" \
    --arg at "$timestamp" --arg curator "$curator" --arg reason "$reason" \
    'if (.duplicates | index($duplicate)) == null then
       .duplicates = ((.duplicates + [$duplicate]) | unique) |
       .history += [{at:$at,event:"dedupe-canonical",actor:$curator,detail:$reason}]
     else . end'
}

dedupe_command() {
  local duplicate=${2:-} canonical='' curator='' reason='' timestamp duplicate_json duplicate_path
  local canonical_json canonical_path disposition updated_canonical updated_duplicate existing summary_after
  local canonical_classifier duplicate_classifier duplicate_origin
  [ -n "$duplicate" ] || die "dedupe requires a duplicate candidate id"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --into) [ "$#" -ge 2 ] || die "--into requires a value"; canonical=$2; shift 2 ;;
      --curator) [ "$#" -ge 2 ] || die "--curator requires a value"; curator=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || die "--reason requires a value"; reason=$2; shift 2 ;;
      *) die "unknown dedupe argument: $1" ;;
    esac
  done
  validate_candidate_id "$duplicate"
  validate_candidate_id "$canonical"
  [ "$duplicate" != "$canonical" ] || die "duplicate and canonical ids must differ"
  validate_slug curator "$curator"
  validate_text reason "$reason"

  acquire_mutation_lock
  load_summary_index_for_mutation
  load_record "$duplicate"
  duplicate_json=$RECORD_JSON
  duplicate_path=$RECORD_PATH
  [ "$(printf '%s\n' "$duplicate_json" | jq '.duplicates | length')" -eq 0 ] \
    || die "a canonical candidate with duplicates cannot itself be deduplicated"
  ensure_curator_separate_from_cluster "$duplicate_json" "$curator"

  load_record "$canonical"
  canonical_json=$RECORD_JSON
  canonical_path=$RECORD_PATH
  ensure_curator_separate_from_cluster "$canonical_json" "$curator"
  duplicate_origin=$(printf '%s\n' "$duplicate_json" | jq -r '.incident.origin_task')
  canonical_classifier=$(printf '%s\n' "$canonical_json" | jq -r '.classification.curator // empty')
  [ -z "$canonical_classifier" ] || ensure_curator_separate_from_cluster "$canonical_json" "$canonical_classifier" "classification curator"
  [ -z "$canonical_classifier" ] || [ "$canonical_classifier" != "$duplicate_origin" ] \
    || die "classification curator must differ from the originating task and every originating task in the candidate cluster"
  duplicate_classifier=$(printf '%s\n' "$duplicate_json" | jq -r '.classification.curator // empty')
  [ -z "$duplicate_classifier" ] || ensure_curator_separate_from_cluster "$duplicate_json" "$duplicate_classifier" "classification curator"
  [ -z "$duplicate_classifier" ] || ensure_curator_separate_from_cluster "$canonical_json" "$duplicate_classifier" "classification curator"

  existing=$(printf '%s\n' "$duplicate_json" | jq -cS '.disposition // null')
  if [ "$existing" != null ]; then
    if printf '%s\n' "$existing" | jq -e --arg curator "$curator" --arg canonical "$canonical" --arg reason "$reason" \
      '.outcome == "duplicate" and .curator == $curator and .reference == $canonical and .note == $reason' >/dev/null; then
      timestamp=$(printf '%s\n' "$existing" | jq -r '.at')
      updated_canonical=$(derive_canonical_link "$canonical_json" "$duplicate" \
        "$timestamp" "$curator" "$reason")
      if [ "$updated_canonical" != "$canonical_json" ]; then
        write_record "$canonical_path" "$updated_canonical"
      fi
      printf '%s\n' "$canonical"
      return 0
    fi
    die "candidate already has a different disposition: $duplicate"
  fi
  [ "$(printf '%s\n' "$duplicate_json" | jq -r '.lifecycle_state')" = unresolved ] \
    || die "only an unresolved candidate can be deduplicated"
  [ "$(printf '%s\n' "$canonical_json" | jq -r '.lifecycle_state')" = unresolved ] \
    || die "canonical candidate must remain unresolved"
  timestamp=$(now_rfc3339)
  updated_canonical=$(derive_canonical_link "$canonical_json" "$duplicate" \
    "$timestamp" "$curator" "$reason")
  disposition=$(jq -cnS --arg at "$timestamp" --arg curator "$curator" \
    --arg note "$reason" --arg reference "$canonical" \
    '{at:$at,curator:$curator,outcome:"duplicate",note:$note,reference:$reference}')
  updated_duplicate=$(printf '%s\n' "$duplicate_json" | jq -cS --argjson disposition "$disposition" \
    --arg at "$timestamp" --arg curator "$curator" --arg canonical "$canonical" \
    '.lifecycle_state="duplicate" | .disposition=$disposition |
     .history += [{at:$at,event:"deduplicated",actor:$curator,detail:$canonical}]')
  summary_after=$(summary_index_remove "$SUMMARY_INDEX_JSON" "$duplicate")
  begin_summary_transaction dedupe "$duplicate" duplicate '' "$canonical" "$summary_after"
  write_record "$duplicate_path" "$updated_duplicate"
  if [ "$updated_canonical" != "$canonical_json" ]; then
    write_record "$canonical_path" "$updated_canonical"
  fi
  finish_summary_transaction "$summary_after"
  printf '%s\n' "$canonical"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
require_jq
case "$1" in
  capture) require_hash_tool; capture_command "$@" ;;
  get) get_command "$@" ;;
  list) list_command "$@" ;;
  batch) batch_command "$@" ;;
  summary) summary_command "$@" ;;
  classify) classify_command "$@" ;;
  disposition) disposition_command "$@" ;;
  dedupe) dedupe_command "$@" ;;
  *) die "unknown command: $1" ;;
esac
