#!/usr/bin/env bash
# A remote summary read must not turn an unseeded secondmate route into a home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-file-unseeded-home)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

REMOTE_HOME="$TMP_ROOT/remote-home"
if env -u FM_STATE_OVERRIDE FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-remote-file.sh" get state/home-summary.json \
  > "$TMP_ROOT/get.out" 2>&1; then
  fail "a missing remote summary unexpectedly read successfully"
fi
assert_absent "$REMOTE_HOME" "a failed read created an unseeded remote home"

printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
  "$(printf 'remote-test' | base64 | tr -d '\n')" \
  "$(printf 'Remote test charter.\n' | base64 | tr -d '\n')" \
  > "$TMP_ROOT/manifest"
env -u FM_STATE_OVERRIDE FM_HOME="$REMOTE_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/manifest" > "$TMP_ROOT/provision.out" \
  || fail "provisioning a home after a failed summary read did not succeed"
assert_present "$REMOTE_HOME/.fm-secondmate-home" "remote home was not seeded"
[ "$(cat "$REMOTE_HOME/.fm-secondmate-home")" = remote-test ] \
  || fail "remote home marker names the wrong secondmate"
pass "a missing remote summary leaves an absent home available for real provisioning"

OCCUPIED_HOME="$TMP_ROOT/occupied-home"
mkdir -p "$OCCUPIED_HOME/state"
printf 'existing work\n' > "$OCCUPIED_HOME/state/work"
if env -u FM_STATE_OVERRIDE FM_HOME="$OCCUPIED_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/manifest" \
  > "$TMP_ROOT/occupied.out" 2>&1; then
  fail "provisioning accepted an occupied unseeded home"
fi
assert_grep 'existing remote home is not a safe Firstmate checkout' "$TMP_ROOT/occupied.out" \
  "occupied home refusal changed"
[ "$(cat "$OCCUPIED_HOME/state/work")" = 'existing work' ] \
  || fail "refused provision changed occupied home data"
pass "occupied unseeded homes remain protected"

echo "ALL TESTS PASSED"
