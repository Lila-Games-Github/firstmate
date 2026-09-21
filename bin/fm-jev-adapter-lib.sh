# shellcheck shell=bash
# Shared opt-in gate for the explicitly invoked Jev adapters.
# Usage: . bin/fm-jev-adapter-lib.sh
#
# bin/fm-dispatch-resolve.sh names its off reason on stderr and exits zero when
# its key is absent. This is that contract for the Jev adapters a human or a
# workflow step runs by name: accept-check, commit-lint, and open-questions all
# say why they are doing nothing instead of exiting silently, since an operator
# who enabled the feature with no key otherwise gets no feedback from any
# surface. The presentation-path triage hook stays silent by design and does not
# use this helper.

# fm_jev_adapter_ready <use>
# 0 when <use> is configured on and a key is resolvable, leaving the effective
# mode in FM_JEV_ADAPTER_MODE. Otherwise prints one "<use>: off (<reason>)" line
# on stderr and returns 1. Never prints the key or any part of it.
FM_JEV_ADAPTER_MODE=off
fm_jev_adapter_ready() { # <use>
  local use=$1 dir status mode reason key explanation
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FM_JEV_ADAPTER_MODE=off
  status=$("$dir/fm-jev.sh" status "$use" 2>/dev/null) || status=
  if [ -z "$status" ]; then
    printf '%s: off (bin/fm-jev.sh could not report its configuration)\n' "$use" >&2
    return 1
  fi
  IFS=$'\t' read -r mode reason key explanation <<<"$status"
  FM_JEV_ADAPTER_MODE=${mode:-off}
  if [ "$FM_JEV_ADAPTER_MODE" = off ] || [ "$key" != present ] || [ "$reason" != none ]; then
    printf '%s: off (%s)\n' "$use" "${explanation:-${reason:-unavailable}}" >&2
    FM_JEV_ADAPTER_MODE=off
    return 1
  fi
  return 0
}
