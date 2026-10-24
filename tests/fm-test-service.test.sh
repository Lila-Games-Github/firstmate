#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
svc=$root/bin/fm-test-service.py
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-service.XXXXXX")
server=
cleanup() { if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi; if [ "${KEEP_TEST_TMP:-0}" = 1 ]; then echo "test tmp: $tmp"; else rm -rf "$tmp"; fi; }
trap cleanup EXIT
trap 'echo "failed at line $LINENO: $BASH_COMMAND" >&2' ERR
export HOME=$tmp/home FM_HOME=$tmp/fm FM_TEST_SERVICE_STATE=$tmp/state EVENTS=$tmp/events
mkdir -p "$HOME/.config/firstmate" "$FM_HOME/config/test-service" "$tmp/bin" "$tmp/project"
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
rg -q '^ExecStart=".*/bin/fm-test-service.py" serve$' "$(cat "$tmp/unit-path")"
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
[ "$(rg -n 'suite-end' "$EVENTS" | cut -d: -f1)" -gt "$(rg -n 'phone-start' "$EVENTS" | cut -d: -f1)" ]
[ "$(tail -1 "$EVENTS")" = benchmark-v1 ]
[ "$(cat "$tmp/pass.receipt")" = "$(printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0' "$sha1")" ]
# The same parser used by fm-merge-local accepts the output.
( source "$root/bin/fm-landing-health-lib.sh"; fm_health_receipt_read "$tmp/pass.receipt" "$sha1"; [ "$FM_HEALTH_COUNT" = 0 ] )
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
# A changed landing branch triggers a fresh test of the new exact SHA.
cat > suite.sh <<'FAIL'
#!/usr/bin/env bash
echo 'FAIL fake-suite-test: expected green' >&2
exit 1
FAIL
chmod +x suite.sh
git add suite.sh && git commit -qm v2
sha2=$(git rev-parse HEAD)
for i in $(seq 1 300); do
  if python3 - "$FM_TEST_SERVICE_STATE/status.json" "$request" "$sha2" 2>/dev/null <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
assert any(r['id']==sys.argv[2] and r['sha']==sys.argv[3] and r['generation']==1 and r['state']=='failed' for r in s['requests'])
PY
  then break; fi
  sleep .2
done
[ -f "$FM_TEST_SERVICE_STATE/results/$request/$sha2.failure.json" ]
rg -q 'fake-suite-test' "$FM_TEST_SERVICE_STATE/results/$request/$sha2.failure.json"
$svc cancel "$request"
# A locked phone with no configured PIN fails clearly.
touch "$HOME/locked-S22"
rm -f "$HOME/unlocked-S22"
locked=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$locked" > "$tmp/locked.out" && exit 1 || true
rg -q 'phone-locked: add S22' "$tmp/locked.out"
# A private per-phone PIN unlocks the fake device without recording the secret.
printf 'S22=1234\n' > "$HOME/.config/firstmate/test-device-pins"
chmod 644 "$HOME/.config/firstmate/test-device-pins"
insecure=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$insecure" > "$tmp/insecure.out" && exit 1 || true
rg -q 'mode-600 private file' "$tmp/insecure.out"
chmod 600 "$HOME/.config/firstmate/test-device-pins"
unlocked=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$unlocked" | grep -q '^passed '
[ -e "$HOME/unlocked-S22" ]
if rg -q '1234' "$FM_TEST_SERVICE_STATE/status.json" "$FM_TEST_SERVICE_STATE"/logs/*; then exit 1; fi
any_phone=$($svc submit fake "$PWD" "$sha1" --suite --device-gate any)
$svc wait "$any_phone" | grep -q '^passed '
rg -q '^phone-start-v1:S22:$' "$EVENTS"
printf 'S21\nM31\n' > "$HOME/online-devices"
fallback=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$fallback" | grep -q '^passed '
rg -q '^phone-start-v1:S21:$' "$EVENTS"
printf 'S22\nS21\n' > "$HOME/online-devices"
touch "$HOME/slow-phone"
before_s22=$(rg -c '^phone-start-v1:S22:$' "$EVENTS")
before_s21=$(rg -c '^phone-start-v1:S21:$' "$EVENTS")
disconnect=$($svc submit fake "$PWD" "$sha1" --device-gate S22)
for i in $(seq 1 300); do
  count=$(rg -c '^phone-start-v1:S22:$' "$EVENTS")
  [ "$count" -gt "$before_s22" ] && break
  sleep .05
done
[ "$count" -gt "$before_s22" ]
printf 'S21\n' > "$HOME/online-devices"
$svc wait "$disconnect" | grep -q '^passed '
rm "$HOME/slow-phone"
[ "$(rg -c '^phone-start-v1:S21:$' "$EVENTS")" -gt "$before_s21" ]
printf 'S21\n' > "$HOME/online-devices"
performance=$($svc submit fake "$PWD" "$sha1" --device-gate M31)
$svc wait "$performance" > "$tmp/performance.out" && exit 1 || true
rg -q 'device-unavailable: M31' "$tmp/performance.out"
: > "$HOME/online-devices"
offline=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
$svc wait "$offline" > "$tmp/offline.out" && exit 1 || true
rg -q 'device-unavailable: S22' "$tmp/offline.out"
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
rg -q 'phone-locked: could not unlock S22' "$tmp/wrong.out"
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
rg -q '^cancelled ' "$tmp/cancel.out"
# A killed daemon leaves a running request to rerun on restart.
before=$(rg -c 'suite-start-v1' "$EVENTS")
restart=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22)
for i in $(seq 1 300); do
  count=$(rg -c 'suite-start-v1' "$EVENTS")
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
[ "$(rg -c 'suite-start-v1' "$EVENTS")" -ge "$((before + 2))" ]
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
$svc cancel "$retested"
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
before_parallel=$(rg -c '^parallel-start:' "$EVENTS")
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
  started=$(rg -c '^parallel-start:' "$EVENTS")
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
[ "$(rg -c '^parallel-start:' "$EVENTS")" -ge "$((before_parallel + 8))" ]
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
rg -q 'SCRIPT ERROR: fake parse failure' "$FM_TEST_SERVICE_STATE/results/$script_error/$sha3.failure.json"
echo 'ok - test service ordering, pinning, restart, records, retest, cancel, phone unlock, and four parallel suites'
