#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
root=$(cd "$(dirname "$0")/.." && pwd -P)
svc=$root/bin/fm-test-service.py
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-service.XXXXXX")
server=
submitting=
cleanup() { if [ -n "$submitting" ]; then touch "$tmp/clone-barrier.release"; wait "$submitting" 2>/dev/null || true; fi; if [ -n "$server" ]; then kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fi; if [ "${KEEP_TEST_TMP:-0}" = 1 ]; then echo "test tmp: $tmp"; else rm -rf "$tmp"; fi; }
trap cleanup EXIT
trap 'echo "failed at line $LINENO: $BASH_COMMAND" >&2' ERR
export HOME=$tmp/home FM_HOME=$tmp/fm FM_TEST_SERVICE_STATE=$tmp/state EVENTS=$tmp/events
export FM_STATE_OVERRIDE=$FM_HOME/state
export FM_TEST_QUEUE_LEGACY_ROOT=$FM_TEST_SERVICE_STATE/queues/legacy
mkdir -p "$FM_TEST_QUEUE_LEGACY_ROOT"
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
  'dumpsys activity activities')
    if [ -e "$HOME/wrong-foreground" ]; then
      echo 'topResumedActivity: ActivityRecord{1 com.other.app/.Main}'
    elif [ -e "$HOME/stale-foreground" ]; then
      echo 'topResumedActivity: ActivityRecord{1 com.example.oldperf/.Main}'
    else
      echo 'topResumedActivity: ActivityRecord{1 com.example.perftest/.Main}'
    fi ;;
  'am force-stop com.example.oldperf') echo stop-old >> "$EVENTS"; mv "$HOME/stale-foreground" "$HOME/stale-cleared" ;;
  'am force-stop com.example.perftest') echo stop-own >> "$EVENTS" ;;
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
{"prepare":["prepare.sh"],"suite":["suite.sh"],"quick_suite":["suite.sh"],"device":["phone.sh","--serial","{serial}"],"any_device":["phone.sh","--serial","any"],"quick_device":["phone.sh","--serial","{serial}","--quick"],"phones":["S22","S21","M31"],"any_phones":["S22","S21","M31"],"equivalent_phones":{"S22":["S21"],"S21":["S22"]},"landing_branch":"main","scenarios":{"smoke":["--smoke"]}}
JSON
# The unit carries the installing shell's tool order and isolated paths.
unit=$(cat "$tmp/unit-path")
grep -Fqx "Environment=\"PATH=$PATH\"" "$unit"
grep -Fqx "Environment=\"FM_TEST_SERVICE_CONFIG_ROOT=$FM_HOME/config/test-service\"" "$unit"
grep -Fqx "ExecStartPre=\"$svc\" check-tools" "$unit"
python3 - "$FM_HOME/config/test-service/fake.json" <<'PYUNIT'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data['required_tools'] = {'adb': [], 'python3': ['PIL']}
open(path, 'w').write(json.dumps(data))
PYUNIT
mkdir -p "$tmp/python-only"
ln -s "$(command -v python3)" "$tmp/python-only/python3"
if PATH="$tmp/python-only" "$svc" check-tools > "$tmp/check-absent-adb" 2>&1; then
  echo 'missing adb fixture passed' >&2; exit 1
fi
grep -q 'fake: missing tool adb' "$tmp/check-absent-adb"
mkdir -p "$tmp/bad-python"
cat > "$tmp/bad-python/python3" <<'PYSHIM'
#!/bin/sh
if [ "$1" = -c ]; then exit 1; fi
exec /usr/bin/python3 "$@"
PYSHIM
chmod +x "$tmp/bad-python/python3"
if PATH="$tmp/bad-python:$tmp/bin:/usr/bin:/bin" "$svc" check-tools > "$tmp/check-absent-pil" 2>&1; then
  echo 'missing PIL fixture passed' >&2; exit 1
fi
grep -q 'fake: python3 missing Python module PIL' "$tmp/check-absent-pil"
python3 - "$FM_HOME/config/test-service/fake.json" <<'PYUNIT'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
del data['required_tools']
open(path, 'w').write(json.dumps(data))
PYUNIT
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
set -euo pipefail
serial=$2
echo "phone-ticket:$serial" >> "$EVENTS"
if [ "$serial" = any ]; then
  while :; do
    for candidate in S22 S21 M31; do
      [ ! -e "$HOME/vip-wait-$candidate" ] || continue
      if [ -e "$HOME/online-devices" ] && ! grep -qx "$candidate" "$HOME/online-devices"; then continue; fi
      exec {phone_lock}> "$FM_TEST_QUEUE_LEGACY_ROOT/frogpile-phone-$candidate.lock"
      if flock -n "$phone_lock"; then serial=$candidate; break; fi
      exec {phone_lock}>&-
    done
    [ "$serial" = any ] || break
    sleep .05
  done
fi
echo "phone-start-v1:$serial:${3:-}" >> "$EVENTS"
if [ -e "$HOME/fail-phone" ]; then echo 'PHONE ERROR: simulated device failure'; exit 1; fi
if [ "$serial" = S22 ] && [ -e "$HOME/slow-phone" ]; then sleep 8; else sleep .2; fi
echo "phone-end-v1" >> "$EVENTS"
PHONE
cat > benchmark.sh <<'BENCH'
#!/usr/bin/env bash
echo "benchmark-v1" >> "$EVENTS"
BENCH
cat > m31-perf.sh <<'PERF'
#!/usr/bin/env bash
set -euo pipefail
exec {phone_lock}> "$HOME/m31-perf.lock"
flock -n "$phone_lock"
echo 'm31-perf-start' >> "$EVENTS"
sleep .2
echo 'm31-perf-end' >> "$EVENTS"
PERF
chmod +x prepare.sh suite.sh phone.sh benchmark.sh m31-perf.sh
git add . && git commit -qm v1
sha1=$(git rev-parse HEAD)
# A daemon starting during a submit must leave its partial clone alone until
# the submitter finishes, then run that request normally.
FM_TEST_REAL_GIT=$(command -v git)
export FM_TEST_REAL_GIT
cat > "$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${FM_TEST_CLONE_BARRIER:-}" ] && [ "${1:-}" = clone ]; then
  dest=${!#}
  "$FM_TEST_REAL_GIT" "${@:1:$#-1}" "$dest.staged"
  mkdir "$dest"
  : > "$FM_TEST_CLONE_BARRIER.ready"
  until [ -e "$FM_TEST_CLONE_BARRIER.release" ]; do sleep .05; done
  rmdir "$dest"
  mv "$dest.staged" "$dest"
else
  exec "$FM_TEST_REAL_GIT" "$@"
fi
GIT
chmod +x "$tmp/bin/git"
FM_TEST_CLONE_BARRIER="$tmp/clone-barrier" "$svc" submit fake "$PWD" "$sha1" --suite > "$tmp/inflight-id" 2> "$tmp/inflight-error" & submitting=$!
for ((attempt=0; attempt<100; attempt++)); do
  [ -e "$tmp/clone-barrier.ready" ] && break
  kill -0 "$submitting" 2>/dev/null || fail 'submitter exited before the clone barrier'
  sleep .05
done
[ "$attempt" -lt 100 ] || fail 'submitter never reached the clone barrier'
"$svc" serve > "$tmp/server.log" 2>&1 & server=$!
for ((attempt=0; attempt<100; attempt++)); do
  if [ -e "$FM_TEST_SERVICE_STATE/service.lock" ] && python3 - "$FM_TEST_SERVICE_STATE/service.lock" <<'PYLOCK'
import fcntl, sys
with open(sys.argv[1], 'w') as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(0)
sys.exit(1)
PYLOCK
  then break; fi
  kill -0 "$server" 2>/dev/null || fail 'service exited before startup recovery'
  sleep .05
done
[ "$attempt" -lt 100 ] || fail 'service never acquired its startup lock'
sleep .5
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" <<'PY'
import sqlite3, sys
row = sqlite3.connect(sys.argv[1]).execute('SELECT state FROM requests').fetchone()
assert row == ('preparing',), row
PY
touch "$tmp/clone-barrier.release"
wait "$submitting" || fail "submitter failed: $(cat "$tmp/inflight-error")"
submitting=
inflight=$(cat "$tmp/inflight-id")
"$svc" wait "$inflight" | grep -q "^passed $sha1"
: > "$EVENTS"
printf '\necho dirty-live-tree >&2; exit 1\n' >> suite.sh
request=$($svc submit fake "$PWD" "$sha1" --suite --device-gate S22 --scenario smoke --harness benchmark.sh --receipt "$tmp/pass.receipt" --retest-on-move)
$svc wait "$request" | grep -q "^passed $sha1"
# Preparation finishes before the suite and phone enter their queues.
[ "$(sed -n '1p' "$EVENTS")" = prepare-v1 ]
[ "$(sed -n '2p' "$EVENTS")" = suite-start-v1 ] || [ "$(sed -n '2p' "$EVENTS")" = phone-ticket:S22 ]
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
grep -q '^phone-ticket:any$' "$EVENTS"
grep -q '^phone-start-v1:S22:$' "$EVENTS"
quick_any=$($svc submit fake "$PWD" "$sha1" --suite --check quick --target "$sha1" --device-gate any)
$svc wait "$quick_any" | grep -q '^passed '
grep -q '^phone-start-v1:S22:--quick$' "$EVENTS"
python3 - "$FM_HOME/config/test-service/fake.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path)); data['max_concurrent']=2
open(path,'w').write(json.dumps(data))
PY
touch "$HOME/slow-phone"
before_s22=$(grep -c '^phone-start-v1:S22:$' "$EVENTS")
concurrent_one=$($svc submit fake "$PWD" "$sha1" --device-gate any)
for i in $(seq 1 300); do
  [ "$(grep -c '^phone-start-v1:S22:$' "$EVENTS")" -gt "$before_s22" ] && break
  sleep .05
done
[ "$i" -lt 300 ]
concurrent_two=$($svc submit fake "$PWD" "$sha1" --device-gate any)
$svc wait "$concurrent_two" | grep -q '^passed '
$svc wait "$concurrent_one" | grep -q '^passed '
grep -q '^phone-start-v1:S21:$' "$EVENTS"
if [ "$(grep -c '^phone-ticket:any$' "$EVENTS")" -lt 3 ]; then fail 'any-phone request passed a named serial'; fi
rm "$HOME/slow-phone"
touch "$HOME/vip-wait-M31"
exec {vip_s22}> "$FM_TEST_QUEUE_LEGACY_ROOT/frogpile-phone-S22.lock"
flock "$vip_s22"
vip_waiting=$($svc submit fake "$PWD" "$sha1" --device-gate any)
$svc wait "$vip_waiting" | grep -q '^passed '
exec {vip_s22}>&-
[ "$(tail -2 "$EVENTS" | grep -c '^phone-start-v1:S21:$')" -eq 1 ]
rm "$HOME/vip-wait-M31"
exec {m31_s22}> "$FM_TEST_QUEUE_LEGACY_ROOT/frogpile-phone-S22.lock"
exec {m31_s21}> "$FM_TEST_QUEUE_LEGACY_ROOT/frogpile-phone-S21.lock"
flock "$m31_s22"
flock "$m31_s21"
m31_any=$($svc submit fake "$PWD" "$sha1" --device-gate any)
$svc wait "$m31_any" | grep -q '^passed '
exec {m31_s22}>&-
exec {m31_s21}>&-
[ "$(tail -2 "$EVENTS" | grep -c '^phone-start-v1:M31:$')" -eq 1 ]
exec {external_phone}> "$FM_TEST_QUEUE_LEGACY_ROOT/frogpile-phone-S22.lock"
flock "$external_phone"
leased=$($svc submit fake "$PWD" "$sha1" --device-gate any)
$svc wait "$leased" | grep -q '^passed '
exec {external_phone}>&-
[ "$(tail -2 "$EVENTS" | grep -c '^phone-start-v1:S21:$')" -eq 1 ]
python3 - "$FM_HOME/config/test-service/fake.json" <<'PY'
import json,sys
path=sys.argv[1]
data=json.load(open(path)); data.pop('max_concurrent')
open(path,'w').write(json.dumps(data))
PY
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
printf 'S21\nM31\n' > "$HOME/online-devices"
named_m31=$($svc submit fake "$PWD" "$sha1" --device-gate M31)
$svc wait "$named_m31" | grep -q '^passed '
grep -q '^phone-ticket:M31$' "$EVENTS"
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
$svc status --json > "$tmp/interrupted-status.json"
sleep .2
$svc status --json > "$tmp/interrupted-status-again.json"
python3 - "$tmp/interrupted-status.json" "$tmp/interrupted-status-again.json" "$restart" <<'PY'
import json,sys
first,second=(json.load(open(path)) for path in sys.argv[1:3])
rid=sys.argv[3]
assert first['runner']['instance'] and not first['runner']['alive']
assert first['updated']==second['updated']
assert next(r for r in second['requests'] if r['id']==rid)['state']=='interrupted'
assert rid not in [r['id'] for r in second['running_requests']]
assert any(a['id']==rid and 'runner unavailable' in a['message'] for a in second['alerts'])
PY
grep -q "test-service-runner:.*:$restart" "$FM_STATE_OVERRIDE/.wake-queue"
export SUITE_SLEEP=5
python3 - "$FM_TEST_SERVICE_STATE/service.lock" "$tmp/probe-held" <<'PY' & probe=$!
import fcntl,pathlib,sys,time
with open(sys.argv[1], 'w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(.4)
PY
for i in $(seq 1 100); do [ -e "$tmp/probe-held" ] && break; sleep .01; done
[ -e "$tmp/probe-held" ] || fail 'transient lock probe did not start'
"$svc" serve > "$tmp/server2.log" 2>&1 & server=$!
wait "$probe"
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
# A preparation orphan has a deadline and does not block another request.
kill -TERM "$server" 2>/dev/null || true
wait "$server" 2>/dev/null || true
server=
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$request" <<'PY'
import sqlite3,sys,time
db=sqlite3.connect(sys.argv[1]); db.execute('''INSERT INTO requests
(id,seq,project,source,original_sha,sha,options,state,submitted,queued_at,generation)
SELECT 'stale-preparing', (SELECT MAX(seq)+1 FROM requests),project,source,original_sha,sha,options,
'preparing', ?, ?, 0 FROM requests WHERE id=?''',(time.time()-600,time.time()-600,sys.argv[2])); db.commit()
PY
"$svc" serve > "$tmp/server3.log" 2>&1 & server=$!
if $svc wait stale-preparing > "$tmp/stale-preparing.out"; then fail 'stale preparation passed'; fi
grep -q 'preparing timed out' "$tmp/stale-preparing.out"
after_stale=$($svc submit fake "$PWD" "$sha1" --suite)
$svc wait "$after_stale" | grep -q '^passed '
# A late worker cannot turn a terminal timeout into a passing suite or receipt.
before_late=$(grep -c 'suite-start-v1' "$EVENTS")
before_late_end=$(grep -c 'suite-end-v1' "$EVENTS")
late_result=$($svc submit fake "$PWD" "$sha1" --suite)
for i in $(seq 1 300); do
  started_late=$(grep -c 'suite-start-v1' "$EVENTS")
  [ "$started_late" -gt "$before_late" ] && break
  sleep .05
done
[ "$started_late" -gt "$before_late" ] || fail 'late-result suite never started'
python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$late_result" <<'PY'
import sqlite3,sys,time
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("UPDATE requests SET state='failed',error='preparing timed out',finished=? WHERE id=?",
               (time.time(),sys.argv[2]))
PY
if $svc wait "$late_result" > "$tmp/late-result.out"; then fail 'terminal timeout became a pass'; fi
grep -q 'preparing timed out' "$tmp/late-result.out"
for i in $(seq 1 300); do
  ended_late=$(grep -c 'suite-end-v1' "$EVENTS")
  [ "$ended_late" -gt "$before_late_end" ] && break
  sleep .05
done
[ "$ended_late" -gt "$before_late_end" ] || fail 'late-result suite never ended'
sleep .5
[ ! -e "$FM_TEST_SERVICE_STATE/results/$late_result/$sha1.receipt" ] || fail 'late worker wrote a pass receipt'
if $svc wait "$late_result" > "$tmp/late-result-final.out"; then fail 'late result changed to passed'; fi
grep -q 'preparing timed out' "$tmp/late-result-final.out"
# A live submit must preserve the service's timeout verdict and fail its CLI.
real_git=$(command -v git)
cat > "$tmp/bin/git" <<'GIT'
#!/usr/bin/env bash
if [ "$1" = clone ] && [ -e "$HOME/slow-clone" ]; then
  touch "$HOME/clone-start"
  while [ ! -e "$HOME/release-clone" ]; do sleep .05; done
fi
exec "$REAL_GIT" "$@"
GIT
chmod +x "$tmp/bin/git"
export REAL_GIT=$real_git
touch "$HOME/slow-clone"
$svc submit fake "$PWD" "$sha1" --suite > "$tmp/late-submit.out" 2> "$tmp/late-submit.err" & late_submit=$!
for i in $(seq 1 100); do [ -e "$HOME/clone-start" ] && break; sleep .05; done
[ -e "$HOME/clone-start" ] || fail 'late submit never reached clone'
late_id=$(python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" <<'PY'
import sqlite3,sys,time
with sqlite3.connect(sys.argv[1]) as db:
    row=db.execute("SELECT id FROM requests WHERE state='preparing' ORDER BY seq DESC LIMIT 1").fetchone()
    assert row
    db.execute("UPDATE requests SET submitted=? WHERE id=?", (time.time()-600,row[0]))
    print(row[0])
PY
)
for i in $(seq 1 100); do
  timed_out=$(python3 - "$FM_TEST_SERVICE_STATE/requests.sqlite3" "$late_id" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    print(db.execute("SELECT COUNT(*) FROM requests WHERE id=? AND state='failed' AND error='preparing timed out'",(sys.argv[2],)).fetchone()[0])
PY
)
  [ "$timed_out" -eq 1 ] && break
  sleep .05
done
[ "$timed_out" -eq 1 ] || fail 'live preparation did not time out'
touch "$HOME/release-clone"
if wait "$late_submit"; then fail 'timed-out submit returned success'; fi
[ ! -s "$tmp/late-submit.out" ] || fail 'timed-out submit printed request ID'
rm "$tmp/bin/git" "$HOME/slow-clone" "$HOME/clone-start" "$HOME/release-clone"
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
for i in $(seq 1 300); do
  [ "$(grep -c '^parallel-start:' "$EVENTS")" -ge 4 ] && break
  sleep .05
done
[ "$i" -lt 300 ]
performance=$($svc submit fake "$PWD" "$sha1" --task m31-only --harness m31-perf.sh)
$svc wait "$performance" | grep -q "^passed $sha1"
python3 - "$EVENTS" <<'PY'
from pathlib import Path
import sys
events=Path(sys.argv[1]).read_text().splitlines()
assert 'm31-perf-end' in events
assert not any(e.startswith('parallel-end:') for e in events[:events.index('m31-perf-start')])
PY
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
{"suite":["suite.sh"],"quick_suite":["suite.sh"],"device":["phone.sh","--serial","{serial}"],"quick_device":["phone.sh","--serial","{serial}"],"phones":["S22"],"landing_branch":"main"}
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
priority_running=$($svc submit frogpile "$PWD" "$sha1" --task priority-running --suite)
for i in $(seq 1 300); do
  if python3 - "$FM_TEST_SERVICE_STATE/status.json" "$priority_running" <<'PY' 2>/dev/null
import json,sys
assert any(row['id']==sys.argv[2] for row in json.load(open(sys.argv[1]))['running_requests'])
PY
  then break; fi
  sleep .05
done
[ "$i" -lt 300 ]
priority_ordinary=$($svc submit frogpile "$PWD" "$sha1" --task priority-ordinary --suite)
priority_quick=$($svc submit frogpile "$PWD" "$sha1" --task priority-quick --suite --check quick --target "$sha1" --device-gate S22)
for id in "$priority_running" "$priority_ordinary" "$priority_quick"; do
  $svc wait "$id" | grep -q "^passed $sha1"
done
python3 - "$FM_TEST_SERVICE_STATE/status.json" "$priority_quick" "$priority_ordinary" <<'PY'
import json,sys
rows={row['id']:row for row in json.load(open(sys.argv[1]))['requests']}
assert rows[sys.argv[2]]['started'] < rows[sys.argv[3]]['started'], 'landing check did not start first'
PY
rm "$FM_HOME/config/test-service/frogpile.json"
# The project suite entry point reports its script error to the service.
cat > suite.sh <<'SCRIPT_ERROR'
#!/usr/bin/env bash
echo 'export warning: ErrorNames.csv was not generated'
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
touch "$HOME/fail-phone"
early_fail=$($svc submit fake "$PWD" "$sha1" --task notify --suite --device-gate S22)
await_notice "$early_fail-failure-0-device" delivered
$svc status --json > "$tmp/early-failure-status.json"
python3 - "$tmp/early-failure-status.json" "$early_fail" <<'PY'
import json,sys
data=json.load(open(sys.argv[1])); row=next(r for r in data['requests'] if r['id']==sys.argv[2])
assert row['state']=='failed' and row['finished'] is None
assert row['error'].startswith('device: PHONE ERROR:')
assert any(s['name']=='suite' and s['state']=='running' for s in row['steps'])
PY
grep -q "request=$early_fail state=failed" "$FM_STATE_OVERRIDE/notify.inbox/006.msg"
if $svc wait "$early_fail" > "$tmp/early-fail.out"; then fail 'failed phone request passed'; fi
await_notice "$early_fail" delivered
$svc status --json > "$tmp/terminal-failure-status.json"
python3 - "$tmp/terminal-failure-status.json" "$early_fail" <<'PY'
import json,sys
data=json.load(open(sys.argv[1]))
assert next(r for r in data['requests'] if r['id']==sys.argv[2])['finished'] is not None
assert not any(a['id']==sys.argv[2] for a in data['alerts'])
PY
rm "$HOME/fail-phone"
echo 'ok - test service ordering, pinning, restart, records, retest, cancel, phone unlock, and four parallel suites'
echo 'ok - terminal completions wake once across restarts, acknowledgements, failures, and cancellation'
echo 'ok - failed completion sends back off and stop at the retry cap with one firstmate wake, and the outbox upgrade never replays history'

# Performance plans are validated from the pinned commit and execute all phone
# actions in one queue child, leaving a queryable bundle and named comparison.
cat > "$tmp/project/perf-queue.sh" <<'QUEUE'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --serial ] && [ "$2" = M31 ] && [ "$3" = -- ]
shift 3
echo lease-start >> "$EVENTS"
trap 'echo lease-end >> "$EVENTS"' EXIT
PERF_LEASE=1 "$@"
QUEUE
cat > "$tmp/project/perf-action.sh" <<'ACTION'
#!/usr/bin/env bash
set -euo pipefail
action=$1; shift
if [ "$action" = build ]; then
  [ -z "${PERF_LEASE:-}" ]
  echo build >> "$EVENTS"
  exit
fi
[ "${PERF_LEASE:-}" = 1 ]
echo "$action" >> "$EVENTS"
if [ "$action" = drive ] && [ -e "$HOME/perf-dirty" ]; then
  echo dirty >> perf-plan.json
fi
if [ "$action" = drive ] && [ -e "$HOME/perf-block" ]; then
  touch "$HOME/perf-blocked"
  while [ -e "$HOME/perf-block" ]; do sleep 0.1; done
fi
if [ "$action" = capture ]; then
  printf '{"fps":%s,"p95_ms":%s}\n' "${PERF_FPS:-40}" 34 > "$1"
  printf 'fixture trace\n' > "$(dirname "$1")/$(basename "$1" .json).pftrace"
fi
ACTION
cat > "$tmp/bin/trace_processor" <<'PROCESSOR'
#!/usr/bin/env bash
[ "$1" = query ] || exit 1
printf 'id,parent_id,name,category,ts,dur,track_id\n1,[NULL],Godot::draw,engine,100,5000000,2\n2,1,pond_zone,script,200,2000000,2\n'
PROCESSOR
chmod +x "$tmp/project/perf-queue.sh" "$tmp/project/perf-action.sh"
chmod +x "$tmp/bin/trace_processor"
python3 - "$FM_HOME/config/test-service/fake.json" <<'PY'
import json,sys
p=sys.argv[1]; data=json.load(open(p))
data['phones']=sorted(set(data['phones'])|{'M31'})
data['performance']={
  'package':'com.example.perftest',
  'isolated_package_prefixes':['com.example'],
  'queue':['perf-queue.sh','--serial','{device}'],
  'build':['perf-action.sh','build'],
  'install':['perf-action.sh','install'],
  'drive':['perf-action.sh','drive'],
  'capture':['perf-action.sh','capture','{output}'],
  'pull':['perf-action.sh','pull'],
  'uninstall':['perf-action.sh','uninstall']}
open(p,'w').write(json.dumps(data))
PY
cat > "$tmp/project/perf-plan.json" <<'PLAN'
{"schema":"fm-performance-plan.v1","device":"M31","states":[{"name":"pond","target":"pond_idle","measurements":["frame"],"repeats":2,"thresholds":{"fps":{"min":39},"p95_ms":{"max":35}}},{"name":"missions","target":"ftue_missions","measurements":["frame"],"repeats":1,"thresholds":{"fps":{"min":39}}}]}
PLAN
git add perf-queue.sh perf-action.sh perf-plan.json && git commit -qm perf-plan
perf_sha=$(git rev-parse HEAD)
touch "$HOME/stale-foreground"
perf_first=$($svc submit fake "$PWD" "$perf_sha" --perf-plan perf-plan.json)
$svc wait "$perf_first" | grep -q '^passed '
python3 - "$FM_TEST_SERVICE_STATE/results/$perf_first/$perf_sha/performance/summary.json" "$EVENTS" <<'PY'
import json,sys
data=json.load(open(sys.argv[1])); assert data['pass'] and len(data['rows'])==3
events=open(sys.argv[2]).read().splitlines()
start=events.index('lease-start'); end=events.index('lease-end',start)
assert events[start-1]=='build'
assert events[start+1:end]==['stop-old','install','drive','capture','pull','drive','capture','pull','drive','capture','pull','stop-own','uninstall']
PY
$svc perf-query "$FM_TEST_SERVICE_STATE/results/$perf_first/$perf_sha/performance" 'SELECT kind,name,SUM(calls),SUM(total_ms) FROM wallclock GROUP BY kind,name ORDER BY kind,name' > "$tmp/trace-query.csv"
grep -q 'function,Godot::draw,3,15.0' "$tmp/trace-query.csv"
grep -q 'zone,pond_zone,3,6.0' "$tmp/trace-query.csv"
python3 - "$tmp/project/perf-plan.json" "$perf_first" <<'PY'
import json,sys
p=sys.argv[1]; data=json.load(open(p)); data['compare_to']=sys.argv[2]
open(p,'w').write(json.dumps(data))
PY
git add perf-plan.json && git commit -qm perf-compare
compare_sha=$(git rev-parse HEAD)
perf_second=$($svc submit fake "$PWD" "$compare_sha" --perf-plan perf-plan.json)
$svc wait "$perf_second" | grep -q '^passed '
python3 - "$FM_TEST_SERVICE_STATE/results/$perf_second/$compare_sha/performance/summary.json" <<'PY'
import json,sys
data=json.load(open(sys.argv[1])); assert len(data['diff'])==3
assert all(row['delta']=={'fps':0,'p95_ms':0} for row in data['diff'])
PY
touch "$HOME/wrong-foreground"
lost_focus=$($svc submit fake "$PWD" "$perf_sha" --perf-plan perf-plan.json)
if $svc wait "$lost_focus" > "$tmp/lost-focus.out"; then
  fail 'performance capture proceeded without app focus'
fi
grep -q 'did not hold focus' "$tmp/lost-focus.out"
[ "$(tail -2 "$EVENTS" | tr '\n' ' ')" = 'uninstall lease-end ' ]
mv "$HOME/wrong-foreground" "$HOME/wrong-foreground-cleared"
python3 - "$tmp/project/perf-plan.json" <<'PY'
import json,sys
p=sys.argv[1]; data=json.load(open(p)); data['states'][0]['repeats']=0
open(p,'w').write(json.dumps(data))
PY
git add perf-plan.json && git commit -qm perf-bad
bad_sha=$(git rev-parse HEAD)
if $svc submit fake "$PWD" "$bad_sha" --perf-plan perf-plan.json > "$tmp/bad.out" 2>&1; then
  fail 'known-bad committed performance plan was accepted'
fi
grep -q 'repeats must be 1..20' "$tmp/bad.out"
if $svc submit fake "$PWD" "$perf_sha" --suite --perf-plan perf-plan.json > "$tmp/perf-suite.out" 2>&1; then
  fail 'performance plan accepted --suite without running it'
fi
grep -q 'cannot combine with suite' "$tmp/perf-suite.out"
touch "$HOME/perf-dirty"
dirty=$($svc submit fake "$PWD" "$perf_sha" --perf-plan perf-plan.json)
if $svc wait "$dirty" > "$tmp/perf-dirty.out"; then
  fail 'performance plan passed after changing the tracked test copy'
fi
grep -q 'test copy changed during test' "$tmp/perf-dirty.out"
rm "$HOME/perf-dirty"
touch "$HOME/perf-block"
blocked=$($svc submit fake "$PWD" "$perf_sha" --perf-plan perf-plan.json)
for i in $(seq 1 300); do [ -e "$HOME/perf-blocked" ] && break; sleep 0.1; done
[ -e "$HOME/perf-blocked" ] || fail 'performance drive never started'
$svc cancel "$blocked"
$svc wait "$blocked" > "$tmp/perf-cancel.out" && exit 1 || true
rm -f "$HOME/perf-block" "$HOME/perf-blocked"
grep -q '^cancelled ' "$tmp/perf-cancel.out"
[ ! -e "$FM_TEST_SERVICE_STATE/results/$blocked/$perf_sha.failure.json" ]
python3 - "$tmp/project/perf-plan.json" <<'PY'
import json,sys
p=sys.argv[1]; data=json.load(open(p)); data['states'][0]['repeats']=1; data['states'][0]['measurements']=['frame','gpu']; data.pop('compare_to',None)
open(p,'w').write(json.dumps(data))
PY
git add perf-plan.json && git commit -qm perf-duplicate
duplicate_sha=$(git rev-parse HEAD)
duplicate=$($svc submit fake "$PWD" "$duplicate_sha" --perf-plan perf-plan.json)
if $svc wait "$duplicate" > "$tmp/perf-duplicate.out"; then
  fail 'performance plan merged duplicate metric names across kinds'
fi
grep -q 'repeats metric names: fps, p95_ms' "$tmp/perf-duplicate.out"
echo 'ok - performance plan validation, ordered single-lease bundle, and named diff'
