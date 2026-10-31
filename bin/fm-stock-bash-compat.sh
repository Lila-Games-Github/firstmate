#!/usr/bin/env bash
# fm-stock-bash-compat.sh - run every stock macOS Bash compatibility consumer.
#
# The caller must run this script under stock macOS Bash 3.2 and provide
# RUNNER_TEMP for streamed per-consumer logs.
# FM_STOCK_BASH_*_TIMEOUT values may shorten individual consumer bounds.
# Every consumer is bounded independently, reports its own verdict, and leaves
# later consumers runnable before the aggregate verdict exits nonzero.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STOCK_BASH=${FM_STOCK_BASH_BIN:-/bin/bash}
PARSE_TIMEOUT=${FM_STOCK_BASH_PARSE_TIMEOUT:-60}
FLEET_TIMEOUT=${FM_STOCK_BASH_FLEET_TIMEOUT:-120}
BEARINGS_TIMEOUT=${FM_STOCK_BASH_BEARINGS_TIMEOUT:-420}
BEARINGS_OVERSIZED_TIMEOUT=${FM_STOCK_BASH_BEARINGS_OVERSIZED_TIMEOUT:-180}
PUBLIC_FOLLOWUP_TIMEOUT=${FM_STOCK_BASH_PUBLIC_FOLLOWUP_TIMEOUT:-60}
WATCH_CHURN_TIMEOUT=${FM_STOCK_BASH_WATCH_CHURN_TIMEOUT:-60}
LEARNING_TIMEOUT=${FM_STOCK_BASH_LEARNING_TIMEOUT:-30}
MERGE_TIMEOUT=${FM_STOCK_BASH_MERGE_TIMEOUT:-120}
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
validate_timeout() {
  case "$2" in
    ''|*[!0-9]*|0) echo "::error::$1 must be a positive integer"; exit 2 ;;
  esac
}
validate_timeout FM_STOCK_BASH_PARSE_TIMEOUT "$PARSE_TIMEOUT"
validate_timeout FM_STOCK_BASH_FLEET_TIMEOUT "$FLEET_TIMEOUT"
validate_timeout FM_STOCK_BASH_BEARINGS_TIMEOUT "$BEARINGS_TIMEOUT"
validate_timeout FM_STOCK_BASH_BEARINGS_OVERSIZED_TIMEOUT "$BEARINGS_OVERSIZED_TIMEOUT"
validate_timeout FM_STOCK_BASH_PUBLIC_FOLLOWUP_TIMEOUT "$PUBLIC_FOLLOWUP_TIMEOUT"
validate_timeout FM_STOCK_BASH_WATCH_CHURN_TIMEOUT "$WATCH_CHURN_TIMEOUT"
validate_timeout FM_STOCK_BASH_LEARNING_TIMEOUT "$LEARNING_TIMEOUT"
validate_timeout FM_STOCK_BASH_MERGE_TIMEOUT "$MERGE_TIMEOUT"

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

echo "stock Bash timeout mechanism: $(fm_timeout_mechanism)"
compatibility_failed=0
run_consumer() {
  label=$1
  seconds=$2
  expected=$3
  shift 3
  output="$RUNNER_TEMP/stock-bash-${label//[^A-Za-z0-9]/-}.log"
  echo "::group::$label"
  set +e
  fm_run_timed "$seconds" "$@" 2>&1 | tee "$output"
  consumer_rc=${PIPESTATUS[0]}
  set -e
  echo "::endgroup::"
  if [ "$consumer_rc" -eq 124 ]; then
    echo "::error title=Stock Bash consumer timed out::$label exceeded ${seconds}s"
    compatibility_failed=1
    return 0
  fi
  if [ "$consumer_rc" -ne 0 ]; then
    echo "::error title=Stock Bash consumer failed::$label exited $consumer_rc"
    compatibility_failed=1
    return 0
  fi
  pass_count=$(grep -c '^ok - ' "$output" || true)
  if [ "$pass_count" -ne "$expected" ]; then
    echo "::error title=Stock Bash consumer incomplete::$label emitted $pass_count of $expected expected assertions"
    compatibility_failed=1
    return 0
  fi
  echo "::notice title=Stock Bash consumer passed::$label emitted $pass_count expected assertions"
}

shell_inventory="$RUNNER_TEMP/fm-shell-inventory"
# shellcheck disable=SC2016 # Variables expand in the child stock Bash.
run_consumer "shell parse sweep" "$PARSE_TIMEOUT" 0 "$STOCK_BASH" -c '
  root=$1
  stock_bash=$2
  shell_inventory=$3
  "$root/bin/fm-lint.sh" --list-files > "$shell_inventory" || exit $?
  [ -s "$shell_inventory" ] || {
    echo "::error::stock Bash shell inventory is empty"
    exit 1
  }
  parse_fail=0
  while IFS= read -r file; do
    "$stock_bash" -n "$file" || {
      echo "::error::stock macOS Bash 3.2 failed to parse $file"
      parse_fail=1
    }
  done < "$shell_inventory"
  [ "$parse_fail" -eq 0 ]
' _ "$ROOT" "$STOCK_BASH" "$shell_inventory"
run_consumer "fleet snapshot and view" "$FLEET_TIMEOUT" 18 \
  "$STOCK_BASH" "$ROOT/tests/fm-fleet-snapshot-view.test.sh"
# Keep the oversized parsed-backlog route separate from the 59-case suite.
# Its own bound preserves a verdict when that CPU-heavy route stalls on Bash 3.2.
run_consumer "Bearings snapshot" "$BEARINGS_TIMEOUT" 59 \
  env FM_BEARINGS_TEST_SKIP_OVERSIZED=1 \
  "$STOCK_BASH" "$ROOT/tests/fm-bearings-snapshot.test.sh"
run_consumer "Bearings oversized parsed-backlog route" "$BEARINGS_OVERSIZED_TIMEOUT" 1 \
  env FM_BEARINGS_TEST_ONLY=oversized-parsed-backlog \
  "$STOCK_BASH" "$ROOT/tests/fm-bearings-snapshot.test.sh"
run_consumer "public-followup empty-lock register" "$PUBLIC_FOLLOWUP_TIMEOUT" 1 \
  env FM_TEST_ONLY=test_first_register_succeeds_with_empty_lock_list_under_bash32 \
  "$STOCK_BASH" "$ROOT/tests/fm-public-followup.test.sh"
run_consumer "watcher churn deferral" "$WATCH_CHURN_TIMEOUT" 1 \
  env FM_TEST_ONLY=test_turn_ended_churn_existing_marker_absorbed \
  "$STOCK_BASH" "$ROOT/tests/fm-watch-triage.test.sh"
run_consumer "PR 18 learning-candidate NUL enumeration" "$LEARNING_TIMEOUT" 1 \
  env FM_LEARNING_TEST_ONLY=stock-bash-summary-enumeration \
  "$STOCK_BASH" "$ROOT/tests/fm-learning-candidate.test.sh"
run_consumer "PR 19 local-merge branch resolution" "$MERGE_TIMEOUT" 17 \
  "$STOCK_BASH" "$ROOT/tests/fm-merge-local.test.sh"
[ "$compatibility_failed" -eq 0 ] || {
  echo "::error::one or more stock macOS Bash consumers failed or did not return a verdict"
  exit 1
}
