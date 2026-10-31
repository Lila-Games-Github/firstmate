#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
root=$(cd "$(dirname "$0")/.." && pwd -P)
svc=$root/bin/fm-test-service.py
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-service.XXXXXX")
server=
cleanup() { if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi; if [ "${KEEP_TEST_TMP:-0}" = 1 ]; then echo "test tmp: $tmp"; else rm -rf "$tmp"; fi; }
trap cleanup EXIT
trap 'echo "failed at line $LINENO: $BASH_COMMAND" >&2' ERR
export HOME=$tmp/home FM_HOME=$tmp/fm FM_TEST_SERVICE_STATE=$tmp/state EVENTS=$tmp/events
export FM_STATE_OVERRIDE=$FM_HOME/state
mkdir -p "$HOME/.config/firstmate" "$FM_HOME/config/test-service" "$FM_STATE_OVERRIDE" "$tmp/bin" "$tmp/project"
export PATH=$tmp/bin:$PATH
cat > "$tmp/bin/adb" <<'ADB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = devices ]; then
  echo 'List of devices attached'
  if [ -e "$HOME/online-devices" ]; then
    while read -r serial; do [ -z "$serial" ] || printf '%s\tdevice\n' "$serial"; done < "$HOME/online-devices"
  else
    printf 'S22\tdevice\nS21\tdevice\nM31\tdevice\n'
  fi
  exit 0
fi
[ "$1" = -s ]; serial=$2; shift 2
[ "$1" = shell ]; shift
case "$*" in
  'input keyevent KEYCODE_WAKEUP') exit 0 ;;
  'settings get global stay_on_while_plugged_in') echo 0 ;;
  'settings put global stay_on_while_plugged_in 2') exit 0 ;;
  'dumpsys window')
    if [ -e "$HOME/unlocked-$serial" ] || [ ! -e "$HOME/locked-$serial" ]; then echo 'isKeyguardShowing=false'; else echo 'isKeyguardShowing=true'; fi ;;
  '')
    input=$(cat)
    if [[ "$input" == *$'KEYCODE_1\ninput keyevent KEYCODE_2\ninput keyevent KEYCODE_3\ninput keyevent KEYCODE_4'* ]]; then touch "$HOME/unlocked-$serial"; fi ;;
  *) exit 1 ;;
esac
ADB
chmod +x "$tmp/bin/adb"
$svc install-unit > "$tmp/unit-path"
grep -q '^ExecStart=".*/bin/fm-test-service.py" serve$' "$(cat "$tmp/unit-path")"
cat > "$FM_HOME/config/test-service/fake.json" <<'JSON'
{"prepare":["prepare.sh"],"suite":["suite.sh"],"device":["phone.sh","--serial","{serial}"],"any_device":["phone.sh","--serial","any"],"phones":["S22","S21","M31"],"any_phones":["S22","S21"],"equivalent_phones":{"S22":["S21"],"S21":["S22"]},"landing_branch":"main","scenarios":{"smoke":["--smoke"]}}
JSON
cd "$tmp/project"
git init -q -b main
git config user.name Test
git config user.email test@example.com
cat > prepare.sh <<'PREPARE'
#!/usr/bin/env bash
echo "prepare-v1" >> "$EVENTS"
PREPARE
cat > suite.sh <<'SUITE'
#!/usr/bin/env bash
set -euo pipefail
if [ -e "$HOME/parallel-mode" ]; then
  [ -z "${FROGPILE_SUITE_LOCK_HELD:-}" ]
  echo "parallel-start:$PWD" >> "$EVENTS"
else
  echo "suite-start-v1" >> "$EVENTS"
fi
if [ -e "$HOME/parallel-mode" ]; then sleep 7; else sleep "${SUITE_SLEEP:-2}"; fi
if [ -e "$HOME/parallel-mode" ]; then
  echo "parallel-end:$PWD" >> "$EVENTS"
else
  echo "suite-end-v1" >> "$EVENTS"
fi
echo suite-end-v1
SUITE
cat > phone.sh <<'PHONE'
#!/usr/bin/env bash
serial=$2
[ "$serial" != any ] || serial=S22
echo "phone-start-v1:$serial:${3:-}" >> "$EVENTS"
if [ "$serial" = S22 ] && [ -e "$HOME/slow-phone" ]; then sleep 8; else sleep .2; fi
echo "phone-end-v1" >> "$EVENTS"
PHONE
cat > benchmark.sh <<'BENCH'
#!/usr/bin/env bash
echo "benchmark-v1" >> "$EVENTS"
BENCH
chmod +x prepare.sh suite.sh phone.sh benchmark.sh
git add . && git commit -qm v1
sha1=$(git rev-parse HEAD)
printf '\necho dirty-live-tree >&2; exit 1\n' >> suite.sh
"$svc" serve > "$tmp/server.log" 2>&1 & server=$!
request=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22 --scenario smoke --harness benchmark.sh --receipt "$tmp/pass.receipt" --retest-on-move)
$svc wait "$request" | grep -q "^passed $sha1"
# Preparation finishes before the suite and phone enter their queues.
[ "$(sed -n '1p' "$EVENTS")" = prepare-v1 ]
[ "$(sed -n '2p' "$EVENTS")" = suite-start-v1 ] || [ "$(sed -n '2p' "$EVENTS")" = phone-start-v1:S22:--smoke ]
[ "$(grep -n 'suite-end' "$EVENTS" | cut -d: -f1)" -gt "$(grep -n 'phone-start' "$EVENTS" | cut -d: -f1)" ]
[ "$(tail -1 "$EVENTS")" = benchmark-v1 ]
[ "$(cat "$tmp/pass.receipt")" = "$(printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0' "$sha1")" ]
# The same parser used by fm-merge-local accepts the output.
bash -c 'source "$1"; fm_health_receipt_read "$2" "$3"; [ "$FM_HEALTH_COUNT" = 0 ]' _ "$root/bin/fm-landing-health-lib.sh" "$tmp/pass.receipt" "$sha1"
python3 - "$FM_TEST_SERVICE_STATE/status.json" "$request" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert s['schema']=='fm-test-service.v1'
row=next(r for r in s['requests'] if r['id']==sys.argv[2])
assert row['state']=='passed'
assert {step['name'] for step in row['steps']}=={'prepare','suite','device','phone-prep','harness:benchmark.sh'}
assert all(step['state']=='passed' for step in row['steps'])
PY
git checkout -q -- suite.sh
# A landing branch that already contains the submitted commit stops retests and frees its copy.
cat > suite.sh <<'FAIL'
#!/usr/bin/env bash
echo 'FAIL fake-suite-test: expected green' >&2
exit 1
FAIL
chmod +x suite.sh
git add suite.sh && git commit -qm v2
sha2=$(git rev-parse HEAD)
for i in $(seq 1 300); do
  if python3 - "$FM_TEST_SERVICE_STATE/status.json" "$request" "$sha1" 2>/dev/null <<'PY'
import json,sys
row=next(r for r in json.load(open(sys.argv[1]))['requests'] if r['id']==sys.argv[2])
assert row['options']['retest_on_move'] is False
assert row['sha']==sys.argv[3] and row['generation']==0 and row['state']=='passed'
PY
  then break; fi
  sleep .2
done
[ "$i" -lt 300 ]
[ ! -e "$FM_TEST_SERVICE_STATE/repos/$request" ]
[ ! -e "$FM_TEST_SERVICE_STATE/runs/$request" ]
[ ! -e "$FM_TEST_SERVICE_STATE/rebase/$request" ]
# A failing suite records its first failing test and message for that exact SHA.
failing=$($svc submit fake "$PWD" "$sha2" --suite)
$svc wait "$failing" > "$tmp/failing.out" && exit 1 || true
[ -f "$FM_TEST_SERVICE_STATE/results/$failing/$sha2.failure.json" ]
grep -q 'fake-suite-test' "$FM_TEST_SERVICE_STATE/results/$failing/$sha2.failure.json"
# A locked phone with no configured PIN fails clearly.
touch "$HOME/locked-S22"
rm -f "$HOME/unlocked-S22"
locked=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$locked" > "$tmp/locked.out" && exit 1 || true
grep -q 'phone-locked: add S22' "$tmp/locked.out"
# A private per-phone PIN unlocks the fake device without recording the secret.
printf 'S22=1234\n' > "$HOME/.config/firstmate/test-device-pins"
chmod 644 "$HOME/.config/firstmate/test-device-pins"
insecure=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$insecure" > "$tmp/insecure.out" && exit 1 || true
grep -q 'mode-600 private file' "$tmp/insecure.out"
chmod 600 "$HOME/.config/firstmate/test-device-pins"
unlocked=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$unlocked" | grep -q '^passed '
[ -e "$HOME/unlocked-S22" ]
# A finished request without landing retests keeps its logs and results but no test copies.
for i in $(seq 1 100); do
  [ -e "$FM_TEST_SERVICE_STATE/repos/$unlocked" ] || [ -e "$FM_TEST_SERVICE_STATE/runs/$unlocked" ] || break
  sleep .1
done
[ ! -e "$FM_TEST_SERVICE_STATE/repos/$unlocked" ]
[ ! -e "$FM_TEST_SERVICE_STATE/runs/$unlocked" ]
[ -f "$FM_TEST_SERVICE_STATE/results/$unlocked/$sha1.receipt" ]
ls "$FM_TEST_SERVICE_STATE/logs/$unlocked"-0-suite.log > /dev/null
if grep -q '1234' "$FM_TEST_SERVICE_STATE/status.json" "$FM_TEST_SERVICE_STATE"/logs/*; then exit 1; fi
any_phone=$($svc submit fake "$PWD" "$sha1" --suite --device-gate any)
$svc wait "$any_phone" | grep -q '^passed '
grep -q '^phone-start-v1:S22:$' "$EVENTS"
printf 'S21\nM31\n' > "$HOME/online-devices"
fallback=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$fallback" | grep -q '^passed '
grep -q '^phone-start-v1:S21:$' "$EVENTS"
printf 'S22\nS21\n' > "$HOME/online-devices"
touch "$HOME/slow-phone"
before_s22=$(grep -c '^phone-start-v1:S22:$' "$EVENTS")
before_s21=$(grep -c '^phone-start-v1:S21:$' "$EVENTS")
disconnect=$($svc submit fake "$PWD" "$sha1" --device-gate S22)
for i in $(seq 1 300); do
  count=$(grep -c '^phone-start-v1:S22:$' "$EVENTS")
  [ "$count" -gt "$before_s22" ] && break
  sleep .05
done
[ "$count" -gt "$before_s22" ]
printf 'S21\n' > "$HOME/online-devices"
$svc wait "$disconnect" | grep -q '^passed '
rm "$HOME/slow-phone"
[ "$(grep -c '^phone-start-v1:S21:$' "$EVENTS")" -gt "$before_s21" ]
printf 'S21\n' > "$HOME/online-devices"
performance=$($svc submit fake "$PWD" "$sha1" --device-gate M31)
$svc wait "$performance" > "$tmp/performance.out" && exit 1 || true
grep -q 'device-unavailable: M31' "$tmp/performance.out"
: > "$HOME/online-devices"
offline=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$offline" > "$tmp/offline.out" && exit 1 || true
grep -q 'device-unavailable: S22' "$tmp/offline.out"
python3 - "$FM_TEST_SERVICE_STATE/status.json" "$offline" <<'PY'
import json,sys
status=json.load(open(sys.argv[1]))
assert any(a['id']==sys.argv[2] and 'no equivalent connected' in a['message'] for a in status['alerts'])
PY
rm "$HOME/online-devices"
rm "$HOME/unlocked-S22"
printf 'S22=9999\n' > "$HOME/.config/firstmate/test-device-pins"
wrong=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$wrong" > "$tmp/wrong.out" && exit 1 || true
grep -q 'phone-locked: could not unlock S22' "$tmp/wrong.out"
printf 'S22=1234\n' > "$HOME/.config/firstmate/test-device-pins"
# Requests enter the one runner in submission order.
first=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
second=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
# Keep the cancellation behind two earlier requests, so it is still queued.
queue=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc cancel "$queue"
$svc wait "$first" | grep -q '^passed '
$svc wait "$second" | grep -q '^passed '
python3 - "$FM_TEST_SERVICE_STATE/status.json" "$first" "$second" <<'PY'
import json,sys
rows={r['id']:r for r in json.load(open(sys.argv[1]))['requests']}
assert rows[sys.argv[2]]['seq'] < rows[sys.argv[3]]['seq']
assert rows[sys.argv[2]]['finished'] <= rows[sys.argv[3]]['started']
PY
# A queued cancellation remains terminal.
$svc wait "$queue" > "$tmp/cancel.out" && exit 1 || true
grep -q '^cancelled ' "$tmp/cancel.out"
for i in $(seq 1 150); do
  [ -e "$FM_TEST_SERVICE_STATE/repos/$queue" ] || break
  sleep .1
done
[ ! -e "$FM_TEST_SERVICE_STATE/repos/$queue" ]
# A killed daemon leaves a running request to rerun on restart.
before=$(grep -c 'suite-start-v1' "$EVENTS")
restart=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
for i in $(seq 1 300); do
  count=$(grep -c 'suite-start-v1' "$EVENTS")
  [ "$count" -ge "$((before + 1))" ] && break
  sleep .05
done
[ "$count" -eq "$((before + 1))" ]
kill -TERM "$server" 2>/dev/null || true
wait "$server" 2>/dev/null || true
server=
export SUITE_SLEEP=5
"$svc" serve > "$tmp/server2.log" 2>&1 & server=$!
for i in $(seq 1 300); do
  running=$(python3 - "$FM_TEST_SERVICE_STATE/status.json" "$restart" <<'PY'
import json,sys
print(next(r['state'] for r in json.load(open(sys.argv[1]))['requests'] if r['id']==sys.argv[2]))
PY
)
  [ "$running" = running ] && break
  sleep .05
done
time_before=$(python3 - "$FM_TEST_SERVICE_STATE/status.json" "$restart" <<'PY'
import json,sys
print(next(r['run_seconds'] for r in json.load(open(sys.argv[1]))['requests'] if r['id']==sys.argv[2]))
PY
)
sleep 2.3
$svc status --json > "$tmp/current-status.json"
python3 - "$tmp/current-status.json" "$restart" "$time_before" <<'PY'
import json,sys
now=next(r['run_seconds'] for r in json.load(open(sys.argv[1]))['requests'] if r['id']==sys.argv[2])
assert now > float(sys.argv[3])+1
PY
$svc wait "$restart" | grep -q '^passed '
[ "$(grep -c 'suite-start-v1' "$EVENTS")" -ge "$((before + 2))" ]
# A divergent edit to the same committed file reports a rebase conflict.
git clone --no-local -q "$tmp/project" "$tmp/conflict-project"
cd "$tmp/conflict-project"
git config user.name Test
git config user.email test@example.com
git checkout -q -B main "$sha1"
echo base > conflict.txt
git add conflict.txt && git commit -qm base
git checkout -qb feature
echo feature > conflict.txt
git add conflict.txt && git commit -qm feature
feature_sha=$(git rev-parse HEAD)
git checkout -q main
conflicted=$($svc submit fake "$PWD" "$feature_sha" --suite --device-gate S22 --retest-on-move)
$svc wait "$conflicted" | grep -q '^passed '
echo main > conflict.txt
git add conflict.txt && git commit -qm main-change
for i in $(seq 1 300); do
  state=$(python3 - "$FM_TEST_SERVICE_STATE/status.json" "$conflicted" <<'PY'
import json,sys
print(next(r['state'] for r in json.load(open(sys.argv[1]))['requests'] if r['id']==sys.argv[2]))
PY
)
  [ "$state" = conflict ] && break
  sleep .2
done
[ "$state" = conflict ]
# A passing retest of a rebased SHA keeps the worker's receipt on the submitted commit.
git clone --no-local -q "$tmp/project" "$tmp/receipt-project"
cd "$tmp/receipt-project"
git config user.name Test
git config user.email test@example.com
git checkout -q -B main "$sha1"
git checkout -qb feature
echo feature > feature.txt
git add feature.txt && git commit -qm feature
worker_sha=$(git rev-parse HEAD)
git checkout -q main
retested=$($svc submit fake "$PWD" "$worker_sha" --suite --receipt "$tmp/worker.receipt" --retest-on-move)
$svc wait "$retested" | grep -q "^passed $worker_sha"
echo landed > landed.txt
git add landed.txt && git commit -qm landed
for i in $(seq 1 300); do
  rebased_sha=$(python3 - "$FM_TEST_SERVICE_STATE/status.json" "$retested" "$worker_sha" 2>/dev/null <<'PY'
import json,sys
row=next(r for r in json.load(open(sys.argv[1]))['requests'] if r['id']==sys.argv[2])
assert row['generation']==1 and row['state']=='passed' and row['sha']!=sys.argv[3]
print(row['sha'])
PY
) && break
  sleep .2
done
[ -n "$rebased_sha" ]
[ "$(cat "$tmp/worker.receipt")" = "$(printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0' "$worker_sha")" ]
[ "$(cat "$FM_TEST_SERVICE_STATE/results/$retested/$rebased_sha.receipt")" = "$(printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0' "$rebased_sha")" ]
[ -d "$FM_TEST_SERVICE_STATE/repos/$retested" ]
# Landing the worker's change as a new commit stops further retests.
git cherry-pick "$worker_sha" > /dev/null
for i in $(seq 1 300); do
  if python3 - "$FM_TEST_SERVICE_STATE/status.json" "$retested" "$rebased_sha" 2>/dev/null <<'PY'
import json,sys
row=next(r for r in json.load(open(sys.argv[1]))['requests'] if r['id']==sys.argv[2])
assert row['options']['retest_on_move'] is False
assert row['generation']==1 and row['sha']==sys.argv[3] and row['state']=='passed'
PY
  then break; fi
  sleep .2
done
[ "$i" -lt 300 ]
[ ! -e "$FM_TEST_SERVICE_STATE/repos/$retested" ]
# Four clean copies run their full suites at once; the fifth waits for a slot.
cat > "$FM_HOME/config/test-service/fake.json" <<'JSON'
{"prepare":["prepare.sh"],"suite":["suite.sh"],"max_concurrent":4,"device":["phone.sh","--serial","{serial}"],"phones":["S22","S21"],"landing_branch":"main"}
JSON
touch "$HOME/parallel-mode"
cd "$tmp/project"
parallel_ids=()
for n in 1 2 3 4 5; do
  parallel_ids+=("$($svc submit fake "$PWD" "$sha1" --task "parallel-$n" --suite)")
done
for i in $(seq 1 300); do
  if python3 - "$FM_TEST_SERVICE_STATE/status.json" "${parallel_ids[4]}" "$sha1" 2>/dev/null <<'PY'
import json,sys
status=json.load(open(sys.argv[1]))
running=status['running_requests']
waiting=status['waiting_requests']
assert len(running)==4
assert {r['task'] for r in running}=={f'parallel-{n}' for n in range(1,5)}
assert all(r['sha']==sys.argv[3] and r['started'] and r['run_seconds']>=0 for r in running)
assert any(r['id']==sys.argv[2] and r['task']=='parallel-5' and r['state']=='queued' for r in waiting)
PY
  then break; fi
  sleep .05
done
[ "$i" -lt 300 ]
for id in "${parallel_ids[@]}"; do
  $svc wait "$id" | grep -q "^passed $sha1"
done
python3 - "$EVENTS" <<'PY'
from pathlib import Path
import sys
events=Path(sys.argv[1]).read_text().splitlines()
starts=[(i,e.split(':',1)[1]) for i,e in enumerate(events) if e.startswith('parallel-start:')]
ends=[i for i,e in enumerate(events) if e.startswith('parallel-end:')]
assert len(starts)==len(ends)==5
assert len({path for _,path in starts})==5
assert starts[3][0] < ends[0] < starts[4][0]
PY
# A restart requeues every in-flight parallel request from its pinned copy.
before_parallel=$(grep -c '^parallel-start:' "$EVENTS")
parallel_restart=()
for n in 1 2 3 4; do
  parallel_restart+=("$($svc submit fake "$PWD" "$sha1" --task "restart-parallel-$n" --suite)")
done
for i in $(seq 1 300); do
  count=$(python3 - "$FM_TEST_SERVICE_STATE/status.json" <<'PY'
import json,sys
status=json.load(open(sys.argv[1]))
print(sum(r['task'].startswith('restart-parallel-') for r in status['running_requests']))
PY
)
  [ "$count" -eq 4 ] && break
  sleep .05
done
[ "$count" -eq 4 ]
for i in $(seq 1 300); do
  started=$(grep -c '^parallel-start:' "$EVENTS")
  [ "$started" -ge "$((before_parallel + 4))" ] && break
  sleep .05
done
[ "$started" -ge "$((before_parallel + 4))" ]
kill -TERM "$server" 2>/dev/null || true
wait "$server" 2>/dev/null || true
server=
"$svc" serve > "$tmp/server3.log" 2>&1 & server=$!
for id in "${parallel_restart[@]}"; do
  $svc wait "$id" | grep -q "^passed $sha1"
done
[ "$(grep -c '^parallel-start:' "$EVENTS")" -ge "$((before_parallel + 8))" ]
# A project's concurrency comes only from its configuration, never from its name.
cat > "$FM_HOME/config/test-service/frogpile.json" <<'JSON'
{"suite":["suite.sh"],"device":["phone.sh","--serial","{serial}"],"phones":["S22"],"landing_branch":"main"}
JSON
named=()
for n in 1 2; do
  named+=("$($svc submit frogpile "$PWD" "$sha1" --task "named-$n" --suite)")
done
for i in $(seq 1 300); do
  if python3 - "$FM_TEST_SERVICE_STATE/status.json" 2>/dev/null <<'PY'
import json,sys
status=json.load(open(sys.argv[1]))
assert [r['task'] for r in status['running_requests'] if r['project']=='frogpile']==['named-1']
assert any(r['task']=='named-2' and r['state']=='queued' for r in status['waiting_requests'])
PY
  then break; fi
  sleep .05
done
[ "$i" -lt 300 ]
for id in "${named[@]}"; do
  $svc wait "$id" | grep -q "^passed $sha1"
done
rm "$FM_HOME/config/test-service/frogpile.json"
# The project suite entry point reports its script error to the service.
cat > suite.sh <<'SCRIPT_ERROR'
#!/usr/bin/env bash
echo 'SCRIPT ERROR: fake parse failure'
exit 1
SCRIPT_ERROR
git add suite.sh && git commit -qm v3
sha3=$(git rev-parse HEAD)
script_error=$($svc submit fake "$PWD" "$sha3" --task parallel-error --suite)
$svc wait "$script_error" > "$tmp/script-error.out" && exit 1 || true
grep -q 'SCRIPT ERROR: fake parse failure' "$FM_TEST_SERVICE_STATE/results/$script_error/$sha3.failure.json"

# Completion wakes use the real durable sender, with only its terminal stubbed.
# A failed terminal ring is harmless: the inbox and its normal re-ring ladder
# are still the delivery authority for every supported harness/backend.
cat > "$tmp/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$1" in
  display-message) echo fakepane ;;
  list-windows) echo fm-notify ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  send-keys) exit 1 ;;
esac
TMUX
chmod +x "$tmp/bin/tmux"
fm_write_meta "$FM_STATE_OVERRIDE/notify.meta" 'window=sess:fm-notify' 'kind=ship' 'harness=claude'
await_notice() {
  local id=$1 state=$2 attempt
  for ((attempt=0; attempt<300; attempt++)); do
    if python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$id" "$state" <<'PY'
import sqlite3,sys
row=sqlite3.connect(sys.argv[1]).execute('SELECT state FROM notifications WHERE request_id=?',(sys.argv[2],)).fetchone()
sys.exit(0 if row and row[0]==sys.argv[3] else 1)
PY
    then return; fi
    sleep .1
  done
  fail "notification $id did not become $state"
}
notify_pass=$($svc submit fake "$PWD" "$sha1" --task notify --suite --receipt "$tmp/notified.receipt")
$svc wait "$notify_pass" | grep -q "^passed $sha1"
await_notice "$notify_pass" delivered
notice="$FM_STATE_OVERRIDE/notify.inbox/001.msg"
grep -q "request=$notify_pass state=passed sha=$sha1 receipt=$tmp/notified.receipt" "$notice"
grep -q '^first_failure=-$' "$notice"
[ -f "$tmp/notified.receipt" ]

# Replay after a lost outbox acknowledgement and restart must deduplicate even
# when the worker already moved the completion into handled/.
mv "$notice" "$FM_STATE_OVERRIDE/notify.inbox/handled/"
kill -TERM "$server"; wait "$server"; server=
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$notify_pass" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE notifications SET state='pending',attempted=NULL WHERE request_id=?",(sys.argv[2],))
PY
"$svc" serve > "$tmp/notify-server.log" 2>&1 & server=$!
await_notice "$notify_pass" delivered
[ ! -e "$FM_STATE_OVERRIDE/notify.inbox/002.msg" ] || fail 'restart duplicated acknowledged completion'

notify_fail=$($svc submit fake "$PWD" "$sha3" --task notify --suite)
if $svc wait "$notify_fail" > "$tmp/notify-fail.out"; then fail 'known-bad suite passed'; fi
await_notice "$notify_fail" delivered
grep -q "request=$notify_fail state=failed sha=$sha3 receipt=-" "$FM_STATE_OVERRIDE/notify.inbox/002.msg"
grep -q '^first_failure=suite: SCRIPT ERROR: fake parse failure$' "$FM_STATE_OVERRIDE/notify.inbox/002.msg"

# A failed send must leave the run green and allow subsequent runs to finish.
fm_write_meta "$FM_STATE_OVERRIDE/retry.meta" 'window=sess:fm-notify' 'kind=ship' 'harness=claude'
: > "$FM_STATE_OVERRIDE/retry.inbox"
retry=$($svc submit fake "$PWD" "$sha1" --task retry --suite)
$svc wait "$retry" | grep -q "^passed $sha1"
for ((attempt=0; attempt<300; attempt++)); do
  grep -q "notification $retry:" "$tmp/notify-server.log" && break
  sleep .1
done
[ "$attempt" -lt 300 ] || fail 'failed send was not logged'
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$retry" <<'PY'
import sqlite3,sys
row=sqlite3.connect(sys.argv[1]).execute('SELECT state,error FROM notifications WHERE request_id=?',(sys.argv[2],)).fetchone()
assert row[0]=='pending' and 'inbox record could not be written' in row[1],row
PY
rm "$FM_STATE_OVERRIDE/retry.inbox"
await_notice "$retry" delivered
[ -f "$FM_STATE_OVERRIDE/retry.inbox/001.msg" ]
[ ! -f "$FM_STATE_OVERRIDE/retry.inbox/002.msg" ]

# Missing tasks never receive a steer and never fail the request.
missing=$($svc submit fake "$PWD" "$sha1" --task retired --suite)
$svc wait "$missing" | grep -q "^passed $sha1"
await_notice "$missing" skipped
[ ! -e "$FM_STATE_OVERRIDE/retired.inbox" ]
grep -q "notification $missing: task no longer exists; skipped" "$tmp/notify-server.log"

# Cancellation while the service is stopped persists a completion for recovery.
kill -TERM "$server"; wait "$server"; server=
cancelled=$($svc submit fake "$PWD" "$sha1" --task notify --suite)
$svc cancel "$cancelled"
# Simulate an older request/crash before outbox insertion: startup must recover.
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$cancelled" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('DELETE FROM notifications WHERE request_id=?',(sys.argv[2],))
PY
"$svc" serve > "$tmp/notify-server2.log" 2>&1 & server=$!
await_notice "$cancelled" delivered
grep -q "request=$cancelled state=cancelled sha=$sha1 receipt=-" "$FM_STATE_OVERRIDE/notify.inbox/003.msg"
$svc cancel "$cancelled"
kill -TERM "$server"; wait "$server"; server=
"$svc" serve > "$tmp/notify-server3.log" 2>&1 & server=$!
await_notice "$cancelled" delivered
[ ! -e "$FM_STATE_OVERRIDE/notify.inbox/004.msg" ] || fail 'duplicate completion sent twice'

running_cancel=$($svc submit fake "$PWD" "$sha1" --task notify --suite)
for ((attempt=0; attempt<300; attempt++)); do
  if $svc status --json | python3 -c 'import json,sys; r=next(r for r in json.load(sys.stdin)["requests"] if r["id"]==sys.argv[1]); sys.exit(0 if r["state"]=="running" else 1)' "$running_cancel"; then break; fi
  sleep .1
done
[ "$attempt" -lt 300 ] || fail 'cancellation fixture never started'
$svc cancel "$running_cancel"
if $svc wait "$running_cancel" > "$tmp/running-cancel.out"; then fail 'cancelled running request passed'; fi
await_notice "$running_cancel" delivered
grep -q "request=$running_cancel state=cancelled sha=$sha1 receipt=-" "$FM_STATE_OVERRIDE/notify.inbox/004.msg"

# A shared service delivers to the submitting home, even with a same-named task
# in the service's own home. No ambient state override may redirect the send.
other_home="$tmp/other-home"
mkdir -p "$other_home/config/test-service" "$other_home/state"
cp "$FM_HOME/config/test-service/fake.json" "$other_home/config/test-service/fake.json"
fm_write_meta "$other_home/state/notify.meta" 'window=sess:fm-notify' 'kind=ship' 'harness=claude'
other=$(FM_HOME="$other_home" FM_STATE_OVERRIDE="$other_home/state" $svc submit fake "$PWD" "$sha1" --task notify --suite)
$svc wait "$other" | grep -q "^passed $sha1"
await_notice "$other" delivered
grep -q "request=$other state=passed" "$other_home/state/notify.inbox/001.msg"
[ ! -e "$FM_STATE_OVERRIDE/notify.inbox/005.msg" ] || fail 'completion crossed home boundaries'
notice_field() {
  python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$1" "$2" <<'PY'
import sqlite3,sys
print(sqlite3.connect(sys.argv[1]).execute('SELECT %s FROM notifications WHERE request_id=?' % sys.argv[3],(sys.argv[2],)).fetchone()[0])
PY
}

# Failed sends back off with each attempt and stop at the retry cap.
fm_write_meta "$FM_STATE_OVERRIDE/capped.meta" 'window=sess:fm-notify' 'kind=ship' 'harness=claude'
: > "$FM_STATE_OVERRIDE/capped.inbox"
capped=$($svc submit fake "$PWD" "$sha1" --task capped --suite)
$svc wait "$capped" | grep -q "^passed $sha1"
for ((attempt=0; attempt<300; attempt++)); do
  [ "$(notice_field "$capped" attempts)" -ge 1 ] && break
  sleep .1
done
[ "$attempt" -lt 300 ] || fail 'capped send was never attempted'
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$capped" <<'PY'
import sqlite3,sys,time
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE notifications SET attempts=3,attempted=? WHERE request_id=?",(time.time()-10,sys.argv[2]))
PY
sleep 1
[ "$(notice_field "$capped" attempts)" = 3 ] || fail 'retry ignored the growing backoff'
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$capped" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE notifications SET attempts=1000,attempted=0 WHERE request_id=?",(sys.argv[2],))
PY
await_notice "$capped" failed
grep -q "giving up after" "$tmp/notify-server3.log"
wake_rows() { awk -F '\t' -v key="test-service-notify:$1" '$4 == key' "$FM_STATE_OVERRIDE/.wake-queue" 2>/dev/null | wc -l | tr -d ' '; }
[ "$(wake_rows "$capped")" = 1 ] || fail 'given-up completion did not wake firstmate once'
awk -F '\t' -v key="test-service-notify:$capped" '$4 == key { print $5 }' "$FM_STATE_OVERRIDE/.wake-queue" \
  | grep -q "^check: test-service completion undelivered task=capped request=$capped;" || fail 'escalation did not name the task and request'
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$capped" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE notifications SET state='escalating',attempted=0 WHERE request_id=?",(sys.argv[2],))
PY
await_notice "$capped" failed
[ "$(wake_rows "$capped")" = 1 ] || fail 'replayed escalation duplicated the firstmate wake'
# Firstmate consuming the row and losing the final marker must not republish,
# and an escalation retry waits out the persisted bounded backoff.
python3 - "$FM_STATE_OVERRIDE/.wake-queue" "test-service-notify:$capped" <<'PY'
import sys
path,key=sys.argv[1:]
lines=open(path).read().splitlines(True)
open(path,'w').writelines(line for line in lines if line.split('\t')[3:4]!=[key])
PY
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$capped" <<'PY'
import sqlite3,sys,time
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE notifications SET state='escalating',attempts=12,attempted=? WHERE request_id=?",(time.time()-10,sys.argv[2]))
PY
sleep 1
[ "$(notice_field "$capped" state)" = escalating ] || fail 'escalation retry ignored its backoff'
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$capped" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE notifications SET attempted=0 WHERE request_id=?",(sys.argv[2],))
PY
await_notice "$capped" failed
[ "$(wake_rows "$capped")" = 0 ] || fail 'consumed escalation was published again after losing its final marker'
rm "$FM_STATE_OVERRIDE/capped.inbox"
sleep 1
[ ! -e "$FM_STATE_OVERRIDE/capped.inbox" ] || fail 'capped notification was retried'

# The first service to create the outbox settles every earlier completion, so
# an upgrade never replays history, while in-flight requests still notify.
kill -TERM "$server"; wait "$server"; server=
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('DROP TABLE notifications')
PY
inflight=$($svc submit fake "$PWD" "$sha1" --task notify --suite)
[ "$(notice_field "$notify_pass" state)" = skipped ] || fail 'historical completion was left for replay'
"$svc" serve > "$tmp/notify-server4.log" 2>&1 & server=$!
await_notice "$inflight" delivered
grep -q "request=$inflight state=passed" "$FM_STATE_OVERRIDE/notify.inbox/005.msg"
[ ! -e "$FM_STATE_OVERRIDE/notify.inbox/006.msg" ] || fail 'upgrade replayed historical completions'
echo 'ok - test service ordering, pinning, restart, records, retest, cancel, phone unlock, and four parallel suites'
echo 'ok - terminal completions wake once across restarts, acknowledgements, failures, and cancellation'
echo 'ok - failed completion sends back off and stop at the retry cap with one firstmate wake, and the outbox upgrade never replays history'
