#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'
FM_SESSION_LOCK_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_SESSION_LOCK_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$FM_SESSION_LOCK_LIB_DIR/.." && pwd)}
FM_WINDOWS_HARNESS_PROCESS_HELPER=${FM_WINDOWS_HARNESS_PROCESS_HELPER:-$FM_SESSION_LOCK_LIB_DIR/fm-windows-harness-process.ps1}
FM_PLAYBOT_SESSION_LOCK_HELPER=${FM_PLAYBOT_SESSION_LOCK_HELPER:-$FM_SESSION_LOCK_LIB_DIR/fm-playbot-session-lock.mjs}

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

fm_playbot_current_session_id() {
  [ -n "${CODEX_THREAD_ID:-}" ] || return 1
  [ -n "${PLAYBOT_APP_RUN_ID:-}" ] || return 1
  command -v node >/dev/null 2>&1 || return 1
  [ -f "$FM_PLAYBOT_SESSION_LOCK_HELPER" ] || return 1
  node --no-warnings "$FM_PLAYBOT_SESSION_LOCK_HELPER" identity "$FM_SESSION_LOCK_ROOT" 2>/dev/null
}

# Exit 0 for live, 1 for absent or archived, and 2 for uncertainty.
fm_playbot_session_alive() {
  local session_id=$1 status=0
  command -v node >/dev/null 2>&1 || return 2
  [ -f "$FM_PLAYBOT_SESSION_LOCK_HELPER" ] || return 2
  node --no-warnings "$FM_PLAYBOT_SESSION_LOCK_HELPER" alive "$session_id" \
    "$FM_SESSION_LOCK_ROOT" >/dev/null 2>&1 || status=$?
  return "$status"
}

# True when this shell is running under Windows/MSYS and can query the host
# process table through the tracked PowerShell helper.
fm_windows_harness_process_available() {
  local os
  os=$(uname -s 2>/dev/null || true)
  case "$os" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) return 1 ;;
  esac
  command -v powershell.exe >/dev/null 2>&1 || return 1
  [ -f "$FM_WINDOWS_HARNESS_PROCESS_HELPER" ]
}

fm_windows_harness_process_invoke() {
  local helper=$FM_WINDOWS_HARNESS_PROCESS_HELPER tmp status=0
  fm_windows_harness_process_available || return 1
  if command -v cygpath >/dev/null 2>&1; then
    helper=$(cygpath -w "$helper" 2>/dev/null || printf '%s' "$helper")
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-windows-harness.XXXXXX") || return 1
  powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$helper" "$@" >"$tmp" 2>/dev/null || status=$?
  if [ -n "${FM_WINDOWS_HARNESS_DEBUG_FILE:-}" ]; then
    printf 'bash pid=%s os=%s helper=%s status=%s output=%s\n' "$$" "$(uname -s 2>/dev/null || true)" \
      "$helper" "$status" "$(tr -d '\r\n' < "$tmp")" >> "$FM_WINDOWS_HARNESS_DEBUG_FILE"
  fi
  if [ "$status" -eq 0 ]; then
    tr -d '\r' < "$tmp"
  fi
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}

fm_windows_harness_ancestry_record() {
  local record pid harness source current_session
  record=$(fm_windows_harness_process_invoke ancestry) || return 1
  pid=${record%% *}
  record=${record#* }
  harness=${record%% *}
  source=${record#* }
  [ "$record" != "$pid" ] || return 1
  case "$pid" in ''|*[!0-9]*|1) return 1 ;; esac
  case "$harness" in claude|codex|opencode|grok|kimi|pi) ;; *) return 1 ;; esac
  case "$source" in
    ancestry) ;;
    playbot)
      current_session=$(fm_playbot_current_session_id) || return 1
      [ "$current_session" = "${CODEX_THREAD_ID:-}" ] || return 1
      [ "$harness" = codex ] || return 1
      ;;
    *) return 1 ;;
  esac
  printf '%s %s %s\n' "$pid" "$harness" "$source"
}

fm_windows_harness_ancestry_name() {
  local record
  record=$(fm_windows_harness_ancestry_record) || return 1
  record=${record#* }
  printf '%s\n' "${record%% *}"
}

fm_windows_harness_pid_alive() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*|1) return 1 ;; esac
  fm_windows_harness_process_invoke alive "$pid" >/dev/null
}

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0 record
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  if [ "$printed" -eq 0 ]; then
    record=$(fm_windows_harness_ancestry_record) || return 1
    printf '%s\n' "${record%% *}"
  fi
  return 0
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  if kill -0 "$pid" 2>/dev/null; then
    comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if [ -n "$comm" ] && fm_harness_process_matches "$comm" "$args"; then
      return 0
    fi
  fi
  fm_windows_harness_pid_alive "$pid"
}

# True when the recorded holder is still live. A Playbot thread sidecar narrows
# a shared Codex app-server pid to one exact unarchived project thread.
fm_session_lock_holder_alive() {
  local state=$1 lock_pid lock_session status=0
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_harness_pid_alive "$lock_pid" || return 1
  [ -e "$state/.lock-session" ] || return 0
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 0
  lock_session=$(cat "$state/.lock-session" 2>/dev/null || true)
  [ -n "$lock_session" ] || return 0
  fm_playbot_session_alive "$lock_session" || status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 0 ;;
  esac
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid lock_session my_session matched=0
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && matched=1
  done <<EOF
$pids
EOF
  [ "$matched" -eq 1 ] || return 1
  my_session=$(fm_playbot_current_session_id 2>/dev/null || true)
  if [ -e "$state/.lock-session" ]; then
    [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
    lock_session=$(cat "$state/.lock-session" 2>/dev/null || true)
    [ -n "$lock_session" ] || return 1
    [ -n "$my_session" ] && [ "$my_session" = "$lock_session" ]
    return
  fi
  [ -z "$my_session" ]
}
