#!/usr/bin/env bash
# Public CLI fixtures for timestamped phase, wait, historical, and malformed data.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB=$(fm_test_tmproot fm-worker-timing)
trap 'rm -rf "$LAB"' EXIT
TOOL="$ROOT/bin/fm-worker-timing.py"
mkdir -p "$LAB/data" "$LAB/state" "$LAB/project"

cat > "$LAB/events.json" <<'EOF'
[
  {"at":100,"line":"phase: investigating - plan"},
  {"at":110,"line":"phase: building - code"},
  {"at":130,"line":"paused: test-service request=one"},
  {"at":140,"line":"resolved: test service finished"},
  {"at":150,"line":"phase: testing - suite"},
  {"at":160,"line":"phase: fixing - repair"},
  {"at":170,"line":"needs-decision: approval"},
  {"at":180,"line":"resolved: approved"},
  {"at":190,"line":"phase: validating - checks"},
  {"at":200,"line":"phase: ready-to-merge - branch"}
]
EOF
python3 "$TOOL" calculate --events "$LAB/events.json" --start 100 --end 210 > "$LAB/result.json"
jq -e '.phase_seconds == {planning:10,developing:30,testing:20,fixing:20,landing:10}
  and .waiting_seconds.test_service == 10 and .waiting_seconds.captain == 10
  and .timing_unknown_reason == null' "$LAB/result.json" >/dev/null \
  || fail "known phase and wait durations differ"
pass "timestamped phases and waiting causes have exact durations"

printf '%s\n' 'phase: investigating - plan' > "$LAB/state/observed.status"
python3 "$TOOL" observe --state "$LAB/state" --id observed
printf '%s\n' 'phase: building - code' >> "$LAB/state/observed.status"
python3 "$TOOL" observe --state "$LAB/state" --id observed
python3 "$TOOL" observe --state "$LAB/state" --id observed
jq -e '.events | length == 2' "$LAB/state/observed.timing-events.json" >/dev/null \
  || fail "status observation duplicated or missed an append"
pass "append observations are incremental and idempotent"

start=$(( $(date +%s) - 20 ))
cat > "$LAB/state/live.meta" <<EOF
project=$LAB/project
kind=ship
mode=no-mistakes
routing_instance_id=live-one
routing_started_at=$start
routing_relaunches=1
EOF
printf '%s\n' 'phase: investigating - plan' > "$LAB/state/live.status"
python3 "$TOOL" observe --state "$LAB/state" --id live
sleep 1
printf '%s\n' 'phase: building - code' >> "$LAB/state/live.status"
python3 "$TOOL" observe --state "$LAB/state" --id live
python3 "$TOOL" record --meta "$LAB/state/live.meta" --state "$LAB/state" \
  --data "$LAB/data" --id live --outcome landed --method pr-merge
live_file=$(find "$LAB/data/worker-timing" -name '*.jsonl' -print -quit)
jq -e 'select(.task_id == "live") | .wall_seconds >= 20 and .phase_seconds.planning > 0
  and .phase_seconds.developing >= 0 and .relaunches == 1' "$live_file" >/dev/null \
  || fail "observed task was not retained with phase timing"
pass "observed task persists phase timing by project"

printf '%s' '{broken timing row' >> "$live_file"
cat > "$LAB/state/legacy.meta" <<EOF
project=$LAB/project
kind=ship
mode=no-mistakes
routing_instance_id=legacy-one
EOF
printf '%s\n' '{broken routing row' > "$LAB/data/routing-ledger.jsonl"
python3 "$TOOL" record --meta "$LAB/state/legacy.meta" --state "$LAB/state" \
  --data "$LAB/data" --id legacy --outcome landed --method pr-merge
one=$(find "$LAB/data/worker-timing" -name '*.jsonl' -print -quit)
python3 - "$one" <<'PY' || fail "missing start or malformed timing ledger handling failed"
import json
import sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        rows.append(json.loads(line))
    except json.JSONDecodeError:
        pass
legacy = next(row for row in rows if row.get("task_id") == "legacy")
assert legacy["wall_seconds"] is None
assert legacy["phase_seconds"] is None
assert legacy["timing_unknown_reason"] == "start time absent"
PY
pass "missing start stays unknown and malformed timing history is skipped"

printf '%s\n' '{"schema":1,"task_id":"historical","instance_id":"old","project":"/tmp/p","kind":"ship","delivery_mode":"no-mistakes","routing":{"harness":"pi","model":"x","effort":"high"},"started_at":"1970-01-01T00:01:40+00:00","ended_at":"1970-01-01T00:03:20+00:00","wall_seconds":100,"outcome":{"landed":true,"method":"pr-merge"},"failed_rounds":2,"relaunches":1}' > "$LAB/data/routing-ledger.jsonl"
python3 "$TOOL" backfill --data "$LAB/data" > "$LAB/backfill.txt"
python3 "$TOOL" backfill --data "$LAB/data" > "$LAB/backfill-again.txt"
rg -q 'routing_source=1 total_timed=1 new_records=1 phase_timed=0' "$LAB/backfill.txt" \
  || fail "backfill source counts incorrect"
rg -q 'new_records=0' "$LAB/backfill-again.txt" || fail "backfill duplicated a task"
python3 "$TOOL" report --data "$LAB/data" > "$LAB/report.txt"
rg -q 'source_records=3 total_timed=2 phase_timed=1' "$LAB/report.txt" \
  || fail "report counts incorrect"
mkdir -p "$LAB/bad-data"
printf '%s\n' '{broken routing row' '{"task_id":"null-outcome","project":"/tmp/p","outcome":null,"routing":null}' \
  > "$LAB/bad-data/routing-ledger.jsonl"
python3 "$TOOL" backfill --data "$LAB/bad-data" > "$LAB/bad-backfill.txt"
rg -q 'routing_source=1 total_timed=0 new_records=1' "$LAB/bad-backfill.txt" \
  || fail "malformed and null-outcome routing history was not handled"
pass "routing backfill is idempotent and report names observed counts"

printf '%s\n' '[{"at":"broken","line":"phase: building"},{"at":110,"line":"phase: testing"}]' > "$LAB/bad.json"
if python3 "$TOOL" calculate --events "$LAB/bad.json" --start 100 --end 120 \
    --strict > "$LAB/bad-result.json" 2> "$LAB/bad-error.txt"; then
  fail "known-bad fixture passed strict validation"
fi
jq -e '.phase_seconds == null and .timing_unknown_reason != null' "$LAB/bad-result.json" >/dev/null \
  || fail "known-bad fixture was accepted as measured"
rg -q 'invalid timing fixture' "$LAB/bad-error.txt" || fail "validator did not name rejection"
pass "bad timestamp fixture is rejected as measured timing"
