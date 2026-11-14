#!/usr/bin/env bash
# Observe one authenticated GitHub PR poll under the watcher's per-task control lock.
# Usage: fm-pr-wait.sh <state-dir> <task-id> <canonical-pr-url>
# The caller has validated the static poll registration and identity. A private
# per-task record preserves the first observation of each head and condition;
# status appends and watcher restarts do not reset its deadline.
# FM_PR_WAIT_BOUND_SECS sets the bound in seconds (default 1800).
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
[ "$#" -eq 3 ] || exit 2
state_dir=$1
id=$2
url=$3
fm_pr_task_id_valid "$id" && fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = github ] || exit 2
[ -d "$state_dir" ] && [ ! -L "$state_dir" ] || exit 1
case "${FM_PR_WAIT_BOUND_SECS:-1800}" in
  ''|*[!0-9]*) exit 2 ;;
esac
bound=${FM_PR_WAIT_BOUND_SECS:-1800}
[ "$bound" -ge 1 ] || exit 2
command -v jq >/dev/null 2>&1 || exit 1
json=$(gh pr view "$url" --json state,headRefOid,mergeable,statusCheckRollup 2>/dev/null) || exit 0
fields=$(printf '%s' "$json" | jq -er 'select(.state|IN("OPEN","MERGED","CLOSED")) | select(.headRefOid|test("^[0-9a-fA-F]{40}$")) | [.state,.headRefOid,(.mergeable//"UNKNOWN")] | @tsv' 2>/dev/null) || exit 0
IFS=$'\t' read -r pr_state head mergeable <<< "$fields"
record="$state_dir/$id.pr-wait"
[ ! -L "$record" ] || exit 1
if [ "$pr_state" != OPEN ]; then
  rm -f -- "$record"
  exit 0
fi
# CheckRun and StatusContext have different verdict fields. Pending checks do
# not count as red; they also prevent the clean, green-unmerged condition.
non_green=$(github_checks_not_green "$json") || exit 0
# Retain only failed names that the shared merge classifier still considers
# current. An older failed run superseded by a newer green run is not red.
failed_names=$(printf '%s' "$json" | jq -r '.statusCheckRollup[]? | if .__typename=="CheckRun" then select(.status=="COMPLETED" and (.conclusion|IN("FAILURE","TIMED_OUT","ACTION_REQUIRED","CANCELLED"))) | .name else select(.state|IN("FAILURE","ERROR")) | .context end' 2>/dev/null) || exit 0
red=
while IFS= read -r check_name; do
  [ -n "$check_name" ] || continue
  if printf '%s\n' "$non_green" | grep -Fqx -- "$check_name"; then
    [ -z "$red" ] || red="$red, "
    red="$red$check_name"
  fi
done <<< "$failed_names"
red=$(printf '%s' "$red" | tr '\r\n\t' '   ')
red=${red:0:300}
pending=$(printf '%s' "$json" | jq -r '[.statusCheckRollup[]? | if .__typename=="CheckRun" then select(.status!="COMPLETED") else select(.state=="PENDING") end] | length' 2>/dev/null) || exit 0
condition=
reason=
if [ "$mergeable" = CONFLICTING ]; then
  condition=conflict
  reason=merge-conflict
elif [ -n "$red" ]; then
  condition=red
  reason="failing check: $red"
elif [ "$pending" -eq 0 ] && [ "$mergeable" = MERGEABLE ]; then
  condition=green
  reason='green but unmerged'
else
  exit 0
fi
now=$(date +%s)
first=$now
rerun=0
notified=0
old_head=
old_condition=
if [ -f "$record" ]; then
  [ "$(fm_pr_file_link_count "$record")" = 1 ] || exit 1
  IFS=$'\t' read -r old_head old_condition old_first rerun notified < "$record" || true
  if [ "$old_head" = "$head" ]; then
    if [ "$old_condition" = "$condition" ]; then
      case "$old_first" in ''|*[!0-9]*) exit 1 ;; esac
      first=$old_first
    else
      notified=0
    fi
  else
    rerun=0
    notified=0
  fi
fi
# A failed check is classified against the changed paths. Shared CI/config
# changes are related; a matching test or component token is related; other
# names with no path match are reported as not plausibly touched.
relation=unknown
if [ "$condition" = red ] && [ "$rerun" -eq 0 ]; then
  paths=$(gh pr diff "$url" --name-only 2>/dev/null || true)
  [ -z "$paths" ] || relation=not-plausibly-touched
  if printf '%s\n' "$paths" | grep -Eq '(^|/)(\.github/workflows/|bin/fm-test|tests/lib\.sh)' ; then
    relation=plausibly-related
  else
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      stem=${path##*/}
      stem=${stem%%.*}
      case "$red" in *"$stem"*) relation=plausibly-related; break ;; esac
    done <<< "$paths"
  fi
  # Mark the head before asking the forge. A failed or interrupted request is
  # still the one automatic attempt and cannot form an unbounded retry loop.
  rerun=1
  tmp=$(mktemp "$state_dir/.fm-pr-wait.XXXXXX") || exit 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$head" "$condition" "$first" "$rerun" "$notified" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$record"
  repo_path=${url#https://github.com/}
  repo_path=${repo_path%/pull/*}
  runs=$(gh run list --repo "$repo_path" --commit "$head" --json databaseId,conclusion --limit 100 2>/dev/null || true)
  run_ids=$(printf '%s' "$runs" | jq -r '.[] | select(.conclusion|IN("failure","timed_out","action_required","cancelled")) | .databaseId' 2>/dev/null || true)
  while IFS= read -r run_id; do
    case "$run_id" in ''|*[!0-9]*) continue ;; esac
    gh run rerun "$run_id" --failed --repo "$repo_path" >/dev/null 2>&1 || true
  done <<< "$run_ids"
  printf 'working: PR %s head %s failed checks (%s; %s); automatic failed-job rerun attempted once\n' "$url" "$head" "$red" "$relation" >> "$state_dir/$id.status"
fi
if [ "$notified" -ne 1 ] && [ "$((now-first))" -ge "$bound" ]; then
  minutes=$(((now-first)/60))
  line="blocked: PR $url waited ${minutes} minutes: $reason"
  if [ "$notified" -eq 0 ]; then
    printf '%s\n' "$line" >> "$state_dir/$id.status"
  fi
  home=${FM_HOME:-${state_dir%/state}}
  delivery_rc=0
  fm_parent_channel_report "$home" "$state_dir" "$line" || delivery_rc=$?
  case "$delivery_rc" in
    0|1) notified=1 ;;
    *) notified=2 ;;
  esac
  printf 'pr-wait-blocked: %s\n' "$line"
  if [ "$notified" -eq 2 ]; then
    printf 'pr-wait-parent-delivery-failed: %s\n' "$url"
  fi
fi
tmp=$(mktemp "$state_dir/.fm-pr-wait.XXXXXX") || exit 1
printf '%s\t%s\t%s\t%s\t%s\n' "$head" "$condition" "$first" "$rerun" "$notified" > "$tmp"
chmod 0600 "$tmp"
mv -f -- "$tmp" "$record"
