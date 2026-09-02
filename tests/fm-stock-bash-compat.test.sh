#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMPAT="$ROOT/bin/fm-stock-bash-compat.sh"
TIMEOUT_LIB="$ROOT/bin/fm-timeout-lib.sh"

test_hung_inventory_is_named_and_later_consumers_run() {
  local tmp out rc file
  tmp=$(fm_test_tmproot fm-stock-bash-compat)
  mkdir -p "$tmp/bin" "$tmp/tests" "$tmp/runner"
  cp "$COMPAT" "$tmp/bin/fm-stock-bash-compat.sh"
  cp "$TIMEOUT_LIB" "$tmp/bin/fm-timeout-lib.sh"
  cat > "$tmp/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
printf 'inventory started\n'
sleep 10
SH
  chmod +x "$tmp/bin/fm-lint.sh"
  cat > "$tmp/tests/consumer.sh" <<'SH'
#!/usr/bin/env bash
case "${0##*/}" in
  fm-fleet-snapshot-view.test.sh) count=15 ;;
  fm-bearings-snapshot.test.sh) count=42 ;;
  fm-learning-candidate.test.sh) count=29 ;;
  fm-merge-local.test.sh) count=5; printf 'later consumer reached\n' ;;
  *) exit 2 ;;
esac
while [ "$count" -gt 0 ]; do
  printf 'ok - fixture assertion %s\n' "$count"
  count=$((count - 1))
done
SH
  for file in \
    fm-fleet-snapshot-view.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-learning-candidate.test.sh \
    fm-merge-local.test.sh
  do
    cp "$tmp/tests/consumer.sh" "$tmp/tests/$file"
  done

  rc=0
  out=$(cd "$tmp" && RUNNER_TEMP="$tmp/runner" FM_STOCK_BASH_PARSE_TIMEOUT=1 \
    /bin/bash bin/fm-stock-bash-compat.sh 2>&1) || rc=$?
  expect_code 1 "$rc" "hung inventory produces an aggregate compatibility failure"
  assert_contains "$out" "Stock Bash consumer timed out::shell parse sweep exceeded 1s" \
    "hung inventory failure is attributed to the shell parse consumer"
  assert_contains "$out" "later consumer reached" \
    "hung inventory does not suppress the later PR 19 consumer"
  assert_contains "$out" "one or more stock macOS Bash consumers failed" \
    "hung inventory produces the final compatibility verdict"
  pass "stock Bash compatibility: hung inventory is named and later consumers run"
}

test_hung_inventory_is_named_and_later_consumers_run
