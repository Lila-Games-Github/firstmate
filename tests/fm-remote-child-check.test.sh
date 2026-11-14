#!/usr/bin/env bash
# Parent heartbeat reads a fake remote home's live child records over fm-on.
set -u
. "$(dirname "$0")/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(fm_test_tmproot fm-remote-child-check)
PARENT="$TMP/parent"
REMOTE="$TMP/remote"
FAKEBIN=$(fm_fakebin "$TMP/fake")
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state"
trap 'rm -rf -- "$TMP"' EXIT
cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS work (host: fake-host; root: $ROOT; home: $REMOTE; scope: iOS; projects: alpha; added 2026-11-14)
EOF
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = fake-host ] && [ "$2" = fm-remote-entrypoint.sh ] || exit 91
shift 3
root=$(printf '%s' "$1" | base64 -d)
home=$(printf '%s' "$2" | base64 -d)
encoded=$3
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$encoded" | base64 -d)
if [ "${args[0]}" = fm-remote-child-inventory.sh ] && [ -f "$FM_FAKE_REMOTE_DOWN" ]; then exit 255; fi
if [ "${args[0]}" = fm-remote-parent-ack.sh ] && [ -f "$FM_FAKE_DROP_ACK" ]; then
  rm -f "$FM_FAKE_DROP_ACK"
  exit 255
fi
FM_HOME="$home" exec "$root/bin/${args[0]}" "${args[@]:1}"
SH
chmod +x "$FAKEBIN/fake-ssh"
check() {
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_DROP_ACK="$TMP/drop-ack" FM_FAKE_REMOTE_DOWN="$TMP/remote-down" FM_REMOTE_CHILD_STALL_SECS=60 \
    FM_REMOTE_CHILD_GH_AXI_BIN="$FAKEBIN/fake-gh-axi" \
    "$ROOT/bin/fm-remote-child-check.sh" scan
}
cat > "$FAKEBIN/fake-gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'summary: 1 passed, 1 failed, 2 total\n'
SH
chmod +x "$FAKEBIN/fake-gh-axi"

out=$(check)
[ -z "$out" ] || fail "healthy idle remote mate produced a notice: $out"
touch "$TMP/remote-down"
out=$(check)
assert_contains "$out" 'unknown: live child inventory unavailable' 'unreachable host was not reported unknown'
rm -f "$TMP/remote-down"
out=$(check)
[ -z "$out" ] || fail "recovered idle mate did not clear the unknown notice: $out"

cat > "$REMOTE/state/stuck.meta" <<EOF
kind=ship
harness=codex
worktree=$TMP/nonexistent
spawn_gen=abc
pr=https://example.test/owner/repo/pull/7
EOF
printf 'working: waiting on checks\n' > "$REMOTE/state/stuck.status"
perl -e 'utime(time-7200, time-7200, $ARGV[0]) or die $!' "$REMOTE/state/stuck.status"
out=$(check)
assert_contains "$out" 'child=stuck' 'stuck child did not reach parent'
assert_contains "$out" 'reason=stalled' 'stuck child was not classified by status age'
assert_contains "$out" 'pr=https://example.test/owner/repo/pull/7' 'recorded PR was omitted'
out=$(check)
[ -z "$out" ] || fail "unchanged stalled child repeated its notice: $out"

perl -e 'utime(time, time, $ARGV[0]) or die $!' "$REMOTE/state/stuck.status"
sed 's@example.test@github.com@' "$REMOTE/state/stuck.meta" > "$REMOTE/state/stuck.meta.tmp"
mv "$REMOTE/state/stuck.meta.tmp" "$REMOTE/state/stuck.meta"
out=$(check)
assert_contains "$out" 'reason=pr-red' 'red PR checks did not wake the parent'

rm -f "$REMOTE/state/stuck.meta" "$REMOTE/state/stuck.status"
printf 'failed [key=child-outcome]: child build failed\n' > "$REMOTE/state/parent-replies.status"
out=$(check)
assert_contains "$out" 'awaiting acknowledgement' 'dropped parent-channel delivery was invisible'
bytes=$(wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
if command -v shasum >/dev/null 2>&1; then
  hash=$(shasum -a 256 "$REMOTE/state/parent-replies.status" | awk '{print $1}')
else
  hash=$(sha256sum "$REMOTE/state/parent-replies.status" | awk '{print $1}')
fi
mkdir -p "$PARENT/state/remote-replies"
cat > "$PARENT/state/remote-replies/ios.cursor" <<EOF
schema=fm-remote-reply-cursor.v1
offset=$bytes
prefix_sha256=$hash
EOF
touch "$TMP/drop-ack"
out=$(check)
[ ! -e "$REMOTE/state/parent-replies.ack" ] || fail 'failed acknowledgement was recorded on remote'
out=$(check)
[ -z "$out" ] || fail "retry did not settle the parent acknowledgement: $out"
[ "$(cat "$REMOTE/state/parent-replies.ack")" = "$bytes" ] || fail 'remote ack did not advance'
pass 'remote child heartbeat and parent-channel acknowledgement retry'
