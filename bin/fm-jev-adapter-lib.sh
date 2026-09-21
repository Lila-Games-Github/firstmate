# shellcheck shell=bash
# Shared opt-in gate for the explicitly invoked Jev adapters.
# Usage: . bin/fm-jev-adapter-lib.sh
#
# bin/fm-dispatch-resolve.sh names its off reason on stderr and exits zero when
# its key is absent. This is that contract for the Jev adapters a human or a
# workflow step runs by name: accept-check, commit-lint, and open-questions all
# say why they are doing nothing instead of exiting silently, since an operator
# who enabled the feature with no key otherwise gets no feedback from any
# surface. The presentation-path triage hooks share the same gate through
# fm_jev_observer_ready, which answers the same question without printing
# anything, because a per-drain diagnostic on the supervision path would be
# noise.

# fm_jev_adapter_ready <use>
# 0 when <use> is configured on and a key is resolvable, leaving the effective
# mode in FM_JEV_ADAPTER_MODE. Otherwise prints one "<use>: off (<reason>)" line
# on stderr and returns 1. Never prints the key or any part of it.
FM_JEV_ADAPTER_MODE=off
fm_jev_adapter_ready() { # <use>
  local use=$1 status mode reason key explanation
  FM_JEV_ADAPTER_MODE=off
  status=$(fm_jev_use_status "$use") || status=
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

fm_jev_use_status() { # <use>
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$dir/fm-jev.sh" status "$1" 2>/dev/null
}

# fm_jev_observer_ready <use>
# 0 when a consultation for <use> could actually be made, and silent either way,
# so a presentation-path hook can skip staging without printing a per-drain
# diagnostic. `mode` alone never resolves the key, and the built-in
# configuration is active, so a hook gated on it would stage every presented
# line and build a whole envelope on every drain of a keyless home only for the
# client to refuse it. `status` settles the key, the kill switch, an unreadable
# configuration and a zero budget share in one call that costs the same.
fm_jev_observer_ready() { # <use>
  local status mode reason key
  status=$(fm_jev_use_status "$1") || status=
  [ -n "$status" ] || return 1
  IFS=$'\t' read -r mode reason key _ <<<"$status"
  [ "${mode:-off}" != off ] && [ "${key:-absent}" = present ] && [ "${reason:-none}" = none ]
}
