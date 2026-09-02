#!/usr/bin/env bash
# fm-stock-bash-compat.sh - run every stock macOS Bash compatibility consumer.
#
# The caller must run this script under stock macOS Bash 3.2 and provide
# RUNNER_TEMP for streamed per-consumer logs.
# FM_STOCK_BASH_PARSE_TIMEOUT may shorten the shell inventory and parse bound.
# Every consumer is bounded independently, reports its own verdict, and leaves
# later consumers runnable before the aggregate verdict exits nonzero.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STOCK_BASH=${FM_STOCK_BASH_BIN:-/bin/bash}
PARSE_TIMEOUT=${FM_STOCK_BASH_PARSE_TIMEOUT:-60}
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
case "$PARSE_TIMEOUT" in ''|*[!0-9]*|0) echo "::error::FM_STOCK_BASH_PARSE_TIMEOUT must be a positive integer"; exit 2 ;; esac

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
  fi
}

shell_inventory="$RUNNER_TEMP/fm-shell-inventory"
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
run_consumer "fleet snapshot and view" 120 15 \
  "$STOCK_BASH" "$ROOT/tests/fm-fleet-snapshot-view.test.sh"
run_consumer "Bearings snapshot" 180 42 \
  "$STOCK_BASH" "$ROOT/tests/fm-bearings-snapshot.test.sh"
run_consumer "PR 18 learning-candidate NUL enumeration" 180 29 \
  "$STOCK_BASH" "$ROOT/tests/fm-learning-candidate.test.sh"
run_consumer "PR 19 local-merge branch resolution" 120 5 \
  "$STOCK_BASH" "$ROOT/tests/fm-merge-local.test.sh"
[ "$compatibility_failed" -eq 0 ] || {
  echo "::error::one or more stock macOS Bash consumers failed or did not return a verdict"
  exit 1
}
