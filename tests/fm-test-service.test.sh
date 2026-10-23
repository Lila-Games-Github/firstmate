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
{"prepare":["prepare.sh"],"suite":["suite.sh"],"device":["phone.sh","--serial","{serial}"],"any_device":["phone.sh","--serial","any"],"phones":["S22","S21"],"any_phones":["S22","S21"],"landing_branch":"main","scenarios":{"smoke":["--smoke"]}}
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
echo "suite-start-v1" >> "$EVENTS"
sleep "${SUITE_SLEEP:-2}"
echo "suite-end-v1" >> "$EVENTS"
SUITE
cat > phone.sh <<'PHONE'
#!/usr/bin/env bash
serial=$2
[ "$serial" != any ] || serial=S22
echo "phone-start-v1:$serial:${3:-}" >> "$EVENTS"
sleep .2
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
python3 - "$FM_TEST_SERVICE_STATE/status.json" "$restart" "$time_before" <<'PY'
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
echo 'ok - test service ordering, pinning, restart, records, retest, cancel, and phone unlock'
