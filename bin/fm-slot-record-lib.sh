#!/usr/bin/env bash
# shellcheck disable=SC2034 # scan results are output globals for sourcing callers.
# Shared reader for the two questions every Treehouse pool slot check asks:
# which task RECORDS name a slot, and what TREEHOUSE itself currently thinks of
# it. Both answers are needed in three places - bin/fm-spawn.sh before it
# prepares a freshly handed-out slot, bin/fm-teardown.sh before it returns one,
# and bin/fm-bootstrap.sh when it reports a home whose records and pool have
# drifted apart - so the scan lives here once instead of in each of them.
#
# Why the two answers are not interchangeable (observed 2026-09-21, after a host
# reboot): Treehouse records a crewmate slot as a live PROCESS lease, so a
# reboot that kills every lease process makes every slot read available again
# while the task records naming them are untouched and their workers are
# restored by the backend. Treehouse then hands a slot out that a live task
# still owns, and the new spawn re-prepares it - replacing the other task's
# checkout. The record scan is what closes that window, because a task record
# outlives the lease process that a reboot destroys.
#
# Side-effect free and safe to source from a read-only detection path: it
# creates no directories, takes no locks, and writes nothing.
#
# Prerequisites, by function:
#   fm_treehouse_pool_slot, fm_slot_treehouse_status  - git / treehouse only.
#   fm_slot_record_states, fm_slot_record_other_holder - the caller must have
#     already sourced bin/fm-wake-lib.sh (fm_firstmate_root_home),
#     bin/fm-backend.sh (fm_meta_get), and
#     bin/fm-secondmate-registry-lib.sh (secondmate_registry_parse_line).
#     A missing prerequisite fails closed with FM_SLOT_RECORD_ERROR set.

FM_SLOT_RECORD_ERROR=
FM_SLOT_RECORD_STATES=()
FM_SLOT_RECORD_HOLDER_ID=
FM_SLOT_RECORD_HOLDER_META=
FM_SLOT_RECORD_HOLDER_FIELD=

# The physical path of an existing directory, or failure. Every slot comparison
# below goes through it, so a symlinked prefix (Fedora ostree's /home ->
# /var/home) can never make one spelling of a slot look like a different slot.
fm_slot_canonical_dir() {  # <dir>
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( CDPATH='' cd -- "$target" && pwd -P )
}

# A Treehouse slot has the managed pool's fixed <pool>/<slot>/<repo> layout.
# Require both its pool state and the same Git common directory as the recorded
# project; an ordinary linked worktree is not evidence that Treehouse owns it.
fm_treehouse_pool_slot() {  # <project-dir> <worktree>
  local project=$1 worktree=$2 slot pool state project_common slot_common
  [ -d "$project" ] && [ -d "$worktree" ] || return 1
  slot=$(CDPATH='' cd -- "$worktree" 2>/dev/null && pwd -P) || return 1
  pool=$(dirname "$(dirname "$slot")")
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  slot_common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  project_common=$(CDPATH='' cd -- "$project_common" 2>/dev/null && pwd -P) || return 1
  slot_common=$(CDPATH='' cd -- "$slot_common" 2>/dev/null && pwd -P) || return 1
  [ "$project_common" = "$slot_common" ]
}

# What Treehouse currently reports for one slot, printed as a single word:
#   available - Treehouse holds no live lease for it and would hand it out next
#   in-use    - Treehouse sees a live process under it
#   <other>   - whatever else that release of Treehouse reports, passed through
# Fails without printing when treehouse is absent, its status read fails, or no
# recorded entry is the same physical directory as the slot - "cannot tell" is
# never reported as a state, so a caller can only act on a definite answer.
#
# Treehouse resolves the pool from the working directory and reports in-use from
# the processes actually running under each slot, so the read is taken from the
# PROJECT directory the slot belongs to, never from the slot: reading a slot
# from inside it makes the `treehouse status` process itself the live process
# there, and every slot then reports in-use (reproduced against treehouse
# v2.1.1). bin/fm-teardown.sh's path-alias resolution passes the same cd_dir for
# the same reason.
#
# Reads the machine-readable `treehouse status --json` surface (verified against
# treehouse v2.1.1 and v2.3.0) rather than the human status table. The entry's
# "path" and "status" are paired by scanning the key stream in document order
# and emitting a pair once both have been seen, so neither key order within an
# entry nor the nested "processes" objects (which carry neither key) can
# mispair them.
fm_slot_treehouse_status() {  # <slot-dir> <project-dir>
  local slot cd_dir canon json token key value path='' status=''
  slot=$1
  cd_dir=$2
  canon=$(fm_slot_canonical_dir "$slot") || return 1
  cd_dir=$(fm_slot_canonical_dir "$cd_dir") || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  json=$( ( CDPATH='' cd -- "$cd_dir" && treehouse status --json ) 2>/dev/null ) || return 1
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    key=${token%%:*}
    case "$key" in
      *'"path"'*) key=path ;;
      *'"status"'*) key=status ;;
      *) continue ;;
    esac
    value=${token#*:}
    value=${value#*\"}
    value=${value%\"}
    case "$key" in
      path) path=$value ;;
      status) status=$value ;;
    esac
    [ -n "$path" ] && [ -n "$status" ] || continue
    if [ "$(fm_slot_canonical_dir "$path" 2>/dev/null)" = "$canon" ]; then
      printf '%s\n' "$status"
      return 0
    fi
    path=''
    status=''
  done <<EOF
$(printf '%s\n' "$json" | grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"\|"status"[[:space:]]*:[[:space:]]*"[^"]*"')
EOF
  return 1
}

# Every state directory on THIS machine whose task records could name a slot
# from the same pool: the calling home, the local root Firstmate home above it,
# and every locally registered secondmate home reachable from that root. A
# remote registry entry is skipped, because its records live on another machine
# and its slots cannot be this pool's.
#
# Sets FM_SLOT_RECORD_STATES. Fails with FM_SLOT_RECORD_ERROR set to the reason,
# phrased as a bare clause so each caller can wrap it in its own refusal: an
# unreadable registry or an unavailable registered home is never silently
# treated as "no other records".
fm_slot_record_states() {  # <state-dir>
  local record_state=$1 root home_dir reg line child known existing i=0
  local -a homes
  FM_SLOT_RECORD_ERROR=
  FM_SLOT_RECORD_STATES=("$record_state")
  if ! command -v fm_firstmate_root_home >/dev/null 2>&1 \
    || ! command -v secondmate_registry_parse_line >/dev/null 2>&1; then
    FM_SLOT_RECORD_ERROR="the slot record scan is missing its libraries"
    return 1
  fi
  root=$(fm_firstmate_root_home "${FM_HOME:-}") || {
    FM_SLOT_RECORD_ERROR="cannot resolve the root Firstmate home"
    return 1
  }
  homes=("$root")
  while [ "$i" -lt "${#homes[@]}" ]; do
    home_dir=${homes[$i]}
    i=$((i + 1))
    known=0
    for existing in "${FM_SLOT_RECORD_STATES[@]}"; do
      [ "$existing" != "$home_dir/state" ] || known=1
    done
    [ "$known" = 1 ] || FM_SLOT_RECORD_STATES+=("$home_dir/state")
    reg="$home_dir/data/secondmates.md"
    [ ! -e "$reg" ] && [ ! -L "$reg" ] && continue
    [ -f "$reg" ] && [ ! -L "$reg" ] || {
      FM_SLOT_RECORD_ERROR="local Firstmate registry is unsafe at $reg"
      return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*)
          secondmate_registry_parse_line "$line" || {
            FM_SLOT_RECORD_ERROR="malformed local Firstmate registry entry in $reg"
            return 1
          }
          [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
          child=$(fm_slot_canonical_dir "$SECONDMATE_REGISTRY_HOME") || {
            FM_SLOT_RECORD_ERROR="registered local Firstmate home is unavailable: $SECONDMATE_REGISTRY_HOME"
            return 1
          }
          known=0
          for existing in "${homes[@]}"; do
            [ "$existing" != "$child" ] || known=1
          done
          [ "$known" = 1 ] || homes+=("$child")
          ;;
      esac
    done < "$reg"
  done
}

# The first task record OTHER than <self-meta> that names <slot> as its own
# live path, in either of the two fields that can hold one: a crewmate's
# worktree= or a secondmate home's home=. Both are searched because both make
# the slot that record's, and returning a slot named by either destroys live
# work.
#
# <self-meta> may be empty, which is how a spawn asks "does ANY record already
# own this slot" before it has a record of its own.
#
# Returns 0 and sets FM_SLOT_RECORD_HOLDER_ID / _META / _FIELD on a match, 1
# when no other record names the slot, and 2 with FM_SLOT_RECORD_ERROR set when
# the scan itself could not be completed - never "no holder" on an error.
fm_slot_record_other_holder() {  # <slot> <self-meta> <state-dir>
  local slot=$1 self_meta=$2 record_state=$3
  local canon state_dir other_meta other_id field other_path other_slot
  FM_SLOT_RECORD_HOLDER_ID=
  FM_SLOT_RECORD_HOLDER_META=
  FM_SLOT_RECORD_HOLDER_FIELD=
  FM_SLOT_RECORD_ERROR=
  if ! command -v fm_meta_get >/dev/null 2>&1; then
    FM_SLOT_RECORD_ERROR="the slot record scan is missing its libraries"
    return 2
  fi
  canon=$(fm_slot_canonical_dir "$slot") || {
    FM_SLOT_RECORD_ERROR="slot path is not an inspectable directory: ${slot:-<missing>}"
    return 2
  }
  fm_slot_record_states "$record_state" || return 2
  for state_dir in "${FM_SLOT_RECORD_STATES[@]}"; do
    for other_meta in "$state_dir"/*.meta; do
      [ -f "$other_meta" ] && [ ! -L "$other_meta" ] || continue
      [ -z "$self_meta" ] || [ "$other_meta" != "$self_meta" ] || continue
      other_id=$(basename "$other_meta" .meta)
      for field in worktree home; do
        other_path=$(fm_meta_get "$other_meta" "$field")
        [ -n "$other_path" ] || continue
        other_slot=$(fm_slot_canonical_dir "$other_path") || continue
        [ "$other_slot" = "$canon" ] || continue
        FM_SLOT_RECORD_HOLDER_ID=$other_id
        FM_SLOT_RECORD_HOLDER_META=$other_meta
        FM_SLOT_RECORD_HOLDER_FIELD=$field
        return 0
      done
    done
  done
  return 1
}
