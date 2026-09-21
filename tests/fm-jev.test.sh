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
  assert_contains "$out" "reason=daily-call-cap refused=1" "the report does not show why nothing ran"
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
  make_big_questions_fixture "$home" 20000
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
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "split rows failed schema validation"
  pass "Jev client: an over-budget envelope is split per question and shortened, never silently dropped"
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
    .[0].unavailable_reason == "per-call-token-cap" and .[0].use == "open-questions"' \
    "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "an unfittable question left no evidence on any surface"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "the refusal row failed schema validation"
  out=$(FM_HOME="$home" "$REPORT" "$home/state/jev-ledger.jsonl") || fail "report rejected the refusal ledger"
  assert_contains "$out" "reason=per-call-token-cap refused=1" "the report hides an oversized refusal"
  pass "Jev client: a question too large even alone is refused with a recorded reason, not silence"
}

test_oversized_accept_check_still_reviews() {
  local home="$TMP_ROOT/accept-big" before
  write_config "$home" shadow off off off 100 2000
  write_key "$home"
  make_accept_fixture "$home"
  awk 'BEGIN { while (length(out) < 20000) out = out "Changed bin/example.sh and ran tests/example.test.sh. "; print out }' \
    > "$home/data/task-a/report.md"
  before=$(request_count)
  jev_env "$home" "$ACCEPT" task-a
  [ -s "$home/data/task-a/acceptance.json" ] || fail "an oversized report produced no acceptance record"
  jq -e '(.criteria | length) == 2 and .verdict == "accepted"' "$home/data/task-a/acceptance.json" >/dev/null \
    || fail "the oversized acceptance record lost a criterion"
  [ "$(request_count)" -eq $((before + 2)) ] || fail "the oversized acceptance check did not split per criterion"
  jq -e -s 'length == 2 and all(.[]; .truncated == true and .use == "accept-check")' \
    "$home/state/jev-ledger.jsonl" >/dev/null \
    || fail "the oversized acceptance rows do not record their shortening"
  "$JEV" validate-ledger "$home/state/jev-ledger.jsonl" || fail "oversized acceptance rows failed validation"
  pass "Jev acceptance adapter: an oversized report is split and shortened by the client, not skipped"
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
  pass "Jev report: a discarded task scores as a negative label and an unlabelled row stays apart"
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
test_unfittable_question_is_refused_with_a_row
test_oversized_accept_check_still_reviews
test_small_global_cap_keeps_every_use_reachable
test_ledger_rotates_monthly_and_report_reads_archives
test_consult_does_not_read_the_whole_ledger
test_shadow_presentation_hooks
test_model_family_and_mismatch
test_report_fixture_and_empty_error
test_report_scores_discarded_labels_as_the_negative_class

printf 'all fm-jev tests passed\n'
