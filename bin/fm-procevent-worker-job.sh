#!/usr/bin/env bash
# Worker background-job completion adapter for fm-procevent.sh.
# Usage: fm-procevent-worker-job.sh arm <task> <job-name> -- <wait-command> [args...]
#        fm-procevent-worker-job.sh run <task> <job-name> -- <wait-command> [args...]
#        fm-procevent-worker-job.sh autohandle <source-id> <sequence> <result-file>
#        fm-procevent-worker-job.sh classify|terminal <result-file>
#        fm-procevent-worker-job.sh self-announcing
# The wait command must observe an existing job and return when it ends. It must
# be safe to rerun after a runner crash. Its exit status reaches the worker.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
valid_name() { case $1 in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
source_id() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf 'worker-job-v1\n%s\n%s\n' "$1" "$2" | sha256sum | cut -c1-40) || return 1
  else
    digest=$(printf 'worker-job-v1\n%s\n%s\n' "$1" "$2" | shasum -a 256 | cut -c1-40) || return 1
  fi
  printf 'worker-job-%s\n' "$digest"
}
valid_task() {
  valid_name "$1" || return 1
  [ -f "$STATE/$1.meta" ] && [ ! -L "$STATE/$1.meta" ] || return 1
  grep -Eq '^kind=(ship|scout)$' "$STATE/$1.meta"
}
case ${1-} in
  arm)
    [ "$#" -ge 5 ] && [ "$4" = -- ] || die 'usage: arm <task> <job-name> -- <wait-command> [args...]'
    valid_task "$2" || die 'task must be a local ship or scout'
    valid_name "$3" || die 'job name must be path-safe'
    task=$2 name=$3
    id=$(source_id "$task" "$name") || die 'cannot derive source id'
    [ ! -e "$STATE/procevent/$id.source" ] || die 'job name is already registered'
    shift 4
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-procevent.sh" register worker-job "$id" -- \
      "$SCRIPT_DIR/fm-procevent-worker-job.sh" run "$task" "$name" -- "$@"
    ;;
  run)
    [ "$#" -ge 5 ] && [ "$4" = -- ] || die 'invalid registered job command'
    task=$2 name=$3
    valid_name "$task" && valid_name "$name" || die 'invalid registered job identity'
    shift 4
    "$@" >/dev/null 2>&1
    rc=$?
    printf 'task: %s\njob: %s\nexit: %s\n' "$task" "$name" "$rc"
    ;;
  self-announcing) exit 0 ;;
  terminal) exit 0 ;;
  classify) printf 'worker-job-complete\n' ;;
  autohandle)
    [ "$#" -eq 4 ] || die 'invalid autohandle arguments'
    id=$2 seq=$3 result=$4
    [ -f "$result" ] && [ ! -L "$result" ] || die 'result missing'
    task=$(sed -n 's/^task: //p' "$result" | head -1)
    name=$(sed -n 's/^job: //p' "$result" | head -1)
    rc=$(sed -n 's/^exit: //p' "$result" | head -1)
    valid_task "$task" && valid_name "$name" || die 'invalid result identity'
    [ "$(source_id "$task" "$name")" = "$id" ] || die 'source identity mismatch'
    case $seq in ''|*[!0-9]*) die 'invalid sequence' ;; esac
    case $rc in ''|*[!0-9]*) die 'invalid exit status' ;; esac
    message="Automatic background job doorbell for $name (source $id, result $seq): command exited $rc. Inspect the job result and continue."
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 \
      "$SCRIPT_DIR/fm-send.sh" "$task" "$message" >/dev/null || exit 1
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-procevent.sh" handled "$id" "$seq" >/dev/null
    ;;
  *) die 'unknown command' ;;
esac
