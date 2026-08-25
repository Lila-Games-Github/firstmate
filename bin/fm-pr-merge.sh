#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# Recording pr= is what this path exists for and stays mandatory, but ARMING the
# merge poll is supervision, and losing supervision must never block real work.
# Exactly one failure is treated that way: the poll collision fm-pr-check.sh
# reports with FM_PR_POLL_COLLISION_STATUS, raised when a Playbot lane
# supervision poll already owns state/<id>.check.sh. Its own refusal has already
# reached stderr; this names what was lost and what to do.
#
# The decision keys on that status and never on whether pr= is present, because
# fm-pr-check.sh rewrites the pr= line on every successful run and a re-run after
# an earlier success would find it already there. Every other non-zero exit stays
# fatal exactly as it was, including the state-integrity prepasses that run
# before the metadata is committed and have nothing to do with supervision.
PR_CHECK_STATUS=0
"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL" || PR_CHECK_STATUS=$?
if [ "$PR_CHECK_STATUS" -ne 0 ] && [ "$PR_CHECK_STATUS" -ne "$FM_PR_POLL_COLLISION_STATUS" ]; then
  exit "$PR_CHECK_STATUS"
fi
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}
if [ "$PR_CHECK_STATUS" -ne 0 ]; then
  echo "warning: pr= was recorded for $ID, but merge detection was NOT armed (fm-pr-check.sh exited $PR_CHECK_STATUS); the existing Playbot lane poll is preserved, and this collision is transient because it self-retires when its worker reaches a terminal state" >&2
fi

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"
