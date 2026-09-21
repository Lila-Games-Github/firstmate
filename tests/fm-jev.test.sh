#!/usr/bin/env bash
# Behavior tests for the bounded Jev client, four adapters, and metrics report.
#
# Every enabled adapter talks only to tests/jev-http-server.py on 127.0.0.1.
# Off, missing-key, and cap paths prove no request reaches even that local
# server. Request assertions inspect what the executable public adapters sent,
# not their implementation source.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

JEV="$ROOT/bin/fm-jev.sh"
ACCEPT="$ROOT/bin/fm-jev-accept-check.sh"
TRIAGE="$ROOT/bin/fm-jev-triage.sh"
COMMIT_LINT="$ROOT/bin/fm-jev-commit-lint.sh"
OPEN_QUESTIONS="$ROOT/bin/fm-jev-open-questions.sh"
REPORT="$ROOT/bin/fm-jev-report.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
LAVISH="$ROOT/bin/fm-procevent-lavish.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev)
PORT_FILE="$TMP_ROOT/server.port"
REQUEST_LOG="$TMP_ROOT/requests.jsonl"
: > "$REQUEST_LOG"
python3 "$ROOT/tests/jev-http-server.py" "$PORT_FILE" "$REQUEST_LOG" &
SERVER_PID=$!
cleanup_suite() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_suite EXIT INT TERM
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$PORT_FILE" ] || fail "local Jev fixture server did not start"
ENDPOINT="http://127.0.0.1:$(cat "$PORT_FILE")/v1/systemone"

request_count() { awk 'END { print NR + 0 }' "$REQUEST_LOG"; }

write_config() { # <home> <accept> <triage> <commit> <open> [call-cap] [token-cap] [spend-cap] [triage-call-cap]
  local home=$1 accept=$2 triage=$3 commit=$4 open=$5 calls=${6:-100} tokens=${7:-32000} spend=${8:-1}
  local triage_calls=${9:-} triage_budget=''
  mkdir -p "$home/config" "$home/state" "$home/data"
  [ -z "$triage_calls" ] || triage_budget=", \"daily\": {\"call_cap\": $triage_calls, \"spend_usd_cap\": $spend}"
  cat > "$home/config/jev.json" <<JSON
{
  "version": 1,
  "kill_switch": false,
  "per_call_token_cap": $tokens,
  "daily": {"call_cap": $calls, "spend_usd_cap": $spend},
  "uses": {
    "accept-check": {"mode": "$accept", "confidence_floor": 0.8, "daily": {"call_cap": $calls, "spend_usd_cap": $spend}},
    "triage": {"mode": "$triage", "confidence_floor": 0.65$triage_budget},
    "commit-lint": {"mode": "$commit", "confidence_floor": 0.8, "daily": {"call_cap": $calls, "spend_usd_cap": $spend}},
    "open-questions": {"mode": "$open", "confidence_floor": 0.65, "daily": {"call_cap": $calls, "spend_usd_cap": $spend}}
  }
}
JSON
}

write_key() { printf 'TYPESAFE_API_KEY=test-only-key\n' > "$1/.env"; }

jev_env() { # <home> <command...>
  local home=$1
  shift
  FM_HOME="$home" FM_JEV_TESTING=1 FM_JEV_TEST_ENDPOINT="$ENDPOINT" "$@"
}

make_accept_fixture() { # <home>
  mkdir -p "$1/data/task-a"
  cat > "$1/data/task-a/brief.md" <<'MD'
# Task

## Acceptance criteria

- The report names the changed file.
- The report includes a passing test command.
MD
  cat > "$1/data/task-a/report.md" <<'MD'
Changed bin/example.sh and ran tests/example.test.sh successfully.
MD
}

make_git_fixture() { # <path>
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  fm_git_identity
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm 'base'
  git -C "$repo" checkout -qb fm/task-c
  printf 'change\n' >> "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm 'Update file'
}

make_questions_fixture() { # <home>
  mkdir -p "$1/pages"
  cat > "$1/questions.md" <<'MD'
# Open questions

- Which launch date applies? [page: launch.md]
MD
  cat > "$1/pages/launch.md" <<'MD'
The approved launch date is 2026-10-04.
MD
}

test_off_is_noop_for_every_adapter() {
  local home="$TMP_ROOT/off" repo="$TMP_ROOT/off-repo" before out err
  write_config "$home" off off off off
  write_key "$home"
  make_accept_fixture "$home"
  make_git_fixture "$repo"
  make_questions_fixture "$home"
  before=$(request_count)
  out=$(jev_env "$home" "$ACCEPT" task-a 2>"$TMP_ROOT/off.err")
  err=$(cat "$TMP_ROOT/off.err")
  [ -z "$out" ] || fail "off acceptance adapter printed on stdout: $out"
  assert_contains "$err" "accept-check: off" "off acceptance adapter did not name its off reason"
  [ ! -e "$home/data/task-a/acceptance.json" ] || fail "off acceptance adapter wrote a result"
  out=$(printf 'done: routine\n' | jev_env "$home" "$TRIAGE" --kind status 2>&1)
  [ -z "$out" ] || fail "off triage hook printed output: $out"
  out=$(jev_env "$home" "$COMMIT_LINT" "$repo" 2>"$TMP_ROOT/off.err")
  err=$(cat "$TMP_ROOT/off.err")
  [ -z "$out" ] || fail "off commit adapter printed on stdout: $out"
  assert_contains "$err" "commit-lint: off" "off commit adapter did not name its off reason"
  out=$(jev_env "$home" "$OPEN_QUESTIONS" "$home/questions.md" "$home/pages" 2>"$TMP_ROOT/off.err")
  err=$(cat "$TMP_ROOT/off.err")
  [ -z "$out" ] || fail "off open-question adapter printed on stdout: $out"
  assert_contains "$err" "open-questions: off" "off open-question adapter did not name its off reason"
  [ ! -e "$home/questions-jev-review.md" ] || fail "off open-question adapter wrote a proposal"
  [ "$(request_count)" -eq "$before" ] || fail "off mode reached the local HTTP server"
  pass "Jev adapters: off mode makes no call and no change, and every invoked adapter says why"
}

test_missing_key_diagnostic_names_the_key() {
  local home="$TMP_ROOT/keyless" before out err
  write_config "$home" active off off off
  make_accept_fixture "$home"
  before=$(request_count)
  out=$(jev_env "$home" "$ACCEPT" task-a 2>"$TMP_ROOT/keyless.err")
  err=$(cat "$TMP_ROOT/keyless.err")
  [ -z "$out" ] || fail "keyless acceptance adapter printed on stdout: $out"
  assert_contains "$err" "TYPESAFE_API_KEY absent" "keyless adapter did not name the missing key"
  [ ! -e "$home/data/task-a/acceptance.json" ] || fail "keyless acceptance adapter wrote a result"
  [ "$(request_count)" -eq "$before" ] || fail "keyless path reached the local HTTP server"
  pass "Jev adapters: an enabled use with no key names the absent key instead of failing silently"
}

test_absent_config_defaults_active() {
  local home="$TMP_ROOT/default-active" before out
  mkdir -p "$home/config" "$home/state" "$home/data"
  write_key "$home"
  before=$(request_count)
  out=$(printf 'done: ready\n' | jev_env "$home" "$TRIAGE" --kind status)
  [ "$out" = "actionable" ] || fail "default-active triage returned '$out', expected actionable"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "absent config did not make exactly one active request"
  jq -e '.mode == "active" and .configured_mode == "active" and .used_jev == true and
    .baseline_decision == {"item_1__attention":"actionable"} and (.baseline_rationale | length) > 0 and
    (.jev_rationale | length) > 0 and (.jev_probabilities.item_1__attention.actionable == 0.9) and
    .response_model == "jev-1.13.0" and .truncated == false and
    .agreement == true' "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "default-active ledger row lacks the required side-by-side evidence"
  pass "Jev client: absent config uses active defaults and records both decisions with rationale and probabilities"
}

test_unavailable_key_and_caps_fall_back() {
  local missing="$TMP_ROOT/missing" capped="$TMP_ROOT/capped" killed="$TMP_ROOT/killed" before out
  write_config "$missing" off shadow off off
  before=$(request_count)
  out=$(printf 'blocked: waiting\n' | jev_env "$missing" "$TRIAGE" --kind status 2>&1)
  [ -z "$out" ] || fail "missing-key triage changed caller output: $out"
  [ "$(request_count)" -eq "$before" ] || fail "missing-key path reached HTTP"
  [ ! -e "$missing/state/jev-ledger.jsonl" ] || fail "missing-key path wrote a consultation row"

  write_config "$capped" off shadow off off 0
  write_key "$capped"
  out=$(printf 'failed: build\n' | jev_env "$capped" "$TRIAGE" --kind wake 2>&1)
  [ -z "$out" ] || fail "cap-reached triage changed caller output: $out"
  [ "$(request_count)" -eq "$before" ] || fail "cap-reached path reached HTTP"
  [ ! -e "$capped/state/jev-ledger.jsonl" ] || fail "cap-reached path wrote a consultation row"

  write_config "$killed" off shadow off off
  write_key "$killed"
  if ! jq '.kill_switch = true' "$killed/config/jev.json" > "$killed/config/jev.json.tmp" \
    || ! mv "$killed/config/jev.json.tmp" "$killed/config/jev.json"; then
    fail "could not enable the fixture kill switch"
  fi
  out=$(printf 'done: ready\n' | jev_env "$killed" "$TRIAGE" --kind status 2>&1)
  [ -z "$out" ] || fail "kill-switch triage changed caller output: $out"
  [ "$(request_count)" -eq "$before" ] || fail "kill-switch path reached HTTP"
  [ ! -e "$killed/state/jev-ledger.jsonl" ] || fail "kill-switch path wrote a consultation row"
  pass "Jev client: absent keys, exhausted caps, and the kill switch degrade without network or behavior changes"
}

test_per_use_budget_protects_other_uses() {
  local home="$TMP_ROOT/budget" before out
  # Two calls a day in total, one of them reserved for triage: an over-eager
  # triage path must not be able to consume the acceptance check's share.
  write_config "$home" shadow shadow off off 2 32000 1 1
  write_key "$home"
  make_accept_fixture "$home"
  before=$(request_count)
  out=$(printf 'done: one\n' | jev_env "$home" "$TRIAGE" --kind status)
  [ "$out" = actionable ] || fail "first triage call did not consult Jev: '$out'"
  out=$(printf 'done: two\n' | jev_env "$home" "$TRIAGE" --kind status)
  [ -z "$out" ] || fail "triage exceeded its own daily call budget: '$out'"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "the over-budget triage call still reached HTTP"
  jev_env "$home" "$ACCEPT" task-a
  [ -e "$home/data/task-a/acceptance.json" ] \
    || fail "acceptance check was starved of budget by triage"
  [ "$(request_count)" -eq $((before + 2)) ] || fail "acceptance check did not make its own request"
  pass "Jev budgets: each use owns its daily share, so a busy use cannot starve another"
}

test_accept_request_and_artifact() {
  local home="$TMP_ROOT/accept" before request out
  write_config "$home" shadow off off off
  write_key "$home"
  make_accept_fixture "$home"
  before=$(request_count)
  jev_env "$home" "$ACCEPT" task-a
  [ "$(request_count)" -eq $((before + 1)) ] || fail "acceptance adapter did not make exactly one request"
  request=$(tail -1 "$REQUEST_LOG")
  jq -e '.model == "jev-1.13.0" and (.questions | length) == 2 and all(.questions[]; .type == "noul")' \
    <<<"$request" >/dev/null || fail "acceptance request is not one pinned-model Noul batch"
  jq -e '(.criteria | length) == 2 and .verdict == "accepted"' "$home/data/task-a/acceptance.json" >/dev/null \
    || fail "acceptance artifact does not carry both criterion verdicts"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "acceptance ledger row failed schema validation"
  out=$(jev_env "$home" "$JEV" finalize --use accept-check --subject task-a --decision-json '"accepted"') \
    || fail "acceptance final decision could not be recorded"
  [ "$(jq -r '.updated' <<<"$out")" -eq 1 ] || fail "acceptance finalization did not update its pending row"
  jq -e '.final_decision == "accepted" and .eventual_outcome == "accepted"' "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "acceptance ledger did not retain its later final decision"
  pass "Jev acceptance adapter: one reviewed request writes an artifact and accepts a later final label"
}

test_triage_request_builder() {
  local home="$TMP_ROOT/triage" before out request
  write_config "$home" off shadow off off
  write_key "$home"
  before=$(request_count)
  out=$(printf 'task-a\tapprove\tApproved\n' | jev_env "$home" "$TRIAGE" --kind review-answer)
  [ "$out" = "actionable ruling" ] || fail "triage returned '$out', expected actionable ruling"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "triage did not make exactly one request"
  request=$(tail -1 "$REQUEST_LOG")
  jq -e '(.questions | keys | sort) == ["item_1__attention","item_1__review_kind"] and
    all(.questions[]; .type == "choice")' \
    <<<"$request" >/dev/null || fail "review-answer triage request lost its two Choices"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "triage ledger row failed schema validation"
  pass "Jev triage adapter: review answers return attention and answer-kind Choices from one request"
}

test_triage_batches_many_items_into_one_call() {
  local home="$TMP_ROOT/triage-batch" before out request
  write_config "$home" off shadow off off
  write_key "$home"
  before=$(request_count)
  out=$(printf 'status\tdone: one\nwake\tcheck: two\nreview-answer\tApproved\n' \
    | jev_env "$home" "$TRIAGE" --batch)
  [ "$(request_count)" -eq $((before + 1)) ] || fail "a three-item batch made more than one request"
  request=$(tail -1 "$REQUEST_LOG")
  jq -e '(.state.items | length) == 3 and (.questions | length) == 4 and
    (.questions | has("item_3__review_kind")) and (.questions | has("item_1__review_kind") | not)' \
    <<<"$request" >/dev/null || fail "batched triage request lost an item or its answer-kind Choice"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 3 ] \
    || fail "batched triage did not classify every item: $out"
  assert_contains "$out" $'3\tactionable\truling' "batched triage lost the review answer's second Choice"
  jq -e -s 'length == 1 and (.[0].subject == "review-answer+status+wake") and
    (.[0].jev_verdict | length) == 3' "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "batched triage did not record one row naming every classified item"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "batched triage row failed schema validation"
  pass "Jev triage adapter: a whole batch of supervision items costs one consultation"
}

test_commit_request_builder() {
  local home="$TMP_ROOT/commit" repo="$TMP_ROOT/commit-repo" before out request
  write_config "$home" off off shadow off
  write_key "$home"
  make_git_fixture "$repo"
  before=$(request_count)
  out=$(jev_env "$home" "$COMMIT_LINT" "$repo")
  assert_contains "$out" "commit-lint: clear" "safe fixture should produce a clear advisory"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "the one-commit branch did not make exactly one request"
  request=$(tail -1 "$REQUEST_LOG")
  jq -e '(.questions | length) == 5 and all(.questions[]; .type == "noul") and
    (.state.commit.sha | length) == 40 and (.state.commit.diff | length) > 0 and
    .state.commit.truncated == false' \
    <<<"$request" >/dev/null || fail "commit lint request is not one five-Noul request for one commit"
  jq -e '.commits | length == 1 and all(.[]; .status == "reviewed" and .truncated == false)' \
    "$home/data/task-c/commit-lint.json" >/dev/null \
    || fail "commit lint did not record its per-commit evidence"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "commit lint ledger row failed schema validation"
  pass "Jev commit lint adapter: each branch commit is one request covering every declared risk"
}

test_commit_lint_truncates_instead_of_skipping() {
  local home="$TMP_ROOT/commit-big" repo="$TMP_ROOT/commit-big-repo" before out request
  # A per-call cap far below the diff size: the branch must still be linted.
  write_config "$home" off off shadow off 100 2000
  write_key "$home"
  make_git_fixture "$repo"
  awk 'BEGIN { for (i = 0; i < 4000; i++) print "padding line " i }' >> "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm 'Add a diff far larger than the per-call budget'
  before=$(request_count)
  out=$(jev_env "$home" "$COMMIT_LINT" "$repo")
  assert_contains "$out" "commit-lint:" "an oversized commit cancelled the whole branch lint"
  [ "$(request_count)" -eq $((before + 2)) ] || fail "commit lint did not send one request per commit"
  request=$(tail -1 "$REQUEST_LOG")
  jq -e '.state.commit.truncated == true and (.state.commit.diff | contains("file.txt |"))' \
    <<<"$request" >/dev/null || fail "the truncated request did not fall back to the commit stat"
  jq -e -s 'map(select(.truncated == true)) | length == 1' "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "the ledger does not mark the truncated consultation"
  jq -e '.commits | length == 2 and any(.[]; .truncated == true and .status == "reviewed")' \
    "$home/data/task-c/commit-lint.json" >/dev/null \
    || fail "commit lint evidence lost the truncated commit"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "truncated commit lint rows failed validation"
  pass "Jev commit lint adapter: a commit larger than the budget is truncated and recorded, not skipped"
}

test_active_advisories_never_touch_task_status() {
  local home="$TMP_ROOT/active-advisories" repo="$TMP_ROOT/active-advisories-repo" out latest
  write_config "$home" active off active off
  write_key "$home"
  make_accept_fixture "$home"
  printf 'FORCE_UNMET\n' > "$home/data/task-a/report.md"
  printf 'working: started\ndone: PR https://example.test/1 checks green\n' > "$home/state/task-a.status"
  jev_env "$home" "$ACCEPT" task-a
  jq -e '.advisory != null and (.unmet_criteria | length) > 0' "$home/data/task-a/acceptance.json" >/dev/null \
    || fail "active acceptance did not record its advisory in the task's acceptance record"
  assert_contains "$(cat "$home/state/task-a.status")" "done: PR https://example.test/1 checks green" \
    "the acceptance check disturbed the task status file"
  latest=$(last_status_line "$home/state/task-a.status")
  [ "$latest" = "done: PR https://example.test/1 checks green" ] \
    || fail "the acceptance check superseded the worker's terminal report with '$latest'"
  status_is_terminal_verb "$latest" || fail "the worker's done: line stopped being terminal"
  status_is_captain_relevant "$latest" || fail "the worker's done: line stopped being captain relevant"

  make_git_fixture "$repo"
  printf 'FORCE_CREDENTIAL_FLAG\n' >> "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm 'Exercise risk fixture'
  printf 'done: landed\n' > "$home/state/task-c.status"
  out=$(jev_env "$home" "$COMMIT_LINT" "$repo")
  assert_contains "$out" "credential" "active commit lint did not return the fixture flag"
  jq -e '.advisory != null and (.commits | map(.flags[]) | index("credential")) != null' \
    "$home/data/task-c/commit-lint.json" >/dev/null \
    || fail "active commit lint did not record its advisory in the task's commit-lint record"
  [ "$(cat "$home/state/task-c.status")" = "done: landed" ] \
    || fail "the commit lint disturbed the task status file"
  out=$(FM_HOME="$home" "$REPORT" "$home/state/jev-ledger.jsonl")
  assert_contains "$out" "advisories:" "the report does not surface the active advisories"
  assert_contains "$out" "flagged=credential" "the report does not name the flagged commit risk"
  pass "Jev active adapters: advisories reach their evidence records and the report, never the status stream"
}

test_open_questions_request_builder() {
  local home="$TMP_ROOT/questions" before out request proposal
  write_config "$home" off off off shadow
  write_key "$home"
  make_questions_fixture "$home"
  before=$(request_count)
  out=$(jev_env "$home" "$OPEN_QUESTIONS" "$home/questions.md" "$home/pages")
  proposal="$home/questions-jev-review.md"
  [ "$out" = "$proposal" ] || fail "open-question adapter did not name its proposal"
  [ -s "$proposal" ] || fail "open-question adapter did not write its proposal"
  assert_contains "$(cat "$proposal")" "settled" "proposal does not contain the Jev classification"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "open-question adapter did not make exactly one request"
  request=$(tail -1 "$REQUEST_LOG")
  jq -e '(.questions | length) == 1 and all(.questions[]; .type == "choice") and .state.questions.question_1.page == "launch.md"' \
    <<<"$request" >/dev/null || fail "open-question request lost its referenced page Choice"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "open-question ledger row failed schema validation"
  pass "Jev open-question adapter: one referenced-page Choice produces a proposal without editing the register"
}

test_shadow_presentation_hooks() {
  local home="$TMP_ROOT/hooks" before out capture
  write_config "$home" off shadow off off
  write_key "$home"

  append_wake "$home/state" check task-a "check: task-a needs review" \
    || fail "could not stage a wake for the Jev observer"
  before=$(request_count)
  out=$(jev_env "$home" "$DRAIN" 2>/dev/null) || fail "wake drain failed with shadow triage enabled"
  assert_contains "$out" "check: task-a needs review" "shadow triage changed or hid the presented wake"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "wake drain did not batch its observation into one request"
  jq -e -s 'length == 1 and .[0].use == "triage" and (.[0].subject | contains("wake"))' \
    "$home/state/jev-ledger.jsonl" >/dev/null || fail "wake drain did not record the expected triage row"

  capture="$home/review-result"
  cat > "$capture" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[3]{uid,prompt,selector,tag,text}:
  "el-choice","Context data: {\"question\":\"task-a\",\"answer\":\"approve\"}","section#review > button",choice,"Approve"
  "el-note","Please keep this note","section#review > p",note,"Review note"
  "","Can this ship?","",message,"Freeform message"
EOF
  before=$(request_count)
  out=$(jev_env "$home" "$LAVISH" read "$capture") || fail "Lavish read failed with shadow triage enabled"
  assert_contains "$out" "| Approve" "shadow triage changed or hid the captured review answer"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "Lavish read did not batch its three items into one request"
  jq -e -s 'length == 2 and .[1].use == "triage" and .[1].subject == "review-answer" and
    (.[1].jev_verdict | length) == 3' "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "Lavish read did not record one row covering every captured review item"
  pass "Jev triage hooks: a whole drain and a whole Lavish read each cost one observation"
}

test_model_family_and_mismatch() {
  local home="$TMP_ROOT/model" before out
  write_config "$home" off shadow off off
  write_key "$home"
  before=$(request_count)
  out=$(printf 'done: FORCE_MODEL_ALIAS\n' | jev_env "$home" "$TRIAGE" --kind status)
  [ "$out" = actionable ] || fail "a response from another build of the pinned family was rejected: '$out'"
  jq -e -s '.[0].available == true and .[0].response_model == "jev-1.13"' \
    "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "the ledger did not record the model id the service returned"

  out=$(printf 'done: FORCE_MODEL_MISMATCH\n' | jev_env "$home" "$TRIAGE" --kind status)
  [ -z "$out" ] || fail "an answer from an unrelated model was used: '$out'"
  jq -e -s '.[1].available == false and .[1].unavailable_reason == "response-model-mismatch" and
    .[1].response_model == "some-other-model-2"' "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "an unrelated model id was not recorded as a distinct mismatch"
  [ "$(request_count)" -eq $((before + 2)) ] || fail "the model fixture cases did not each make one request"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "model-id rows failed schema validation"
  pass "Jev client: any pinned-family build answers, and another model is a named mismatch with its id"
}

test_report_fixture_and_empty_error() {
  local out rc=0 empty="$TMP_ROOT/empty-ledger" malformed="$TMP_ROOT/malformed-ledger"
  out=$($REPORT "$ROOT/tests/fixtures/jev-ledger.jsonl") || fail "report rejected the valid fixture ledger"
  assert_contains "$out" "jev configuration:" "report did not open with the effective configuration"
  assert_contains "$out" "TYPESAFE_API_KEY=" "report did not state whether a key is present"
  assert_contains "$out" $'overall\t3\t3\t1\t33.33%\t1\t1\t0.000126\t6000\t1' \
    "report did not compute agreement, error counts, spend, and estimated tokens"
  assert_contains "$out" "consultation_id=fixture-commit" "report did not list a Jev-versus-baseline disagreement"
  assert_contains "$out" 'jev_rationale="At least one configured risk probability met the confidence floor."' \
    "report did not show the Jev rationale for a disagreement"
  assert_contains "$out" 'baseline_rationale="The existing landing path applies its normal delivery gates without this additional Jev risk lint."' \
    "report did not show the baseline rationale for a disagreement"
  head -1 "$ROOT/tests/fixtures/jev-ledger.jsonl" | jq -c 'del(.jev_rationale)' > "$malformed"
  if "$JEV" validate-ledger "$malformed"; then
    fail "ledger validation accepted a row without its Jev rationale"
  fi
  : > "$empty"
  out=$($REPORT "$empty" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "empty ledger report exited zero"
  assert_contains "$out" "ledger is empty" "empty ledger report did not explain the failure"
  pass "Jev report: fixture quality metrics are correct and an empty ledger fails clearly"
}

test_off_is_noop_for_every_adapter
test_missing_key_diagnostic_names_the_key
test_absent_config_defaults_active
test_unavailable_key_and_caps_fall_back
test_per_use_budget_protects_other_uses
test_accept_request_and_artifact
test_triage_request_builder
test_triage_batches_many_items_into_one_call
test_commit_request_builder
test_commit_lint_truncates_instead_of_skipping
test_active_advisories_never_touch_task_status
test_open_questions_request_builder
test_shadow_presentation_hooks
test_model_family_and_mismatch
test_report_fixture_and_empty_error

printf 'all fm-jev tests passed\n'
