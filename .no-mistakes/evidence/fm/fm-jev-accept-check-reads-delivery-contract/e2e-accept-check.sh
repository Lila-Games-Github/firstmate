#!/usr/bin/env bash
# End-to-end: real fm-brief.sh briefs (each delivery mode) -> fm-jev-accept-check.sh
# against the local Jev fixture server; compare base (e5332db) vs this change.
set -u
ROOT=$1
W=$(mktemp -d /tmp/fm-accept-e2e.XXXX)
trap 'kill $SRV 2>/dev/null; rm -rf "$W"' EXIT
python3 "$ROOT/tests/jev-http-server.py" "$W/port" "$W/req.jsonl" & SRV=$!
for _ in $(seq 20); do [ -s "$W/port" ] && break; sleep 0.1; done
EP="http://127.0.0.1:$(cat "$W/port")/v1/systemone"
cp -r "$ROOT/bin" "$W/basebin"
git -C "$ROOT" show e5332db:bin/fm-jev-accept-check.sh > "$W/basebin/fm-jev-accept-check.sh"
for mode in local-only no-mistakes direct-PR; do
  H="$W/home-$mode"; mkdir -p "$H/config" "$H/state" "$H/data"
  printf 'TYPESAFE_API_KEY=test-only-key\n' > "$H/.env"
  cat > "$H/config/jev.json" <<'JSON'
{"version":1,"kill_switch":false,"per_call_token_cap":32000,"daily":{"call_cap":100,"spend_usd_cap":1},
 "uses":{"accept-check":{"mode":"shadow","confidence_floor":0.8,"daily":{"call_cap":100,"spend_usd_cap":1}},
  "triage":{"mode":"off","confidence_floor":0.65},
  "commit-lint":{"mode":"off","confidence_floor":0.8,"daily":{"call_cap":100,"spend_usd_cap":1}},
  "open-questions":{"mode":"off","confidence_floor":0.65,"daily":{"call_cap":100,"spend_usd_cap":1}}}}
JSON
  FM_HOME="$H" bash "$ROOT/bin/fm-brief.sh" task-a firstmate --mode "$mode" >/dev/null
  B="$H/data/task-a/brief.md"
  python3 - "$B" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("{TASK}","Level 0 region fills the phone screen. Done when the level-0 region fills the phone viewport with no letterbox.")
s=s.replace("{FIRSTMATE_SPEC}","Context: see bin/example.sh.\n\n1. Scale the region to the viewport.\n2. Add a regression test covering phone aspect ratios.")
open(p,"w").write(s)
PY
  printf 'Scaled the region in bin/example.sh; the level-0 region now fills the phone viewport with no letterbox; added tests/example.test.sh covering phone aspect ratios. Committed on fm/task-a (local-only, no push).\n' > "$H/data/task-a/report.md"
  for which in base new; do
    [ $which = base ] && S="$W/basebin/fm-jev-accept-check.sh" || S="$ROOT/bin/fm-jev-accept-check.sh"
    rm -f "$H/data/task-a/acceptance.json"
    FM_HOME="$H" FM_JEV_TESTING=1 FM_JEV_TEST_ENDPOINT="$EP" bash "$S" task-a 2>/dev/null
    echo "=== mode=$mode  extractor=$which ==="
    if [ -f "$H/data/task-a/acceptance.json" ]; then
      jq -r '"verdict: \(.verdict)", (.criteria[] | "  \(.id) met=\(.met): \(.text | gsub("\n";" ⏎ ") | .[0:110])")' "$H/data/task-a/acceptance.json"
    else echo "  (no acceptance.json written)"; fi
  done
done
