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
# state/learning-candidates/<candidate-id>.<lifecycle-state>.json in the active
# FM_HOME. Record content owns lifecycle state; the suffix is a derived hint.
# The directory is outside task-scoped state, so fm-teardown.sh never removes it.
# The strict path resolver normalizes the selected state alias and validates the
# store, every lifecycle sibling, and every mutation destination. Enumeration
# validates each exact entry independently and returns every schema-valid record
# to every read surface matched by its content-owned state. Invalid entries are
# reported separately, and valid siblings are reported without selecting a winner.
# Record reads accept at most 1,048,576 bytes; enumerators report and skip an
# oversized entry, while strict get and mutation paths fail on it.
# Every record replacement publishes at the current path by atomic temp-plus-rename,
# then renames that sole record when its lifecycle hint changes. A read that finds
# a stale or missing hint trusts readable content and corrects the name under the
# mutation lock unless summary --read-only disables that mutation. Capture makes
# one non-waiting mutation-lock attempt; curator mutations may wait for the lock.
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
#   fm-learning-candidate.sh summary [--limit <0..5>] [--read-only]
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
# for independent curation. `summary` reads sorted NUL-delimited record names from
# an ephemeral private spool, retains only the at-most-five unresolved records it
# will display, and trusts record content for its count. It has no index,
# transaction, pending write, repair pass, or repair command.
# `summary` is silent when no candidate is unresolved and otherwise emits its
# capped detail lines plus one remainder line. `get` emits one complete record.
#
# Lifecycle states are unresolved, dismissed, documented, promoted, follow-up,
# and duplicate. Dismissal may precede classification. Documented, promoted, and
# follow-up dispositions require a classification and a reference. Dedupe leaves
# the canonical candidate unresolved and marks only the duplicate. Exact retries
# of classification, disposition, and dedupe are idempotent; conflicting retries
# are refused.
#
# FM_HOME selects the private operational home. FM_STATE_OVERRIDE overrides its
# state directory. FM_LEARNING_NOW may provide one non-empty timestamp for a
# deterministic fixture; otherwise UTC RFC3339 time is used. jq is required for
# every lifecycle command; capture additionally requires shasum or sha256sum.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MAX_TEXT_BYTES=8192
MAX_RECORD_BYTES=1048576

die() {
  printf 'fm-learning-candidate: %s\n' "$*" >&2
  exit 2
}

RESOLVED_PATH=
RESOLVED_ID=
RESOLVED_EXISTS=0
resolve_candidate_path() { # <state|store|entry|slot|record> <value> [value] [policy]
  local kind=$1 value=$2 policy=${3:-required} path base id hint state
  local found multiple attempt slot_exists slot_path
  RESOLVED_PATH=
  RESOLVED_ID=
  RESOLVED_EXISTS=0
  case "$kind" in
    state)
      path=$value
      while [ "$path" != / ]; do
        case "$path" in
          */) path=${path%/} ;;
          */.) path=${path%/.}; [ -n "$path" ] || path=/ ;;
          *) break ;;
        esac
      done
      if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
        die "state path must be a real directory: $path"
      fi
      RESOLVED_PATH=$path
      [ ! -e "$path" ] || RESOLVED_EXISTS=1
      ;;
    store)
      path="$STATE/learning-candidates"
      if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
        die "candidate store must be a real directory: $path"
      fi
      RESOLVED_PATH=$path
      [ ! -e "$path" ] || RESOLVED_EXISTS=1
      ;;
    entry)
      path=$value
      case "$path" in
        ./*) path="$CANDIDATE_DIR/${path#./}" ;;
        "$CANDIDATE_DIR"/*) ;;
        *) die "candidate path is outside the candidate store: $path" ;;
      esac
      base=${path##*/}
      if [ "$base" = 'lc-*.json' ] && [ ! -L "$path" ] && [ ! -e "$path" ]; then
        RESOLVED_PATH=$path
        return 0
      fi
      id=${base%%.*}
      hint=${base#"$id."}
      hint=${hint%.json}
      validate_candidate_id "$id"
      validate_lifecycle_state "$hint"
      [ "$base" = "$id.$hint.json" ] || die "invalid candidate record name: $base"
      [ "$path" = "$CANDIDATE_DIR/$base" ] \
        || die "candidate path is outside the candidate store: $path"
      RESOLVED_PATH=$path
      RESOLVED_ID=$id
      if [ -L "$path" ]; then
        die "candidate path must be a regular file: $path"
      fi
      if [ ! -e "$path" ]; then
        [ "$policy" = allow-missing ] || die "candidate record not found: $path"
        return 0
      fi
      if [ ! -f "$path" ]; then
        if [ ! -e "$path" ]; then
          return 0
        fi
        die "candidate path must be a regular file: $path"
      fi
      RESOLVED_EXISTS=1
      ;;
    slot)
      id=$value
      hint=$policy
      policy=${4:-required}
      validate_candidate_id "$id"
      validate_lifecycle_state "$hint"
      resolve_candidate_path entry "$CANDIDATE_DIR/$id.$hint.json" "$policy"
      ;;
    record)
      id=$value
      validate_candidate_id "$id"
      attempt=0
      while [ "$attempt" -lt 2 ]; do
        found=
        multiple=0
        for state in unresolved dismissed documented promoted follow-up duplicate; do
          resolve_candidate_path slot "$id" "$state" allow-missing
          slot_exists=$RESOLVED_EXISTS
          slot_path=$RESOLVED_PATH
          [ "$slot_exists" -eq 1 ] || continue
          if [ -n "$found" ]; then
            multiple=1
            break
          fi
          found=$slot_path
        done
        if [ "$multiple" -eq 0 ] && [ -n "$found" ]; then
          RESOLVED_PATH=$found
          RESOLVED_ID=$id
          RESOLVED_EXISTS=1
          return 0
        fi
        attempt=$((attempt + 1))
      done
      [ "$multiple" -eq 0 ] || die "candidate has multiple lifecycle records: $id"
      if [ "$policy" = allow-missing ]; then
        RESOLVED_ID=$id
        return 0
      fi
      die "candidate not found: $id"
      ;;
    *) die "invalid candidate path resolver kind: $kind" ;;
  esac
}

resolve_candidate_path state "$STATE"
STATE=$RESOLVED_PATH
CANDIDATE_DIR="$STATE/learning-candidates"
MUTATION_LOCK="$STATE/.learning-candidates.lock"
export FM_STATE_OVERRIDE=$STATE

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

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

candidate_id_is_valid() { # <value>
  local value=$1 suffix
  case "$value" in lc-*) ;; *) return 1 ;; esac
  suffix=${value#lc-}
  [ "${#suffix}" -eq 24 ] || return 1
  case "$suffix" in *[!0-9a-f]*) return 1 ;; esac
}

validate_candidate_id() { # <value>
  candidate_id_is_valid "$1" || die "invalid candidate id: $1"
}

validate_text() { # <label> <value> [max-bytes]
  local label=$1 value=$2 max=${3:-$MAX_TEXT_BYTES} bytes compact
  [ -n "$value" ] || die "$label must not be empty"
  bytes=$(printf '%s' "$value" | LC_ALL=C wc -c | tr -d ' ')
  [ "$bytes" -le "$max" ] || die "$label exceeds $max bytes"
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

lifecycle_state_is_valid() {
  case "$1" in
    unresolved|dismissed|documented|promoted|follow-up|duplicate) ;;
    *) return 1 ;;
  esac
}

validate_lifecycle_state() {
  lifecycle_state_is_valid "$1" || die "invalid lifecycle state: $1"
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
  resolve_candidate_path state "$STATE"
  mkdir -p "$STATE"
  resolve_candidate_path store "$CANDIDATE_DIR" allow-missing
  [ "$RESOLVED_EXISTS" -eq 1 ] || mkdir -p "$RESOLVED_PATH"
  resolve_candidate_path store "$CANDIDATE_DIR"
  chmod 700 "$CANDIDATE_DIR"
}

store_available_read_only() {
  resolve_candidate_path state "$STATE"
  resolve_candidate_path store "$CANDIDATE_DIR" allow-missing
  [ "$RESOLVED_EXISTS" -eq 1 ]
}

LOCK_HELD=0
TEMP_FILE=
ENUMERATION_FILE=
cleanup() {
  [ -z "$TEMP_FILE" ] || rm -f -- "$TEMP_FILE" 2>/dev/null || true
  [ -z "$ENUMERATION_FILE" ] || rm -f -- "$ENUMERATION_FILE" 2>/dev/null || true
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

acquire_read_correction_lock() {
  store_available_read_only || return 1
  fm_lock_acquire_wait "$MUTATION_LOCK" || die "could not acquire candidate mutation lock"
  LOCK_HELD=1
}

read_valid_record() { # <expected-id> [path]
  local expected=${1:-} source=${2:-/dev/stdin}
  LC_ALL=C head -c "$((MAX_RECORD_BYTES + 1))" -- "$source" \
    | jq -cneS --arg expected "$expected" --argjson max "$MAX_RECORD_BYTES" \
      --rawfile raw /dev/stdin '
    if ($raw | utf8bytelength) > $max then null | halt_error(3)
    elif ($raw | contains("\u0000")) then error("invalid candidate record")
    else ($raw | fromjson) end |
    if (
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
      and (.actor | type == "string" and length > 0))))
    then . else error("invalid candidate record") end
  '
}

record_json_is_valid() { # <json> [expected-id]
  local json=$1 expected=${2:-}
  printf '%s\n' "$json" | read_valid_record "$expected" >/dev/null 2>&1
}

validate_record_json() { # <json> [expected-id]
  record_json_is_valid "$1" "${2:-}" \
    || die "invalid candidate record${2:+: $2}"
}

ENUMERATED_PATH=
ENUMERATED_ID=
ENUMERATED_HINT=
ENUMERATED_ERROR=
resolve_enumerated_entry() { # <path>
  local path=$1 base id hint
  ENUMERATED_PATH=
  ENUMERATED_ID=
  ENUMERATED_HINT=
  ENUMERATED_ERROR=
  case "$path" in
    ./*) path="$CANDIDATE_DIR/${path#./}" ;;
    "$CANDIDATE_DIR"/*) ;;
    *) ENUMERATED_ERROR="candidate path is outside the candidate store"; return 1 ;;
  esac
  base=${path##*/}
  [ "$path" = "$CANDIDATE_DIR/$base" ] \
    || { ENUMERATED_ERROR="candidate path is outside the candidate store"; return 1; }
  case "$base" in lc-*.json) ;; *) ENUMERATED_ERROR="invalid candidate record name"; return 1 ;; esac
  id=${base%%.*}
  if ! candidate_id_is_valid "$id"; then
    printf -v ENUMERATED_ERROR 'invalid candidate id: %q' "$id"
    return 1
  fi
  case "$base" in
    "$id.json") hint= ;;
    "$id."*.json) hint=${base#"$id."}; hint=${hint%.json} ;;
    *)
      printf -v ENUMERATED_ERROR 'invalid candidate record name: %q' "$base"
      return 1
      ;;
  esac
  if [ -L "$path" ]; then
    ENUMERATED_ERROR="candidate path must be a regular file"
    return 1
  fi
  if [ ! -e "$path" ]; then
    ENUMERATED_ERROR="candidate record not found"
    return 1
  fi
  if [ ! -f "$path" ]; then
    ENUMERATED_ERROR="candidate path must be a regular file"
    return 1
  fi
  ENUMERATED_PATH=$path
  ENUMERATED_ID=$id
  ENUMERATED_HINT=$hint
}

report_skipped_entry() { # <path> <reason>
  printf 'fm-learning-candidate: skipped candidate entry: %q: %s\n' "$1" "$2" >&2
}

report_sibling_inconsistency() { # <candidate-id> <path>...
  local id=$1 path escaped paths=''
  shift
  for path in "$@"; do
    printf -v escaped '%q' "$path"
    paths="${paths}${paths:+ }$escaped"
  done
  printf 'fm-learning-candidate: inconsistent candidate siblings: %s: %s\n' \
    "$id" "$paths" >&2
}

find_enumerated_replacement() { # <candidate-id>
  local id=$1 path found='' count=0 state
  for state in unresolved dismissed documented promoted follow-up duplicate; do
    path="$CANDIDATE_DIR/$id.$state.json"
    if [ ! -L "$path" ] && [ -f "$path" ] \
      && read_valid_record "$id" "$path" >/dev/null 2>&1; then
      found=$path
      count=$((count + 1))
    fi
  done
  path="$CANDIDATE_DIR/$id.json"
  if [ ! -L "$path" ] && [ -f "$path" ] \
    && read_valid_record "$id" "$path" >/dev/null 2>&1; then
    found=$path
    count=$((count + 1))
  fi
  [ "$count" -eq 1 ] || return 1
  ENUMERATED_PATH=$found
}

correct_enumerated_name() { # <path> <candidate-id> <lifecycle-state>
  local path=$1 id=$2 state=$3 destination json
  [ "$LOCK_HELD" -eq 1 ] || die "candidate name correction requires the mutation lock"
  destination="$CANDIDATE_DIR/$id.$state.json"
  if [ "$path" = "$destination" ]; then
    RECORD_PATH=$path
    return 0
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    printf -v ENUMERATED_ERROR \
      'candidate lifecycle correction blocked from %q to %q: destination already exists' \
      "$path" "$destination"
    return 2
  fi
  if mv -- "$path" "$destination" 2>/dev/null; then
    RECORD_PATH=$destination
    return 0
  fi
  if [ ! -e "$path" ] && [ ! -L "$destination" ] && [ -f "$destination" ]; then
    if json=$(read_valid_record "$id" "$destination" 2>/dev/null) \
      && printf '%s\n%s\n' "$json" "$RECORD_JSON" | jq -en \
        'input as $actual | input as $expected | $actual == $expected' >/dev/null; then
      RECORD_PATH=$destination
      return 0
    fi
  fi
  ENUMERATED_ERROR="could not correct candidate lifecycle hint"
  return 1
}

load_enumerated_record() { # <path> <correct-hint>; sets RECORD_JSON and RECORD_PATH
  local requested=$1 correct_hint=$2 path id hint state attempt=0 read_rc correction_rc
  while [ "$attempt" -lt 2 ]; do
    if ! resolve_enumerated_entry "$requested"; then
      if [ "$ENUMERATED_ERROR" = "candidate record not found" ]; then
        id=${requested##*/}
        id=${id%%.*}
        if candidate_id_is_valid "$id" && find_enumerated_replacement "$id"; then
          requested=$ENUMERATED_PATH
          resolve_enumerated_entry "$requested" || {
            report_skipped_entry "$requested" "$ENUMERATED_ERROR"
            return 1
          }
        else
          report_skipped_entry "$requested" "$ENUMERATED_ERROR"
          return 1
        fi
      else
        report_skipped_entry "$requested" "$ENUMERATED_ERROR"
        return 1
      fi
    fi
    path=$ENUMERATED_PATH
    id=$ENUMERATED_ID
    hint=$ENUMERATED_HINT
    if ! exec 4< "$path"; then
      attempt=$((attempt + 1))
      if [ "$attempt" -lt 2 ] && find_enumerated_replacement "$id"; then
        requested=$ENUMERATED_PATH
        continue
      fi
      report_skipped_entry "$path" "candidate record is unreadable"
      return 1
    fi
    exec 4<&-
    if RECORD_JSON=$(read_valid_record "$id" "$path" 2>/dev/null); then
      break
    else
      read_rc=$?
    fi
    if [ "$read_rc" -eq 3 ]; then
      report_skipped_entry "$path" "candidate record exceeds $MAX_RECORD_BYTES-byte limit"
      return 1
    fi
    if ! resolve_enumerated_entry "$path"; then
      if [ "$ENUMERATED_ERROR" = "candidate record not found" ]; then
        attempt=$((attempt + 1))
        if [ "$attempt" -lt 2 ] && find_enumerated_replacement "$id"; then
          requested=$ENUMERATED_PATH
          continue
        fi
      else
        report_skipped_entry "$path" "$ENUMERATED_ERROR"
        return 1
      fi
    fi
    report_skipped_entry "$path" "invalid candidate record: $id"
    return 1
  done
  state=$(printf '%s\n' "$RECORD_JSON" | jq -r '.lifecycle_state')
  RECORD_PATH=$path
  if [ "$hint" = "$state" ] && lifecycle_state_is_valid "$hint"; then
    return 0
  fi
  [ "$correct_hint" -eq 1 ] || return 0
  if correct_enumerated_name "$path" "$id" "$state"; then
    return 0
  else
    correction_rc=$?
  fi
  report_skipped_entry "$path" "$ENUMERATED_ERROR"
  [ "$correction_rc" -eq 2 ] && return 0
  return 1
}

load_record() { # <candidate-id> [correct-hint]; sets RECORD_JSON and RECORD_PATH
  local id=$1 correct_hint=${2:-1} content_state corrected_path corrected_exists attempt=0 read_rc
  validate_candidate_id "$id"
  store_available_read_only || die "candidate not found: $id"
  while [ "$attempt" -lt 2 ]; do
    resolve_candidate_path record "$id"
    RECORD_PATH=$RESOLVED_PATH
    if ! exec 4< "$RECORD_PATH"; then
      attempt=$((attempt + 1))
      continue
    fi
    exec 4<&-
    if RECORD_JSON=$(read_valid_record "$id" "$RECORD_PATH" 2>/dev/null); then
      read_rc=0
    else
      read_rc=$?
    fi
    if [ "$read_rc" -ne 0 ]; then
      resolve_candidate_path entry "$RECORD_PATH" allow-missing
      if [ "$RESOLVED_EXISTS" -eq 0 ]; then
        attempt=$((attempt + 1))
        continue
      fi
      [ "$read_rc" -ne 3 ] \
        || die "candidate record exceeds $MAX_RECORD_BYTES-byte limit: $id"
      die "invalid candidate record: $id"
    fi
    content_state=$(printf '%s\n' "$RECORD_JSON" | jq -r '.lifecycle_state')
    resolve_candidate_path slot "$id" "$content_state" allow-missing
    corrected_path=$RESOLVED_PATH
    corrected_exists=$RESOLVED_EXISTS
    [ "$corrected_path" != "$RECORD_PATH" ] || return 0
    [ "$correct_hint" -eq 1 ] || return 0
    if [ "$corrected_exists" -eq 1 ] || ! mv -- "$RECORD_PATH" "$corrected_path" 2>/dev/null; then
      attempt=$((attempt + 1))
      continue
    fi
    RECORD_PATH=$corrected_path
    return 0
  done
  die "candidate changed while being read: $id"
}

write_record() { # <path> <json>
  local path=$1 json=$2 id
  id=$(printf '%s\n' "$json" | jq -r '.id')
  validate_record_json "$json" "$id"
  resolve_candidate_path entry "$path" allow-missing
  [ "$RESOLVED_ID" = "$id" ] || die "candidate destination does not match record id: $id"
  TEMP_FILE=$(mktemp "$CANDIDATE_DIR/.candidate.XXXXXX") || die "could not create candidate temporary file"
  printf '%s\n' "$json" > "$TEMP_FILE"
  chmod 600 "$TEMP_FILE"
  mv -f -- "$TEMP_FILE" "$path"
  TEMP_FILE=
}

replace_record() { # <old-path> <json>
  local old_path=$1 json=$2 id state new_path new_exists old_exists
  id=$(printf '%s\n' "$json" | jq -r '.id')
  state=$(printf '%s\n' "$json" | jq -r '.lifecycle_state')
  resolve_candidate_path slot "$id" "$state" allow-missing
  new_path=$RESOLVED_PATH
  new_exists=$RESOLVED_EXISTS
  if [ "$new_path" != "$old_path" ]; then
    [ "$new_exists" -eq 0 ] || die "candidate lifecycle destination already exists: $id"
  fi
  write_record "$old_path" "$json"
  if [ "$new_path" != "$old_path" ] && ! mv -- "$old_path" "$new_path" 2>/dev/null; then
    resolve_candidate_path entry "$old_path" allow-missing
    old_exists=$RESOLVED_EXISTS
    [ "$old_exists" -eq 0 ] || die "could not update candidate lifecycle hint: $id"
    load_record "$id"
    [ "$RECORD_PATH" = "$new_path" ] \
      || die "could not update candidate lifecycle hint: $id"
    printf '%s\n%s\n' "$RECORD_JSON" "$json" | jq -en \
      'input as $actual | input as $expected | $actual == $expected' >/dev/null \
      || die "candidate changed during lifecycle cutover: $id"
  fi
}

records_stream() {
  local path id previous=''
  local -a sibling_paths=()
  store_available_read_only || return 0
  for path in "$CANDIDATE_DIR"/lc-*.json; do
    if [ "$path" = "$CANDIDATE_DIR/lc-*.json" ] && [ ! -e "$path" ] && [ ! -L "$path" ]; then
      continue
    fi
    load_enumerated_record "$path" 1 || continue
    id=$(printf '%s\n' "$RECORD_JSON" | jq -r '.id')
    if [ "$id" != "$previous" ]; then
      previous=$id
      sibling_paths=("$RECORD_PATH")
    else
      sibling_paths+=("$RECORD_PATH")
      report_sibling_inconsistency "$id" "${sibling_paths[@]}"
    fi
    printf '%s\n' "$RECORD_JSON" | jq -cS .
  done
}

records_array() {
  records_stream | jq -s 'sort_by(.captured_at, .id)'
}

capture_command() {
  local task='' project='' signal='' impact='' root_cause='' escaped_contract='' missing_check=''
  local consumer='' prevention='' evidence='' proposed_owner='' counterfactual=''
  local payload digest id path timestamp record existing
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
  record=$(printf '%s\n' "$payload" | jq -cnS \
    --arg id "$id" --arg digest "$digest" --arg at "$timestamp" \
    'input as $incident |
    {schema:1, id:$id, capture_digest:$digest, captured_at:$at,
      lifecycle_state:"unresolved", incident:$incident, classification:null,
      disposition:null, duplicates:[], history:[{at:$at,event:"captured",actor:$incident.origin_task}]}')

  acquire_capture_lock
  resolve_candidate_path record "$id" allow-missing
  if [ "$RESOLVED_EXISTS" -eq 1 ]; then
    load_record "$id"
    existing=$RECORD_JSON
    [ "$(printf '%s\n' "$existing" | jq -r '.capture_digest')" = "$digest" ] \
      || die "candidate digest collision: $id"
    printf '%s\n%s\n' "$existing" "$payload" | jq -en \
      'input as $existing | input as $incident | $existing.incident == $incident' >/dev/null \
      || die "candidate digest collision: $id"
    printf '%s\n' "$id"
    return 0
  fi
  resolve_candidate_path slot "$id" unresolved allow-missing
  path=$RESOLVED_PATH
  write_record "$path" "$record"
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
  acquire_read_correction_lock || true
  array=$(records_array)
  printf '%s\n' "$array" | jq -r --arg filter "$filter" --argjson limit "$limit" '
    def terminal_safe:
      explode | map(if (. < 32 or (. >= 127 and . <= 159)) then 32 else . end) | implode;
    def compact: terminal_safe | if length > 160 then .[:157] + "..." else . end;
    [.[] | select($filter == "all" or .lifecycle_state == $filter)][: $limit][] |
    [.id, .lifecycle_state, (.incident.project | terminal_safe), .incident.signal_type,
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
  acquire_read_correction_lock || true
  array=$(records_array)
  printf '%s\n' "$array" | jq --argjson limit "$limit" '[.[] | select(.lifecycle_state == "unresolved")][: $limit]'
}

summary_command() {
  local limit=3 count=0 sample_count=0 idx=0 name id state impact project signal line
  local correct_hint=1 previous=''
  local -a samples=() sibling_paths=()
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --limit) [ "$#" -ge 2 ] || die "--limit requires a value"; limit=$2; shift 2 ;;
      --read-only) correct_hint=0; shift ;;
      *) die "unknown summary argument: $1" ;;
    esac
  done
  validate_summary_limit "$limit"
  store_available_read_only || return 0
  if [ "$correct_hint" -eq 1 ]; then
    acquire_read_correction_lock || true
  fi
  ENUMERATION_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-learning-candidates.XXXXXX") \
    || die "could not create candidate enumeration file"
  chmod 600 "$ENUMERATION_FILE"
  if ! (
    CDPATH='' cd -- "$CANDIDATE_DIR" && \
      find . -maxdepth 1 -name 'lc-*.json' -print0 | LC_ALL=C sort -z
  ) >"$ENUMERATION_FILE"; then
    die "could not enumerate candidate store: $CANDIDATE_DIR"
  fi
  exec 3< "$ENUMERATION_FILE"
  rm -f -- "$ENUMERATION_FILE"
  ENUMERATION_FILE=
  while IFS= read -r -d '' name; do
    load_enumerated_record "$name" "$correct_hint" || continue
    id=$(printf '%s\n' "$RECORD_JSON" | jq -r '.id')
    state=$(printf '%s\n' "$RECORD_JSON" | jq -r '.lifecycle_state')
    if [ "$id" != "$previous" ]; then
      previous=$id
      sibling_paths=("$RECORD_PATH")
    else
      sibling_paths+=("$RECORD_PATH")
      report_sibling_inconsistency "$id" "${sibling_paths[@]}"
    fi
    [ "$state" = unresolved ] || continue
    count=$((count + 1))
    [ "$sample_count" -lt "$limit" ] || continue
    project=$(printf '%s\n' "$RECORD_JSON" | jq -r '
      .incident.project |
      explode | map(if (. < 32 or (. >= 127 and . <= 159)) then 32 else . end) | implode')
    signal=$(printf '%s\n' "$RECORD_JSON" | jq -r '.incident.signal_type')
    impact=$(printf '%s\n' "$RECORD_JSON" | jq -r '
      .incident.user_visible_impact |
      explode | map(if (. < 32 or (. >= 127 and . <= 159)) then 32 else . end) | implode |
      if length > 120 then .[:117] + "..." else . end')
    printf -v line -- '- %s [%s/%s] %s' "$id" "$project" "$signal" "$impact"
    samples[sample_count]=$line
    sample_count=$((sample_count + 1))
  done <&3
  exec 3<&-
  [ "$count" -gt 0 ] || return 0

  printf 'LEARNING CANDIDATES: %s unresolved\n' "$count"
  while [ "$idx" -lt "$sample_count" ]; do
    printf '%s\n' "${samples[$idx]}"
    idx=$((idx + 1))
  done
  if [ "$count" -gt "$limit" ]; then
    printf -- '- ... %s more; run bin/fm-learning-candidate.sh batch\n' "$((count - limit))"
  fi
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
    validate_text skill-statement "$skill_statement"
    validate_text skill-feature-neutral-evidence "$skill_feature_neutral"
    validate_text skill-procedure "$skill_procedure"
    validate_text skill-load-trigger "$skill_load_trigger"
    validate_text skill-counterfactual "$skill_counterfactual"
    if [ "$count" -lt 2 ]; then
      validate_text skill-feature-agnostic-evidence "$skill_feature_agnostic"
    elif [ -n "$skill_feature_agnostic" ]; then
      validate_text skill-feature-agnostic-evidence "$skill_feature_agnostic"
    fi
    skill_gate=$(printf '%s\n' "$task_types_json" | jq -cnS --arg statement "$skill_statement" \
      --arg feature_neutral "$skill_feature_neutral" \
      --arg feature_agnostic "$skill_feature_agnostic" \
      --arg procedure "$skill_procedure" \
      --arg load_trigger "$skill_load_trigger" --arg counterfactual "$skill_counterfactual" \
      'input as $task_types |
      {general_statement:$statement, feature_neutral_evidence:$feature_neutral,
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
  load_record "$id"
  [ "$(printf '%s\n' "$RECORD_JSON" | jq -r '.incident.origin_task')" != "$curator" ] \
    || die "curator must differ from the originating task"
  comparable=$(printf '%s\n' "$skill_gate" | jq -cnS \
    --arg curator "$curator" --arg route "$route" --arg owner "$owner" \
    --arg surface "$surface" --arg recommendation "$recommendation" --arg rationale "$rationale" \
    'input as $skill_gate |
    {curator:$curator, route:$route, owner:$owner, surface:$surface,
      recommendation:$recommendation, rationale:$rationale, skill_gate:$skill_gate}')
  existing=$(printf '%s\n' "$RECORD_JSON" | jq -cS '.classification // null')
  if [ "$existing" != null ]; then
    if printf '%s\n%s\n' "$existing" "$comparable" | jq -en \
      'input as $existing | input as $wanted | ($existing | del(.at)) == $wanted' >/dev/null; then
      printf '%s\n' "$id"
      return 0
    fi
    die "candidate already has a different classification: $id"
  fi
  [ "$(printf '%s\n' "$RECORD_JSON" | jq -r '.lifecycle_state')" = unresolved ] \
    || die "only an unresolved candidate can be classified"
  timestamp=$(now_rfc3339)
  classification=$(printf '%s\n' "$comparable" | jq -cS --arg at "$timestamp" '. + {at:$at}')
  updated=$(printf '%s\n%s\n' "$RECORD_JSON" "$classification" | jq -cnS \
    --arg at "$timestamp" --arg curator "$curator" --arg route "$route" \
    'input as $record | input as $classification | $record |
     .classification=$classification |
     .history += [{at:$at,event:"classified",actor:$curator,detail:$route}]')
  replace_record "$RECORD_PATH" "$updated"
  printf '%s\n' "$id"
}

disposition_command() {
  local id=${2:-} curator='' outcome='' note='' reference='' timestamp disposition existing comparable updated
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
  load_record "$id"
  [ "$(printf '%s\n' "$RECORD_JSON" | jq -r '.incident.origin_task')" != "$curator" ] \
    || die "curator must differ from the originating task"
  comparable=$(jq -cnS --arg curator "$curator" --arg outcome "$outcome" \
    --arg note "$note" --arg reference "$reference" \
    '{curator:$curator, outcome:$outcome, note:$note,
      reference:(if $reference == "" then null else $reference end)}')
  existing=$(printf '%s\n' "$RECORD_JSON" | jq -cS '.disposition // null')
  if [ "$existing" != null ]; then
    if printf '%s\n%s\n' "$existing" "$comparable" | jq -en \
      'input as $existing | input as $wanted | ($existing | del(.at)) == $wanted' >/dev/null; then
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
  updated=$(printf '%s\n%s\n' "$RECORD_JSON" "$disposition" | jq -cnS \
    --arg at "$timestamp" --arg curator "$curator" --arg outcome "$outcome" \
    'input as $record | input as $disposition | $record |
     .lifecycle_state=$outcome | .disposition=$disposition |
     .history += [{at:$at,event:"disposed",actor:$curator,detail:$outcome}]')
  replace_record "$RECORD_PATH" "$updated"
  printf '%s\n' "$id"
}

dedupe_command() {
  local duplicate=${2:-} canonical='' curator='' reason='' timestamp duplicate_json duplicate_path
  local canonical_json canonical_path disposition updated_canonical updated_duplicate existing exact_retry=0
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
  load_record "$duplicate"
  duplicate_json=$RECORD_JSON
  duplicate_path=$RECORD_PATH
  [ "$(printf '%s\n' "$duplicate_json" | jq -r '.incident.origin_task')" != "$curator" ] \
    || die "curator must differ from the originating task"

  existing=$(printf '%s\n' "$duplicate_json" | jq -cS '.disposition // null')
  if [ "$existing" != null ]; then
    if printf '%s\n' "$existing" | jq -e --arg curator "$curator" --arg canonical "$canonical" --arg reason "$reason" \
      '.outcome == "duplicate" and .curator == $curator and .reference == $canonical and .note == $reason' >/dev/null; then
      exact_retry=1
    else
      die "candidate already has a different disposition: $duplicate"
    fi
  else
    [ "$(printf '%s\n' "$duplicate_json" | jq -r '.lifecycle_state')" = unresolved ] \
      || die "only an unresolved candidate can be deduplicated"
  fi

  load_record "$canonical"
  canonical_json=$RECORD_JSON
  canonical_path=$RECORD_PATH
  [ "$(printf '%s\n' "$canonical_json" | jq -r '.incident.origin_task')" != "$curator" ] \
    || die "curator must differ from both originating tasks"
  if [ "$exact_retry" -eq 0 ]; then
    [ "$(printf '%s\n' "$canonical_json" | jq -r '.lifecycle_state')" = unresolved ] \
      || die "canonical candidate must remain unresolved"
  elif printf '%s\n' "$canonical_json" | jq -e --arg duplicate "$duplicate" \
    '.duplicates | index($duplicate) != null' >/dev/null; then
    printf '%s\n' "$canonical"
    return 0
  fi

  timestamp=$(now_rfc3339)
  if [ "$exact_retry" -eq 0 ]; then
    disposition=$(jq -cnS --arg at "$timestamp" --arg curator "$curator" \
      --arg note "$reason" --arg reference "$canonical" \
      '{at:$at,curator:$curator,outcome:"duplicate",note:$note,reference:$reference}')
    updated_duplicate=$(printf '%s\n%s\n' "$duplicate_json" "$disposition" | jq -cnS \
      --arg at "$timestamp" --arg curator "$curator" --arg canonical "$canonical" \
      'input as $record | input as $disposition | $record |
       .lifecycle_state="duplicate" | .disposition=$disposition |
       .history += [{at:$at,event:"deduplicated",actor:$curator,detail:$canonical}]')
    replace_record "$duplicate_path" "$updated_duplicate"
  fi
  updated_canonical=$(printf '%s\n' "$canonical_json" | jq -cS --arg duplicate "$duplicate" \
    --arg at "$timestamp" --arg curator "$curator" --arg reason "$reason" \
    'if (.duplicates | index($duplicate)) == null then
       .duplicates = ((.duplicates + [$duplicate]) | unique) |
       .history += [{at:$at,event:"dedupe-canonical",actor:$curator,detail:$reason}]
     else . end')
  replace_record "$canonical_path" "$updated_canonical"
  printf '%s\n' "$canonical"
}

case "${1:-}" in
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
