#!/usr/bin/env bash
# tests/fm-lane-send.test.sh - durable-producer delivery into a Playbot lane.
#
# The test service's completion hook calls fm-send.sh <task> <text> under
# FM_SEND_IDEMPOTENT=1 and treats exit 0 as delivered and any other nonzero as
# "retry, then raise the undelivered check wake". A kind=lane task has no shell
# endpoint, so fm-send hands that notice to bin/fm-lane-send.sh, which sends it
# into the lane's chat through fm-playbot-lanes.mjs send_message. These tests
# drive the real fm-send executable with a stand-in lane tool and pin:
#   1. A lane completion reaches send_message with the lane's recorded project,
#      workspace, and thread, and the exact text; nothing lands in an inbox.
#   2. A shell task's completion still rides its steering inbox unchanged.
#   3. A failed verdict, a lane-tool error, or a record missing its thread exits
#      nonzero, so the producer's undelivered escalation still applies.
#   4. Queued and unknown verdicts exit 0 and are never resent; unknown also
#      queues one check wake.
#   5. A replay of the exact accepted body is not sent twice.
#   6. An ordinary (non-producer) send to a lane is still refused.
#   7. When a testfarm checkout is present (TESTFARM_CHECKOUT or the installed
#      testfarm command), its real completion hook delivers a lane completion
#      and, after a failed lane delivery, its escalation raises the undelivered
#      check wake; without one, or under the stock Bash consumer, this case
#      reports an explicit skip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_test_require_node "fm-lane-send"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-send)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stand-in for bin/fm-playbot-lanes.mjs: records each call's argv and stdin
# arguments, then answers like the real `call send_message` (or fails).
FAKE_TOOL="$TMP_ROOT/fake-lanes.mjs"
cat >"$FAKE_TOOL" <<'JS'
import fs from "node:fs";
const input = fs.readFileSync(0, "utf8");
fs.appendFileSync(process.env.FAKE_LANES_LOG, JSON.stringify({ argv: process.argv.slice(2), args: JSON.parse(input) }) + "\n");
if (process.env.FAKE_LANES_EXIT) {
  console.error("Playbot renderer is not reachable");
  process.exit(Number(process.env.FAKE_LANES_EXIT));
}
const state = process.env.FAKE_LANES_VERDICT || "delivered";
const value = state === "none" ? { thread: {} } : { thread: {}, delivery: { state } };
console.log(JSON.stringify({ content: [{ type: "text", text: JSON.stringify(value) }], structuredContent: value }, null, 2));
JS

setup_case() { # <name> -> echoes case dir with a lane task and a shell task
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/fakebin"
  fm_write_meta "$dir/home/state/lane1.meta" "kind=lane" "playbot_project=project_abc" \
    "playbot_workspace=ws_123" "playbot_thread=chat-lane-1" "mode=local-only"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/fakebin/tmux"
  chmod +x "$dir/fakebin/tmux"
  # Under the minimum-runtime consumer, every bash shebang resolves to stock Bash.
  [ -z "${FM_STOCK_BASH_BIN:-}" ] || ln -s "$FM_STOCK_BASH_BIN" "$dir/fakebin/bash"
  : >"$dir/lanes.log"
  printf '%s\n' "$dir"
}

producer_send() { # <case-dir> [env...] -- <task> <text>  (the completion hook's call)
  local dir=$1
  shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_PLAYBOT_LANES_TOOL="$FAKE_TOOL" FAKE_LANES_LOG="$dir/lanes.log" FM_SEND_SETTLE=0 \
    FM_SEND_IDEMPOTENT=1 ${envs[@]+"${envs[@]}"} "$SEND" "$@" >"$dir/out" 2>"$dir/err"
}

calls() { wc -l <"$1/lanes.log" | tr -d ' '; }

COMPLETION=$'test-service request=r-42 state=failed\nResume this request\'s work using this result; do not resubmit or poll it.'

test_lane_completion_goes_to_send_message() {
  local dir rc
  dir=$(setup_case lane-delivered)
  producer_send "$dir" -- lane1 "$COMPLETION"
  rc=$?
  expect_code 0 "$rc" "a delivered lane completion should exit 0: $(cat "$dir/err")"
  [ "$(calls "$dir")" = 1 ] || fail "expected one send_message call, got $(calls "$dir")"
  LOG="$dir/lanes.log" EXPECT="$COMPLETION" node -e '
const call = JSON.parse(require("fs").readFileSync(process.env.LOG, "utf8").trim());
const want = { project: "project_abc", workspace: "ws_123", thread: "chat-lane-1", message: process.env.EXPECT };
if (JSON.stringify(call.argv) !== JSON.stringify(["call", "send_message", "-"])) { console.error("argv", call.argv); process.exit(1); }
for (const [k, v] of Object.entries(want)) if (call.args[k] !== v) { console.error(k, call.args[k]); process.exit(1); }
' || fail "send_message did not receive the lane's recorded identity and exact text"
  [ ! -e "$dir/home/state/lane1.inbox" ] || fail "a lane completion must not be written to a shell inbox"
  pass "fm-lane-send: a lane completion goes to send_message with the lane's recorded project, workspace, and thread"
}

test_shell_task_unchanged() {
  local dir rc
  dir=$(setup_case shell)
  producer_send "$dir" -- t1 "$COMPLETION"
  rc=$?
  expect_code 0 "$rc" "a shell task completion should exit 0: $(cat "$dir/err")"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "a shell task completion should land in its steering inbox"
  [ "$(calls "$dir")" = 0 ] || fail "a shell task completion must never reach the lane tool"
  pass "fm-lane-send: a shell task's completion still rides its steering inbox"
}

test_failures_exit_nonzero() {
  local dir rc
  dir=$(setup_case failed-verdict)
  producer_send "$dir" FAKE_LANES_VERDICT=failed -- lane1 "$COMPLETION"
  rc=$?
  [ "$rc" -ne 0 ] || fail "a failed verdict must exit nonzero so the producer escalates"
  assert_contains "$(cat "$dir/err")" "Playbot refused" "a failed verdict should be named"
  producer_send "$dir" FAKE_LANES_VERDICT=delivered -- lane1 "$COMPLETION" ||
    fail "a retry after a failed verdict should be sent: $(cat "$dir/err")"
  [ "$(calls "$dir")" = 2 ] || fail "a failed verdict must stay eligible for the producer's retry"

  dir=$(setup_case tool-error)
  producer_send "$dir" FAKE_LANES_EXIT=1 -- lane1 "$COMPLETION"
  rc=$?
  [ "$rc" -ne 0 ] || fail "a lane-tool error must exit nonzero"
  assert_contains "$(cat "$dir/err")" "renderer is not reachable" "the tool's error should be surfaced"

  dir=$(setup_case no-verdict)
  producer_send "$dir" FAKE_LANES_VERDICT=none -- lane1 "$COMPLETION"
  rc=$?
  [ "$rc" -ne 0 ] || fail "a result with no readable verdict must exit nonzero"

  # Known-bad fixture: a lane record with no recorded thread is refused unsent.
  dir=$(setup_case no-thread)
  fm_write_meta "$dir/home/state/lane1.meta" "kind=lane" "playbot_project=project_abc"
  producer_send "$dir" -- lane1 "$COMPLETION"
  rc=$?
  [ "$rc" -ne 0 ] || fail "a lane record without playbot_thread must be refused"
  [ "$(calls "$dir")" = 0 ] || fail "a lane record without playbot_thread must not be guessed"
  assert_contains "$(cat "$dir/err")" "rather than guessing" "the refusal should say why"
  pass "fm-lane-send: failed, errored, unreadable, and identity-less deliveries exit nonzero for the producer's escalation"
}

test_queued_and_unknown_are_not_resent() {
  local dir rc wakes
  dir=$(setup_case queued)
  producer_send "$dir" FAKE_LANES_VERDICT=queued -- lane1 "$COMPLETION"
  rc=$?
  expect_code 0 "$rc" "a queued verdict exits 0: Playbot holds the message"
  producer_send "$dir" FAKE_LANES_VERDICT=queued -- lane1 "$COMPLETION" || fail "replay after queued failed"
  [ "$(calls "$dir")" = 1 ] || fail "a queued message must never be resent, got $(calls "$dir") calls"

  dir=$(setup_case unknown)
  producer_send "$dir" FAKE_LANES_VERDICT=unknown -- lane1 "$COMPLETION"
  rc=$?
  expect_code 0 "$rc" "an unknown verdict exits 0 and is not resent"
  producer_send "$dir" FAKE_LANES_VERDICT=unknown -- lane1 "$COMPLETION" || fail "replay after unknown failed"
  [ "$(calls "$dir")" = 1 ] || fail "an unknown verdict must never be resent"
  wakes=$(grep -c "lane-delivery-unconfirmed task=lane1" "$dir/home/state/.wake-queue" 2>/dev/null || true)
  [ "$wakes" = 1 ] || fail "an unknown verdict should queue exactly one check wake, got $wakes"
  pass "fm-lane-send: queued and unknown verdicts are never resent, and unknown queues one check wake"
}

test_replay_and_distinct_requests() {
  local dir
  dir=$(setup_case replay)
  producer_send "$dir" -- lane1 "$COMPLETION" || fail "first send failed"
  producer_send "$dir" -- lane1 "$COMPLETION" || fail "replay failed"
  [ "$(calls "$dir")" = 1 ] || fail "an exact replay must not be sent twice"
  producer_send "$dir" -- lane1 "test-service request=r-43 state=passed" || fail "distinct request failed"
  [ "$(calls "$dir")" = 2 ] || fail "a distinct completion must still be sent"
  pass "fm-lane-send: an exact replay is suppressed while a distinct completion is sent"
}

test_ordinary_lane_send_still_refused() {
  local dir rc
  dir=$(setup_case ordinary)
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_PLAYBOT_LANES_TOOL="$FAKE_TOOL" FAKE_LANES_LOG="$dir/lanes.log" \
    "$SEND" lane1 "please rebase" >/dev/null 2>"$dir/err"
  rc=$?
  [ "$rc" -ne 0 ] || fail "an ordinary send to a lane should still be refused"
  [ "$(calls "$dir")" = 0 ] || fail "an ordinary send must not reach the lane tool"
  assert_contains "$(cat "$dir/err")" "no backend target recorded" "the existing refusal should stand"
  pass "fm-lane-send: an ordinary steer to a lane keeps today's refusal"
}

farm_hook() {
  local farm=${TESTFARM_CHECKOUT:-} command
  if [ -z "$farm" ] && command=$(command -v testfarm 2>/dev/null); then
    farm=$(dirname "$(dirname "$(realpath "$command")")")
  fi
  [ -n "$farm" ] && [ -x "$farm/compat/firstmate-notify" ] && printf '%s\n' "$farm/compat/firstmate-notify"
}

test_real_farm_hook_delivers_and_escalates() {
  local hook dir rc
  if [ -n "${FM_STOCK_BASH_BIN:-}" ] || ! hook=$(farm_hook); then
    echo "skip - fm-lane-send: the real completion hook was not exercised (no testfarm checkout, or the stock Bash consumer)"
    return 0
  fi
  dir=$(setup_case farm-hook)
  printf '%s' "$COMPLETION" | env FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FIRSTMATE_BIN="$ROOT/bin" \
    FM_PLAYBOT_LANES_TOOL="$FAKE_TOOL" FAKE_LANES_LOG="$dir/lanes.log" TESTFARM_NOTIFY_TASK=lane1 \
    "$hook" deliver >/dev/null 2>"$dir/err"
  rc=$?
  expect_code 0 "$rc" "the farm hook should deliver a lane completion: $(cat "$dir/err")"
  [ "$(calls "$dir")" = 1 ] || fail "the farm hook did not reach send_message"

  dir=$(setup_case farm-hook-failed)
  printf '%s' "$COMPLETION" | env FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FIRSTMATE_BIN="$ROOT/bin" \
    FM_PLAYBOT_LANES_TOOL="$FAKE_TOOL" FAKE_LANES_LOG="$dir/lanes.log" FAKE_LANES_VERDICT=failed \
    TESTFARM_NOTIFY_TASK=lane1 "$hook" deliver >/dev/null 2>"$dir/err"
  rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] || fail "a failed lane delivery must read as retryable to the farm, got exit $rc"
  printf 'check: test-service completion undelivered task=lane1 request=r-42' | env FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FIRSTMATE_BIN="$ROOT/bin" TESTFARM_NOTIFY_TASK=lane1 \
    TESTFARM_NOTIFY_KEY="test-service-undelivered r-42" TESTFARM_NOTIFY_RECEIPT="$dir/receipt" \
    "$hook" escalate >/dev/null 2>"$dir/err" || fail "the farm escalation failed: $(cat "$dir/err")"
  grep -q "completion undelivered task=lane1" "$dir/home/state/.wake-queue" ||
    fail "a failed lane delivery should still raise the undelivered check wake"
  pass "fm-lane-send: the real farm hook delivers a lane completion and still escalates a failed one"
}

test_lane_completion_goes_to_send_message
test_shell_task_unchanged
test_failures_exit_nonzero
test_queued_and_unknown_are_not_resent
test_replay_and_distinct_requests
test_ordinary_lane_send_still_refused
test_real_farm_hook_delivers_and_escalates
