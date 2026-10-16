#!/usr/bin/env bash
# fm-dispatch-preflight-lib.sh - the single owner of the dispatch preflight
# probes bin/fm-spawn.sh runs on a fresh ship or scout spawn after the task
# worktree exists on its selected base and before the worker starts.
#
# Sourced, never executed. Each probe catches a launch that would strand the
# worker on something no worker can fix from inside its task:
#
#   Git identity (ship only). A ship worker must commit without waiting for a
#   human, so the worktree must resolve both `git var GIT_AUTHOR_IDENT` and
#   `git var GIT_COMMITTER_IDENT`. They are evaluated in the spawn's own
#   environment, filtered to the launch-env allowlist names when that opt-in is
#   active, because the pane sees no more than that. Linked worktrees share the
#   project clone's configuration, so the remedy is a commit identity configured
#   on the clone when it is registered (or a global one).
#
#   Existing inputs (ship and scout). A brief declares what must already exist
#   on the task's base with one fixed line per input, anywhere in the brief:
#     Existing input: path <repository-relative path>
#     Existing input: symbol <identifier>
#   A path must resolve as a blob or tree at the worktree's HEAD, which spawn
#   has just reset to the recorded landing branch (else the default branch). A
#   symbol must appear as a whole word (git grep -w -F) in that HEAD's tree.
#   Paths the task will create are deliberately never declared, so only what
#   the brief marks as an existing input is tested. An absent input means the
#   brief was written against code that has since moved: the spawn refuses so
#   the brief goes back for re-triage rather than to an implementation worker.
#
#   Required tools (ship and scout). A brief declares an external tool or
#   service the worker must call, plus optional preserved raw inputs that can
#   stand in for it:
#     Required tool: command <executable>
#     Required tool: mcp <server name>
#     Preserved input: <absolute path>
#   `command` resolves on the spawn's PATH, which the launch environment keeps.
#   `mcp` asks the selected harness's own CLI from inside the worktree, so
#   project-scoped servers and the harness's config directory count:
#     claude  `claude mcp get <name>` must exit 0 with a Status line saying
#             Connected (it also exits 0 for a server that failed to connect or
#             needs authentication, so the Status line carries the verdict).
#     codex   `codex mcp list --json` must list the name as enabled with an
#             auth_status other than not_logged_in.
#   No other harness, and no raw launch command, has a verified MCP probe, so
#   there an mcp tool counts as not callable. Each harness CLI runs under a
#   30-second bound and a timeout counts as not callable.
#   When every declared tool is callable nothing is bundled. Otherwise every
#   Preserved input is copied into the task bundle at data/<id>/inputs/ (that
#   directory is owned by this preflight and replaced whenever it bundles), and
#   with no preserved input to fall back on the spawn refuses. Either way the
#   outcome per tool is written to data/<id>/dispatch-preflight.md, which spawn
#   appends to the worker's launch brief, including on relaunch.
#
# A malformed marker line (unknown kind, empty value, an absolute or
# parent-escaping input path, or a relative preserved input) refuses the spawn
# before any endpoint exists; fm_preflight_markers_check is that early check.
#
# Functions return 0 on pass and nonzero on refusal with a one-line
# explanation in FM_PREFLIGHT_REASON. Live verification of the harness probes:
# tests/fm-dispatch-preflight-live-e2e.test.sh; portable regression:
# tests/fm-dispatch-preflight.test.sh.
set -u

# shellcheck source=bin/fm-timeout-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"

FM_PREFLIGHT_REASON=
FM_PREFLIGHT_MCP_TIMEOUT=${FM_PREFLIGHT_MCP_TIMEOUT:-30}

# Marker values of one kind, one per line, trimmed. <brief> <prefix>
fm_preflight_marker_values() {
  sed -n "s/^$2[[:space:]]*//p" "$1" | sed 's/[[:space:]]*$//'
}

# fm_preflight_markers_check <brief>
fm_preflight_markers_check() {
  local brief=$1 line kind value
  FM_PREFLIGHT_REASON=
  while IFS= read -r line; do
    kind=${line%%[[:space:]]*}
    value=${line#"$kind"}
    value=${value#"${value%%[![:space:]]*}"}
    case "$kind" in
    path)
      case "$value" in
      '' | /* | .. | ../* | */../* | */..)
        FM_PREFLIGHT_REASON="Existing input path must be repository-relative without '..': '$line'"
        return 1 ;;
      esac ;;
    symbol)
      if [ -z "$value" ]; then
        FM_PREFLIGHT_REASON="Existing input symbol is empty: '$line'"
        return 1
      fi ;;
    *)
      FM_PREFLIGHT_REASON="Existing input must be 'path <path>' or 'symbol <identifier>': '$line'"
      return 1 ;;
    esac
  done < <(fm_preflight_marker_values "$brief" 'Existing input:')
  while IFS= read -r line; do
    kind=${line%%[[:space:]]*}
    value=${line#"$kind"}
    value=${value#"${value%%[![:space:]]*}"}
    case "$kind" in
    command | mcp)
      if [ -z "$value" ]; then
        FM_PREFLIGHT_REASON="Required tool names no $kind: '$line'"
        return 1
      fi ;;
    *)
      FM_PREFLIGHT_REASON="Required tool must be 'command <executable>' or 'mcp <server>': '$line'"
      return 1 ;;
    esac
  done < <(fm_preflight_marker_values "$brief" 'Required tool:')
  while IFS= read -r line; do
    case "$line" in
    /*) ;;
    *)
      FM_PREFLIGHT_REASON="Preserved input must be an absolute path: '$line'"
      return 1 ;;
    esac
  done < <(fm_preflight_marker_values "$brief" 'Preserved input:')
  return 0
}

# fm_preflight_git_identity <worktree> <filtered 0|1> [<env-name>...]
fm_preflight_git_identity() {
  local wt=$1 filtered=$2 var out name
  shift 2
  local -a envcmd=()
  if [ "$filtered" = 1 ]; then
    envcmd=(/usr/bin/env -i)
    for name in "$@"; do
      [ -n "${!name+x}" ] && envcmd+=("$name=${!name}")
    done
  fi
  FM_PREFLIGHT_REASON=
  for var in GIT_AUTHOR_IDENT GIT_COMMITTER_IDENT; do
    if ! out=$("${envcmd[@]+"${envcmd[@]}"}" git -C "$wt" var "$var" 2>&1); then
      FM_PREFLIGHT_REASON="$var does not resolve ($(printf '%s\n' "$out" | grep -m1 '^fatal:' || printf '%s\n' "$out" | tail -n 1))"
      return 1
    fi
  done
  return 0
}

# fm_preflight_existing_inputs <worktree> <brief>
fm_preflight_existing_inputs() {
  local wt=$1 brief=$2 line kind value rc missing=''
  FM_PREFLIGHT_REASON=
  while IFS= read -r line; do
    kind=${line%%[[:space:]]*}
    value=${line#"$kind"}
    value=${value#"${value%%[![:space:]]*}"}
    case "$kind" in
    path)
      value=${value#./}
      git -C "$wt" cat-file -e "HEAD:$value" 2>/dev/null || missing="$missing${missing:+, }path $value" ;;
    symbol)
      git -C "$wt" grep -q -w -F -e "$value" HEAD -- >/dev/null 2>&1
      rc=$?
      case "$rc" in
      0) ;;
      1) missing="$missing${missing:+, }symbol $value" ;;
      *)
        FM_PREFLIGHT_REASON="git grep could not search for symbol $value (exit $rc)"
        return 2 ;;
      esac ;;
    esac
  done < <(fm_preflight_marker_values "$brief" 'Existing input:')
  if [ -n "$missing" ]; then
    FM_PREFLIGHT_REASON=$missing
    return 1
  fi
  return 0
}

# fm_preflight_mcp_callable <worktree> <harness> <raw 0|1> <server>
# Sets FM_PREFLIGHT_REASON to why it is not callable.
fm_preflight_mcp_callable() {
  local wt=$1 harness=$2 raw=$3 server=$4 out rc
  FM_PREFLIGHT_REASON=
  if [ "$raw" = 1 ]; then
    FM_PREFLIGHT_REASON="a raw launch command has no verified MCP probe"
    return 1
  fi
  case "$harness" in
  claude)
    out=$(cd "$wt" && fm_run_timed "$FM_PREFLIGHT_MCP_TIMEOUT" claude mcp get "$server" </dev/null 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Eq '^[[:space:]]*Status:.*Connected'; then
      return 0
    fi
    if [ "$rc" -eq 124 ]; then
      FM_PREFLIGHT_REASON="claude mcp get timed out after ${FM_PREFLIGHT_MCP_TIMEOUT}s"
    elif printf '%s\n' "$out" | grep -q 'No MCP server named'; then
      FM_PREFLIGHT_REASON="claude reports no server named $server"
    elif out=$(printf '%s\n' "$out" | grep -m1 -E '^[[:space:]]*Status:'); then
      FM_PREFLIGHT_REASON="claude reports ${out#"${out%%[![:space:]]*}"}"
    else
      FM_PREFLIGHT_REASON="claude mcp get exited $rc without a Status line"
    fi
    return 1 ;;
  codex)
    out=$(cd "$wt" && fm_run_timed "$FM_PREFLIGHT_MCP_TIMEOUT" codex mcp list --json </dev/null 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      FM_PREFLIGHT_REASON="codex mcp list exited $rc"
      return 1
    fi
    if printf '%s' "$out" | jq -e --arg n "$server" \
      'any(.[]?; .name == $n and .enabled == true and .auth_status != "not_logged_in")' >/dev/null 2>&1; then
      return 0
    fi
    FM_PREFLIGHT_REASON="codex lists no enabled, authenticated server named $server"
    return 1 ;;
  *)
    FM_PREFLIGHT_REASON="$harness has no verified MCP probe"
    return 1 ;;
  esac
}

# fm_preflight_required_tools <worktree> <brief> <harness> <raw 0|1> <bundle-dir> <record>
# Writes <record> when the brief declares any required tool. Returns 1 (with
# FM_PREFLIGHT_REASON) when a tool is not callable and nothing can be bundled.
fm_preflight_required_tools() {
  local wt=$1 brief=$2 harness=$3 raw=$4 bundle=$5 record=$6
  local line kind value outcomes='' unavailable='' src base tmp
  FM_PREFLIGHT_REASON=
  rm -f -- "$record"
  while IFS= read -r line; do
    kind=${line%%[[:space:]]*}
    value=${line#"$kind"}
    value=${value#"${value%%[![:space:]]*}"}
    case "$kind" in
    command)
      if command -v -- "$value" >/dev/null 2>&1; then
        outcomes="$outcomes- Required tool \`$line\`: callable."$'\n'
      else
        unavailable="$unavailable${unavailable:+; }$line (not on PATH)"
        outcomes="$outcomes- Required tool \`$line\`: NOT callable in this worker (not on PATH)."$'\n'
      fi ;;
    mcp)
      if fm_preflight_mcp_callable "$wt" "$harness" "$raw" "$value"; then
        outcomes="$outcomes- Required tool \`$line\`: callable."$'\n'
      else
        unavailable="$unavailable${unavailable:+; }$line ($FM_PREFLIGHT_REASON)"
        outcomes="$outcomes- Required tool \`$line\`: NOT callable in this worker ($FM_PREFLIGHT_REASON)."$'\n'
      fi ;;
    esac
  done < <(fm_preflight_marker_values "$brief" 'Required tool:')
  [ -n "$outcomes" ] || return 0

  local -a preserved=()
  while IFS= read -r line; do
    [ -n "$line" ] && preserved+=("$line")
  done < <(fm_preflight_marker_values "$brief" 'Preserved input:')
  if [ -n "$unavailable" ]; then
    if [ "${#preserved[@]}" -eq 0 ]; then
      FM_PREFLIGHT_REASON="$unavailable; and the brief names no Preserved input to bundle instead"
      return 1
    fi
    tmp="$bundle.tmp.$$"
    rm -rf -- "$tmp"
    mkdir -p -- "$tmp" || {
      FM_PREFLIGHT_REASON="could not create the input bundle at $bundle"
      return 1
    }
    for src in "${preserved[@]}"; do
      base=$(basename -- "$src")
      if [ ! -e "$src" ]; then
        rm -rf -- "$tmp"
        FM_PREFLIGHT_REASON="$unavailable; and Preserved input $src does not exist"
        return 1
      fi
      if [ -e "$tmp/$base" ]; then
        rm -rf -- "$tmp"
        FM_PREFLIGHT_REASON="two Preserved inputs share the name $base"
        return 1
      fi
      cp -R -- "$src" "$tmp/$base" || {
        rm -rf -- "$tmp"
        FM_PREFLIGHT_REASON="could not copy Preserved input $src into the bundle"
        return 1
      }
    done
    rm -rf -- "$bundle"
    mv -- "$tmp" "$bundle" || {
      rm -rf -- "$tmp"
      FM_PREFLIGHT_REASON="could not publish the input bundle at $bundle"
      return 1
    }
    outcomes="$outcomes- Bundled instead: the preserved inputs are copied into \`$bundle\`; work from them where a required tool is not callable."$'\n'
  fi
  printf '# Dispatch preflight\n%s' "$outcomes" >"$record" || {
    FM_PREFLIGHT_REASON="could not write the preflight record $record"
    return 1
  }
  return 0
}
