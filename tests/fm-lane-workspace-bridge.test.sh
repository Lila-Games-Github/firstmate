#!/usr/bin/env bash
# Dispatch-shaped workspace exchange and lane brief behavior.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-lane-workspace-bridge)
repo="$tmp/repo"
worker="$tmp/worker"
home="$tmp/home"
mkdir -p "$repo" "$home/state" "$home/data"
git -C "$repo" init -q
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@example.test
printf 'tracked\n' > "$repo/tracked.txt"
git -C "$repo" add tracked.txt
git -C "$repo" commit -qm base
landing=$(git -C "$repo" symbolic-ref --short HEAD)
target=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" worktree add -qb lane "$worker"

bridge="$ROOT/bin/fm-lane-workspace-bridge.py"
python3 "$bridge" prepare "$home" sample "$worker" > "$tmp/prepared.json"
box="$worker/.firstmate/sample"
[ -f "$box/fm-lane-workspace-bridge.py" ] || fail "dispatch did not install the workspace request endpoint"
git -C "$worker" check-ignore -q "$box/fm-lane-workspace-bridge.py" || fail "exchange is not Git ignored"

printf 'phase: building - source\nworking: source arrived\n' > "$box/status.log"
printf 'handoff\n' > "$box/phase-handoff.md"
printf 'schema=fm-full-suite.v1\nsha=abc\nfailures=0\n' > "$box/receipts/suite.receipt"
printf 'capture\n' > "$box/captures/godot-after.png"
printf '%s\n' '{"op":"uid-collisions","args":["check","bad"]}' > "$box/requests/bad.json"
python3 "$bridge" collect "$home" sample "$worker" > "$tmp/collected.json"
cmp -s "$box/status.log" "$home/state/sample.status" || fail "status lines did not reach firstmate state"
cmp -s "$box/phase-handoff.md" "$home/data/sample/phase-handoff.md" || fail "handoff did not reach firstmate data"
cmp -s "$box/receipts/suite.receipt" "$home/data/sample/receipts/suite.receipt" || fail "receipt did not reach firstmate data"
cmp -s "$box/receipts/suite.receipt" "$home/data/sample/suite.receipt" || fail "suite receipt did not reach its canonical firstmate path"
cmp -s "$box/captures/godot-after.png" "$home/data/sample/captures/godot-after.png" || fail "capture did not reach firstmate data"
python3 - "$tmp/collected.json" "$box/requests/bad.json" "$box/responses/bad.json" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1]))
assert result == {"status_bytes": 49, "files": 3, "requests": 1}, result
assert json.load(open(sys.argv[3]))["code"] == 1
assert json.load(open(sys.argv[2]))["args"] == ["check", "bad"]
PY
printf '%s\n' '{"op":"test-service","args":["submit","fixture-suite","--receipt","/etc/passwd"]}' > "$box/requests/outside.json"
python3 "$bridge" collect "$home" sample "$worker" > /dev/null
python3 - "$box/responses/outside.json" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1]))
assert result["code"] == 1 and "outside its workspace exchange" in result["output"], result
PY
python3 "$bridge" collect "$home" sample "$worker" > /dev/null
[ "$(wc -l < "$home/state/sample.status")" -eq 2 ] || fail "collector replayed status lines"

(cd "$worker" && python3 .firstmate/sample/fm-lane-workspace-bridge.py request base-check "$landing" > "$tmp/base-check.out" 2>&1) &
request_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(find "$box/requests" -maxdepth 1 -name '*.json' | wc -l)" -ge 2 ] && break
  sleep 1
done
python3 "$bridge" collect "$home" sample "$worker" > /dev/null
wait "$request_pid" || fail "workspace helper base check failed: $(cat "$tmp/base-check.out")"
rg -q 'current:' "$tmp/base-check.out" || fail "workspace helper did not return the base verdict"
(cd "$worker" && python3 .firstmate/sample/fm-lane-workspace-bridge.py request uid-collisions check "$target" > "$tmp/uid.out" 2>&1) &
request_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(find "$box/requests" -maxdepth 1 -name '*.json' | wc -l)" -ge 2 ] && break
  sleep 1
done
python3 "$bridge" collect "$home" sample "$worker" > /dev/null
wait "$request_pid" || fail "workspace UID check failed: $(cat "$tmp/uid.out")"
python3 - "$tmp/uid.out" <<'PY'
import json
import sys
result = json.load(open(sys.argv[1]))
assert result["source_untracked_count"] == 0, result
assert result["source_target_tracked_count"] == 1, result
assert result["collision_count"] == 0, result
PY

ln -s "$tmp" "$box/captures/escape"
if python3 "$bridge" collect "$home" sample "$worker" > "$tmp/unsafe.out" 2>&1; then
  fail "collector accepted a symlinked capture"
fi
rm "$box/captures/escape"

mkdir -p "$tmp/testfarm/compat"
cat > "$tmp/testfarm/compat/fm-test-service.py" <<'PY'
#!/usr/bin/env python3
import sys
if sys.argv[1:2] == ["project-for-repo"]:
    print("fixture-suite")
else:
    sys.exit(2)
PY
for mode in local-only direct-PR no-mistakes; do
  FM_HOME="$home" TESTFARM_CHECKOUT="$tmp/testfarm" "$ROOT/bin/fm-brief.sh" "brief-$mode" fixture --mode "$mode" --lane --landing-branch main --no-template fixture > /dev/null
  file="$home/data/brief-$mode/brief.md"
  if rg -F "$tmp" "$file" >/dev/null || rg -F "$ROOT" "$file" >/dev/null; then
    fail "$mode lane brief named a path outside its workspace"
  fi
  python3 - "$file" <<'PY' || fail "$mode lane brief contains an absolute filesystem path"
import pathlib
import re
import sys
text = pathlib.Path(sys.argv[1]).read_text()
text = re.sub(r"https?://\S+", "", text)
text = text.replace("$(git rev-parse --show-toplevel)/.firstmate/", ".firstmate/")
absolute = r"(?<![\w/])/(?:[A-Za-z0-9._-]+/)+[A-Za-z0-9._-]*"
assert re.search(absolute, "Read /var/private/reference before dispatch")
assert not re.search(absolute, text)
PY
  rg -q "\.firstmate/brief-$mode/status.log" "$file" || fail "$mode lane brief lacks its workspace status path"
  rg -q 'request test-service submit fixture-suite' "$file" || fail "$mode lane brief omitted its workspace service request"
done
if FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-herdr fixture --mode direct-PR --lane --landing-branch main --herdr-lab --no-template fixture > "$tmp/herdr.out" 2>&1; then
  fail "lane brief allowed an outside-workspace Herdr helper"
fi
rg -q 'workspace exchange' "$tmp/herdr.out" || fail "Herdr refusal omitted the workspace reason"

pass "lane workspace exchange: 2 status lines and 3 files collected; base and UID checks ran on the real worktree; bad request and symlink rejected; 3 lane modes stay workspace-local"
