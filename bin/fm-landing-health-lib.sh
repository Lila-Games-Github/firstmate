#!/usr/bin/env bash
# Shared parser for project-agnostic full-suite receipts.
# A receipt is a UTF-8 text file with exactly these first three lines:
#   schema=fm-full-suite.v1
#   sha=<full commit SHA>
#   failures=<decimal count>
# Each failure then has one `failure=<stable assertion or check identifier>` line.
# Identifiers are literal, nonempty, single-line strings; duplicate identifiers,
# extra lines, and a count that differs from the failure lines are refused.
# The producer owns running its project's complete suite and choosing stable
# identifiers. This parser binds that claim to a Git commit; it cannot run an
# arbitrary project's suite or attest that the producer was honest.

fm_health_receipt_read() { # <receipt> <expected-full-sha>; sets FM_HEALTH_COUNT, FM_HEALTH_SET
  local receipt=$1 expected=$2 line n=0 declared='' count=0 failures='' seen=''
  # shellcheck disable=SC2034 # Globals returned to the sourcing caller.
  FM_HEALTH_COUNT=
  # shellcheck disable=SC2034 # Globals returned to the sourcing caller.
  FM_HEALTH_SET=
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || {
    echo "error: full-suite receipt is missing or is not a regular file: $receipt" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$n" in
      1) [ "$line" = schema=fm-full-suite.v1 ] || { echo "error: invalid full-suite receipt schema in $receipt" >&2; return 1; } ;;
      2) [ "$line" = "sha=$expected" ] || { echo "error: full-suite receipt SHA does not name exact commit $expected: $receipt" >&2; return 1; } ;;
      3)
        case "$line" in
          failures=*) declared=${line#failures=} ;;
          *) echo "error: missing full-suite failure count in $receipt" >&2; return 1 ;;
        esac
        case "$declared" in
          ''|*[!0-9]*) echo "error: invalid full-suite failure count in $receipt" >&2; return 1 ;;
        esac
        ;;
      *)
        case "$line" in
          failure=?*) failures="${failures}${line#failure=}"$'\n'; count=$((count + 1)) ;;
          *) echo "error: invalid full-suite failure identifier in $receipt" >&2; return 1 ;;
        esac
        ;;
    esac
  done < "$receipt"
  [ "$n" -ge 3 ] && [ "$declared" -eq "$count" ] || {
    echo "error: full-suite receipt count does not match its failure lines: $receipt" >&2
    return 1
  }
  if [ "$count" -gt 0 ]; then
    seen=$(printf '%s' "$failures" | LC_ALL=C sort -u)
    [ "$(printf '%s\n' "$seen" | wc -l | tr -d ' ')" -eq "$count" ] || {
      echo "error: duplicate full-suite failure identifier in $receipt" >&2
      return 1
    }
  fi
  # shellcheck disable=SC2034 # Globals returned to the sourcing caller.
  FM_HEALTH_COUNT=$count
  # shellcheck disable=SC2034 # Globals returned to the sourcing caller.
  FM_HEALTH_SET=$seen
}

fm_health_key() { # <canonical-project-path> <landing-branch>
  printf '%s\n%s\n' "$1" "$2" | git hash-object --stdin
}

fm_health_store() { # <receipt> <data-dir> <key>
  local receipt=$1 data=$2 key=$3 dir tmp
  dir="$data/landing-health"
  [ ! -L "$dir" ] || { echo "error: landing-health directory is a symlink" >&2; return 1; }
  mkdir -p "$dir" || return 1
  tmp="$dir/.$key.${BASHPID:-$$}.tmp"
  cp -- "$receipt" "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dir/$key.receipt" || { rm -f -- "$tmp"; return 1; }
}
