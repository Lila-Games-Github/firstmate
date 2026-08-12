#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
LOCK_SESSION="$STATE/.lock-session"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  old_session=$(cat "$LOCK_SESSION" 2>/dev/null || true)
  if fm_session_lock_holder_alive "$STATE"; then
    if [ -n "$old_session" ]; then
      echo "lock: held by live harness pid $old session $old_session"
    else
      echo "lock: held by live harness pid $old"
    fi
  else
    echo "lock: stale (pid $old dead, not a harness, or session archived)"
  fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
me_session=$(fm_playbot_current_session_id 2>/dev/null || true)
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if fm_session_lock_owned_by_self "$STATE"; then
    if [ -n "$me_session" ]; then
      echo "lock acquired: harness pid $me session $me_session"
    else
      echo "lock acquired: harness pid $me"
    fi
    exit 0
  fi
  if fm_session_lock_holder_alive "$STATE"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if ! fm_session_lock_owned_by_self "$STATE" && fm_session_lock_holder_alive "$STATE"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if [ -e "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
  if [ ! -f "$LOCK_SESSION" ] || [ -L "$LOCK_SESSION" ]; then
    echo "error: session lock identity is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
fi
session_tmp=
if [ -n "$me_session" ]; then
  session_tmp=$(mktemp "$STATE/.lock-session.XXXXXX" 2>/dev/null) || {
    echo "error: cannot write session lock identity; operate read-only until resolved" >&2
    exit 1
  }
  if ! printf '%s\n' "$me_session" > "$session_tmp" 2>/dev/null \
    || ! mv -f "$session_tmp" "$LOCK_SESSION" 2>/dev/null; then
    rm -f "$session_tmp" 2>/dev/null || true
    echo "error: cannot publish session lock identity; operate read-only until resolved" >&2
    exit 1
  fi
else
  rm -f "$LOCK_SESSION" 2>/dev/null || {
    echo "error: cannot clear stale session lock identity; operate read-only until resolved" >&2
    exit 1
  }
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ] \
  || ! fm_session_lock_owned_by_self "$STATE"; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
if [ -n "$me_session" ]; then
  echo "lock acquired: harness pid $me session $me_session"
else
  echo "lock acquired: harness pid $me"
fi
