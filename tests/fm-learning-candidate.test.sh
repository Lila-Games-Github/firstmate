#!/usr/bin/env bash
# Behavioral coverage for the public learning-candidate lifecycle command.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMMAND="$ROOT/bin/fm-learning-candidate.sh"
TMP_ROOT=$(fm_test_tmproot fm-learning-candidate)
trap fm_test_cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() { # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

run_learning() { # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_LEARNING_NOW=2026-08-28T12:00:00Z "$COMMAND" "$@"
}

candidate_path() { # <home> <candidate-id> [lifecycle-state]
  printf '%s/state/learning-candidates/%s.%s.json\n' "$1" "$2" "${3:-unresolved}"
}

capture_candidate() { # <home> <task> <project> <signal> <impact> [evidence]
  local home=$1 task=$2 project=$3 signal=$4 impact=$5 evidence
  evidence=${6:-"evidence for $task"}
  run_learning "$home" capture \
    --task "$task" \
    --project "$project" \
    --signal "$signal" \
    --impact "$impact" \
    --root-cause "root cause for $task" \
    --escaped-contract "escaped contract for $task" \
    --missing-check "missing check for $task" \
    --consumer "consumer for $task" \
    --prevention "proposed prevention for $task" \
    --evidence "$evidence" \
    --proposed-owner "proposed owner for $task" \
    --counterfactual "the proposal would have exposed $task before completion"
}

classify_feature() { # <home> <id> <curator> [owner]
  run_learning "$1" classify "$2" \
    --curator "$3" \
    --route feature \
    --owner "${4:-FrogPile-quest}" \
    --surface tests \
    --recommendation "Add a feature regression" \
    --rationale "The behavior belongs to one feature"
}

test_help_avoids_private_state_access() {
  local home absent invalid output rc
  home="$TMP_ROOT/help-state"
  absent="$home/absent-state"
  invalid="$home/not-a-directory"
  mkdir -p "$home"

  output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$absent" "$COMMAND" --help) \
    || fail "help failed for an absent private state path"
  assert_contains "$output" "Usage:" "help omitted the executable mechanics contract"
  assert_absent "$absent" "help created an absent private state path"

  printf 'not a directory\n' >"$invalid"
  set +e
  output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$invalid" "$COMMAND" --help 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "help consulted an invalid private state override: $output"
  assert_contains "$output" "Usage:" "help was unavailable with an invalid state override"
  pass "help remains available without private state access"
}

test_capture_validation_and_complete_record() {
  local home id json rc path original
  home=$(make_home validation)
  set +e
  run_learning "$home" capture \
    --task incomplete --project FrogPile --signal escaped-defect \
    --impact impact --root-cause cause --escaped-contract contract \
    --missing-check check --consumer player --prevention prevention \
    --evidence evidence --proposed-owner owner >"$home/missing.out" 2>"$home/missing.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "capture accepted a record without its counterfactual"
  assert_grep "counterfactual must not be empty" "$home/missing.err" \
    "missing-field refusal did not name the absent field"

  set +e
  capture_candidate "$home" bad-signal FrogPile routine-success impact >"$home/signal.out" 2>"$home/signal.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "capture accepted a routine-success signal"
  assert_grep "invalid signal type" "$home/signal.err" "invalid signal refusal was not explicit"

  id=$(capture_candidate "$home" hud-reference FrogPile escaped-defect \
    "HUD visibly violated its screenshot reference") || fail "valid capture failed"
  json=$(run_learning "$home" get "$id") || fail "captured record could not be read"
  printf '%s\n' "$json" | jq -e '
    .schema == 1
    and .lifecycle_state == "unresolved"
    and .incident.origin_task == "hud-reference"
    and .incident.project == "FrogPile"
    and .incident.signal_type == "escaped-defect"
    and (.incident | has("user_visible_impact") and has("root_cause")
      and has("escaped_contract") and has("missing_check")
      and has("affected_consumer") and has("proposed_prevention")
      and has("evidence") and has("proposed_owner") and has("counterfactual"))
    and .classification == null and .disposition == null
  ' >/dev/null || fail "capture omitted required independent-classification fields: $json"

  path=$(candidate_path "$home" "$id")
  original=$(cat "$path")
  printf '{}\n%s\n' "$original" >"$path"
  set +e
  run_learning "$home" get "$id" >"$home/multiple.out" 2>"$home/multiple.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "record validation accepted multiple top-level JSON values"
  assert_grep "invalid candidate record" "$home/multiple.err" \
    "multiple-value record validation failure was not explicit"
  printf '%s\n' "$original" >"$path"

  jq '.incident.signal_type="routine-success"' "$path" >"$home/corrupt.json"
  mv "$home/corrupt.json" "$path"
  set +e
  run_learning "$home" get "$id" >"$home/corrupt.out" 2>"$home/corrupt.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "record validation accepted a non-qualifying stored signal"
  assert_grep "invalid candidate record" "$home/corrupt.err" \
    "stored-record validation failure was not explicit"
  pass "learning candidates validate qualifying signals and preserve every required incident field"
}

test_large_escaped_capture_avoids_argv_limits() {
  local home large first second json
  home=$(make_home large-escaped-capture)
  printf -v large '%*s' 8192 ''
  large=${large// /\\}
  first=$(run_learning "$home" capture \
    --task large-escaped --project FrogPile --signal escaped-defect \
    --impact "$large" --root-cause "$large" --escaped-contract "$large" \
    --missing-check "$large" --consumer "$large" --prevention "$large" \
    --evidence "$large" --proposed-owner "$large" --counterfactual "$large") \
    || fail "maximum-size escaped capture failed"
  second=$(run_learning "$home" capture \
    --task large-escaped --project FrogPile --signal escaped-defect \
    --impact "$large" --root-cause "$large" --escaped-contract "$large" \
    --missing-check "$large" --consumer "$large" --prevention "$large" \
    --evidence "$large" --proposed-owner "$large" --counterfactual "$large") \
    || fail "maximum-size escaped repeat capture failed"
  [ "$first" = "$second" ] || fail "maximum-size escaped repeat changed candidate identity"
  json=$(run_learning "$home" get "$first") || fail "maximum-size escaped record was unreadable"
  printf '%s\n' "$json" | jq -e '
    [.incident.user_visible_impact, .incident.root_cause,
     .incident.escaped_contract, .incident.missing_check,
     .incident.affected_consumer, .incident.proposed_prevention,
     .incident.evidence, .incident.proposed_owner,
     .incident.counterfactual] | all(length == 8192)
  ' >/dev/null || fail "maximum-size escaped record did not preserve accepted field bounds"
  pass "maximum-size escaped capture and repeat avoid argv limits"
}

test_repeat_capture_is_idempotent() {
  local home first second count path rc
  home=$(make_home repeat)
  first=$(capture_candidate "$home" repeated-review FrogPile review-rejection \
    "review rejected the completed HUD") || fail "first capture failed"
  second=$(capture_candidate "$home" repeated-review FrogPile review-rejection \
    "review rejected the completed HUD") || fail "repeat capture failed"
  [ "$first" = "$second" ] || fail "exact repeat capture produced a different identity"
  count=$(find "$home/state/learning-candidates" -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "exact repeat capture created $count records"
  path=$(candidate_path "$home" "$first")
  jq '.incident.evidence="altered while retaining the original digest"' "$path" >"$home/altered.json"
  mv "$home/altered.json" "$path"
  set +e
  capture_candidate "$home" repeated-review FrogPile review-rejection \
    "review rejected the completed HUD" >"$home/altered.out" 2>"$home/altered.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "repeat capture accepted incident content not bound to its digest"
  assert_grep "candidate digest collision" "$home/altered.err" \
    "altered repeat-capture refusal was not explicit"
  pass "exact repeat capture converges on one durable candidate"
}

test_read_commands_reject_symlinked_state() {
  local target exposed normal id override command output rc
  normal=$(make_home state-alias-normalization)
  for override in "$normal/state/" "$normal/state/."; do
    output=$(FM_HOME="$normal" FM_STATE_OVERRIDE="$override" "$COMMAND" list --all) \
      || fail "list rejected real state alias $override"
    [ -z "$output" ] || fail "empty real state alias produced candidate output"
  done

  target=$(make_home symlink-target)
  id=$(capture_candidate "$target" symlink-source FrogPile escaped-defect \
    "state overrides must stay inside the selected private home")
  classify_feature "$target" "$id" curator-symlink >/dev/null
  run_learning "$target" disposition "$id" --curator curator-symlink \
    --status documented --note "The state boundary is documented" \
    --reference "docs/state-boundary.md" >/dev/null
  mv "$(candidate_path "$target" "$id" documented)" "$(candidate_path "$target" "$id")"

  exposed=$(make_home symlink-reader)
  rmdir "$exposed/state"
  ln -s "$target/state" "$exposed/state"
  for override in "$exposed/state/" "$exposed/state/."; do
    for command in get list batch summary capture classify disposition dedupe; do
      case "$command" in
        get) set -- get "$id" ;;
        list) set -- list --all ;;
        batch) set -- batch ;;
        summary) set -- summary ;;
        capture) set -- capture ;;
        classify) set -- classify "$id" ;;
        disposition) set -- disposition "$id" ;;
        dedupe) set -- dedupe "$id" ;;
      esac
      set +e
      FM_HOME="$exposed" FM_STATE_OVERRIDE="$override" \
        FM_LEARNING_NOW=2026-08-28T12:00:00Z "$COMMAND" "$@" \
        >"$exposed/$command.out" 2>"$exposed/$command.err"
      rc=$?
      set -e
      [ "$rc" -ne 0 ] || fail "$command followed symlinked state alias $override"
      assert_grep "state path must be a real directory" "$exposed/$command.err" \
        "$command did not reject symlinked state alias $override"
    done
  done
  assert_present "$(candidate_path "$target" "$id")" \
    "a read command renamed a record through the symlinked state override"
  assert_absent "$(candidate_path "$target" "$id" documented)" \
    "a read command corrected lifecycle state outside the selected private home"
  pass "state aliases normalize before public lifecycle path validation"
}

test_atomic_lifecycle_publication_and_content_authority() {
  local home id fakebin real_mv call_file rc count summary listed json
  home=$(make_home atomic-lifecycle)
  id=$(capture_candidate "$home" atomic-transition FrogPile escaped-defect \
    "lifecycle publication must preserve the authoritative record")
  classify_feature "$home" "$id" curator-atomic >/dev/null
  fakebin=$(fm_fakebin "$home/rename-interruption")
  real_mv=$(command -v mv)
  call_file="$home/mv-calls"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'count=0' \
    '[ ! -f "$FM_TEST_MV_CALLS" ] || count=$(cat "$FM_TEST_MV_CALLS")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" >"$FM_TEST_MV_CALLS"' \
    '[ "$count" -ne 2 ] || exit 1' \
    'exec "$FM_TEST_REAL_MV" "$@"' >"$fakebin/mv"
  chmod +x "$fakebin/mv"
  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_MV_CALLS="$call_file" \
    run_learning "$home" \
    disposition "$id" --curator curator-atomic --status documented \
    --note "The contract now documents the transition" --reference "docs/atomic.md" \
    >"$home/publish.out" 2>"$home/publish.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "lifecycle fixture did not interrupt the suffix rename"
  count=$(find "$home/state/learning-candidates" -type f -name "$id.*.json" | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "interrupted lifecycle cutover left $count candidate records"
  assert_present "$(candidate_path "$home" "$id")" \
    "interrupted lifecycle cutover did not retain the sole current-path record"
  assert_absent "$(candidate_path "$home" "$id" documented)" \
    "interrupted lifecycle cutover published a second record"
  [ "$(jq -r '.lifecycle_state' "$(candidate_path "$home" "$id")")" = documented ] \
    || fail "interrupted lifecycle cutover did not publish updated content first"
  summary=$(run_learning "$home" summary --read-only 2>"$home/read-only-summary.err") \
    || fail "read-only summary rejected a readable stale lifecycle hint"
  [ -z "$summary" ] || fail "read-only summary trusted a stale unresolved filename over terminal content"
  [ ! -s "$home/read-only-summary.err" ] || fail "read-only summary reported a stale derived hint"
  assert_present "$(candidate_path "$home" "$id")" \
    "read-only summary renamed the stale lifecycle hint"
  assert_absent "$(candidate_path "$home" "$id" documented)" \
    "read-only summary published a corrected lifecycle hint"
  summary=$(run_learning "$home" summary 2>"$home/summary.err") \
    || fail "summary rejected a readable record with a stale lifecycle hint"
  [ -z "$summary" ] || fail "summary counted terminal content under a stale unresolved hint"
  [ ! -s "$home/summary.err" ] || fail "summary reported a stale derived lifecycle hint"
  assert_absent "$(candidate_path "$home" "$id")" \
    "summary did not correct the stale lifecycle hint in passing"
  assert_present "$(candidate_path "$home" "$id" documented)" \
    "summary did not preserve the sole record under its corrected hint"
  listed=$(run_learning "$home" list --all)
  assert_contains "$listed" "$id" "list omitted the interrupted candidate"
  assert_contains "$listed" $'\tdocumented\t' "list trusted the filename hint over record content"
  json=$(run_learning "$home" get "$id")
  [ "$(printf '%s\n' "$json" | jq -r '.lifecycle_state')" = documented ] \
    || fail "get did not return the content-authoritative lifecycle state"
  pass "interrupted lifecycle cutover keeps one content-authoritative record"
}

test_concurrent_suffix_rename_reresolves() {
  local home id source destination fakebin real_cat real_mv json rc count
  home=$(make_home concurrent-read)
  id=$(capture_candidate "$home" concurrent-reader FrogPile escaped-defect \
    "a reader must tolerate an overlapping lifecycle rename")
  classify_feature "$home" "$id" curator-reader >/dev/null
  run_learning "$home" disposition "$id" --curator curator-reader \
    --status documented --note "The lifecycle contract is documented" \
    --reference "docs/concurrent.md" >/dev/null
  source=$(candidate_path "$home" "$id")
  destination=$(candidate_path "$home" "$id" documented)
  mv "$destination" "$source"
  fakebin=$(fm_fakebin "$home/concurrent-rename")
  real_cat=$(command -v cat)
  real_mv=$(command -v mv)
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$1" = "$FM_TEST_RACE_SOURCE" ] && [ ! -e "$FM_TEST_RACE_DONE" ]; then' \
    '  : >"$FM_TEST_RACE_DONE"' \
    '  "$FM_TEST_REAL_MV" "$FM_TEST_RACE_SOURCE" "$FM_TEST_RACE_DESTINATION"' \
    'fi' \
    'exec "$FM_TEST_REAL_CAT" "$@"' >"$fakebin/cat"
  chmod +x "$fakebin/cat"
  json=$(PATH="$fakebin:$PATH" FM_TEST_REAL_CAT="$real_cat" FM_TEST_REAL_MV="$real_mv" \
    FM_TEST_RACE_SOURCE="$source" FM_TEST_RACE_DESTINATION="$destination" \
    FM_TEST_RACE_DONE="$home/race-done" run_learning "$home" get "$id") \
    || fail "get rejected one record renamed after discovery"
  [ "$(printf '%s\n' "$json" | jq -r '.lifecycle_state')" = documented ] \
    || fail "concurrent read did not preserve content-authoritative lifecycle state"
  count=$(find "$home/state/learning-candidates" -type f -name "$id.*.json" | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "concurrent suffix rename produced $count candidate records"

  cp "$destination" "$source"
  set +e
  run_learning "$home" get "$id" >"$home/duplicate.out" 2>"$home/duplicate.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "bounded re-resolution accepted genuine duplicate records"
  assert_grep "candidate has multiple lifecycle records" "$home/duplicate.err" \
    "genuine duplicate refusal was not explicit"
  pass "concurrent suffix renames re-resolve without hiding genuine duplicates"
}

test_cutover_accepts_concurrent_read_correction() {
  local home id fakebin real_mv call_file json count
  home=$(make_home concurrent-cutover)
  id=$(capture_candidate "$home" concurrent-cutover FrogPile escaped-defect \
    "a reader may correct the lifecycle hint during cutover")
  classify_feature "$home" "$id" curator-cutover >/dev/null
  fakebin=$(fm_fakebin "$home/cutover-reader")
  real_mv=$(command -v mv)
  call_file="$home/mv-calls"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'count=0' \
    '[ ! -f "$FM_TEST_MV_CALLS" ] || count=$(cat "$FM_TEST_MV_CALLS")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" >"$FM_TEST_MV_CALLS"' \
    'if [ "$count" -eq 2 ]; then' \
    '  PATH="$FM_TEST_BASE_PATH" "$FM_TEST_COMMAND" get "$FM_TEST_CANDIDATE" >"$FM_TEST_READ_OUT"' \
    'fi' \
    'exec "$FM_TEST_REAL_MV" "$@"' >"$fakebin/mv"
  chmod +x "$fakebin/mv"
  PATH="$fakebin:$PATH" FM_TEST_BASE_PATH="$PATH" FM_TEST_COMMAND="$COMMAND" \
    FM_TEST_CANDIDATE="$id" FM_TEST_READ_OUT="$home/read.out" \
    FM_TEST_REAL_MV="$real_mv" FM_TEST_MV_CALLS="$call_file" run_learning "$home" \
    disposition "$id" --curator curator-cutover --status documented \
    --note "The lifecycle contract is documented" --reference "docs/cutover.md" >/dev/null \
    || fail "cutover rejected an already-corrected sole record"
  json=$(run_learning "$home" get "$id")
  [ "$(printf '%s\n' "$json" | jq -r '.lifecycle_state')" = documented ] \
    || fail "concurrent cutover lost the committed lifecycle content"
  count=$(find "$home/state/learning-candidates" -type f -name "$id.*.json" | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "concurrent cutover left $count candidate records"
  pass "cutover accepts a sole record already corrected by a reader"
}

test_list_resolves_ids_after_suffix_rename() {
  local home first second trigger target trigger_path source destination fakebin
  local real_cat real_mv listed lines
  home=$(make_home list-rename)
  first=$(capture_candidate "$home" list-first FrogPile escaped-defect \
    "first candidate drives concurrent list timing")
  second=$(capture_candidate "$home" list-second FrogPile review-rejection \
    "second candidate must remain visible after rename")
  if [ "$first" \< "$second" ]; then
    trigger=$first
    target=$second
  else
    trigger=$second
    target=$first
  fi
  classify_feature "$home" "$target" curator-list >/dev/null
  run_learning "$home" disposition "$target" --curator curator-list \
    --status documented --note "The list contract is documented" \
    --reference "docs/list.md" >/dev/null
  trigger_path=$(candidate_path "$home" "$trigger")
  source=$(candidate_path "$home" "$target")
  destination=$(candidate_path "$home" "$target" documented)
  mv "$destination" "$source"
  fakebin=$(fm_fakebin "$home/list-reader")
  real_cat=$(command -v cat)
  real_mv=$(command -v mv)
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$1" = "$FM_TEST_TRIGGER_PATH" ] && [ ! -e "$FM_TEST_RENAME_DONE" ]; then' \
    '  : >"$FM_TEST_RENAME_DONE"' \
    '  "$FM_TEST_REAL_MV" "$FM_TEST_RENAME_SOURCE" "$FM_TEST_RENAME_DESTINATION"' \
    'fi' \
    'exec "$FM_TEST_REAL_CAT" "$@"' >"$fakebin/cat"
  chmod +x "$fakebin/cat"
  listed=$(PATH="$fakebin:$PATH" FM_TEST_TRIGGER_PATH="$trigger_path" \
    FM_TEST_RENAME_SOURCE="$source" FM_TEST_RENAME_DESTINATION="$destination" \
    FM_TEST_RENAME_DONE="$home/rename-done" FM_TEST_REAL_CAT="$real_cat" \
    FM_TEST_REAL_MV="$real_mv" run_learning "$home" list --all) \
    || fail "list failed while a later candidate suffix was renamed"
  lines=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$lines" -eq 2 ] || fail "list omitted a candidate renamed after path enumeration"
  assert_contains "$listed" "$target" "list omitted the concurrently renamed candidate id"
  assert_contains "$listed" $'\tdocumented\t' \
    "list did not resolve the renamed candidate through content"
  pass "list resolves enumerated candidate ids after suffix renames"
}

test_routes_and_no_one_off_skill_gate() {
  local home quest hud lost playbot pointer json rc
  home=$(make_home routes)
  quest=$(capture_candidate "$home" completed-quest FrogPile escaped-defect \
    "completed quest remained visible")
  hud=$(capture_candidate "$home" screenshot-hud FrogPile review-rejection \
    "HUD did not match the screenshot reference")
  lost=$(capture_candidate "$home" lost-worker-decision firstmate workflow-gap-blocker \
    "worker decision disappeared after absent supervision")
  playbot=$(capture_candidate "$home" playbot-submit Playbot escaped-defect \
    "Playbot dropped a submitted prompt")
  pointer=$(capture_candidate "$home" pointer-coordinates FrogPile captain-correction \
    "physical pointer coordinates were not validated")

  classify_feature "$home" "$quest" curator-feature >/dev/null \
    || fail "feature classification failed"
  run_learning "$home" classify "$hud" --curator curator-ui --route project \
    --owner FrogPile --surface instructions \
    --recommendation "Require visual-reference comparison for project UI work" \
    --rationale "The practice spans several UI feature tasks" >/dev/null \
    || fail "project classification failed"
  run_learning "$home" classify "$lost" --curator curator-pipeline --route firstmate \
    --owner Firstmate --surface pipeline \
    --recommendation "Preserve worker decisions through supervision" \
    --rationale "The failure crossed projects and arose in supervision" >/dev/null \
    || fail "Firstmate classification failed"
  run_learning "$home" classify "$playbot" --curator curator-tool --route tool \
    --owner Playbot --surface tool-repository \
    --recommendation "Validate Playbot prompt delivery" \
    --rationale "The named tool caused the defect" >/dev/null \
    || fail "tool classification failed"

  set +e
  run_learning "$home" classify "$pointer" --curator curator-input --route project \
    --owner FrogPile --surface skill \
    --recommendation "Add reusable physical-input validation" \
    --rationale "The practice spans input interactions" >"$home/skill-missing.out" 2>"$home/skill-missing.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "project skill classification bypassed its evidence gate"
  assert_grep "skill-statement must not be empty" "$home/skill-missing.err" \
    "skill-gate refusal did not name its missing evidence"

  set +e
  run_learning "$home" classify "$pointer" --curator curator-input --route project \
    --owner FrogPile --surface skill \
    --recommendation "Add reusable physical-input validation" \
    --rationale "The practice spans input interactions" \
    --skill-statement "Validate physical coordinates at interaction boundaries" \
    --skill-feature-neutral-evidence "The rule names an input boundary rather than a feature" \
    --skill-task-type drag \
    --skill-procedure "Convert coordinates, validate bounds, then exercise the physical event" \
    --skill-load-trigger "Load before implementing physical pointer interaction" \
    --skill-counterfactual "The validation would have rejected the original coordinates" \
    >"$home/skill-one-type.out" 2>"$home/skill-one-type.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "one task type qualified for a skill without feature-agnostic evidence"
  assert_grep "skill-feature-agnostic-evidence must not be empty" "$home/skill-one-type.err" \
    "single-task skill refusal did not require alternate generality evidence"

  set +e
  run_learning "$home" classify "$pointer" --curator curator-input --route project \
    --owner FrogPile --surface skill \
    --recommendation "Add reusable physical-input validation" \
    --rationale "The practice spans input interactions" \
    --skill-statement " " --skill-feature-neutral-evidence $'\t' \
    --skill-feature-agnostic-evidence " " --skill-procedure $'\n' \
    --skill-load-trigger " " --skill-counterfactual $'\r' \
    >"$home/skill-blank.out" 2>"$home/skill-blank.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "whitespace-only evidence bypassed the project skill gate"
  assert_grep "must contain non-whitespace text" "$home/skill-blank.err" \
    "blank skill-gate refusal did not require substantive evidence"

  run_learning "$home" classify "$pointer" --curator curator-input --route project \
    --owner FrogPile --surface skill \
    --recommendation "Add reusable physical-input validation" \
    --rationale "The practice spans input interactions" \
    --skill-statement "Validate physical coordinates at interaction boundaries" \
    --skill-feature-neutral-evidence "The rule names an input boundary rather than a feature" \
    --skill-task-type drag --skill-task-type canvas-click \
    --skill-procedure "Convert coordinates, validate bounds, then exercise the physical event" \
    --skill-load-trigger "Load before implementing physical pointer interaction" \
    --skill-counterfactual "The validation would have rejected the original coordinates" >/dev/null \
    || fail "complete multi-task skill evidence was rejected"

  json=$(run_learning "$home" get "$pointer")
  printf '%s\n' "$json" | jq -e '
    .classification.route == "project"
    and .classification.owner == "FrogPile"
    and .classification.surface == "skill"
    and .classification.skill_gate.task_types == ["canvas-click", "drag"]
    and (.classification.skill_gate.general_statement | length > 0)
    and (.classification.skill_gate.feature_neutral_evidence | length > 0)
    and (.classification.skill_gate.repeatable_procedure | length > 0)
    and (.classification.skill_gate.load_trigger | length > 0)
    and (.classification.skill_gate.counterfactual | length > 0)
  ' >/dev/null || fail "skill classification did not preserve gate evidence: $json"

  set +e
  run_learning "$home" classify "$pointer" --curator pointer-coordinates \
    --route project --owner FrogPile --surface tooling \
    --recommendation changed --rationale changed >"$home/same-lane.out" 2>"$home/same-lane.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "originating task was accepted as its own curator"

  set +e
  run_learning "$home" classify "$hud" --curator other-curator --route feature \
    --owner FrogPile-HUD --surface skill --recommendation wrong --rationale wrong \
    >"$home/route-mismatch.out" 2>"$home/route-mismatch.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "feature-specific route accepted a skill surface"
  assert_grep "not valid for route" "$home/route-mismatch.err" \
    "route-surface mismatch was not explicit"

  pass "classification routes feature, project, Firstmate, and named-tool incidents and enforces the skill gate"
}

test_lifecycle_dispositions_and_deduplication() {
  local home dismissed documented promoted followup canonical duplicate json rc
  home=$(make_home lifecycle)
  dismissed=$(capture_candidate "$home" dismissed-case FrogPile workflow-gap-blocker \
    "one local outage had no reusable prevention")
  run_learning "$home" disposition "$dismissed" --curator curator-dismiss \
    --status dismissed --note "The cause was already removed and cannot recur" >/dev/null \
    || fail "unclassified dismissal failed"

  documented=$(capture_candidate "$home" documented-case FrogPile escaped-defect \
    "quest completion behavior escaped tests")
  set +e
  run_learning "$home" disposition "$documented" --curator curator-doc \
    --status documented --note "Already covered" --reference "docs/quest.md" \
    >"$home/early-doc.out" 2>"$home/early-doc.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "documented disposition succeeded before classification"
  classify_feature "$home" "$documented" curator-doc >/dev/null
  run_learning "$home" disposition "$documented" --curator curator-doc \
    --status documented --note "The feature contract now covers it" \
    --reference "FrogPile/docs/quest.md" >/dev/null \
    || fail "documented disposition failed"
  assert_absent "$(candidate_path "$home" "$documented")" \
    "documented candidate retained a second unresolved record"
  assert_present "$(candidate_path "$home" "$documented" documented)" \
    "documented candidate did not move to its single lifecycle record"
  classify_feature "$home" "$documented" curator-doc >/dev/null \
    || fail "exact classification retry stopped being idempotent after disposition"

  promoted=$(capture_candidate "$home" promoted-case FrogPile review-rejection \
    "visual review practice needs project adoption")
  run_learning "$home" classify "$promoted" --curator curator-promote --route project \
    --owner FrogPile --surface tooling --recommendation "Add screenshot comparison tooling" \
    --rationale "The practice spans multiple UI task types" >/dev/null
  run_learning "$home" disposition "$promoted" --curator curator-promote \
    --status promoted --note "Entered the normal project delivery path" \
    --reference "FrogPile proposal ui-visual-check" >/dev/null \
    || fail "promoted disposition failed"

  followup=$(capture_candidate "$home" followup-case firstmate substantive-no-mistakes-correction \
    "validation evidence was incomplete")
  run_learning "$home" classify "$followup" --curator curator-followup --route firstmate \
    --owner Firstmate --surface pipeline --recommendation "Tighten validation evidence capture" \
    --rationale "The practice affects delivery across projects" >/dev/null
  run_learning "$home" disposition "$followup" --curator curator-followup \
    --status follow-up --note "A proposed task owns the next step" \
    --reference "proposal learning-evidence-followup" >/dev/null \
    || fail "follow-up disposition failed"

  canonical=$(capture_candidate "$home" duplicate-a FrogPile review-rejection \
    "the same visual review gap appeared")
  duplicate=$(capture_candidate "$home" duplicate-b FrogPile review-rejection \
    "the same visual review gap appeared" "second incident with the same cause")
  set +e
  run_learning "$home" dedupe "$duplicate" --into "$canonical" \
    --curator duplicate-a --reason "same escaped contract and prevention" \
    >"$home/canonical-origin.out" 2>"$home/canonical-origin.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "canonical originating lane was accepted as the dedupe curator"
  run_learning "$home" dedupe "$duplicate" --into "$canonical" \
    --curator curator-dedupe --reason "same escaped contract and prevention" >/dev/null \
    || fail "dedupe failed"
  run_learning "$home" dedupe "$duplicate" --into "$canonical" \
    --curator curator-dedupe --reason "same escaped contract and prevention" >/dev/null \
    || fail "idempotent dedupe retry failed"
  json=$(run_learning "$home" get "$duplicate")
  printf '%s\n' "$json" | jq -e --arg canonical "$canonical" '
    .lifecycle_state == "duplicate" and .disposition.reference == $canonical
  ' >/dev/null || fail "duplicate disposition did not reference its canonical candidate"
  assert_absent "$(candidate_path "$home" "$duplicate")" \
    "deduplicated candidate retained a second unresolved record"
  assert_present "$(candidate_path "$home" "$duplicate" duplicate)" \
    "deduplicated candidate did not move to its single lifecycle record"
  json=$(run_learning "$home" get "$canonical")
  printf '%s\n' "$json" | jq -e --arg duplicate "$duplicate" '
    .lifecycle_state == "unresolved" and (.duplicates | index($duplicate) != null)
  ' >/dev/null || fail "canonical candidate did not stay unresolved with its duplicate link"

  [ "$(run_learning "$home" list --status dismissed | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "dismissed lifecycle state was not listable"
  [ "$(run_learning "$home" list | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "unresolved list included disposed or duplicate records"
  pass "candidates can be dismissed, documented, promoted, linked to follow-up, or deduplicated"
}

test_dedupe_interruption_and_terminal_retry() {
  local home canonical duplicate fakebin real_mv call_file failed_file rc json
  home=$(make_home dedupe-interruption)
  canonical=$(capture_candidate "$home" canonical-interrupted FrogPile review-rejection \
    "canonical incident for interrupted dedupe")
  duplicate=$(capture_candidate "$home" duplicate-interrupted FrogPile review-rejection \
    "duplicate incident for interrupted dedupe" "matching escaped behavior")
  fakebin=$(fm_fakebin "$home/mv-failure")
  real_mv=$(command -v mv)
  call_file="$home/mv-calls"
  failed_file="$home/mv-failed"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'count=0' \
    '[ ! -f "$FM_TEST_MV_CALLS" ] || count=$(cat "$FM_TEST_MV_CALLS")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" >"$FM_TEST_MV_CALLS"' \
    'if [ "$count" -eq 2 ] && [ ! -e "$FM_TEST_MV_FAILED" ]; then' \
    '  : >"$FM_TEST_MV_FAILED"' \
    '  exit 1' \
    'fi' \
    'exec "$FM_TEST_REAL_MV" "$@"' >"$fakebin/mv"
  chmod +x "$fakebin/mv"
  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_MV_CALLS="$call_file" \
    FM_TEST_MV_FAILED="$failed_file" run_learning "$home" dedupe "$duplicate" \
    --into "$canonical" --curator curator-interrupted --reason "same escaped behavior" \
    >"$home/interrupted.out" 2>"$home/interrupted.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dedupe fixture did not interrupt the canonical backlink publication"
  json=$(run_learning "$home" get "$duplicate")
  printf '%s\n' "$json" | jq -e --arg canonical "$canonical" '
    .lifecycle_state == "duplicate" and .disposition.reference == $canonical
  ' >/dev/null || fail "interrupted dedupe did not make the duplicate disposition authoritative first"
  json=$(run_learning "$home" get "$canonical")
  printf '%s\n' "$json" | jq -e --arg duplicate "$duplicate" \
    '.duplicates | index($duplicate) == null' >/dev/null \
    || fail "interrupted dedupe published the canonical backlink before duplicate authority"

  run_learning "$home" dedupe "$duplicate" --into "$canonical" \
    --curator curator-interrupted --reason "same escaped behavior" >/dev/null \
    || fail "exact dedupe retry did not complete the missing canonical backlink"
  json=$(run_learning "$home" get "$canonical")
  printf '%s\n' "$json" | jq -e --arg duplicate "$duplicate" '
    ([.duplicates[] | select(. == $duplicate)] | length) == 1
  ' >/dev/null || fail "dedupe retry did not add exactly one canonical backlink"
  classify_feature "$home" "$canonical" curator-interrupted >/dev/null
  run_learning "$home" disposition "$canonical" --curator curator-interrupted \
    --status documented --note "The canonical prevention is documented" \
    --reference "docs/canonical.md" >/dev/null
  run_learning "$home" dedupe "$duplicate" --into "$canonical" \
    --curator curator-interrupted --reason "same escaped behavior" >/dev/null \
    || fail "exact dedupe retry rejected a later-disposed canonical candidate"
  pass "dedupe interruption converges and exact retries survive canonical disposition"
}

test_concise_outputs_strip_terminal_controls() {
  local home id project impact list summary get batch
  home=$(make_home terminal-controls)
  project=$'Frog\e[2JPile\177'
  impact=$'visible impact\e[31m\tforged\u009b'
  id=$(capture_candidate "$home" terminal-control "$project" escaped-defect "$impact")
  list=$(run_learning "$home" list)
  summary=$(run_learning "$home" summary)
  assert_not_contains "$list" $'\e' "list preserved an escape control from candidate text"
  assert_not_contains "$list" $'\177' "list preserved a delete control from candidate text"
  assert_not_contains "$list" $'\u009b' "list preserved a C1 control from candidate text"
  assert_not_contains "$summary" $'\e' "summary preserved an escape control from candidate text"
  assert_not_contains "$summary" $'\177' "summary preserved a delete control from candidate text"
  assert_not_contains "$summary" $'\u009b' "summary preserved a C1 control from candidate text"
  get=$(run_learning "$home" get "$id")
  batch=$(run_learning "$home" batch)
  printf '%s\n' "$get" | jq -e --arg project "$project" --arg impact "$impact" \
    '.incident.project == $project and .incident.user_visible_impact == $impact' >/dev/null \
    || fail "get did not preserve complete terminal-control evidence"
  printf '%s\n' "$batch" | jq -e --arg project "$project" --arg impact "$impact" \
    '.[0].incident.project == $project and .[0].incident.user_visible_impact == $impact' >/dev/null \
    || fail "batch did not preserve complete terminal-control evidence"
  pass "concise views strip terminal controls while complete views preserve evidence"
}

test_bounded_summary_and_batch() {
  local home empty_home i summary lines batch rc
  empty_home=$(make_home empty-summary)
  [ -z "$(run_learning "$empty_home" summary)" ] || fail "empty summary was not silent"
  assert_absent "$empty_home/state/learning-candidates" \
    "routine read-side summary created candidate state for an empty home"
  home=$(make_home bounded)
  i=1
  while [ "$i" -le 9 ]; do
    capture_candidate "$home" "bounded-$i" FrogPile escaped-defect \
      "candidate impact $i with enough detail to remain recognizable" >/dev/null
    i=$((i + 1))
  done
  summary=$(run_learning "$home" summary) || fail "summary failed"
  lines=$(printf '%s\n' "$summary" | wc -l | tr -d ' ')
  [ "$lines" -eq 5 ] || fail "default summary emitted $lines lines instead of five"
  assert_contains "$summary" "LEARNING CANDIDATES: 9 unresolved" "summary omitted exact unresolved count"
  assert_contains "$summary" "... 6 more" "summary omitted bounded remainder"
  assert_not_contains "$summary" "candidate impact 4" "summary exceeded its default detail bound"
  batch=$(run_learning "$home" batch --limit 2) || fail "bounded batch failed"
  [ "$(printf '%s\n' "$batch" | jq 'length')" -eq 2 ] || fail "batch ignored its record limit"

  set +e
  run_learning "$home" summary --limit 6 >"$home/large-summary.out" 2>"$home/large-summary.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "summary accepted an output limit above its hard cap"
  pass "summary and batch output remain bounded as the unresolved inbox grows"
}

test_summary_producer_failure_propagates() {
  local home fakebin real_find rc
  home=$(make_home summary-producer-failure)
  capture_candidate "$home" summary-producer FrogPile escaped-defect \
    "summary enumeration failures must be visible" >/dev/null
  fakebin=$(fm_fakebin "$home/failed-find")
  real_find=$(command -v find)
  cat >"$fakebin/find" <<'SH'
#!/usr/bin/env bash
if [ "$PWD" = "$FM_TEST_CANDIDATE_DIR" ]; then
  printf 'candidate enumeration failed\n' >&2
  exit 9
fi
exec "$FM_TEST_REAL_FIND" "$@"
SH
  chmod +x "$fakebin/find"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_CANDIDATE_DIR="$home/state/learning-candidates" \
    FM_TEST_REAL_FIND="$real_find" run_learning "$home" summary \
    >"$home/summary.out" 2>"$home/summary.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "summary accepted a failed enumeration producer"
  assert_grep "could not enumerate candidate store" "$home/summary.err" \
    "summary did not report its failed enumeration"
  [ ! -s "$home/summary.out" ] || fail "summary rendered output after enumeration failed"
  pass "summary propagates enumeration failures before rendering"
}

test_summary_rejects_unsafe_entries() {
  local home extra_home dangling_home id valid rc
  home=$(make_home unsafe-summary-entry)
  id=lc-000000000000000000000000
  mkdir -p "$home/state/learning-candidates"
  ln -s "$home/state" "$(candidate_path "$home" "$id")"

  set +e
  run_learning "$home" summary >"$home/unsafe.out" 2>"$home/unsafe.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "summary silently skipped an unsafe candidate entry"
  assert_grep "candidate path must be a regular file" "$home/unsafe.err" \
    "summary did not route an unsafe entry through record-path validation"
  [ ! -s "$home/unsafe.out" ] || fail "summary rendered output after finding an unsafe entry"

  extra_home=$(make_home extra-summary-entry)
  valid=$(capture_candidate "$extra_home" extra-summary FrogPile escaped-defect \
    "summary must validate the exact enumerated basename")
  ln -s "$(candidate_path "$extra_home" "$valid")" \
    "$(candidate_path "$extra_home" "$valid" backup)"
  set +e
  run_learning "$extra_home" summary >"$extra_home/extra.out" 2>"$extra_home/extra.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "summary reloaded a valid record for an invalid extra entry"
  assert_grep "invalid lifecycle state: backup" "$extra_home/extra.err" \
    "summary did not validate the exact enumerated lifecycle suffix"

  dangling_home=$(make_home dangling-record-entry)
  valid=$(capture_candidate "$dangling_home" dangling-record FrogPile escaped-defect \
    "record discovery must reject dangling symlink siblings")
  ln -s "$dangling_home/missing-record" "$(candidate_path "$dangling_home" "$valid" documented)"
  set +e
  run_learning "$dangling_home" get "$valid" \
    >"$dangling_home/dangling.out" 2>"$dangling_home/dangling.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "record discovery skipped a dangling symlink sibling"
  assert_grep "candidate path must be a regular file" "$dangling_home/dangling.err" \
    "record discovery did not reject the dangling symlink sibling"
  pass "summary and record discovery reject unsafe exact entries"
}

test_canonical_path_boundary_forms() {
  local seed dangling_home escape_home nonregular_home store_target store_home file_store_home
  local mutation_home id outside rc
  seed=$(make_home capture-sibling-seed)
  id=$(capture_candidate "$seed" capture-sibling FrogPile escaped-defect \
    "capture must reject every unsafe deterministic sibling")
  dangling_home=$(make_home capture-dangling-sibling)
  mkdir -p "$dangling_home/state/learning-candidates"
  ln -s "$dangling_home/missing-record" "$(candidate_path "$dangling_home" "$id" documented)"
  set +e
  capture_candidate "$dangling_home" capture-sibling FrogPile escaped-defect \
    "capture must reject every unsafe deterministic sibling" \
    >"$dangling_home/capture.out" 2>"$dangling_home/capture.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "capture accepted a dangling deterministic sibling"
  assert_grep "candidate path must be a regular file" "$dangling_home/capture.err" \
    "capture did not route its deterministic sibling through path validation"
  assert_absent "$(candidate_path "$dangling_home" "$id")" \
    "capture published a record beside a dangling deterministic sibling"

  escape_home=$(make_home record-symlink-escape)
  mkdir -p "$escape_home/state/learning-candidates"
  outside="$escape_home/outside-record.json"
  printf '{}\n' >"$outside"
  id=lc-000000000000000000000001
  ln -s "$outside" "$(candidate_path "$escape_home" "$id")"
  set +e
  run_learning "$escape_home" summary >"$escape_home/summary.out" 2>"$escape_home/summary.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "summary followed a candidate symlink outside the store"
  assert_grep "candidate path must be a regular file" "$escape_home/summary.err" \
    "summary did not reject the store-escaping candidate symlink"

  nonregular_home=$(make_home nonregular-record-entry)
  id=lc-000000000000000000000002
  mkdir -p "$(candidate_path "$nonregular_home" "$id")"
  set +e
  run_learning "$nonregular_home" summary \
    >"$nonregular_home/summary.out" 2>"$nonregular_home/summary.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "summary accepted a non-regular candidate entry"
  assert_grep "candidate path must be a regular file" "$nonregular_home/summary.err" \
    "summary did not reject a non-regular candidate entry"

  store_target=$(make_home candidate-store-target)
  mkdir -p "$store_target/external-candidates"
  store_home=$(make_home candidate-store-symlink)
  ln -s "$store_target/external-candidates" "$store_home/state/learning-candidates"
  set +e
  run_learning "$store_home" list --all >"$store_home/list.out" 2>"$store_home/list.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "list followed a candidate-store directory symlink"
  assert_grep "candidate store must be a real directory" "$store_home/list.err" \
    "list did not reject a candidate-store directory symlink"
  set +e
  capture_candidate "$store_home" store-symlink FrogPile escaped-defect \
    "capture must reject a symlinked candidate store" \
    >"$store_home/capture.out" 2>"$store_home/capture.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "capture followed a candidate-store directory symlink"
  assert_grep "candidate store must be a real directory" "$store_home/capture.err" \
    "capture did not reject a candidate-store directory symlink"

  file_store_home=$(make_home nonregular-candidate-store)
  printf 'not a directory\n' >"$file_store_home/state/learning-candidates"
  set +e
  run_learning "$file_store_home" batch \
    >"$file_store_home/batch.out" 2>"$file_store_home/batch.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "batch accepted a non-directory candidate store"
  assert_grep "candidate store must be a real directory" "$file_store_home/batch.err" \
    "batch did not reject a non-directory candidate store"

  mutation_home=$(make_home lifecycle-destination-symlink)
  id=$(capture_candidate "$mutation_home" lifecycle-destination FrogPile escaped-defect \
    "lifecycle mutation must reject unsafe destination paths")
  classify_feature "$mutation_home" "$id" curator-path >/dev/null
  outside="$mutation_home/outside-destination.json"
  printf '{}\n' >"$outside"
  ln -s "$outside" "$(candidate_path "$mutation_home" "$id" documented)"
  set +e
  run_learning "$mutation_home" disposition "$id" --curator curator-path \
    --status documented --note "The path boundary is documented" \
    --reference "docs/path-boundary.md" \
    >"$mutation_home/disposition.out" 2>"$mutation_home/disposition.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "lifecycle mutation accepted a symlink destination"
  assert_grep "candidate path must be a regular file" "$mutation_home/disposition.err" \
    "lifecycle mutation did not validate its destination path"
  [ "$(jq -r '.lifecycle_state' "$(candidate_path "$mutation_home" "$id")")" = unresolved ] \
    || fail "failed lifecycle path validation changed authoritative record content"
  pass "canonical path boundary rejects unsafe state, store, record, capture, and mutation forms"
}

test_read_commands_reject_dangling_store() {
  local home command rc
  home=$(make_home dangling-candidate-store)
  ln -s "$home/missing-store" "$home/state/learning-candidates"
  for command in list batch summary; do
    set +e
    run_learning "$home" "$command" >"$home/$command.out" 2>"$home/$command.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$command treated a dangling candidate store as absent"
    assert_grep "candidate store must be a real directory" "$home/$command.err" \
      "$command did not identify the dangling candidate store"
  done
  pass "public read commands reject a dangling candidate store"
}

test_capture_does_not_wait_for_curation() {
  local home lock ready release holder capture_pid attempt rc count
  home=$(make_home bounded-capture)
  lock="$home/state/.learning-candidates.lock"
  ready="$home/lock-ready"
  release="$home/lock-release"
  (
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
      . "$1"
      fm_lock_acquire_wait "$2"
      : > "$3"
      while [ ! -e "$4" ]; do sleep 0.02; done
      fm_lock_release "$2"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$ready" "$release"
  ) &
  holder=$!
  attempt=0
  while [ ! -e "$ready" ] && kill -0 "$holder" 2>/dev/null && [ "$attempt" -lt 100 ]; do
    sleep 0.02
    attempt=$((attempt + 1))
  done
  [ -e "$ready" ] || fail "capture-lock fixture did not acquire the curator lock"

  (
    set +e
    capture_candidate "$home" contended-capture FrogPile review-rejection \
      "contended bounded capture" >"$home/contended.out" 2>"$home/contended.err"
    printf '%s\n' "$?" >"$home/contended.rc"
  ) &
  capture_pid=$!
  attempt=0
  while kill -0 "$capture_pid" 2>/dev/null && [ "$attempt" -lt 50 ]; do
    sleep 0.02
    attempt=$((attempt + 1))
  done
  if kill -0 "$capture_pid" 2>/dev/null; then
    : >"$release"
    wait "$holder"
    wait "$capture_pid" || true
    fail "origin capture waited for curator-held state"
  fi
  wait "$capture_pid" || true
  rc=$(cat "$home/contended.rc")
  : >"$release"
  wait "$holder"
  [ "$rc" -ne 0 ] || fail "contended capture succeeded instead of reporting temporary unavailability"
  assert_grep "capture is temporarily unavailable" "$home/contended.err" \
    "contended capture refusal was not explicit"
  count=$(find "$home/state/learning-candidates" -type f -name 'lc-*.json' | wc -l | tr -d ' ')
  [ "$count" -eq 0 ] || fail "contended capture mutated candidate records"
  pass "origin capture remains bounded while asynchronous curation owns the mutation lock"
}

test_candidate_survives_nonblocking_task_cleanup() {
  local home fakebin id candidate rc
  command -v tasks-axi >/dev/null 2>&1 || { pass "task cleanup survival skipped because tasks-axi is unavailable"; return; }
  home=$(make_home cleanup)
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat >"$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  id=cleanup-source
  (cd "$home" && tasks-axi add "$id" "Capture cleanup learning" --kind scout --repo FrogPile --start >/dev/null) \
    || fail "could not create cleanup backlog fixture"
  mkdir -p "$home/data/$id"
  printf '%s\n' "completed scout report" >"$home/data/$id/report.md"
  printf '%s\n' "done: report complete" >"$home/state/$id.status"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/FrogPile" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-decision-hold.sh" complete "$id" --none >/dev/null \
    || fail "could not attest the cleanup fixture's decision inventory"
  candidate=$(capture_candidate "$home" "$id" FrogPile review-rejection \
    "the finished review exposed a reusable gap") || fail "cleanup candidate capture failed"

  set +e
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-teardown.sh" "$id" \
    >"$home/teardown.out" 2>"$home/teardown.err"
  rc=$?
  set -e
  expect_code 0 "$rc" "ordinary task cleanup must not wait for learning classification: $(cat "$home/teardown.err")"
  assert_absent "$home/state/$id.meta" "task cleanup did not remove task-scoped metadata"
  assert_present "$(candidate_path "$home" "$candidate")" \
    "task cleanup removed the durable learning candidate"
  [ "$(run_learning "$home" get "$candidate" | jq -r '.lifecycle_state')" = unresolved ] \
    || fail "task cleanup changed the unresolved candidate"
  pass "ordinary task cleanup neither waits for classification nor removes the captured candidate"
}

test_help_avoids_private_state_access
test_capture_validation_and_complete_record
test_large_escaped_capture_avoids_argv_limits
test_repeat_capture_is_idempotent
test_read_commands_reject_symlinked_state
test_atomic_lifecycle_publication_and_content_authority
test_concurrent_suffix_rename_reresolves
test_cutover_accepts_concurrent_read_correction
test_list_resolves_ids_after_suffix_rename
test_routes_and_no_one_off_skill_gate
test_lifecycle_dispositions_and_deduplication
test_dedupe_interruption_and_terminal_retry
test_concise_outputs_strip_terminal_controls
test_bounded_summary_and_batch
test_summary_producer_failure_propagates
test_summary_rejects_unsafe_entries
test_canonical_path_boundary_forms
test_read_commands_reject_dangling_store
test_capture_does_not_wait_for_curation
test_candidate_survives_nonblocking_task_cleanup

echo "# fm-learning-candidate.test.sh: all assertions passed"
