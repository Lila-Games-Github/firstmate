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
  jq -e -s 'length == 1 and .[0].network_attempted == false and .[0].available == false and
    .[0].unavailable_reason == "daily-call-cap" and .[0].cost_usd == 0 and .[0].input_tokens == 0' \
    "$capped/state/jev-ledger.jsonl" >/dev/null \
    || fail "a cap refusal left no evidence of why nothing ran"
  "$JEV" validate-ledger "$capped/state/jev-ledger.jsonl" || fail "the refusal row failed schema validation"
  out=$(FM_HOME="$capped" "$REPORT" "$capped/state/jev-ledger.jsonl") || fail "report rejected a refusal-only ledger"
  assert_contains "$out" "reason=daily-call-cap kind=pre-request-refusal count=1" \
    "the report does not show why nothing ran"
  assert_contains "$out" $'triage\t0\t0\t0\t0\tn/a' "a refusal was counted as a consultation"

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
  jev_env "$home" "$JEV" finalize --use accept-check --subject task-a --decision-json '"accepted"' \
    && fail "finalize recorded a ground-truth label without naming the path that observed it"
  out=$(jev_env "$home" "$JEV" finalize --use accept-check --subject task-a --decision-json '"accepted"' \
    --label-source teardown-landed) || fail "acceptance final decision could not be recorded"
  [ "$(jq -r '.updated' <<<"$out")" -eq 1 ] || fail "acceptance finalization did not update its pending row"
  jq -e '.final_decision == "accepted" and .eventual_outcome == "accepted"
    and .label_source == "teardown-landed"' "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "acceptance ledger did not retain its later final decision and its source"
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

test_mixed_confidence_batch_is_gated_per_item() {
  local home="$TMP_ROOT/triage-mixed" before out row avoided
  write_config "$home" off active off off
  write_key "$home"
  before=$(request_count)
  out=$(printf 'status\tFORCE_ROUTINE one\nstatus\tFORCE_ROUTINE FORCE_LOW_CONFIDENCE two\nstatus\tFORCE_ROUTINE three\n' \
    | jev_env "$home" "$TRIAGE" --batch)
  [ "$(request_count)" -eq $((before + 1)) ] || fail "the mixed-confidence batch did not cost one request"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
    || fail "the unconfident item did not cost its confident siblings their answers: '$out'"
  assert_contains "$out" $'1\troutine' "a confident item was discarded with its unconfident sibling"
  assert_contains "$out" $'3\troutine' "a confident item was discarded with its unconfident sibling"
  row=$(cat "$home/state/jev-ledger.jsonl")
  jq -e '.used_jev_keys == {"item_1__attention":true,"item_2__attention":false,"item_3__attention":true} and
    .used_jev == true and .jev_confidences.item_2__attention == 0.4 and .confidence == 0.4' <<<"$row" >/dev/null \
    || fail "the ledger did not record the batch item by item: $row"
  jq -e '.decision_after_jev ==
    {"item_1__attention":"routine","item_2__attention":"actionable","item_3__attention":"routine"}' \
    <<<"$row" >/dev/null \
    || fail "decision_after_jev is not the per-item mix of Jev answers and baseline: $row"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "mixed-confidence row failed schema validation"
  out=$(FM_HOME="$home" "$REPORT" "$home/state/jev-ledger.jsonl") || fail "report rejected the mixed-confidence ledger"
  avoided=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "triage" { print $10 }')
  [ -n "$avoided" ] && [ "$avoided" -gt 0 ] \
    || fail "a batch with two confident answers contributed no estimated tokens avoided: $out"
  pass "Jev batched triage: each item is gated, recorded, and credited on its own confidence"
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
  awk 'BEGIN { for (i = 0; i < 14000; i++) print "padding line " i }' >> "$repo/file.txt"
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

# One unparseable line bearing today's date is enough to make the day scan
# fail. Reading that as an unspent budget would turn every daily and per-use
# cap off for the rest of the day, so the client must refuse instead and leave
# evidence of why.
# An open decision is re-printed on every drain until it is answered, so
# staging it unconditionally would re-consult the identical line every drain
# and spend the day's triage share on duplicates while a genuinely new line
# goes unconsulted.
test_unchanged_presentation_is_consulted_once() {
  local home="$TMP_ROOT/drain-dedup" before out
  write_config "$home" off shadow off off
  write_key "$home"
  mkdir -p "$home/state"
  printf 'working: started\nneeds-decision: which approach should the crew take?\n' \
    > "$home/state/task-d.status"
  before=$(request_count)
  out=$(jev_env "$home" "$DRAIN" 2>/dev/null) || fail "the first drain failed"
  assert_contains "$out" "needs-decision: which approach should the crew take?" \
    "the first drain did not present the open decision"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "the first drain did not consult once"

  out=$(jev_env "$home" "$DRAIN" 2>/dev/null) || fail "the second drain failed"
  assert_contains "$out" "needs-decision: which approach should the crew take?" \
    "the dedup suppressed the presentation itself, not just the consultation"
  [ "$(request_count)" -eq $((before + 1)) ] \
    || fail "an unchanged open decision was re-consulted on the next drain"
  jq -e -s 'length == 1' "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "the second drain appended another row for the same unchanged item"

  # A genuinely different line is still consulted, and the resolved one is
  # pruned rather than suppressing it forever.
  printf 'working: started\nneeds-decision: which rollout window applies?\n' \
    > "$home/state/task-d.status"
  out=$(jev_env "$home" "$DRAIN" 2>/dev/null) || fail "the third drain failed"
  [ "$(request_count)" -eq $((before + 2)) ] \
    || fail "a changed open decision was suppressed by the seen set"
  pass "Jev triage hooks: an unchanged presented item is consulted once, not once per drain"
}

test_presentation_overflow_is_consulted_on_next_drain() {
  local home="$TMP_ROOT/drain-overflow" before i out
  write_config "$home" off shadow off off
  write_key "$home"
  for i in $(seq 1 51); do
    printf 'needs-decision: decide approach %s?\n' "$i" > "$home/state/task-$i.status"
  done
  before=$(request_count)
  jev_env "$home" "$DRAIN" >/dev/null 2>&1 || fail "first overflow drain failed"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "first overflow drain did not consult"
  [ "$(wc -l < "$home/state/.jev-triage-seen")" -eq 50 ] || fail "overflow was marked seen"
  out=$(jev_env "$home" "$DRAIN" 2>/dev/null) || fail "second overflow drain failed"
  assert_contains "$out" 'needs-decision:' "overflow drain lost presentation"
  [ "$(request_count)" -eq $((before + 2)) ] || fail "overflow was never consulted"
  jq -e -s '([.[].state.items | keys[]] | length) == 51' \
    <<<"$(tail -2 "$REQUEST_LOG")" >/dev/null || fail "overflow consultation coverage was incomplete"
  jev_env "$home" "$DRAIN" >/dev/null 2>&1 || fail "third overflow drain failed"
  [ "$(request_count)" -eq $((before + 2)) ] || fail "covered items were reconsulted"
  rm -f "$home/state/"*.status
  jev_env "$home" "$DRAIN" >/dev/null 2>&1 || fail "resolved drain failed"
  [ ! -s "$home/state/.jev-triage-seen" ] || fail "resolved items were not pruned"
  pass "Jev triage hooks: overflow remains eligible until consulted"
}

test_unreadable_day_scan_refuses_instead_of_spending() {
  local home="$TMP_ROOT/corrupt-day" before today out row
  write_config "$home" off shadow off off
  write_key "$home"
  today=$(date -u +%Y-%m-%d)
  before=$(request_count)
  out=$(printf 'done: first\n' | jev_env "$home" "$TRIAGE" --kind status)
  [ "$out" = actionable ] || fail "the first consultation did not reach the endpoint: '$out'"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "the first consultation made no request"

  printf '{"schema_version":2,"timestamp":"x","date":"%s","use":"tri\n' "$today" \
    >> "$home/state/jev-ledger.jsonl"
  before=$(request_count)
  out=$(printf 'done: second\n' | jev_env "$home" "$TRIAGE" --kind status)
  [ -z "$out" ] || fail "a consultation used Jev while the day's spend could not be counted: '$out'"
  [ "$(request_count)" -eq "$before" ] \
    || fail "an unreadable day scan was read as an unspent budget and reached the endpoint"
  row=$(tail -1 "$home/state/jev-ledger.jsonl")
  jq -e '.network_attempted == false and .unavailable_reason == "ledger-unreadable" and
    .cost_usd == 0 and .use == "triage"' <<<"$row" >/dev/null \
    || fail "the refusal left no evidence of why nothing ran: $row"

  before=$(request_count)
  out=$(printf 'done: third\n' | jev_env "$home" "$TRIAGE" --kind status)
  [ "$(request_count)" -eq "$before" ] \
    || fail "a later consultation that day still spent against the uncountable budget"
  pass "Jev budgets: a day whose spend cannot be counted refuses rather than spending freely"
}

# `mode` never resolves the key and the built-in configuration is active, so the
# presentation hooks have to ask `status` or a keyless home stages every line
# and builds a whole envelope on every drain for a consultation that cannot
# happen.
test_observer_gate_requires_a_usable_key() {
  local home="$TMP_ROOT/observer-gate" before out
  write_config "$home" off shadow off off
  mkdir -p "$home/state"
  # shellcheck source=bin/fm-jev-adapter-lib.sh
  . "$ROOT/bin/fm-jev-adapter-lib.sh"

  if FM_HOME="$home" fm_jev_observer_ready triage; then
    fail "the observer gate opened for a home with no key"
  fi

  write_key "$home"
  FM_HOME="$home" fm_jev_observer_ready triage \
    || fail "the observer gate stayed shut for a configured use with a key"

  if FM_HOME="$home" fm_jev_observer_ready accept-check; then
    fail "the observer gate opened for a use configured off"
  fi
  if ! jq '.kill_switch = true' "$home/config/jev.json" > "$home/config/jev.json.tmp" \
    || ! mv "$home/config/jev.json.tmp" "$home/config/jev.json"; then
    fail "could not engage the kill switch"
  fi
  if FM_HOME="$home" fm_jev_observer_ready triage; then
    fail "the observer gate opened with the kill switch engaged"
  fi
  write_config "$home" off shadow off off

  # The keyless drain must still present every row and reach no endpoint.
  rm -f "$home/.env"
  append_wake "$home/state" check task-k "check: task-k needs review" \
    || fail "could not stage a wake for the keyless drain"
  before=$(request_count)
  out=$(jev_env "$home" "$DRAIN" 2>/dev/null) || fail "keyless wake drain failed"
  assert_contains "$out" "check: task-k needs review" "the keyless drain hid a presented wake"
  [ "$(request_count)" -eq "$before" ] || fail "a keyless drain reached the endpoint"
  [ ! -e "$home/state/jev-ledger.jsonl" ] || fail "a keyless drain wrote a ledger row"
  pass "Jev triage hooks: the presentation gate needs a usable key, and a keyless drain still presents"
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

make_big_questions_fixture() { # <home> <page-bytes>
  local home=$1 bytes=$2
  mkdir -p "$home/pages"
  cat > "$home/questions.md" <<'MD'
# Open questions

- Which launch date applies? [page: launch.md]
- Which pricing tier applies? [page: pricing.md]
MD
  awk -v n="$bytes" 'BEGIN { while (length(out) < n) out = out "The approved launch date is 2026-10-04. "; print out }' \
    > "$home/pages/launch.md"
  awk -v n="$bytes" 'BEGIN { while (length(out) < n) out = out "The approved pricing tier is premium. "; print out }' \
    > "$home/pages/pricing.md"
}

test_shared_page_is_sent_once() {
  local home="$TMP_ROOT/questions-shared" before out request
  write_config "$home" off off off shadow
  write_key "$home"
  mkdir -p "$home/pages"
  cat > "$home/questions.md" <<'MD'
# Open questions

- Which launch date applies? [page: launch.md]
- Who signed off on that date? [page: launch.md]
MD
  printf 'The approved launch date is 2026-10-04, signed off by the captain.\n' > "$home/pages/launch.md"
  before=$(request_count)
  out=$(jev_env "$home" "$OPEN_QUESTIONS" "$home/questions.md" "$home/pages") \
    || fail "open-question adapter failed on two questions sharing one page"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "two questions over one page did not cost one request"
  request=$(tail -1 "$REQUEST_LOG")
  jq -e '(.state.questions | length) == 2 and (.state.pages | length) == 1 and
    (.state.pages | has("launch.md")) and
    (.state.questions.question_1.page == "launch.md") and
    ([.state.questions[] | has("text")] | any | not)' <<<"$request" >/dev/null \
    || fail "the referenced page was not carried once as shared context: $request"
  assert_contains "$(cat "$out")" "settled" "the shared-context proposal lost its classification"
  pass "Jev open-question adapter: a page two questions cite is transmitted once, not once per question"
}

test_oversized_material_splits_and_truncates() {
  local home="$TMP_ROOT/questions-big" before out proposal rows
  # A per-call cap far below one page: the sweep must still answer both
  # questions instead of becoming a silent no-op.
  write_config "$home" off off off shadow 100 2000
  write_key "$home"
  make_big_questions_fixture "$home" 200000
  before=$(request_count)
  out=$(jev_env "$home" "$OPEN_QUESTIONS" "$home/questions.md" "$home/pages") \
    || fail "an oversized open-question sweep failed instead of splitting"
  proposal="$home/questions-jev-review.md"
  [ "$out" = "$proposal" ] && [ -s "$proposal" ] || fail "the oversized sweep wrote no proposal"
  [ "$(grep -c '^- ' "$proposal")" -eq 2 ] \
    || fail "the oversized sweep lost a question: $(cat "$proposal")"
  [ "$(request_count)" -eq $((before + 2)) ] || fail "the oversized sweep did not split per question"
  jq -e -s 'all(.[]; (.state.pages | length) == 1) and
    ([.[] | .state.pages | keys[]] | sort) == ["launch.md","pricing.md"]' \
    <<<"$(tail -2 "$REQUEST_LOG")" >/dev/null \
    || fail "a split part carried a page its own question never referenced"
  rows=$(cat "$home/state/jev-ledger.jsonl")
  jq -e -s 'length == 2 and all(.[]; .truncated == true and .available == true)' <<<"$rows" >/dev/null \
    || fail "the split rows do not record that Jev saw shortened pages: $rows"
  jq -e -s '[.[].subject] | sort == ["questions.md#question_1","questions.md#question_2"]' <<<"$rows" >/dev/null \
    || fail "the split rows do not each name their own subject: $rows"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "split rows failed schema validation"
  pass "Jev client: an over-budget envelope is split per question and shortened, never silently dropped"
}

# An N-part split spends N calls and N request bodies. Starting one that cannot
# finish leaves the later questions permanently unanswered for the day, so the
# client keeps one shrunk request that still classifies every question.
test_split_that_cannot_finish_is_never_started() {
  local home before out proposal

  home="$TMP_ROOT/questions-spend-capped"
  # Room for one budget-sized request today, not the two a split would cost.
  write_config "$home" off off off shadow 100 2000 0.0001
  write_key "$home"
  make_big_questions_fixture "$home" 20000
  before=$(request_count)
  out=$(jev_env "$home" "$OPEN_QUESTIONS" "$home/questions.md" "$home/pages") \
    || fail "a spend-capped sweep failed instead of sending one request"
  proposal="$home/questions-jev-review.md"
  [ "$out" = "$proposal" ] && [ -s "$proposal" ] || fail "the spend-capped sweep wrote no proposal"
  [ "$(request_count)" -eq $((before + 1)) ] \
    || fail "a split was started that the per-use spend cap could not finish"
  [ "$(grep -c '^- ' "$proposal")" -eq 2 ] \
    || fail "the spend-capped sweep lost a question: $(cat "$proposal")"
  grep -q 'null' "$proposal" && fail "the spend-capped sweep rendered an unanswered question"
  jq -e -s 'length == 1 and .[0].available == true and .[0].truncated == true' \
    "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "the spend-capped sweep did not record one shortened consultation"

  home="$TMP_ROOT/questions-call-capped"
  write_config "$home" off off off shadow 1 2000
  write_key "$home"
  make_big_questions_fixture "$home" 20000
  before=$(request_count)
  out=$(jev_env "$home" "$OPEN_QUESTIONS" "$home/questions.md" "$home/pages") \
    || fail "a call-capped sweep failed instead of sending one request"
  proposal="$home/questions-jev-review.md"
  [ -s "$proposal" ] || fail "the call-capped sweep wrote no proposal"
  [ "$(request_count)" -eq $((before + 1)) ] \
    || fail "a split was started that the daily call cap could not finish"
  [ "$(grep -c '^- ' "$proposal")" -eq 2 ] \
    || fail "the call-capped sweep lost a question: $(cat "$proposal")"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "the capped sweep row failed validation"
  pass "Jev client: a split that a call or spend cap could not finish is never started"
}

# Ten questions over one page: splitting would send that page ten times, one
# near-identical truncated prefix per part, for ten of the day's calls. The
# page is what makes the envelope oversized, not the question text, so one
# shortened request classifies all ten instead.
test_one_page_cited_by_every_question_is_not_duplicated() {
  local home="$TMP_ROOT/questions-one-page" before out proposal i
  write_config "$home" off off off shadow 100 2000
  write_key "$home"
  mkdir -p "$home/pages"
  {
    printf '# Open questions\n\n'
    for i in 1 2 3 4 5 6 7 8 9 10; do
      printf -- '- Which launch detail number %s applies? [page: launch.md]\n' "$i"
    done
  } > "$home/questions.md"
  awk 'BEGIN { while (length(out) < 20000) out = out "The approved launch date is 2026-10-04. "; print out }' \
    > "$home/pages/launch.md"
  before=$(request_count)
  out=$(jev_env "$home" "$OPEN_QUESTIONS" "$home/questions.md" "$home/pages") \
    || fail "a single-page sweep failed instead of sending one request"
  proposal="$home/questions-jev-review.md"
  [ "$out" = "$proposal" ] && [ -s "$proposal" ] || fail "the single-page sweep wrote no proposal"
  [ "$(request_count)" -eq $((before + 1)) ] \
    || fail "one page cited by every question was duplicated across per-question requests"
  [ "$(grep -c '^- ' "$proposal")" -eq 10 ] \
    || fail "the single-page sweep lost a question: $(cat "$proposal")"
  grep -q 'null' "$proposal" && fail "the single-page sweep left a question unclassified"
  jq -e '(.state.questions | length) == 10 and (.state.pages | length) == 1 and
    (.state.pages["launch.md"] | length) < 20000' <<<"$(tail -1 "$REQUEST_LOG")" >/dev/null \
    || fail "the single request lost a question or kept the whole page"
  jq -e -s 'length == 1 and .[0].truncated == true and .[0].available == true' \
    "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "the single-page sweep did not record exactly one shortened consultation"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "the single-page row failed validation"
  pass "Jev client: a page every question cites is shortened into one request, never sent per question"
}

# A part of a split can fail on its own. The questions its siblings answered
# are still real answers, but the one it never asked about must not be rendered
# as a classification Jev made.
test_failed_split_part_is_not_rendered_as_a_classification() {
  local home="$TMP_ROOT/questions-part-failed" before out proposal rows
  write_config "$home" off off off shadow 100 2000
  write_key "$home"
  mkdir -p "$home/pages"
  cat > "$home/questions.md" <<'MD'
# Open questions

- Which launch date applies? [page: launch.md]
- Which pricing tier applies? [page: pricing.md]
MD
  awk 'BEGIN { while (length(out) < 20000) out = out "The approved launch date is 2026-10-04. "; print out }' \
    > "$home/pages/launch.md"
  awk 'BEGIN { out = "FORCE_HTTP_500 "
    while (length(out) < 20000) out = out "The approved pricing tier is premium. "; print out }' \
    > "$home/pages/pricing.md"
  before=$(request_count)
  out=$(jev_env "$home" "$OPEN_QUESTIONS" "$home/questions.md" "$home/pages") \
    || fail "a sweep with one failing part produced no proposal"
  proposal="$home/questions-jev-review.md"
  [ "$out" = "$proposal" ] && [ -s "$proposal" ] || fail "the partial sweep wrote no proposal"
  [ "$(request_count)" -eq $((before + 2)) ] || fail "the sweep did not split into two requests"
  [ "$(grep -c '^- ' "$proposal")" -eq 2 ] \
    || fail "the partial sweep lost a question: $(cat "$proposal")"
  grep -q 'null' "$proposal" \
    && fail "the unanswered question was rendered as a classification: $(cat "$proposal")"
  assert_contains "$(cat "$proposal")" "**unclassified** (no answer): Which pricing tier applies?" \
    "the question whose part failed is not marked unclassified"
  assert_contains "$(cat "$proposal")" "1 of 2 questions were not answered" \
    "the proposal does not say part of the sweep went unanswered"
  assert_contains "$(cat "$proposal")" "http-500" "the proposal does not name why a question is unanswered"
  grep -q '^- \*\*settled\*\*.*launch date' "$proposal" \
    || fail "the answered question lost its classification: $(cat "$proposal")"
  rows=$(cat "$home/state/jev-ledger.jsonl")
  jq -e -s 'length == 2 and ([.[] | select(.available)] | length) == 1 and
    ([.[] | select(.unavailable_reason == "http-500")] | length) == 1' <<<"$rows" >/dev/null \
    || fail "the partial sweep did not record both the answer and the failure: $rows"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "partial-split rows failed validation"
  pass "Jev client: a question whose split part failed is reported unclassified, never guessed"
}

test_unfittable_question_is_refused_with_a_row() {
  local home="$TMP_ROOT/questions-unfittable" before out
  # A cap no request can fit under: the refusal must be recorded, not silent.
  write_config "$home" off off off shadow 100 1
  write_key "$home"
  make_questions_fixture "$home"
  before=$(request_count)
  out=$(jev_env "$home" "$OPEN_QUESTIONS" "$home/questions.md" "$home/pages")
  [ -z "$out" ] || fail "an unfittable sweep claimed to write a proposal: $out"
  [ ! -e "$home/questions-jev-review.md" ] || fail "an unfittable sweep wrote a proposal"
  [ "$(request_count)" -eq "$before" ] || fail "an unfittable request still reached the endpoint"
  jq -e -s 'length == 1 and .[0].network_attempted == false and
    .[0].unavailable_reason == "question-block-token-cap" and .[0].use == "open-questions"' \
    "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "an unfittable question left no evidence on any surface"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "the refusal row failed schema validation"
  out=$(FM_HOME="$home" "$REPORT" "$home/state/jev-ledger.jsonl") || fail "report rejected the refusal ledger"
  assert_contains "$out" "reason=question-block-token-cap kind=pre-request-refusal count=1" \
    "the report does not say the cap is too small for the questions themselves"
  pass "Jev client: a question too large even alone is refused with a recorded reason, not silence"
}

# The report every criterion shares is not group-owned, so splitting would copy
# the same oversized text into every part for the same truncated prefix at N
# times the spend and N of the day's calls. One shrunk request answers all of
# them instead.
test_oversized_shared_report_is_shrunk_not_duplicated() {
  local home="$TMP_ROOT/accept-big" before request
  write_config "$home" shadow off off off 100 2000
  write_key "$home"
  make_accept_fixture "$home"
  awk 'BEGIN { while (length(out) < 200000) out = out "Changed bin/example.sh and ran tests/example.test.sh. "; print out }' \
    > "$home/data/task-a/report.md"
  before=$(request_count)
  jev_env "$home" "$ACCEPT" task-a
  [ -s "$home/data/task-a/acceptance.json" ] || fail "an oversized report produced no acceptance record"
  jq -e '(.criteria | length) == 2 and .verdict == "accepted"' "$home/data/task-a/acceptance.json" >/dev/null \
    || fail "the oversized acceptance record lost a criterion"
  [ "$(request_count)" -eq $((before + 1)) ] \
    || fail "the shared oversized report was duplicated across per-criterion requests"
  request=$(tail -1 "$REQUEST_LOG")
  jq -e '(.questions | length) == 2 and (.state.acceptance_criteria | length) == 2 and
    (.state.report | length) < 20000' <<<"$request" >/dev/null \
    || fail "the single request lost a criterion or kept the whole oversized report"
  jq -e -s 'length == 1 and .[0].truncated == true and .[0].use == "accept-check"' \
    "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "the oversized acceptance row does not record its shortening"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "oversized acceptance row failed validation"
  pass "Jev client: oversized shared state is shrunk into one request, never copied per question"
}

# The middle regime between the two extremes: a shared report that fits the
# budget on its own but is still the bulk of the envelope. Splitting would send
# five near-identical copies of it to answer five short criteria, where one
# request shortened by a few hundred bytes carries all five.
test_shared_report_under_budget_is_still_not_duplicated() {
  local home="$TMP_ROOT/accept-midsize" before request
  write_config "$home" shadow off off off 100 2000
  write_key "$home"
  mkdir -p "$home/data/task-a"
  cat > "$home/data/task-a/brief.md" <<'MD'
# Task

## Acceptance criteria

- The report names the changed file.
- The report includes a passing test command.
- The report names the reviewed branch.
- The report records the run identifier.
- The report states the landing outcome.
MD
  awk 'BEGIN { while (length(out) < 7600) out = out "Changed bin/example.sh and ran tests/example.test.sh. "; print substr(out, 1, 7600) }' \
    > "$home/data/task-a/report.md"
  before=$(request_count)
  jev_env "$home" "$ACCEPT" task-a
  [ -s "$home/data/task-a/acceptance.json" ] || fail "a mid-size report produced no acceptance record"
  jq -e '(.criteria | length) == 5' "$home/data/task-a/acceptance.json" >/dev/null \
    || fail "the mid-size acceptance record lost a criterion"
  [ "$(request_count)" -eq $((before + 1)) ] \
    || fail "a report that fits the budget alone was still copied into a request per criterion"
  request=$(tail -1 "$REQUEST_LOG")
  jq -e '(.questions | length) == 5 and (.state.acceptance_criteria | length) == 5 and
    (.state.report | length) < 7600' <<<"$request" >/dev/null \
    || fail "the single request lost a criterion or kept the whole report: $request"
  jq -e -s 'length == 1 and .[0].truncated == true' "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "the mid-size acceptance row does not record its shortening"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "mid-size acceptance row failed validation"
  pass "Jev client: a shared report that is the bulk is shrunk once, even when it fits the budget alone"
}

# The acceptance verdict is one claim about every criterion, so a part of it is
# not a consultation in its own right. Splitting it would append one row per
# part, each asserting the task's whole verdict over the criteria it happened
# to carry, and the report would count one prediction N times. Oversized or
# not, it is one request and one row.
test_oversized_accept_check_is_one_request_and_one_row() {
  local home="$TMP_ROOT/accept-big-criteria" before request out
  write_config "$home" shadow off off off 100 2000
  write_key "$home"
  mkdir -p "$home/data/task-a"
  awk 'BEGIN {
    while (length(one) < 9000) one = one "The report names every changed file. "
    while (length(two) < 9000) two = two "The report includes a passing test command. "
    print "# Task"; print ""; print "## Acceptance criteria"; print ""
    print "- " one; print "- " two
  }' > "$home/data/task-a/brief.md"
  printf 'Changed bin/example.sh and ran tests/example.test.sh successfully.\n' \
    > "$home/data/task-a/report.md"
  before=$(request_count)
  jev_env "$home" "$ACCEPT" task-a
  [ -s "$home/data/task-a/acceptance.json" ] || fail "oversized criteria produced no acceptance record"
  jq -e '(.criteria | length) == 2' "$home/data/task-a/acceptance.json" >/dev/null \
    || fail "the acceptance record lost a criterion"
  [ "$(request_count)" -eq $((before + 1)) ] \
    || fail "an aggregate acceptance verdict was split across requests"
  request=$(tail -1 "$REQUEST_LOG")
  jq -e '(.questions | length) == 2 and (.state.acceptance_criteria | length) == 2' <<<"$request" >/dev/null \
    || fail "the single request lost a criterion: $request"
  # Every criterion came back from a stub, so the row must not be a scored
  # prediction: the report would otherwise count it in agreement and error
  # columns and credit its untruncated estimate as tokens avoided.
  jq -e -s 'length == 1 and .[0].truncated == true and .[0].use == "accept-check" and
    .[0].subject == "task-a" and .[0].network_attempted == true and
    .[0].available == false and .[0].unavailable_reason == "questions-truncated" and
    .[0].jev_verdict == null and .[0].used_jev == false and
    .[0].decision_after_jev == .[0].baseline_decision and (.[0].jev_flagged | length) == 0 and
    .[0].estimated_big_model_tokens <= ((.[0].request_bytes + 3) / 4 | floor)' \
    "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "a verdict built only from stubs was recorded as a scored prediction"
  # Jev judged a stub of each criterion, so the record must not present those
  # answers as judgements of the criteria the brief actually states, and it
  # must not claim a verdict over criteria it says nothing supports.
  jq -e '.truncated == true and .verdict == "unjudged" and .confidence == null and
    (.unjudged_criteria | sort) == ["criterion_1","criterion_2"] and
    (.unmet_criteria | length) == 0 and
    all(.criteria[]; .met == null and .truncated == true and
        .judged_characters < (.text | length))' \
    "$home/data/task-a/acceptance.json" >/dev/null \
    || fail "the record hides that Jev judged shortened criteria: $(cat "$home/data/task-a/acceptance.json")"
  jq -e '[.criteria[] | select(.id == "criterion_1") | .judged_characters] ==
    [($request | fromjson | .state.acceptance_criteria.criterion_1
      | sub("\n\\(truncated to fit the Jev per-call budget\\)$"; "") | length)]' \
    --arg request "$request" "$home/data/task-a/acceptance.json" >/dev/null \
    || fail "judged_characters does not match what the request actually carried"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "the acceptance row failed validation"
  out=$(FM_HOME="$home" "$REPORT" "$home/state/jev-ledger.jsonl") \
    || fail "report rejected the shortened acceptance ledger"
  assert_contains "$out" "reason=questions-truncated kind=failed-attempt count=1" \
    "the report does not name the consultation that could not be scored: $out"
  printf '%s\n' "$out" | awk -F'\t' '$1 == "accept-check" { exit ($3 == "0" && $10 == "0") ? 0 : 1 }' \
    || fail "an unscorable consultation was still counted as a labelled prediction or avoided tokens: $out"
  pass "Jev acceptance check: a verdict built only from stubs is recorded unjudged, never scored"
}

test_small_global_cap_keeps_every_use_reachable() {
  local home="$TMP_ROOT/smallcap" status out
  mkdir -p "$home/config" "$home/state" "$home/data"
  write_key "$home"
  make_accept_fixture "$home"
  # Two calls a day in total and no per-use blocks: the remainder must be handed
  # out rather than floored away, and a use left with nothing must say so.
  cat > "$home/config/jev.json" <<'JSON'
{
  "version": 1,
  "kill_switch": false,
  "per_call_token_cap": 32000,
  "daily": {"call_cap": 2, "spend_usd_cap": 1},
  "uses": {
    "accept-check": {"mode": "shadow", "confidence_floor": 0.8},
    "triage": {"mode": "shadow", "confidence_floor": 0.65},
    "commit-lint": {"mode": "shadow", "confidence_floor": 0.8},
    "open-questions": {"mode": "shadow", "confidence_floor": 0.65}
  }
}
JSON
  status=$(jev_env "$home" "$JEV" status accept-check)
  [ "$(cut -f2 <<<"$status")" = none ] \
    || fail "a cap of 2 left the acceptance check no share at all: $status"
  status=$(jev_env "$home" "$JEV" status triage)
  [ "$(cut -f1 <<<"$status")" = shadow ] && [ "$(cut -f2 <<<"$status")" = no-budget ] \
    || fail "a use with a zero share does not report it: $status"
  jev_env "$home" "$ACCEPT" task-a
  [ -s "$home/data/task-a/acceptance.json" ] \
    || fail "the acceptance check was starved by a small global cap"
  out=$(FM_HOME="$home" "$REPORT" "$home/state/jev-ledger.jsonl")
  assert_contains "$out" "triage=shadow(no-budget)" "the report does not flag a use with no budget"
  pass "Jev budgets: a small global cap is shared out exactly, and a zero share is named"
}

seed_old_rows() { # <ledger> <date> <count>
  local ledger=$1 day=$2 count=$3
  head -1 "$ROOT/tests/fixtures/jev-ledger.jsonl" \
    | jq -c --arg day "$day" '.date = $day | .timestamp = ($day + "T00:00:00Z")' \
    | awk -v n="$count" '{ for (i = 0; i < n; i++) { row = $0; sub(/"fixture-accept"/, "\"old-" i "\"", row); print row } }' \
      >> "$ledger"
}

test_ledger_rotates_monthly_and_report_reads_archives() {
  local home="$TMP_ROOT/rotate" month archive out
  write_config "$home" off shadow off off
  write_key "$home"
  mkdir -p "$home/state"
  month=$(date -u -d '2026-01-15' +%Y-%m 2>/dev/null || printf '2026-01\n')
  seed_old_rows "$home/state/jev-ledger.jsonl" "$month-15" 3
  out=$(printf 'done: ready\n' | jev_env "$home" "$TRIAGE" --kind status)
  [ "$out" = actionable ] || fail "a consultation across a month boundary failed: '$out'"
  archive="$home/state/jev-ledger/$month.jsonl"
  [ -s "$archive" ] || fail "last month's rows were not archived"
  [ "$(wc -l < "$archive")" -eq 3 ] || fail "the archive lost rows"
  [ "$(wc -l < "$home/state/jev-ledger.jsonl")" -eq 1 ] \
    || fail "the running ledger still carries last month's rows"
  out=$(FM_HOME="$home" "$REPORT")
  assert_contains "$out" $'overall\t4\t' "the report does not read the archived months"
  pass "Jev ledger: a new month archives the old one and the report still reads every month"
}

test_consult_does_not_read_the_whole_ledger() {
  local home="$TMP_ROOT/bigledger" today month oldday before out
  write_config "$home" off shadow off off
  write_key "$home"
  mkdir -p "$home/state"
  today=$(date -u +%Y-%m-%d)
  month=$(date -u +%Y-%m)
  case "$today" in "$month-01") oldday="$month-02" ;; *) oldday="$month-01" ;; esac
  seed_old_rows "$home/state/jev-ledger.jsonl" "$oldday" 2000
  printf 'this line is not JSON at all\n' >> "$home/state/jev-ledger.jsonl"
  before=$(request_count)
  out=$(printf 'done: ready\n' | jev_env "$home" "$TRIAGE" --kind status)
  [ "$out" = actionable ] \
    || fail "consult parsed history it never needed and refused the call: '$out'"
  [ "$(request_count)" -eq $((before + 1)) ] || fail "the consultation did not reach the endpoint"
  [ "$(tail -1 "$home/state/jev-ledger.jsonl" | jq -r '.use')" = triage ] \
    || fail "the new row was not appended after the untouched history"
  if "$JEV" validate-ledger "$home/state/jev-ledger.jsonl"; then
    fail "validate-ledger accepted a ledger containing an unparseable line"
  fi
  pass "Jev client: a consultation scans only the day it budgets against, not the whole ledger"
}

# Teardown labels an acceptance row "accepted" or "discarded" while Jev answers
# "accepted" or "rejected", so the report has to compare classes: a correct
# rejection of work that was then discarded is agreement, and an acceptance of
# that same work is the false positive the evaluation needs to be able to see.
test_report_scores_discarded_labels_as_the_negative_class() {
  local ledger="$TMP_ROOT/discarded-ledger" fixture="$ROOT/tests/fixtures/jev-ledger.jsonl" out
  : > "$ledger"
  head -1 "$fixture" | jq -c '.consultation_id = "correct-rejection" | .subject = "task-r" |
    .jev_verdict = "rejected" | .final_decision = "discarded" | .eventual_outcome = "discarded" |
    .label_source = "teardown-force-discard"' >> "$ledger"
  head -1 "$fixture" | jq -c '.consultation_id = "wrong-acceptance" | .subject = "task-w" |
    .existing_decision = "rejected" | .baseline_decision = "rejected" | .agreement = false |
    .final_decision = "discarded" | .eventual_outcome = "discarded" |
    .label_source = "teardown-force-discard"' >> "$ledger"
  head -1 "$fixture" | jq -c '.consultation_id = "still-open" | .subject = "task-u" |
    .final_decision = null | .eventual_outcome = null | .label_source = null' >> "$ledger"
  "$JEV" validate-ledger "$ledger" || fail "a discarded-outcome ledger failed schema validation"
  out=$($REPORT "$ledger") || fail "report rejected the discarded-outcome ledger"
  assert_contains "$out" $'accept-check\t3\t2\t1\t1\t50%\t1\t0\t' \
    "the report did not score discarded work as the negative class with the unlabelled row apart: $out"
  assert_contains "$out" 'eventual_outcome="discarded" label_source="teardown-force-discard"' \
    "the report does not name the ground truth and the teardown path behind a disagreement"
  # An acceptance row supplies no baseline, so `disagreements:` can never hold
  # it; the mismatch against the recorded outcome is the only review surface.
  assert_contains "$out" "outcome-mismatches:" "the report has no outcome-mismatch section"
  assert_contains "$out" "consultation_id=wrong-acceptance" \
    "an acceptance Jev called accepted and teardown discarded is reviewable nowhere: $out"
  assert_contains "$out" 'jev_decision="accepted" eventual_outcome="discarded" label_source="teardown-force-discard"' \
    "the outcome mismatch does not show both sides"
  printf '%s\n' "$out" | grep -q 'consultation_id=correct-rejection use' \
    && fail "a correct rejection was listed as an outcome mismatch: $out"
  pass "Jev report: a discarded task scores as a negative label and an unlabelled row stays apart"
}

# Finding routine items is what triage is for, so one routine answer in a batch
# must not read as a whole-batch disagreement, and the report must name the item
# that diverged rather than dumping every item of the batch.
test_report_names_only_the_differing_items_of_a_batch() {
  local home="$TMP_ROOT/triage-differ" before out row
  write_config "$home" off shadow off off
  write_key "$home"
  before=$(request_count)
  out=$(printf 'status\tFORCE_ROUTINE one\nstatus\ttwo\nstatus\tthree\n' \
    | jev_env "$home" "$TRIAGE" --batch)
  [ "$(request_count)" -eq $((before + 1)) ] || fail "the mixed batch did not cost one request"
  row=$(cat "$home/state/jev-ledger.jsonl")
  jq -e '.differing_keys == ["item_1__attention"] and
    .agreement_keys == {"item_1__attention":false,"item_2__attention":true,"item_3__attention":true} and
    .agreement == false and .schema_version == 2' <<<"$row" >/dev/null \
    || fail "the row did not record agreement item by item: $row"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "the per-item agreement row failed validation"
  out=$(FM_HOME="$home" "$REPORT" "$home/state/jev-ledger.jsonl") || fail "report rejected the mixed-batch ledger"
  assert_contains "$out" "differing_items=1 of 3" "the report does not say how much of the batch diverged"
  assert_contains "$out" 'item=item_1__attention jev_choice="routine"' \
    "the report does not name the item that diverged with its Jev choice"
  assert_contains "$out" 'baseline_choice="actionable"' "the report drops the baseline choice"
  printf '%s\n' "$out" | grep -q 'item=item_2__attention' \
    && fail "the report listed an item that agreed: $out"
  printf '%s\n' "$out" | grep -q 'jev_decision=' \
    && fail "the report still dumped the whole batch verdict object: $out"
  pass "Jev report: a batched disagreement names only the items that diverged"
}

# A version 1 row predates agreement_keys, so the report has to derive the
# differing items from the verdict and the baseline to stay readable.
test_report_derives_differing_items_for_an_old_row() {
  local ledger="$TMP_ROOT/v1-batch-ledger" fixture="$ROOT/tests/fixtures/jev-ledger.jsonl" out
  head -3 "$fixture" | tail -1 | jq -c '
    .consultation_id = "v1-batch" | .subject = "wake+status" |
    .jev_verdict = {"item_1__attention":"routine","item_2__attention":"actionable"} |
    .existing_decision = {"item_1__attention":"actionable","item_2__attention":"actionable"} |
    .baseline_decision = {"item_1__attention":"actionable","item_2__attention":"actionable"} |
    .decision_after_jev = .baseline_decision |
    .final_decision = null | .eventual_outcome = null | .agreement = false' > "$ledger"
  "$JEV" validate-ledger "$ledger" || fail "a version 1 batched row stopped validating after the schema bump"
  out=$($REPORT "$ledger") || fail "report rejected a version 1 batched ledger"
  assert_contains "$out" "differing_items=1 of 2" "the report did not derive the differing items of an old row"
  assert_contains "$out" 'item=item_1__attention jev_choice="routine"' \
    "the derived listing lost the item that diverged"
  pass "Jev report: a pre-bump batched row still lists only its differing items"
}

# The day the key is revoked every consultation fails the same way. If that
# never reaches a report section the operator sees consultations climbing with
# nothing labelled and no stated cause.
test_report_lists_per_key_outcome_mismatches() {
  local home="$TMP_ROOT/question-outcome" out id
  write_config "$home" off off off shadow
  write_key "$home"
  make_questions_fixture "$home"
  printf '%s\n' '- Another date? [page: launch.md]' >> "$home/questions.md"
  jev_env "$home" "$OPEN_QUESTIONS" "$home/questions.md" "$home/pages" >/dev/null
  id=$(jq -r '.subject' "$home/state/jev-ledger.jsonl")
  jev_env "$home" "$JEV" finalize --use open-questions --subject "$id" \
    --decision-json '{"question_1":"still_open","question_2":"settled","missing":"settled"}' --label-source reviewer >/dev/null
  out=$(jev_env "$home" "$REPORT") || fail "report failed for keyed outcomes"
  out=${out#*outcome-mismatches:}
  assert_contains "$out" 'item=question_1 jev_choice="settled" eventual_outcome="still_open"' \
    "report omitted the per-key outcome mismatch"
  assert_contains "$out" 'jev_probabilities=' "mismatch lost probabilities"
  assert_contains "$out" 'label_source="reviewer"' "mismatch lost label provenance"
  assert_contains "$out" 'jev_rationale=' "mismatch lost rationale"
  [[ "$out" != *'item=question_2'* && "$out" != *'item=missing'* ]] \
    || fail "report included matching or absent verdict keys"
  pass "Jev report: keyed outcome mismatches show only differing matched keys"
}

test_report_names_failed_network_attempts() {
  local ledger="$TMP_ROOT/failed-attempts-ledger" fixture="$ROOT/tests/fixtures/jev-ledger.jsonl" out
  head -1 "$fixture" | jq -c '.consultation_id = "revoked-key" | .subject = "task-k" |
    .network_attempted = true | .available = true | .unavailable_reason = "http-401" |
    .jev_verdict = null | .confidence = null | .used_jev = false | .agreement = null |
    .jev_answers = {} | .jev_probabilities = {} | .jev_flagged = [] |
    .final_decision = null | .eventual_outcome = null | .label_source = null |
    .available = false' > "$ledger"
  "$JEV" validate-ledger "$ledger" || fail "a failed-attempt row does not satisfy the ledger schema"
  out=$($REPORT "$ledger") || fail "report rejected a ledger of failed attempts"
  assert_contains "$out" "reason=http-401 kind=failed-attempt count=1" \
    "a revoked key is named on no report section: $out"
  pass "Jev report: an attempt that reached the service and failed is named, not just counted"
}

test_report_fixture_and_empty_error() {
  local out rc=0 empty="$TMP_ROOT/empty-ledger" malformed="$TMP_ROOT/malformed-ledger"
  out=$($REPORT "$ROOT/tests/fixtures/jev-ledger.jsonl") || fail "report rejected the valid fixture ledger"
  assert_contains "$out" "jev configuration:" "report did not open with the effective configuration"
  assert_contains "$out" "TYPESAFE_API_KEY=" "report did not state whether a key is present"
  assert_contains "$out" $'overall\t3\t3\t0\t1\t33.33%\t1\t1\t0.000126\t6000\t1' \
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
test_mixed_confidence_batch_is_gated_per_item
test_commit_request_builder
test_commit_lint_truncates_instead_of_skipping
test_active_advisories_never_touch_task_status
test_open_questions_request_builder
test_shared_page_is_sent_once
test_oversized_material_splits_and_truncates
test_one_page_cited_by_every_question_is_not_duplicated
test_split_that_cannot_finish_is_never_started
test_failed_split_part_is_not_rendered_as_a_classification
test_unfittable_question_is_refused_with_a_row
test_oversized_shared_report_is_shrunk_not_duplicated
test_shared_report_under_budget_is_still_not_duplicated
test_oversized_accept_check_is_one_request_and_one_row
test_small_global_cap_keeps_every_use_reachable
test_ledger_rotates_monthly_and_report_reads_archives
test_consult_does_not_read_the_whole_ledger
test_shadow_presentation_hooks
test_unchanged_presentation_is_consulted_once
test_presentation_overflow_is_consulted_on_next_drain
test_unreadable_day_scan_refuses_instead_of_spending
test_observer_gate_requires_a_usable_key
test_model_family_and_mismatch
test_report_fixture_and_empty_error
test_report_scores_discarded_labels_as_the_negative_class
test_report_names_failed_network_attempts
test_report_lists_per_key_outcome_mismatches
test_report_names_only_the_differing_items_of_a_batch
test_report_derives_differing_items_for_an_old_row

printf 'all fm-jev tests passed\n'
