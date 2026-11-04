#!/usr/bin/env bash
# Worker gate and registered job completion doorbells through the public commands.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-worker-doorbell)
HOME_DIR=$TMP/home
STATE=$HOME_DIR/state
FAKE=$TMP/fakebin
mkdir -p "$STATE" "$FAKE"
export FM_HOME=$HOME_DIR FM_STATE_OVERRIDE=$STATE FM_PROCEVENT_CLAIM_ROOT=$TMP/claims
printf 'kind=ship\nwindow=sess:fm-t1\nharness=claude\n' > "$STATE/t1.meta"
cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
case ${1-} in
  display-message) printf 'fakepane\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  *) : ;;
esac
SH
cat > "$FAKE/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
cat "$FM_FAKE_VERDICT"
SH
chmod +x "$FAKE/tmux" "$FAKE/fm-crew-state.sh"
if [ -n "${FM_STOCK_BASH_BIN:-}" ]; then
  ln -s "$FM_STOCK_BASH_BIN" "$FAKE/bash"
fi
export PATH="$FAKE:$PATH"
export FM_CREW_STATE_BIN=$FAKE/fm-crew-state.sh
export FM_FAKE_VERDICT=$TMP/verdict
count_records() { find "$STATE/t1.inbox" -name '*.msg' -type f 2>/dev/null | wc -l | tr -d ' '; }

printf 'state: parked · source: run-step · parked at document: 2 finding(s) · run: run-a\n' > "$FM_FAKE_VERDICT"
"$ROOT/bin/fm-worker-gate-doorbell.sh" scan || fail 'first gate scan failed'
[ "$(count_records)" = 1 ] || fail 'first gate did not create one durable record'
"$ROOT/bin/fm-worker-gate-doorbell.sh" scan || fail 'replayed gate scan failed'
[ "$(count_records)" = 1 ] || fail 'same gate duplicated its record'
printf 'state: parked · source: run-step · parked at review: 1 finding(s) · run: run-a\n' > "$FM_FAKE_VERDICT"
"$ROOT/bin/fm-worker-gate-doorbell.sh" scan || fail 'new gate scan failed'
[ "$(count_records)" = 2 ] || fail 'new gate was not delivered'
printf 'state: parked · source: run-step · parked at review: 1 finding(s) · run: run-b\n' > "$FM_FAKE_VERDICT"
"$ROOT/bin/fm-worker-gate-doorbell.sh" scan || fail 'new run scan failed'
[ "$(count_records)" = 3 ] || fail 'new run was collapsed into prior gate'
printf 'state: working · source: run-step · validating (running) · run: run-b\n' > "$FM_FAKE_VERDICT"
"$ROOT/bin/fm-worker-gate-doorbell.sh" scan || fail 'working scan failed'
[ "$(count_records)" = 3 ] || fail 'working state created a gate doorbell'
pass 'parked run gates create one durable record per run and gate'

printf 'state: parked · source: run-step · parked at document: 1 finding(s) · run: run-c\n' > "$FM_FAKE_VERDICT"
mv "$STATE/t1.meta" "$STATE/t1.meta.saved"
printf 'kind=ship\n' > "$STATE/t1.meta"
"$ROOT/bin/fm-worker-gate-doorbell.sh" scan > "$TMP/gate-failure.log" 2>&1 || fail 'gate failure capture failed'
"$ROOT/bin/fm-worker-gate-doorbell.sh" scan || fail 'gate failure replay failed'
[ "$(wc -l < "$STATE/.wake-queue" | tr -d ' ')" = 1 ] || fail 'unreachable gate worker must produce exactly one supervisor wake'
# Simulate interruption after queue append but before failure publication.
rm "$STATE/worker-doorbells/"*.failure
"$ROOT/bin/fm-worker-gate-doorbell.sh" scan || fail 'interrupted failure publication recovery failed'
[ "$(wc -l < "$STATE/.wake-queue" | tr -d ' ')" = 1 ] || fail 'failure publication recovery duplicated supervisor wake'
# Expire the persisted retry deadline and prove a failed retry stays quiet.
for record in "$STATE/worker-doorbells/"*.failure; do printf '0 30 1\n' > "$record"; done
"$ROOT/bin/fm-worker-gate-doorbell.sh" scan || fail 'gate retry failed'
[ "$(wc -l < "$STATE/.wake-queue" | tr -d ' ')" = 1 ] || fail 'gate retry duplicated supervisor wake'
rm "$STATE/.wake-queue"
[ "$(count_records)" = 3 ] || fail 'failed gate delivery wrote a record'
mv "$STATE/t1.meta.saved" "$STATE/t1.meta"
pass 'failed gate delivery is reported for supervision'

unset FM_CREW_STATE_BIN
JOB="$ROOT/bin/fm-procevent-worker-job.sh"
TRIGGER=$TMP/job-finished
cat > "$TMP/wait-job.sh" <<'SH'
#!/usr/bin/env bash
while [ ! -e "$1" ]; do sleep 0.05; done
exit 7
SH
chmod +x "$TMP/wait-job.sh"
"$JOB" arm t1 measurement -- "$TMP/wait-job.sh" "$TRIGGER" >/dev/null || fail 'job registration failed'
source=$(find "$STATE/procevent" -name 'worker-job-*.source' -print | head -1)
[ -n "$source" ] || fail 'job source missing'
id=${source##*/}
id=${id%.source}
"$ROOT/bin/fm-procevent.sh" start "$id" > "$TMP/job.log" 2>&1 &
runner=$!
sleep 0.2
[ "$(count_records)" = 3 ] || fail 'job rang before completion'
: > "$TRIGGER"
wait "$runner" || fail "job runner failed: $(cat "$TMP/job.log")"
[ "$(count_records)" = 4 ] || fail "job completion did not reach inbox: $(cat "$TMP/job.log")"
if [ -s "$STATE/.wake-queue" ]; then
  fail 'successful job completion spent a supervisor wake'
fi
result="$STATE/procevent-inbox/$id.1.result"
[ -f "$result" ] || result=$(find "$STATE" -name "$id.1.result" -print | head -1)
[ -f "$result" ] || fail 'captured job result missing'
"$JOB" autohandle "$id" 1 "$result" || fail 'job replay failed'
[ "$(count_records)" = 4 ] || fail 'job replay duplicated its record'
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
[ "$(count_records)" = 4 ] || fail 'reconciliation duplicated completion'
pass 'registered job completion delivers once, including replay'

if "$JOB" arm missing invalid -- /bin/true > "$TMP/invalid.log" 2>&1; then
  fail 'missing task was accepted as a job target'
fi
if [ "$(count_records)" != 4 ]; then
  fail 'invalid fixture changed the observed record count'
fi
pass 'invalid job target is rejected without delivery'

"$JOB" arm t1 missing-target -- /bin/true >/dev/null || fail 'failure-path job registration failed'
source=$(find "$STATE/procevent" -name 'worker-job-*.source' -print | head -1)
id=${source##*/}
id=${id%.source}
mv "$STATE/t1.meta" "$STATE/t1.meta.hidden"
"$ROOT/bin/fm-procevent.sh" start "$id" > "$TMP/failure.log" 2>&1 || fail 'failure-path capture failed'
[ "$(count_records)" = 4 ] || fail 'unresolved target unexpectedly received a record'
if ! grep -q 'check: worker-doorbell' "$STATE/.wake-queue"; then
  fail 'failed worker delivery was not announced to supervision'
fi
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
[ "$(wc -l < "$STATE/.wake-queue" | tr -d ' ')" = 1 ] || fail 'unreachable job worker must produce exactly one supervisor wake'
for record in "$STATE/worker-doorbells/"*.failure; do printf '0 30 1\n' > "$record"; done
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
[ "$(wc -l < "$STATE/.wake-queue" | tr -d ' ')" = 1 ] || fail 'job retry duplicated supervisor wake'
mv "$STATE/t1.meta.hidden" "$STATE/t1.meta"
for record in "$STATE/worker-doorbells/"*.failure; do printf '0 30 1\n' > "$record"; done
result=$(find "$STATE" -name "$id.1.result" -print | head -1)
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || fail 'recovered delivery failed'
[ "$(count_records)" = 5 ] || fail 'recovered result was not delivered'
pass 'failed job delivery remains visible and recoverable'
