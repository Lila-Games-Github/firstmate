#!/usr/bin/env bash
# Sourced library: the single owner of a crewmate task's own branch name.
#
# A new ship task works on `feat/<slug>` for a feature or `fix/<slug>` for a
# bug fix; the `fm/` prefix is no longer used for new task branches. The prefix
# is lowercase and <slug> is short kebab-case: lowercase letters and digits in
# dash-separated words. The default slug is the task id with any leading `fm-`
# or `<project>-` prefix removed, lowercased, and with every other character run
# folded to one dash.
#
# bin/fm-brief.sh chooses the branch at scaffold time (--kind, --branch-name)
# and records it in the ship brief as the fixed machine-readable line
#   Branch contract: branch=<branch>
# bin/fm-spawn.sh copies that line into the task's meta as `branch=` (its header
# owns the meta field), and bin/fm-promote.sh records it for a promoted scout.
# Every consumer resolves the branch through fm_task_branch: the recorded
# `branch=` when present, else the legacy `fm/<task-id>` that tasks spawned
# before this contract were briefed with. Playbot lane branches are owned by
# the lane metadata (`lane_branch=`), never by this library.

FM_TASK_BRANCH_CONTRACT_PREFIX='Branch contract: branch='

# fm_task_branch_kind_valid <kind>: 0 for feat or fix.
fm_task_branch_kind_valid() {
  case "${1:-}" in feat|fix) return 0 ;; *) return 1 ;; esac
}

# fm_task_branch_slug_valid <slug>: 0 for short kebab-case (at most 60 chars).
fm_task_branch_slug_valid() {
  local slug=${1:-}
  [ -n "$slug" ] && [ "${#slug}" -le 60 ] || return 1
  case "$slug" in
    -*|*-|*--*|*[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

# fm_task_branch_default_slug <task-id> [project-name]: prints the default slug.
fm_task_branch_default_slug() {
  local id=${1:-} project=${2:-} slug lower_project
  slug=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
  lower_project=$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]')
  if [ -n "$lower_project" ]; then
    case "$slug" in "$lower_project"-?*) slug=${slug#"$lower_project"-} ;; esac
  fi
  case "$slug" in fm-?*) slug=${slug#fm-} ;; esac
  slug=$(printf '%s' "$slug" | LC_ALL=C sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//' | cut -c1-60)
  slug=${slug%-}
  [ -n "$slug" ] || slug=task
  printf '%s\n' "$slug"
}

# fm_task_branch_compose <feat|fix> <slug>: prints `<kind>/<slug>` or fails
# with a reason on stderr.
fm_task_branch_compose() {
  local kind=${1:-} slug=${2:-}
  fm_task_branch_kind_valid "$kind" || {
    echo "error: task branch kind must be feat or fix (got '$kind')" >&2
    return 1
  }
  fm_task_branch_slug_valid "$slug" || {
    echo "error: task branch name must be short kebab-case - lowercase letters and digits in dash-separated words, at most 60 characters (got '$slug')" >&2
    return 1
  }
  printf '%s/%s\n' "$kind" "$slug"
}

# fm_task_branch_value_valid <branch>: 0 for a value a task record may carry:
# a new `feat/<slug>` or `fix/<slug>`, or a legacy `fm/<task-id>`.
fm_task_branch_value_valid() {
  local branch=${1:-}
  case "$branch" in
    feat/*) fm_task_branch_slug_valid "${branch#feat/}" ;;
    fix/*) fm_task_branch_slug_valid "${branch#fix/}" ;;
    fm/*)
      case "${branch#fm/}" in
        ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
      esac
      git check-ref-format --branch "$branch" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

# fm_task_branch_from_brief <brief-file>: prints the brief's recorded branch.
# Prints nothing and succeeds for a brief scaffolded before this contract; fails
# when the brief records more than one value or an invalid one.
fm_task_branch_from_brief() {
  local brief=$1 values count
  [ -f "$brief" ] || return 0
  values=$(sed -n "s/^${FM_TASK_BRANCH_CONTRACT_PREFIX}//p" "$brief" | sort -u)
  [ -n "$values" ] || return 0
  count=$(printf '%s\n' "$values" | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || {
    echo "error: $brief records more than one branch contract ($(printf '%s' "$values" | tr '\n' ' '))" >&2
    return 1
  }
  fm_task_branch_value_valid "$values" || {
    echo "error: $brief records an invalid branch contract '$values'; branches are feat/<slug> or fix/<slug>" >&2
    return 1
  }
  printf '%s\n' "$values"
}

# fm_task_branch <meta-file> <task-id>: prints the task's own branch - the
# recorded `branch=` when it is a valid value, else the legacy `fm/<task-id>`.
fm_task_branch() {
  local meta=$1 id=$2 line value=''
  if [ -f "$meta" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in branch=*) value=${line#branch=} ;; esac
    done < "$meta" 2>/dev/null || true
  fi
  if [ -n "$value" ] && fm_task_branch_value_valid "$value"; then
    printf '%s\n' "$value"
  else
    printf 'fm/%s\n' "$id"
  fi
}

# fm_task_for_branch <state-dir> <branch>: prints the task id whose meta
# records that branch, or the legacy `fm/<task-id>` suffix; prints nothing and
# fails when no task owns it.
fm_task_for_branch() {
  local state=$1 branch=$2 meta id
  [ -n "$branch" ] || return 1
  if [ -d "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      id=${meta##*/}
      id=${id%.meta}
      if grep -Fqx "branch=$branch" "$meta" 2>/dev/null; then
        printf '%s\n' "$id"
        return 0
      fi
    done
  fi
  case "$branch" in
    fm/?*) printf '%s\n' "${branch#fm/}"; return 0 ;;
  esac
  return 1
}
