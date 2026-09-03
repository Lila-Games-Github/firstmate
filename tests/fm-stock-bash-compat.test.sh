#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COMPAT="$ROOT/bin/fm-stock-bash-compat.sh"
TIMEOUT_LIB="$ROOT/bin/fm-timeout-lib.sh"

make_fixture() {
  local tmp=$1 file
  mkdir -p "$tmp/bin" "$tmp/tests" "$tmp/runner"
  cp "$COMPAT" "$tmp/bin/fm-stock-bash-compat.sh"
  cp "$TIMEOUT_LIB" "$tmp/bin/fm-timeout-lib.sh"
  cat > "$tmp/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_HANG_CONSUMER:-}" = inventory ]; then
  printf 'consumer started: inventory\n' >&2
  sleep 10
fi
printf '%s\n' "$0"
SH
  chmod +x "$tmp/bin/fm-lint.sh"
  cat > "$tmp/tests/consumer.sh" <<'SH'
#!/usr/bin/env bash
case "${0##*/}" in
  fm-fleet-snapshot-view.test.sh) key=fleet; count=15 ;;
  fm-bearings-snapshot.test.sh)
    if [ "${FM_BEARINGS_TEST_ONLY:-}" = oversized-parsed-backlog ]; then
      key=oversized
      count=1
    else
      key=bearings
      count=41
    fi
    ;;
  fm-learning-candidate.test.sh) key=learning; count=1 ;;
  fm-merge-local.test.sh) key=merge; count=5 ;;
  *) exit 2 ;;
esac
if [ "${FM_TEST_HANG_CONSUMER:-}" = "$key" ]; then
  printf 'consumer started: %s\n' "$key"
  sleep 10
fi
if [ "$key" = learning ]; then
    if [ "${FM_TEST_FAIL_LEARNING:-0}" = 1 ]; then
      printf 'wait: pid 42 is not a child of this shell\n' >&2
      exit 2
    fi
fi
while [ "$count" -gt 0 ]; do
  printf 'ok - fixture assertion %s\n' "$count"
  count=$((count - 1))
done
[ "$key" != merge ] || printf 'later consumer completed\n'
SH
  for file in \
    fm-fleet-snapshot-view.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-learning-candidate.test.sh \
    fm-merge-local.test.sh
  do
    cp "$tmp/tests/consumer.sh" "$tmp/tests/$file"
  done
}

run_fixture() {
  local tmp=$1
  shift
  (cd "$tmp" && env \
    RUNNER_TEMP="$tmp/runner" \
    FM_STOCK_BASH_PARSE_TIMEOUT=1 \
    FM_STOCK_BASH_FLEET_TIMEOUT=1 \
    FM_STOCK_BASH_BEARINGS_TIMEOUT=1 \
    FM_STOCK_BASH_BEARINGS_OVERSIZED_TIMEOUT=1 \
    FM_STOCK_BASH_LEARNING_TIMEOUT=1 \
    FM_STOCK_BASH_MERGE_TIMEOUT=1 \
    "$@" /bin/bash bin/fm-stock-bash-compat.sh 2>&1)
}

test_every_hung_consumer_is_named_and_streamed() {
  local key label tmp out rc
  while IFS='|' read -r key label; do
    tmp=$(fm_test_tmproot "fm-stock-bash-compat-$key")
    make_fixture "$tmp"
    rc=0
    out=$(run_fixture "$tmp" env FM_TEST_HANG_CONSUMER="$key") || rc=$?
    expect_code 1 "$rc" "hung $key consumer produces an aggregate compatibility failure"
    assert_contains "$out" "consumer started: $key" \
      "$key consumer streams output before its deadline"
    assert_contains "$out" "Stock Bash consumer timed out::$label exceeded 1s" \
      "$key failure is attributed to its exact consumer"
    assert_contains "$out" "one or more stock macOS Bash consumers failed" \
      "$key timeout produces the final compatibility verdict"
    if [ "$key" != merge ]; then
      assert_contains "$out" "later consumer completed" \
        "$key timeout does not suppress the later PR 19 consumer"
    fi
  done <<'EOF'
inventory|shell parse sweep
fleet|fleet snapshot and view
bearings|Bearings snapshot
oversized|Bearings oversized parsed-backlog route
learning|PR 18 learning-candidate NUL enumeration
merge|PR 19 local-merge branch resolution
EOF
  pass "stock Bash compatibility: every hung consumer is named, streamed, and independently bounded"
}

test_failed_learning_summary_is_named_and_later_merge_runs() {
  local tmp out rc
  tmp=$(fm_test_tmproot fm-stock-bash-compat-learning)
  make_fixture "$tmp"

  rc=0
  out=$(run_fixture "$tmp" env FM_TEST_FAIL_LEARNING=1) || rc=$?
  expect_code 1 "$rc" "failed PR 18 summary produces an aggregate compatibility failure"
  assert_contains "$out" "wait: pid 42 is not a child of this shell" \
    "PR 18 summary streams its Bash incompatibility"
  assert_contains "$out" "Stock Bash consumer failed::PR 18 learning-candidate NUL enumeration exited 2" \
    "PR 18 summary preserves its exact exit status"
  assert_contains "$out" "later consumer completed" \
    "failed PR 18 summary does not suppress the later PR 19 consumer"
  pass "stock Bash compatibility: failed PR 18 summary is named and later consumers run"
}

test_every_hung_consumer_is_named_and_streamed
test_failed_learning_summary_is_named_and_later_merge_runs
