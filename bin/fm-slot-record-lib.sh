#!/usr/bin/env bash
# shellcheck disable=SC2034 # scan results are output globals for sourcing callers.
# Shared reader for the two questions every Treehouse pool slot check asks:
# which task RECORDS name a slot, and what TREEHOUSE itself currently thinks of
# it. Both answers are needed wherever a slot changes hands - bin/fm-spawn.sh
# before it prepares a freshly handed-out slot, bin/fm-teardown.sh before it
# returns one, bin/fm-control.sh before it stops an agent it is about to
# relaunch into the copy its record names, and bin/fm-bootstrap.sh when it
# reports a home whose records and pool have drifted apart - so the scan lives
# here once instead of in each of them.
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
# creates no directories, takes no locks, and changes nothing on disk. The one
# refusal helper below prints its verdict to stderr and returns it; whether that
# ends the process stays with the caller.
#
# Prerequisites, by function:
#   fm_treehouse_pool_slot, fm_slot_project_dir, fm_slot_treehouse_pool_json,
#     fm_slot_treehouse_entry - git / treehouse only.
#   fm_slot_record_states, fm_slot_record_other_holder,
#     fm_slot_refuse_relaunch_into_other_record - the caller must have
#     already sourced bin/fm-wake-lib.sh (fm_firstmate_root_home),
#     bin/fm-backend.sh (fm_meta_get), and
#     bin/fm-secondmate-registry-lib.sh (secondmate_registry_parse_line).
#     A missing prerequisite fails closed with FM_SLOT_RECORD_ERROR set.

FM_SLOT_RECORD_ERROR=
FM_SLOT_RECORD_STATES=()
FM_SLOT_RECORD_HOLDER_ID=
FM_SLOT_RECORD_HOLDER_META=
FM_SLOT_RECORD_HOLDER_FIELD=
FM_SLOT_TREEHOUSE_STATUS=
FM_SLOT_TREEHOUSE_LEASE_HOLDER=
FM_SLOT_TREEHOUSE_PATH=

# The physical path of an existing directory, or failure. Every slot comparison
# below goes through it, so a symlinked prefix (Fedora ostree's /home ->
# /var/home) can never make one spelling of a slot look like a different slot.
fm_slot_canonical_dir() {  # <dir>
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( CDPATH='' cd -- "$target" && pwd -P )
}

# The pool-relative identity of a slot path, printed as "<pool>/<slot>/<repo>"
# from the managed pool's fixed <pool>/<slot>/<repo> layout. Unlike the physical
# path it survives a spelling whose prefix no longer resolves on this host, so
# it is the only identity left for a Treehouse record that names a slot through
# a path alias that is gone. Fails on anything without those three components.
fm_slot_pool_identity() {  # <slot-path>
  local rest=$1 repo slot pool
  case "$rest" in
    /?*) ;;
    *) return 1 ;;
  esac
  rest=${rest%/}
  repo=${rest##*/}
  rest=${rest%/*}
  slot=${rest##*/}
  rest=${rest%/*}
  pool=${rest##*/}
  [ -n "$repo" ] && [ -n "$slot" ] && [ -n "$pool" ] || return 1
  printf '%s/%s/%s\n' "$pool" "$slot" "$repo"
}

# True when a path Treehouse reported names the same slot as <canonical-slot>.
# Treehouse records the spelling it was launched through, which on this host's
# ostree layout is the /home alias of the /var/home path a task meta records
# (verified 2026-09-22, docs/verification/runtime-backends.md), so the two sides
# are compared as physical directories, never as strings.
# When the reported spelling does not resolve here at all - the alias itself is
# gone - the comparison falls back to the pool-relative <pool>/<slot>/<repo>
# identity, which still distinguishes one slot of one pool from another. An
# entry whose identity cannot be derived never matches.
fm_slot_path_matches() {  # <reported-path> <canonical-slot> <slot-identity>
  local reported=$1 canon=$2 identity=$3 reported_canon
  [ -n "$reported" ] || return 1
  if reported_canon=$(fm_slot_canonical_dir "$reported" 2>/dev/null); then
    [ "$reported_canon" = "$canon" ]
    return
  fi
  [ -n "$identity" ] || return 1
  [ "$(fm_slot_pool_identity "$reported" 2>/dev/null)" = "$identity" ]
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

# The project checkout a pool slot belongs to: the working tree holding its
# common git directory. A secondmate home record names no project of its own, so
# the slot itself is what says which pool it came from - and which directory the
# pool has to be read from.
fm_slot_project_dir() {  # <slot>
  local slot=$1 common
  [ -n "$slot" ] && [ -d "$slot" ] || return 1
  common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  fm_slot_canonical_dir "$(dirname "$common")"
}

# The `treehouse status --json` document for the pool that <project-dir>
# resolves to. The read is separated from the parse so one sweep can answer
# every question it has about a slot from a single snapshot, rather than forking
# treehouse once per question and risking two answers taken from two different
# moments.
#
# Treehouse resolves the pool from the working directory and reports in-use from
# the processes actually running under each slot, so the read is taken from the
# PROJECT directory the slot belongs to, never from the slot: reading a slot
# from inside it makes the `treehouse status` process itself the live process
# there, and every slot then reports in-use (reproduced against treehouse
# v2.1.1). bin/fm-teardown.sh's path-alias resolution passes the same cd_dir for
# the same reason.
fm_slot_treehouse_pool_json() {  # <project-dir>
  local cd_dir
  cd_dir=$(fm_slot_canonical_dir "$1") || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  ( CDPATH='' cd -- "$cd_dir" && treehouse status --json ) 2>/dev/null
}

# What Treehouse records for ONE slot in an already-captured pool document.
# Sets, and returns 0 only when the slot has an entry there with a definite
# status - "cannot tell" is never reported as a value:
#   FM_SLOT_TREEHOUSE_STATUS       available - Treehouse holds no lease for it
#                                              and would hand it out next
#                                  in-use    - it sees a live process under it
#                                  leased    - a durable lease reserves it, so
#                                              no later get can be handed it
#                                  <other>   - whatever else that release
#                                              reports, passed through
#   FM_SLOT_TREEHOUSE_LEASE_HOLDER the durable lease's holder label, empty when
#                                  no durable lease reserves the slot
#   FM_SLOT_TREEHOUSE_PATH         the spelling Treehouse itself records for the
#                                  slot, which is the only one its own `return`
#                                  matches - it compares by string, so an
#                                  operator remedy built from the task meta's
#                                  spelling is refused on an alias host
#                                  (docs/verification/runtime-backends.md)
#
# Reads the machine-readable `treehouse status --json` surface (verified against
# treehouse v2.1.1 and v2.3.0) rather than the human status table. Each record
# carries name, path, status, lease_id, lease_holder, leased_at and processes;
# the full recorded shape is in docs/verification/runtime-backends.md.
#
# Every string-valued key is extracted with ONE pattern and the keys of interest
# are picked out below, rather than an alternation of three: alternation in a
# basic regular expression is a GNU grep extension that matches nothing on the
# BSD grep of a stock macOS, which would leave this function silently reporting
# no entry for any slot and both SLOT_RECONCILE directions dead with no error.
# bin/fm-teardown.sh's sibling reader avoids it the same way.
#
# The key stream is scanned in document order, where a "path" token opens the
# entry it belongs to and the next one closes it, so an entry that omits a key -
# or carries it empty, as lease_holder does for every unleased slot - can never
# lend a value to the next entry, and the nested "processes" objects carry none
# of the keys read here.
#
# The queried slot is identified by fm_slot_path_matches, which compares
# physical directories rather than spellings: Treehouse reports the /home alias
# that it was launched through while task metas record the /var/home path it
# resolves to, and a string compare would find no entry at all.
fm_slot_treehouse_entry() {  # <slot-dir> <pool-json>
  local slot=$1 json=$2 canon identity token key value matched=0
  FM_SLOT_TREEHOUSE_STATUS=
  FM_SLOT_TREEHOUSE_LEASE_HOLDER=
  FM_SLOT_TREEHOUSE_PATH=
  canon=$(fm_slot_canonical_dir "$slot") || return 1
  identity=$(fm_slot_pool_identity "$canon") || identity=''
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    key=${token%%:*}
    value=${token#*:}
    value=${value#*\"}
    value=${value%\"}
    case "$key" in
      *'"path"'*)
        [ "$matched" = 0 ] || break
        FM_SLOT_TREEHOUSE_STATUS=
        FM_SLOT_TREEHOUSE_LEASE_HOLDER=
        FM_SLOT_TREEHOUSE_PATH=
        if fm_slot_path_matches "$value" "$canon" "$identity"; then
          matched=1
          FM_SLOT_TREEHOUSE_PATH=$value
        fi
        ;;
      *'"status"'*)
        if [ "$matched" = 1 ]; then FM_SLOT_TREEHOUSE_STATUS=$value; fi
        ;;
      *'"lease_holder"'*)
        if [ "$matched" = 1 ]; then FM_SLOT_TREEHOUSE_LEASE_HOLDER=$value; fi
        ;;
    esac
  done <<EOF
$(printf '%s\n' "$json" | grep -o '"[a-z_]*"[[:space:]]*:[[:space:]]*"[^"]*"')
EOF
  [ -n "$FM_SLOT_TREEHOUSE_STATUS" ] || return 1
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

# The relaunch ownership gate, asked at BOTH ends of the relaunch transaction
# and therefore owned here rather than at either of them: bin/fm-control.sh asks
# it first, while the agent it is about to replace is still running, and
# bin/fm-spawn.sh --relaunch asks it again before it drives an endpoint into the
# recorded copy, so a direct caller is covered too. One wording, because the
# refusal an operator reads is whichever end they entered by.
#
# A relaunch allocates nothing and re-prepares nothing, so there is no hand-out
# to refuse here. What it does do is put a fresh agent into the copy the task's
# own record names - and after a restart that copy can be one a DIFFERENT live
# record now owns, which is the 2026-09-21 state where one slot ended up named
# by two records. A second agent editing another record's copy is the same class
# of outcome the allocation guard exists to prevent.
#
# Returns 0 when the copy is not a pool slot at all, or when no other record
# names it; 1 with the refusal already printed to stderr otherwise. A scan that
# cannot be completed refuses too: "cannot tell" must never become "nobody owns
# it" at a point where being wrong puts two agents in one copy.
fm_slot_refuse_relaunch_into_other_record() {  # <id> <project> <slot> <self-meta> <state-dir>
  local id=$1 project=$2 slot=$3 self_meta=$4 record_state=$5 rc=0
  fm_treehouse_pool_slot "$project" "$slot" || return 0
  fm_slot_record_other_holder "$slot" "$self_meta" "$record_state" || rc=$?
  case "$rc" in
    1) return 0 ;;
    2)
      echo "error: could not check whether task $id's recorded pool slot $slot is also recorded by another task: $FM_SLOT_RECORD_ERROR; refusing to relaunch into a copy whose ownership cannot be read" >&2
      return 1
      ;;
  esac
  echo "error: task $id records pool slot $slot, but task $FM_SLOT_RECORD_HOLDER_ID records it as its $FM_SLOT_RECORD_HOLDER_FIELD ($FM_SLOT_RECORD_HOLDER_META) too; relaunching would start a second agent in a copy another live record owns, so nothing was launched and nothing was changed." >&2
  echo "A pool lease does not survive a host restart while a task record does, so one slot can end up named by two records. Reconcile them first - bin/fm-crew-state.sh $FM_SLOT_RECORD_HOLDER_ID, then bin/fm-teardown.sh <id> --reconcile-slot for whichever record's work is provably safe - then relaunch $id again." >&2
  return 1
}
