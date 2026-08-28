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

test_capture_validation_and_complete_record() {
  local home id json rc path
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

  path="$home/state/learning-candidates/$id.json"
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

test_repeat_capture_is_idempotent() {
  local home first second count
  home=$(make_home repeat)
  first=$(capture_candidate "$home" repeated-review FrogPile review-rejection \
    "review rejected the completed HUD") || fail "first capture failed"
  second=$(capture_candidate "$home" repeated-review FrogPile review-rejection \
    "review rejected the completed HUD") || fail "repeat capture failed"
  [ "$first" = "$second" ] || fail "exact repeat capture produced a different identity"
  count=$(find "$home/state/learning-candidates" -type f -name 'lc-*.json' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "exact repeat capture created $count records"
  pass "exact repeat capture converges on one durable candidate"
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
  [ "$rc" -ne 0 ] || fail "canonical originating task was accepted as dedupe curator"
  assert_grep "curator must differ from the originating task" "$home/canonical-origin.err" \
    "canonical-origin dedupe refusal was not explicit"
  json=$(run_learning "$home" get "$duplicate")
  printf '%s\n' "$json" | jq -e '
    .lifecycle_state == "unresolved" and .disposition == null
  ' >/dev/null || fail "rejected dedupe mutated the duplicate candidate: $json"
  json=$(run_learning "$home" get "$canonical")
  printf '%s\n' "$json" | jq -e '
    .lifecycle_state == "unresolved" and .duplicates == []
  ' >/dev/null || fail "rejected dedupe mutated the canonical candidate: $json"

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

test_dedupe_recovers_interrupted_backlink() {
  local home fakebin real_mv canonical duplicate alternative rc json
  home=$(make_home interrupted-dedupe)
  canonical=$(capture_candidate "$home" interrupted-canonical FrogPile review-rejection \
    "the canonical visual review gap")
  duplicate=$(capture_candidate "$home" interrupted-duplicate FrogPile review-rejection \
    "the repeated visual review gap")
  alternative=$(capture_candidate "$home" alternative-canonical FrogPile review-rejection \
    "an unrelated canonical candidate")
  fakebin=$(fm_fakebin "$home")
  real_mv=$(command -v mv) || fail "could not locate mv for interrupted dedupe fixture"
  cat >"$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_TEST_FAIL_PATH" ]; then
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" \
    FM_TEST_FAIL_PATH="$home/state/learning-candidates/$canonical.json" \
    run_learning "$home" dedupe "$duplicate" --into "$canonical" \
      --curator curator-interrupted --reason "same durable prevention" \
      >"$home/interrupted.out" 2>"$home/interrupted.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "dedupe succeeded after its second record commit failed"
  rm -f "$fakebin/mv"

  json=$(run_learning "$home" get "$duplicate")
  printf '%s\n' "$json" | jq -e --arg canonical "$canonical" '
    .lifecycle_state == "duplicate" and .disposition.reference == $canonical
  ' >/dev/null || fail "interrupted dedupe did not persist its authoritative duplicate state: $json"
  json=$(run_learning "$home" get "$canonical")
  printf '%s\n' "$json" | jq -e --arg duplicate "$duplicate" '
    (.duplicates | index($duplicate)) == null
  ' >/dev/null || fail "interrupted dedupe persisted its derived canonical backlink: $json"

  run_learning "$home" dedupe "$duplicate" --into "$canonical" \
    --curator curator-interrupted --reason "same durable prevention" >/dev/null \
    || fail "exact dedupe retry did not reconcile the missing canonical backlink"
  json=$(run_learning "$home" get "$canonical")
  printf '%s\n' "$json" | jq -e --arg duplicate "$duplicate" '
    ([.duplicates[] | select(. == $duplicate)] | length) == 1
    and ([.history[] | select(.event == "dedupe-canonical")] | length) == 1
  ' >/dev/null || fail "exact dedupe retry did not reconcile one canonical backlink: $json"

  set +e
  run_learning "$home" dedupe "$duplicate" --into "$alternative" \
    --curator curator-interrupted --reason "same durable prevention" \
    >"$home/conflicting.out" 2>"$home/conflicting.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "authoritative duplicate state allowed a conflicting canonical"
  assert_grep "candidate already has a different disposition" "$home/conflicting.err" \
    "conflicting dedupe refusal did not identify the authoritative disposition"
  json=$(run_learning "$home" get "$alternative")
  printf '%s\n' "$json" | jq -e '.duplicates == []' >/dev/null \
    || fail "conflicting dedupe mutated the alternative canonical: $json"
  json=$(run_learning "$home" get "$duplicate")
  printf '%s\n' "$json" | jq -e --arg canonical "$canonical" '
    .lifecycle_state == "duplicate" and .disposition.reference == $canonical
  ' >/dev/null || fail "conflicting dedupe changed the authoritative duplicate state: $json"
  pass "dedupe interruption preserves one authority and exact retry repairs its backlink"
}

test_summary_index_recovers_interrupted_update() {
  local home fakebin real_cat real_mv summary rc
  home=$(make_home interrupted-summary)
  capture_candidate "$home" summary-base FrogPile escaped-defect \
    "base summary candidate" >/dev/null
  fakebin=$(fm_fakebin "$home")
  real_mv=$(command -v mv) || fail "could not locate mv for interrupted summary fixture"
  cat >"$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_TEST_FAIL_PATH" ]; then
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" \
    FM_TEST_FAIL_PATH="$home/state/learning-candidates/.summary.json" \
    capture_candidate "$home" summary-interrupted FrogPile review-rejection \
      "candidate committed before its summary index" \
      >"$home/interrupted-summary.out" 2>"$home/interrupted-summary.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "capture succeeded after its summary index commit failed"
  rm -f "$fakebin/mv"

  jq -cS '.after' "$home/state/learning-candidates/.summary-pending.json" \
    >"$home/after-summary-index.json"
  real_cat=$(command -v cat) || fail "could not locate cat for summary race fixture"
  cat >"$fakebin/cat" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "$FM_TEST_PENDING_PATH" ]; then
  "$FM_TEST_REAL_MV" "$FM_TEST_AFTER_INDEX" "$FM_TEST_INDEX_PATH"
  rm -f -- "$FM_TEST_PENDING_PATH"
  exit 1
fi
exec "$FM_TEST_REAL_CAT" "$@"
SH
  chmod +x "$fakebin/cat"
  summary=$(PATH="$fakebin:$PATH" FM_TEST_REAL_CAT="$real_cat" \
    FM_TEST_REAL_MV="$real_mv" \
    FM_TEST_PENDING_PATH="$home/state/learning-candidates/.summary-pending.json" \
    FM_TEST_INDEX_PATH="$home/state/learning-candidates/.summary.json" \
    FM_TEST_AFTER_INDEX="$home/after-summary-index.json" \
    run_learning "$home" summary) \
    || fail "summary could not retry a concurrently completed transaction"
  rm -f "$fakebin/cat"
  assert_contains "$summary" "LEARNING CANDIDATES: 2 unresolved" \
    "summary lost a transaction completed during its pending-file read"
  capture_candidate "$home" summary-recovery FrogPile workflow-gap-blocker \
    "later mutation recovers the pending summary transaction" >/dev/null \
    || fail "later mutation did not recover the pending summary transaction"
  summary=$(run_learning "$home" summary) || fail "summary failed after transaction recovery"
  assert_contains "$summary" "LEARNING CANDIDATES: 3 unresolved" \
    "recovered summary index lost a committed candidate"
  pass "summary index remains exact across an interrupted index commit"
}

test_summary_read_work_is_store_independent() {
  local home fakebin real_cat id summary rc i details
  home=$(make_home summary-scale)
  i=1
  while [ "$i" -le 24 ]; do
    id=$(capture_candidate "$home" "scale-$i" FrogPile escaped-defect \
      "scale candidate impact $i") || fail "could not capture scale candidate $i"
    if [ "$i" -le 19 ]; then
      run_learning "$home" disposition "$id" --curator scale-curator \
        --status dismissed --note "resolved scale candidate $i" >/dev/null \
        || fail "could not resolve scale candidate $i"
    fi
    i=$((i + 1))
  done

  fakebin=$(fm_fakebin "$home")
  real_cat=$(command -v cat) || fail "could not locate cat for bounded summary fixture"
  cat >"$fakebin/cat" <<'SH'
#!/usr/bin/env bash
last=${!#}
case "$last" in
  "$FM_TEST_CANDIDATE_DIR"/lc-*.json)
    printf 'candidate record read\n' >"$FM_TEST_CAT_MARKER"
    exit 97
    ;;
esac
exec "$FM_TEST_REAL_CAT" "$@"
SH
  chmod +x "$fakebin/cat"

  set +e
  summary=$(PATH="$fakebin:$PATH" FM_TEST_REAL_CAT="$real_cat" \
    FM_TEST_CANDIDATE_DIR="$home/state/learning-candidates" \
    FM_TEST_CAT_MARKER="$home/candidate-read" \
    run_learning "$home" summary 2>"$home/scale-summary.err")
  rc=$?
  set -e
  expect_code 0 "$rc" "bounded summary failed with many resolved records: $(cat "$home/scale-summary.err")"
  assert_contains "$summary" "LEARNING CANDIDATES: 5 unresolved" \
    "bounded summary index lost the exact unresolved count"
  details=$(printf '%s\n' "$summary" | grep -c '^- lc-')
  [ "$details" -eq 3 ] || fail "bounded summary emitted $details details instead of three"
  assert_absent "$home/candidate-read" \
    "summary read a full candidate record instead of its fixed-size index"
  pass "summary read work stays fixed as resolved candidate history grows"
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

test_summary_strips_terminal_controls() {
  local home impact id summary stored batched control
  home=$(make_home summary-controls)
  impact=$'impact\001\007\033[2J\037\177\302\205\302\233\302\237visible'
  id=$(capture_candidate "$home" summary-controls FrogPile review-rejection "$impact") \
    || fail "could not capture a candidate containing control characters"

  summary=$(run_learning "$home" summary) || fail "summary failed for control-character evidence"
  assert_contains "$summary" "impact[2Jvisible" \
    "summary did not retain the printable incident text"
  for control in $'\001' $'\007' $'\033' $'\037' $'\177' $'\302\205' $'\302\233' $'\302\237'; do
    assert_not_contains "$summary" "$control" \
      "summary emitted a captured terminal control character"
  done

  stored=$(run_learning "$home" get "$id" | jq -r '.incident.user_visible_impact')
  [ "$stored" = "$impact" ] || fail "get did not preserve complete control-character evidence"
  batched=$(run_learning "$home" batch --limit 1 | jq -r '.[0].incident.user_visible_impact')
  [ "$batched" = "$impact" ] || fail "batch did not preserve complete control-character evidence"
  pass "summary strips terminal controls while get and batch preserve evidence"
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
  assert_present "$home/state/learning-candidates/$candidate.json" \
    "task cleanup removed the durable learning candidate"
  [ "$(run_learning "$home" get "$candidate" | jq -r '.lifecycle_state')" = unresolved ] \
    || fail "task cleanup changed the unresolved candidate"
  pass "ordinary task cleanup neither waits for classification nor removes the captured candidate"
}

test_capture_validation_and_complete_record
test_repeat_capture_is_idempotent
test_routes_and_no_one_off_skill_gate
test_lifecycle_dispositions_and_deduplication
test_dedupe_recovers_interrupted_backlink
test_summary_index_recovers_interrupted_update
test_summary_read_work_is_store_independent
test_bounded_summary_and_batch
test_summary_strips_terminal_controls
test_candidate_survives_nonblocking_task_cleanup

echo "# fm-learning-candidate.test.sh: all assertions passed"
