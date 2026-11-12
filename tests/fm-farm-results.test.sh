#!/usr/bin/env bash
# tests/fm-farm-results.test.sh - firstmate pulls finished farm results itself.
#
# Drives the real bin/fm-farm-results.py sweep against a stand-in `testfarm
# status --json` and the real bin/fm-send.sh (shell inbox and Playbot lane
# planes), and pins:
#   1. A result with no delivery hook reaches its task once, with the farm's
#      exact completion body, and a repeat sweep sends nothing more.
#   2. De-duplication against the hook: a result the hook already delivered,
#      with the same body or a differing one, is never sent again, and a hooked
#      result waits out the grace before the sweep delivers it.
#   3. A result the task has moved past (it already holds the result of a request
#      submitted after this one finished) is never delivered late, while
#      requests that ran side by side are both delivered; a lane task receives
#      its result through the lane chat exactly once.
#   4. Known-bad requests are never delivered: another home's request, a task
#      with no record here, a malformed task label, and history finished before
#      the home's first sweep.
#   5. Open requests for this home's tasks are written to the open-request file,
#      an unreadable farm leaves it untouched, and a failed send is reported
#      once and retried silently.
#   6. bin/fm-test-service.py submit refuses a request with no task label (or a
#      malformed one) before the farm sees it, and passes labeled submits and
#      other commands through unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_test_require_node "fm-farm-results"

SWEEP="$ROOT/bin/fm-farm-results.py"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-farm-results)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

FAKE_TOOL="$TMP_ROOT/fake-lanes.mjs"
cat >"$FAKE_TOOL" <<'JS'
import fs from "node:fs";
const input = fs.readFileSync(0, "utf8");
fs.appendFileSync(process.env.FAKE_LANES_LOG, JSON.stringify(JSON.parse(input)) + "\n");
const value = { thread: {}, delivery: { state: "delivered" } };
console.log(JSON.stringify({ content: [{ type: "text", text: JSON.stringify(value) }], structuredContent: value }));
JS

setup_case() { # <name> -> case dir with shell task t1, lane task lane1, a fake farm, and an old baseline
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/fakebin" "$dir/farm-state"
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"
  fm_write_meta "$dir/home/state/lane1.meta" "kind=lane" "playbot_project=project_abc" \
    "playbot_workspace=ws_123" "playbot_thread=chat-lane-1" "mode=local-only"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/fakebin/tmux"
  cat >"$dir/fakebin/testfarm" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_FARM_EXIT:-}" ] || exit "$FAKE_FARM_EXIT"
cat "$FAKE_FARM_JSON"
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/testfarm"
  # Under the minimum-runtime consumer, every bash shebang resolves to stock Bash.
  [ -z "${FM_STOCK_BASH_BIN:-}" ] || ln -s "$FM_STOCK_BASH_BIN" "$dir/fakebin/bash"
  printf '%s\n' "$(( $(date +%s) - 86000 ))" >"$dir/home/state/.farm-results-baseline"
  : >"$dir/lanes.log"
  printf '%s\n' "$dir"
}

# farm <case-dir> <row-spec>... : writes the fake status JSON. A row spec is
# id:task:state:finished-seconds-ago:hook(0|1)[:home[:submitted-seconds-ago]]; finished
# "-" means not finished, an empty home means this case's home, and submitted defaults to 4000.
farm() {
  local dir=$1
  shift
  python3 -I - "$dir" "$@" >"$dir/farm.json" <<'PY'
import json, sys, time
dir, specs = sys.argv[1], sys.argv[2:]
now = time.time()
rows = []
for spec in specs:
    rid, task, state, ago, hook, *rest = spec.split(":")
    opts = {"task": task}
    if hook == "1":
        opts["home"] = rest[0] if rest and rest[0] else dir + "/home"
        opts["notify"] = {"command": ["/bin/true"], "env": {}}
    rows.append({"id": rid, "task": task, "state": state, "sha": "a" * 40, "original_sha": "a" * 40,
                 "error": "suite: 2 failed\nmore" if state == "failed" else None,
                 "submitted": now - int(rest[1] if len(rest) > 1 else 4000), "finished": None if ago == "-" else now - int(ago), "options": opts})
print(json.dumps({"schema": "fm-test-service.v1", "requests": rows}))
PY
}

run_sweep() { # <case-dir> [env...]
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_TEST_SERVICE_STATE="$dir/farm-state" FAKE_FARM_JSON="$dir/farm.json" \
    FM_PLAYBOT_LANES_TOOL="$FAKE_TOOL" FAKE_LANES_LOG="$dir/lanes.log" FM_SEND_SETTLE=0 \
    "$@" python3 "$SWEEP" sweep --force >"$dir/out" 2>"$dir/err"
}

hook_send() { # <case-dir> <task> <text>: the farm hook's own fm-send call
  env PATH="$1/fakebin:$PATH" FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/home/state" FM_SEND_SETTLE=0 \
    FM_SEND_IDEMPOTENT=1 FM_PLAYBOT_LANES_TOOL="$FAKE_TOOL" FAKE_LANES_LOG="$1/lanes.log" \
    "$SEND" "$2" "$3" >/dev/null 2>&1
}

records() { # <case-dir> <task>: count of inbox records, pending and handled
  find "$1/home/state/$2.inbox" -name '*.msg' -type f 2>/dev/null | wc -l | tr -d ' '
}

expected_body() { # <request-id> <state> <receipt> <first-failure>
  printf 'Test service completion: request=%s state=%s sha=%s receipt=%s\nfirst_failure=%s\nResume this request'"'"'s work using this result; do not resubmit or poll it.' \
    "$1" "$2" "$(printf 'a%.0s' $(seq 40))" "$3" "$4"
}

test_unhooked_result_delivered_once() {
  local dir rc body
  dir=$(setup_case unhooked)
  farm "$dir" "r1:t1:failed:30:0"
  run_sweep "$dir"
  rc=$?
  expect_code 0 "$rc" "sweep should succeed: $(cat "$dir/err")"
  [ "$(records "$dir" t1)" = 1 ] || fail "an unhooked result should land in its task inbox once, got $(records "$dir" t1)"
  body=$(. "$ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_body "$dir/home/state/t1.inbox/001.msg")
  assert_equals "$(expected_body r1 failed - 'suite: 2 failed')" "$body" "the sweep must send the farm's exact completion body"
  run_sweep "$dir"
  [ "$(records "$dir" t1)" = 1 ] || fail "a repeat sweep must not deliver the same result twice"
  mkdir -p "$dir/home/state/t1.inbox/handled"
  mv "$dir/home/state/t1.inbox/001.msg" "$dir/home/state/t1.inbox/handled/"
  rm -f "$dir/home/state/.farm-results-delivered"
  run_sweep "$dir"
  [ "$(records "$dir" t1)" = 1 ] || fail "an acknowledged result must not be redelivered even without the sweep ledger"
  [ ! -s "$dir/out" ] || fail "a delivered result should print nothing: $(cat "$dir/out")"
  pass "fm-farm-results: an unhooked result reaches its task once with the farm's exact body"
}

test_dedup_against_hook() {
  local dir
  dir=$(setup_case dedup-same)
  farm "$dir" "r2:t1:passed:300:1"
  hook_send "$dir" t1 "$(expected_body r2 passed - -)" || fail "the hook's own send should succeed"
  rm -f "$dir/home/state/.farm-results-delivered"
  run_sweep "$dir"
  [ "$(records "$dir" t1)" = 1 ] || fail "a result the hook delivered must not be sent again, got $(records "$dir" t1)"

  dir=$(setup_case dedup-differs)
  farm "$dir" "r3:t1:passed:300:1"
  hook_send "$dir" t1 "Test service completion: request=r3 state=passed sha=x receipt=/moved/elsewhere" ||
    fail "the hook's own send should succeed"
  run_sweep "$dir"
  [ "$(records "$dir" t1)" = 1 ] || fail "a hook delivery with a differing body must still block a second delivery"

  dir=$(setup_case grace)
  farm "$dir" "r4:t1:passed:10:1"
  run_sweep "$dir"
  [ "$(records "$dir" t1)" = 0 ] || fail "a hooked result inside its grace must be left to the hook"
  run_sweep "$dir" FM_FARM_RESULTS_GRACE=0
  [ "$(records "$dir" t1)" = 1 ] || fail "a hooked result past its grace that the hook never delivered must be delivered"
  hook_send "$dir" t1 "$(expected_body r4 passed - -)"
  [ "$(records "$dir" t1)" = 1 ] || fail "a late hook delivery of the same result must collapse into the sweep's record"
  pass "fm-farm-results: hook deliveries are never duplicated, and a missed hook is covered after its grace"
}

test_superseded_result_not_delivered() {
  local dir
  dir=$(setup_case superseded)
  # s-old finished 3000s ago; the task already holds s-new, submitted 2000s ago.
  farm "$dir" "s-old:t1:failed:3000:0::3500" "s-new:t1:passed:1000:1::2000"
  hook_send "$dir" t1 "$(expected_body s-new passed - -)" || fail "the hook's own send should succeed"
  run_sweep "$dir"
  [ "$(records "$dir" t1)" = 1 ] || fail "a result the task has moved past must not be delivered late"

  dir=$(setup_case side-by-side)
  # p-a and p-b ran together: p-b (submitted later) is already held, p-a finished after p-b was submitted.
  farm "$dir" "p-a:t1:passed:100:0::3000" "p-b:t1:passed:1000:1::2000"
  hook_send "$dir" t1 "$(expected_body p-b passed - -)" || fail "the hook's own send should succeed"
  run_sweep "$dir"
  [ "$(records "$dir" t1)" = 2 ] || fail "requests that ran side by side must both be delivered"

  dir=$(setup_case two-unheld)
  # Neither is held: the newer is delivered and settles the older it supersedes.
  farm "$dir" "u-old:t1:failed:3000:0::3500" "u-new:t1:passed:100:0::2000"
  run_sweep "$dir"
  [ "$(records "$dir" t1)" = 1 ] || fail "only the newer of two sequential unheld results should be delivered"
  assert_contains "$(cat "$dir"/home/state/t1.inbox/*.msg)" "request=u-new " "the newer result should be the one delivered"
  pass "fm-farm-results: a result the task has moved past is settled unsent, side-by-side results both arrive"
}

test_lane_result_delivered_once() {
  local dir
  dir=$(setup_case lane)
  farm "$dir" "r5:lane1:passed:30:0"
  run_sweep "$dir" || fail "sweep should succeed: $(cat "$dir/err")"
  [ "$(wc -l <"$dir/lanes.log" | tr -d ' ')" = 1 ] || fail "a lane result should reach its chat once"
  assert_contains "$(cat "$dir/lanes.log")" '"thread":"chat-lane-1"' "the lane's recorded thread should be addressed"
  rm -f "$dir/home/state/.farm-results-delivered"
  run_sweep "$dir"
  [ "$(wc -l <"$dir/lanes.log" | tr -d ' ')" = 1 ] || fail "a lane result already in the lane chat must not be resent"
  pass "fm-farm-results: a lane result reaches the lane chat exactly once"
}

test_known_bad_requests_rejected() {
  local dir
  dir=$(setup_case known-bad)
  farm "$dir" "r6:t1:passed:300:1:/some/other/home" "r7:gone:passed:30:0" "r8:../t1:passed:30:0" "r9:t1:passed:90000:0"
  run_sweep "$dir" || fail "sweep should succeed: $(cat "$dir/err")"
  [ "$(records "$dir" t1)" = 0 ] || fail "another home's request, a malformed label, or pre-baseline history must not be delivered"
  [ ! -e "$dir/home/state/gone.inbox" ] || fail "a task with no record in this home must not receive a result"

  dir=$(setup_case first-sweep)
  rm -f "$dir/home/state/.farm-results-baseline"
  farm "$dir" "r10:t1:passed:60:0"
  run_sweep "$dir"
  [ "$(records "$dir" t1)" = 0 ] || fail "the first sweep must record a baseline and never replay finished history"
  [ -s "$dir/home/state/.farm-results-baseline" ] || fail "the first sweep should record its baseline"
  pass "fm-farm-results: other homes, unknown tasks, malformed labels, and history are never delivered"
}

test_open_requests_and_failures() {
  local dir open
  dir=$(setup_case open)
  farm "$dir" "o1:t1:queued:-:1" "o2:lane1:running:-:0" "o3:gone:running:-:0" "o4:t1:passed:30:0"
  run_sweep "$dir" || fail "sweep should succeed: $(cat "$dir/err")"
  open=$(cat "$dir/home/state/.farm-open-requests")
  assert_equals "fm-farm-open.v1
t1 o1 queued
lane1 o2 running" "$open" "only this home's open requests should be listed"
  FAKE_FARM_EXIT=1 run_sweep "$dir"
  [ ! -s "$dir/out" ] || fail "an unreadable farm should print nothing"
  assert_equals "$open" "$(cat "$dir/home/state/.farm-open-requests")" "an unreadable farm must leave the last open-request file to age out"

  dir=$(setup_case send-fails)
  fm_write_meta "$dir/home/state/t1.meta" "kind=ship" "harness=claude"
  farm "$dir" "f1:t1:failed:30:0"
  run_sweep "$dir"
  assert_contains "$(cat "$dir/out")" "farm-result undelivered task=t1 request=f1:" "a failed send should be reported"
  run_sweep "$dir"
  [ ! -s "$dir/out" ] || fail "a failed send is reported once, then retried silently"
  pass "fm-farm-results: open requests are listed, an unreadable farm changes nothing, and send failures report once"
}

run_submit() { # <case-dir> <args...>: the shim against a stand-in farm checkout
  local dir=$1
  shift
  env TESTFARM_CHECKOUT="$dir/farm" FM_HOME="$dir" python3 "$ROOT/bin/fm-test-service.py" "$@" 2>"$dir/err"
}

test_submit_requires_task_label() {
  local dir="$TMP_ROOT/submit"
  mkdir -p "$dir/farm/compat"
  printf '%s\n' 'import sys' \
    'with open(sys.argv[0] + ".log", "a") as log:' \
    '    log.write(" ".join(sys.argv[1:]) + "\n")' >"$dir/farm/compat/fm-test-service.py"
  run_submit "$dir" submit frogpile /w abc --suite && fail "a submit with no task label must be refused"
  assert_contains "$(cat "$dir/err")" "submit requires --task" "the refusal should name the missing label"
  run_submit "$dir" submit frogpile /w abc --task "" --suite && fail "an empty task label must be refused"
  run_submit "$dir" submit frogpile /w abc --task --suite && fail "a task flag swallowing the next option must be refused"
  run_submit "$dir" submit frogpile /w abc --task=../x && fail "a malformed task label must be refused"
  [ ! -e "$dir/farm/compat/fm-test-service.py.log" ] || fail "a refused submit must never reach the farm"
  run_submit "$dir" submit frogpile /w abc --task t1 --suite || fail "a labeled submit should pass through: $(cat "$dir/err")"
  run_submit "$dir" status --json || fail "other commands need no label"
  assert_equals "submit frogpile /w abc --task t1 --suite
status --json" "$(cat "$dir/farm/compat/fm-test-service.py.log")" "labeled submits and other commands should reach the farm unchanged"
  pass "fm-test-service: submit refuses a missing or malformed task label before the farm sees it"
}

test_unhooked_result_delivered_once
test_dedup_against_hook
test_superseded_result_not_delivered
test_lane_result_delivered_once
test_known_bad_requests_rejected
test_open_requests_and_failures
test_submit_requires_task_label
