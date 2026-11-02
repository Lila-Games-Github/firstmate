#!/usr/bin/env bash
# Verify config-owned quick commands and touched-file mapping in a real request.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
tmp=$(fm_test_tmproot fm-test-service-quick)
svc="$ROOT/bin/fm-test-service.py"
export HOME="$tmp/home" FM_HOME="$tmp/fm" FM_TEST_SERVICE_STATE="$tmp/state"
export PATH="$tmp/bin:$PATH"
mkdir -p "$HOME" "$FM_HOME/config/test-service" "$tmp/bin" "$tmp/project"
cat > "$tmp/bin/adb" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = devices ]; then printf 'List of devices attached\nPHONE\tdevice\n'; exit 0; fi
shift 3
case "$*" in
  'input keyevent KEYCODE_WAKEUP'|'settings put global stay_on_while_plugged_in 2') exit 0 ;;
  'settings get global stay_on_while_plugged_in') echo 2 ;;
  'dumpsys window') echo 'isKeyguardShowing=false' ;;
esac
EOF
chmod +x "$tmp/bin/adb"
cat > "$FM_HOME/config/test-service/project.json" <<'EOF'
{"suite":["full.sh"],"quick_suite":["quick.sh"],"device":["long-phone.sh","{serial}"],"quick_device":["short-phone.sh","{serial}"],"phones":["PHONE"],"landing_branch":"main"}
EOF
git init -q -b main "$tmp/project"
git -C "$tmp/project" config user.name Test
git -C "$tmp/project" config user.email test@example.com
cat > "$tmp/project/full.sh" <<'EOF'
#!/usr/bin/env bash
echo full >> "$HOME/events"
EOF
cat > "$tmp/project/quick.sh" <<'EOF'
#!/usr/bin/env bash
printf 'quick:%s\n' "$*" >> "$HOME/events"
EOF
cat > "$tmp/project/long-phone.sh" <<'EOF'
#!/usr/bin/env bash
echo long-phone >> "$HOME/events"
EOF
cat > "$tmp/project/short-phone.sh" <<'EOF'
#!/usr/bin/env bash
echo short-phone >> "$HOME/events"
EOF
chmod +x "$tmp/project/"*.sh
git -C "$tmp/project" add .
git -C "$tmp/project" commit -qm base
base=$(git -C "$tmp/project" rev-parse HEAD)
printf 'change\n' > "$tmp/project/app.txt"
git -C "$tmp/project" add .
git -C "$tmp/project" commit -qm change
head=$(git -C "$tmp/project" rev-parse HEAD)
"$svc" serve > "$tmp/server.log" 2>&1 & server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true; fm_test_cleanup' EXIT
request=$("$svc" submit project "$tmp/project" "$head" --suite --check quick --target "$base" --device-gate PHONE --receipt "$tmp/quick.receipt")
"$svc" wait "$request" | grep -q "^passed $head"
grep -q '^quick:app.txt$' "$HOME/events" || fail 'quick suite did not receive the touched file'
grep -q '^short-phone$' "$HOME/events" || fail 'quick check did not use the short phone command'
! grep -q '^full$\|^long-phone$' "$HOME/events" || fail 'quick check ran a full command'
[ "$(cat "$tmp/quick.receipt")" = "$(printf 'schema=fm-quick-check.v1\nsha=%s\ntarget=%s' "$head" "$base")" ] \
  || fail 'quick receipt did not bind exact head and target'
if "$svc" submit project "$tmp/project" "$head" --suite --check quick --target "$base" --device-gate PHONE --retest-on-move > "$tmp/rejected" 2>&1; then
  fail 'quick retest-on-move was accepted'
fi
pass 'test service runs configured touched-file and short-phone commands and binds a quick receipt'
