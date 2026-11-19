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
if (process.env.FAKE_LANES_DELAY) await new Promise(resolve => setTimeout(resolve, Number(process.env.FAKE_LANES_DELAY)));
const value = { thread: {}, delivery: { state: process.env.FAKE_LANES_VERDICT || "delivered" } };
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
  # A child shell, so the sourced library's own variables never shadow this test's.
  body=$(bash -c '. "$1" && fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$dir/home/state/t1.inbox/001.msg")
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

# The independently supervised service uses the same executable delivery path;
# these tests never start fm-watch.sh or a supervisor chat.
run_notifier() {
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE=/must/not/be/used \
    FM_TESTFARM_BIN="$dir/fakebin/testfarm" FAKE_FARM_JSON="$dir/farm.json" \
    FM_PLAYBOT_LANES_TOOL="$FAKE_TOOL" FAKE_LANES_LOG="$dir/lanes.log" FM_SEND_SETTLE=0 \
    FM_FARM_RESULTS_SECS=5 "$@" python3 "$ROOT/bin/fm-farm-notifier.py" run-once >"$dir/service.out" 2>"$dir/service.err"
}

expire_cadence() {
  rm -f "$1/home/state/.last-farm-results-sweep"
}

test_independent_notifier_and_race() {
  local dir a b verdict
  dir=$(setup_case independent)
  farm "$dir" "auto-pass:lane1:passed:30:0" "auto-fail:lane1:failed:30:0" "auto-cancel:lane1:cancelled:30:0"
  run_notifier "$dir" || fail "notifier with no watcher should deliver: $(cat "$dir/service.err")"
  [ "$(wc -l <"$dir/lanes.log" | tr -d ' ')" = 3 ] || fail "all three terminal states must reach the same recorded worker"
  assert_contains "$(cat "$dir/lanes.log")" 'state=cancelled' "cancelled completion body must arrive"
  assert_contains "$(cat "$dir/service.out")" '"sent": 3' "service journal must include observed delivery counts"
  expire_cadence "$dir"
  run_notifier "$dir" || fail "restart should succeed"
  [ "$(wc -l <"$dir/lanes.log" | tr -d ' ')" = 3 ] || fail "service restart must not duplicate accepted results"

  for verdict in delivered queued unknown; do
    dir=$(setup_case "race-$verdict")
    farm "$dir" "race:lane1:passed:30:0"
    # Delay the real lane-call result so the second process contends during send.
    run_notifier "$dir" FAKE_LANES_DELAY=500 FAKE_LANES_VERDICT="$verdict" &
    a=$!
    run_sweep "$dir" FAKE_LANES_DELAY=500 FAKE_LANES_VERDICT="$verdict" &
    b=$!
    wait "$a" || fail "independent path failed"
    wait "$b" || fail "watcher fallback failed"
    [ "$(wc -l <"$dir/lanes.log" | tr -d ' ')" = 1 ] || fail "racing paths must send $verdict exactly once"
    [ "$(cat "$dir/home/state/.farm-results-delivered")" = race ] || fail "settlement must survive both writers"
  done
  pass "fm-farm-results: independent service delivers all terminal states and racing watcher sends once for delivered/queued/unknown"
}

test_independent_failures_and_retirement() {
  local dir
  dir=$(setup_case notifier-outage)
  farm "$dir" "retry:lane1:failed:30:0"
  run_notifier "$dir" FAKE_FARM_EXIT=1 && fail "service must journal farm outage as a failure"
  [ ! -s "$dir/lanes.log" ] || fail "outage must send nothing"
  expire_cadence "$dir"
  run_notifier "$dir" FAKE_LANES_VERDICT=failed || fail "service must retain refused delivery"
  assert_contains "$(cat "$dir/home/state/.farm-results-failed")" retry "refused result must remain retryable"
  # Once attempted, retry remains eligible beyond the ordinary history age window.
  farm "$dir" "retry:lane1:failed:90000:0"
  expire_cadence "$dir"
  run_notifier "$dir" || fail "retry after Playbot recovers should succeed"
  [ "$(wc -l <"$dir/lanes.log" | tr -d ' ')" = 2 ] || fail "one refused and one accepted attempt expected"
  [ "$(cat "$dir/home/state/.farm-results-delivered")" = retry ] || fail "recovered result must settle"
  expire_cadence "$dir"
  run_notifier "$dir" || fail "settled retry replay should succeed"
  [ "$(wc -l <"$dir/lanes.log" | tr -d ' ')" = 2 ] || fail "accepted retry must not be duplicated"

  dir=$(setup_case retired-notifier)
  farm "$dir" "retired:lane1:passed:30:0"
  rm "$dir/home/state/lane1.meta"
  run_notifier "$dir" || fail "retired task should be skipped safely"
  [ ! -s "$dir/lanes.log" ] || fail "retired task must not cause a guessed chat delivery"
  pass "fm-farm-results: independent outages retry, refused deliveries outlive the age window, retired tasks receive nothing"
}

test_notifier_unit_lifecycle() {
  local dir mode=${1:-existing}
  dir=$(setup_case "unit-lifecycle-$mode")
  farm "$dir" "unit-result:lane1:passed:30:0"
  if [ "$mode" = startup ]; then
    rm "$dir/home/state/.farm-results-baseline"
    farm "$dir" "unit-result:lane1:running:-:0"
  fi
  mkdir -p "$dir/receipts with % and dollar\$/results/unit-result"
  : >"$dir/receipts with % and dollar\$/results/unit-result/$(printf 'a%.0s' $(seq 40)).receipt"
  cat >"$dir/fakebin/loginctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_LINGER:-yes}"
SH
  # Stand-in user manager consumes the generated unit's Environment and
  # ExecStart as systemd would. It runs delivery without starting a watcher.
  cat >"$dir/fakebin/systemctl" <<'PYTHON'
#!/usr/bin/env python3
import configparser, json, os, pathlib, shlex, subprocess, sys, time
args = sys.argv[1:]
with open(os.environ["MANAGER_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
if "enable" in args:
    service = pathlib.Path(os.environ["XDG_CONFIG_HOME"]) / "systemd/user" / args[-1].replace(".timer", ".service")
    unit = configparser.ConfigParser(interpolation=None)
    unit.read(service)
    env = dict(os.environ)
    # A user manager does not inherit the invoking terminal's optional setting.
    env.pop("FM_TEST_SERVICE_STATE", None)
    env.update(value.replace("%%", "%").split("=", 1) for value in shlex.split(unit["Service"]["Environment"]))
    if os.environ["UNIT_TEST_MODE"] == "startup":
        baseline = pathlib.Path(env["FM_HOME"]) / "state/.farm-results-baseline"
        assert baseline.is_file(), "timer activated before completion eligibility existed"
        data = pathlib.Path(os.environ["FAKE_FARM_JSON"])
        status = json.loads(data.read_text())
        finished = time.time()
        status["requests"][0].update(state="passed", finished=finished)
        data.write_text(json.dumps(status))
        # Cross a whole second before the first sweep. A late baseline would
        # exclude this completion instead of accidentally passing by rounding.
        while int(time.time()) <= finished:
            time.sleep(0.01)
    command = [arg.replace("%%", "%").replace("$$", "$") for arg in shlex.split(unit["Service"]["ExecStart"])]
    sys.exit(subprocess.run(command, env=env).returncode)
if "show" in args:
    print("ActiveState=inactive\nResult=success\nExecMainStatus=0")
else:
    print("active")
PYTHON
  chmod +x "$dir/fakebin/loginctl" "$dir/fakebin/systemctl"
  # Spaces, percent and dollar signs must survive systemd's unit-value parsing.
  mkdir -p "$dir/home with % and dollar\$"
  mv "$dir/home/state" "$dir/home with % and dollar\$/state"
  mv "$dir/home" "$dir/unused-home"
  ln -s "$dir/home with % and dollar\$" "$dir/home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" XDG_CONFIG_HOME="$dir/units" \
    UNIT_TEST_MODE="$mode" FM_TEST_SERVICE_STATE="$dir/receipts with % and dollar\$" \
    MANAGER_LOG="$dir/manager.log" FAKE_FARM_JSON="$dir/farm.json" \
    FM_PLAYBOT_LANES_TOOL="$FAKE_TOOL" FAKE_LANES_LOG="$dir/lanes.log" \
    python3 "$ROOT/bin/fm-farm-notifier.py" install >"$dir/install.out" 2>"$dir/install.err" ||
    fail "generated service must execute its own delivery: $(cat "$dir/install.err")"
  [ "$(wc -l <"$dir/lanes.log" | tr -d ' ')" = 1 ] || fail "manager must deliver without any watcher/chat process"
  assert_contains "$(cat "$dir/lanes.log")" "receipt=$dir/receipts with % and dollar\$/results/unit-result/" \
    "the service must retain the configured receipt path without inheriting the submitter's environment"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze --user verify "$dir/units/systemd/user/"*.service "$dir/units/systemd/user/"*.timer >"$dir/verify.out" 2>&1 ||
      fail "systemd must accept generated units: $(cat "$dir/verify.out")"
  else
    echo "skip - fm-farm-results: systemd unit parser unavailable on this platform"
  fi
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" XDG_CONFIG_HOME="$dir/units" \
    MANAGER_LOG="$dir/manager.log" python3 "$ROOT/bin/fm-farm-notifier.py" status >"$dir/status.out" || fail "unit status failed"
  assert_contains "$(cat "$dir/status.out")" 'linger=yes' "status must expose logout persistence"
  assert_contains "$(cat "$dir/status.out")" 'journalctl --user' "status must expose journal inspection"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" XDG_CONFIG_HOME="$dir/units" \
    MANAGER_LOG="$dir/manager.log" python3 "$ROOT/bin/fm-farm-notifier.py" uninstall >"$dir/uninstall.out" || fail "unit uninstall failed"
  [ "$(find "$dir/units" -type f | wc -l | tr -d ' ')" = 0 ] || fail "uninstall must remove units"
  [ -s "$dir/home/state/.farm-results-delivered" ] || fail "uninstall must retain delivery deduplication"
  # Known-bad persistence fixture: no lingering means install must reject it.
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" XDG_CONFIG_HOME="$dir/units" \
    MANAGER_LOG="$dir/manager.log" FAKE_LINGER=no python3 "$ROOT/bin/fm-farm-notifier.py" install \
    >"$dir/bad.out" 2>"$dir/bad.err" && fail "installation without logout/reboot persistence must be refused"
  assert_contains "$(cat "$dir/bad.err")" 'loginctl enable-linger' "bad configuration must identify remedy"
  [ "$(find "$dir/units" -type f | wc -l | tr -d ' ')" = 0 ] || fail "rejected install must publish no units"
  pass "fm-farm-results: $mode installation delivers with retained receipt configuration, valid systemd units and guarded lifecycle"
}

test_unhooked_result_delivered_once
test_dedup_against_hook
test_superseded_result_not_delivered
test_lane_result_delivered_once
test_known_bad_requests_rejected
test_open_requests_and_failures
test_submit_requires_task_label
test_independent_notifier_and_race
test_independent_failures_and_retirement
test_notifier_unit_lifecycle
test_notifier_unit_lifecycle startup
