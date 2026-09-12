#!/usr/bin/env bash
# Regression guard for bin/fm-install-treehouse.sh's download resilience.
#
# CI incident: GitHub's release CDN reset the connection mid-download for the
# pinned Treehouse archive, and the installer had no retry, so a single
# transient network blip failed the entire required real-Herdr job. Mirrors
# the retry contract fm-lint.test.sh already proves for
# bin/fm-install-shellcheck.sh's installer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-install-treehouse.sh"
TREEHOUSE_SHA_LINUX_X86_64=1d5a32751ab921670103fd201ddb2b91b47338cb13976f45642b827cf8976af2

# fm_install_stub_uname <fakebin>: uname -s / uname -m from FM_TEST_UNAME_S/M.
fm_install_stub_uname() {
  local fakebin=$1
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FM_TEST_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FM_TEST_UNAME_S:-Linux}" ;;
esac
SH
  chmod +x "$fakebin/uname"
}

# fm_install_stub_curl <fakebin>: log the URL, fail CURL_FAIL_UNTIL times, then
# write an empty file at -o. CURL_COUNT is a path the stub updates when invoked.
fm_install_stub_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "${CURL_COUNT:-}" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
[ -z "${CURL_COUNT:-}" ] || printf '%s\n' "$count" > "$CURL_COUNT"
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *) shift ;;
  esac
done
fail_until=${CURL_FAIL_UNTIL:-0}
[ "$count" -gt "$fail_until" ] || exit 35
: > "$out"
exit 0
SH
  chmod +x "$fakebin/curl"
}

fm_install_stub_hasher() {
  local fakebin=$1
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
printf '%s  %s\n' "${SHA256_STUB_HASH:?}" "$1"
SH
  chmod +x "$fakebin/sha256sum"
}

# fm_install_stub_tar_treehouse <fakebin>: -C target gets a `treehouse` binary
# at the archive root that prints the pinned version on --version.
fm_install_stub_tar_treehouse() {
  local fakebin=$1
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    cat > "$2/treehouse" <<'EOF'
#!/usr/bin/env bash
printf 'v2.0.1\n'
EOF
    chmod +x "$2/treehouse"
    exit 0
  fi
  shift
done
exit 2
SH
  chmod +x "$fakebin/tar"
}

fm_install_stub_sleep() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

test_installer_retries_transient_download_failure() {
  local tmp fakebin destination out
  tmp=$(fm_test_tmproot fm-treehouse-download)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin"
  fm_install_stub_tar_treehouse "$fakebin"
  fm_install_stub_sleep "$fakebin"

  # Reproduce the CI incident: the release CDN reset the connection for the
  # first three attempts before recovering. Force linux/x86_64 so the retry
  # path stays the CI archive even when this suite runs on macOS.
  out=$(CURL_COUNT="$tmp/curl-count" CURL_FAIL_UNTIL=3 \
    SHA256_STUB_HASH="$TREEHOUSE_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) \
    || fail "installer did not recover from a transient download failure"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 4 ] || fail "installer did not recover after three failed downloads"
  assert_contains "$out" "download attempt 3 failed; retrying" "installer did not disclose its third retry"
  [ -x "$destination/treehouse" ] || fail "installer did not install treehouse after retrying"
  pass "Treehouse installer retries a transient download failure"
}

test_installer_gives_up_after_exhausting_retries() {
  local tmp fakebin destination out rc
  tmp=$(fm_test_tmproot fm-treehouse-download-exhausted)
  fakebin=$(fm_fakebin "$tmp")
  destination="$tmp/bin"

  fm_install_stub_uname "$fakebin"
  fm_install_stub_curl "$fakebin"
  fm_install_stub_hasher "$fakebin"
  fm_install_stub_tar_treehouse "$fakebin"
  fm_install_stub_sleep "$fakebin"

  rc=0
  out=$(CURL_COUNT="$tmp/curl-count" CURL_FAIL_UNTIL=99 \
    SHA256_STUB_HASH="$TREEHOUSE_SHA_LINUX_X86_64" \
    FM_TEST_UNAME_S=Linux FM_TEST_UNAME_M=x86_64 \
    PATH="$fakebin:$PATH" "$INSTALLER" "$destination" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installer succeeded despite an always-failing download"$'\n'"$out"
  [ "$(cat "$tmp/curl-count")" -eq 6 ] || fail "installer did not stop after its documented attempt cap"
  assert_contains "$out" "download failed for" "installer did not report the exhausted-retry failure"
  [ ! -e "$destination/treehouse" ] || fail "installer installed treehouse despite exhausting retries"
  pass "Treehouse installer gives up after exhausting its retry budget"
}

test_installer_retries_transient_download_failure
test_installer_gives_up_after_exhausting_retries
