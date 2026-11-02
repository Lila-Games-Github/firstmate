#!/usr/bin/env bash
# Worker-owned local landing train. Never merges, rebases, pushes, or runs tests.
# Usage: fm-landing-queue.sh <ready|status|receipt|gate|fail|baseline|reconcile> <task-id>
#          --project <checkout> [--landing-branch <branch>]
#          [--branch <branch> --head <full-sha>] [--target <full-sha>]
#          [--receipt <file>] [--gate-receipt <name>=<file>]...
#          [--gate <name>] [--reason <text>]
# FM_HOME must explicitly select the owning home; FM_STATE_OVERRIDE and
# FM_DATA_OVERRIDE optionally select its state and data directories.
# Without --landing-branch, use this task's recorded landing_branch, else the
# repository's origin/HEAD, main, or master. All branches must be local refs.
#
# ready joins at the back only with --branch, --head, --target, a green exact-head
# full-suite --receipt, and one --gate-receipt for each configured landing gate.
# The branch must contain the current landing tip, and the target must equal it.
# Each gate receipt is four lines: schema=fm-landing-gate.v1, gate=<name>,
# sha=<full head SHA>, target=<full target SHA>. A failed car must pass these
# checks again before re-enrolling. Active cars use ready without a receipt to
# acknowledge their one front-of-line rebase.
# A head already contained in the landing tip has nothing to land and is refused.
# After rebasing, repeat ready with --target from status to acknowledge the new
# base. The target must still be current and an ancestor of the submitted head.
# status reconciles the whole queue and prints this car as key=value lines:
# place (bottom=1), target_ref, target_sha, rebase_from, head, status, receipt,
# and reason (a failed car's recorded reason or this invocation's red-receipt
# reason, else '-').
# Use git rebase --onto <target_sha> <rebase_from> when the front base changes,
# retaining only this car's commits, then ready --target before the last check.
# Only the bottom car prepares final evidence on the live landing tip. Upper
# cars return waiting-for-front, regardless of receipts or target movement, and
# their workers pause instead of polling, as do workers at ready-to-land and
# needs-baseline. A per-car park-<id> marker beside the queue snapshot records
# the parked status. When a parked car leaves parking - it reaches bottom, lands,
# fails, or its head, target, gates, or receipt return work - and when a
# needs-baseline car becomes ready-to-land, any invocation that observes it,
# including one naming that same task, sends the task one durable steering
# message through fm-send.sh (FM_SEND_IDEMPOTENT=1, a body naming the new status,
# tip, and head), then updates or clears the marker. A failed send leaves the
# marker for the next invocation to retry. A task without a .meta file is not
# steered.
# reconcile refreshes and persists the whole queue, emitting due wakes and park
# steers, without requiring <task-id> to be a car; it prints nothing and is a
# no-op when the landing branch has no queue. fm-merge-local.sh runs it after
# every landing, so a landing steers its own car and advances sleeping cars.
# receipt requires --head, --target and --receipt. At needs-quick it accepts
# exactly schema=fm-quick-check.v1, sha=<full head SHA>, target=<full target SHA>.
# The service produces that receipt only after its configured touched-file suite
# and short phone check pass. At needs-full it accepts fm-full-suite.v1 instead.
# A quick failure is reported with --reason, requiring a later full rerun.
# A tip change touching any of this car's files also requires the full rerun.
# Only the bottom car can submit its last-check receipt.
# A target/head race refuses the submission; status then supplies the new work.
# The legacy gate command can still record a configured gate at the front;
# admission requires all configured gate receipts on the tested pre-queue head.
# A failing front check moves its car to the back when another car waits and
# sends it one durable reason message.
# Its old final evidence is cleared; it fixes its branch while waiting and
# rebases and tests again only on reaching the front. The queue accepts it
# only for the current head and target.
# fail removes a car from the active train with --reason, a single line without
# control characters other than '-', recorded for later status calls. A later
# ready with the same id and branch re-enrolls it at the back. Landed ids stay
# terminal. A missing branch whose recorded head is in the landing tip is landed;
# any other missing branch becomes a failed car on reconciliation.
# baseline requires --receipt for exactly the live landing tip and records it as
# that tip's landing-health baseline, under the same lock as fm-merge-local.sh,
# without moving any ref. It refuses a set conflicting with one already recorded.
# A queued task id names the car whose needs-baseline wake prompted it.
#
# Durable format: data/landing-queue/<hash>/queue is a versioned TSV snapshot,
# identified by the canonical common Git directory and landing branch. Rows in
# append order hold id, branch, head, state, acknowledged base, receipt file,
# receipt target, last notified event hash, and failure reason (failed rows
# only). '-' means absent. Immutable
# receipt snapshots live beside it. Queue writes are atomic and serialized by
# state/.landing-queue-<hash>.lock using the shared recoverable lock helpers.
# Every invocation refreshes live refs, retires heads already in the landing tip,
# and invalidates receipts after head/target changes. Landing an unchanged lower
# car preserves the next car's pre-queue evidence. Failed cars are skipped; their
# successors retain rebase_from so they can drop the failed car's commits.
# Known-red acceptance uses the current landing-health baseline, as the local
# merge gate does. A red bottom receipt is needs-baseline when the live tip has
# no recorded baseline, or red-receipt when it names failures outside that
# baseline; neither demands another suite run on the same head. Once firstmate
# records the baseline, the car becomes ready-to-land, needs-gate, or red-receipt.
# red-receipt is the worker's to fix on a new head when no other car waits.
# Existing v1 rows and still-matching receipts remain readable without migration.
# Only ready-to-land (bottom, acceptable receipt, every configured gate passed,
# fast-forward of the live tip),
# needs-baseline, and failed transitions append durable `check: landing-queue`
# wakes, deduplicated per event. A wake is an event: firstmate rechecks status
# before acting, following the landing-queue agent skill.
# Only firstmate invokes fm-merge-local.sh and pushes, subject
# to the existing merge authority. This tool has no daemon; park and requeue
# steers are its only steering messages.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
die() { echo "error: $*" >&2; exit 1; }
[ "$#" -ge 2 ] || { usage >&2; exit 2; }
ACTION=$1 ID=$2
shift 2
case "$ACTION" in ready|status|receipt|gate|fail|baseline|reconcile) ;; *) die "unknown queue command $ACTION" ;; esac
[[ "$ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid task id'
[ -n "${FM_HOME:-}" ] || die 'FM_HOME must explicitly select the owning home'
PROJECT='' LANDING='' BRANCH='' HEAD='' TARGET='' RECEIPT='' REASON='' GATE=''
GATE_RECEIPTS=()
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
  case "$1" in
    --project) PROJECT=$2 ;;
    --landing-branch) LANDING=$2 ;;
    --branch) BRANCH=$2 ;;
    --head) HEAD=$2 ;;
    --target) TARGET=$2 ;;
    --receipt) RECEIPT=$2 ;;
    --reason) REASON=$2 ;;
    --gate) GATE=$2 ;;
    --gate-receipt) GATE_RECEIPTS[${#GATE_RECEIPTS[@]}]=$2 ;;
    *) die "unknown queue option $1" ;;
  esac
  shift 2
done
[ -n "$PROJECT" ] || die '--project is required'
valid_reason() { [ -n "$1" ] && [ "$1" != - ] && ! [[ "$1" =~ [[:cntrl:]] ]]; }
[ -z "$REASON" ] || valid_reason "$REASON" || die '--reason must be one line without control characters'
COMMON=$(git -C "$PROJECT" rev-parse --git-common-dir) || die 'project is not a Git checkout'
case "$COMMON" in /*) ;; *) COMMON="$PROJECT/$COMMON" ;; esac
COMMON=$(cd "$COMMON" && pwd -P)
PRIMARY=$(git -C "$PROJECT" worktree list --porcelain | sed -n '1s/^worktree //p')
[ -n "$PRIMARY" ] || die 'cannot identify the primary checkout'
PRIMARY=$(cd "$PRIMARY" && pwd -P)
REPO_NAME=${PRIMARY##*/}
GATES_OUTPUT=$(FM_HOME="$FM_HOME" python3 "$SCRIPT_DIR/fm-test-service.py" landing-gates-for-repo "$REPO_NAME") \
  || die "cannot read landing gates for $REPO_NAME"
GATES=()
if [ -n "$GATES_OUTPUT" ]; then
  while IFS= read -r gate_name; do GATES[${#GATES[@]}]=$gate_name; done <<< "$GATES_OUTPUT"
fi
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
if [ -z "$LANDING" ] && [ -f "$STATE/$ID.meta" ]; then
  LANDING=$(sed -n 's/^landing_branch=//p' "$STATE/$ID.meta" | tail -1)
fi
if [ -z "$LANDING" ]; then
  LANDING=$(git -C "$PROJECT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  LANDING=${LANDING#origin/}
  if [ -z "$LANDING" ]; then
    for candidate in main master; do
      if git -C "$PROJECT" show-ref --verify --quiet "refs/heads/$candidate"; then LANDING=$candidate; break; fi
    done
  fi
fi
valid_branch() { [ -n "$1" ] && [ "${1#refs/}" = "$1" ] && git check-ref-format "refs/heads/$1" >/dev/null 2>&1; }
valid_branch "$LANDING" || die 'invalid or missing landing branch'
resolve() { git -C "$PROJECT" rev-parse --verify "refs/heads/$1^{commit}" 2>/dev/null; }
TIP=$(resolve "$LANDING") || die "missing local landing branch $LANDING"
case "$COMMON$PRIMARY$DATA$STATE" in *$'\n'*|*$'\t'*) die 'queue paths cannot contain tabs or newlines' ;; esac
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-landing-health-lib.sh
. "$SCRIPT_DIR/fm-landing-health-lib.sh"
KEY=$(fm_health_key "$COMMON" "$LANDING")
HEALTH_KEY=$(fm_health_key "$PRIMARY" "$LANDING")
DIR="$DATA/landing-queue/$KEY"
if [ "$ACTION" = reconcile ] && [ ! -e "$DIR/queue" ]; then exit 0; fi
for path in "$DATA" "$DATA/landing-queue" "$DIR"; do
  [ ! -L "$path" ] || die "queue directory is a symlink: $path"
done
mkdir -p "$DIR"
LOCK="$STATE/.landing-queue-$KEY.lock"
HEALTH_LOCK="$STATE/.landing-health-$HEALTH_KEY.lock"
TMP='' WAKE_HELD=0 HEALTH_HELD=0
gate_receipt_read() { # <path> <gate> <head> <target>
  local path=$1 gate=$2 head=$3 target=$4 line lines=()
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do lines[${#lines[@]}]=$line; done < "$path"
  [ "${#lines[@]}" -eq 4 ] && [ "${lines[0]}" = schema=fm-landing-gate.v1 ] \
    && [ "${lines[1]}" = "gate=$gate" ] && [ "${lines[2]}" = "sha=$head" ] \
    && [ "${lines[3]}" = "target=$target" ]
}
gate_receipt_path() { printf '%s/gate-%s-%s-%s-%s.receipt' "$DIR" "$1" "$2" "$3" "$4"; }
pre_target() {
  local path="$DIR/pre-$1" value
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r value < "$path"
  [[ "$value" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  printf '%s' "$value"
}
overlap_requires_full() { # <id> <head> <target>
  local prior changed touched
  [ ! -L "$DIR/full-$1" ] || die "full-rerun marker is a symlink: $DIR/full-$1"
  [ -f "$DIR/full-$1" ] && return 0
  prior=$(pre_target "$1") || return 0
  [ "$prior" = "$3" ] && return 1
  git -C "$PROJECT" merge-base --is-ancestor "$prior" "$3" || return 0
  changed=$(git -C "$PROJECT" diff --name-only "$prior" "$3") || return 0
  touched=$(git -C "$PROJECT" diff --name-only "$3" "$2") || return 0
  changed=$(printf '%s\n' "$changed" | LC_ALL=C sort -u)
  touched=$(printf '%s\n' "$touched" | LC_ALL=C sort -u)
  [ -z "$changed" ] && return 1
  [ -z "$touched" ] && return 1
  [ -n "$(LC_ALL=C comm -12 <(printf '%s\n' "$changed") <(printf '%s\n' "$touched"))" ]
}
cleanup() {
  trap '' TERM INT HUP
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ "$HEALTH_HELD" -eq 0 ] || fm_lock_release "$HEALTH_LOCK" || true
  [ "$WAKE_HELD" -eq 0 ] || fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
  fm_lock_release "$LOCK" || true
}
trap cleanup EXIT
trap 'trap "" TERM INT HUP; exit 143' TERM INT HUP
fm_lock_acquire_wait "$LOCK"
FILE="$DIR/queue"
ids=() branches=() heads=() states=() bases=() receipts=() targets=() notified=() reasons=()
count=0 found=-1 joined=0 requeue_reason='' waiting=0
if [ -e "$FILE" ]; then
  [ -f "$FILE" ] && [ ! -L "$FILE" ] || die 'invalid queue snapshot'
  {
    IFS= read -r schema && [ "$schema" = fm-landing-queue.v1 ] || die 'invalid queue schema'
    IFS= read -r repository && [ "$repository" = "$COMMON" ] || die 'queue repository mismatch'
    IFS= read -r landing && [ "$landing" = "$LANDING" ] || die 'queue landing branch mismatch'
    while IFS=$'\t' read -r row_id row_branch row_head row_state row_base row_receipt row_target row_notified row_reason extra; do
      [[ "$row_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid queue task id'
      valid_branch "$row_branch" || die 'invalid queue branch'
      [ -n "$row_notified" ] && [ -n "$row_reason" ] && [ -z "$extra" ] || die 'incomplete queue row'
      [[ "$row_head" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] \
        && [[ "$row_base" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || die 'invalid queue commit'
      case "$row_receipt" in
        -) ;;
        *) [[ "$row_receipt" =~ ^[0-9a-f]{40}([0-9a-f]{24})?\.receipt$ ]] || die 'invalid queue receipt name' ;;
      esac
      case "$row_state" in active|landed|failed) ;; *) die 'invalid queue state' ;; esac
      if [ "$row_state" = failed ]; then
        valid_reason "$row_reason" || die 'invalid queue failure reason'
      else
        [ "$row_reason" = - ] || die 'queue reason on a car that has not failed'
      fi
      for ((i=0; i<count; i++)); do
        [ "${ids[i]}" != "$row_id" ] && [ "${branches[i]}" != "$row_branch" ] || die 'duplicate queue car'
      done
      ids[count]=$row_id branches[count]=$row_branch heads[count]=$row_head states[count]=$row_state
      bases[count]=$row_base receipts[count]=$row_receipt targets[count]=$row_target notified[count]=$row_notified
      reasons[count]=$row_reason
      if [ "$row_id" = "$ID" ]; then found=$count; fi
      count=$((count + 1))
    done
  } < "$FILE"
fi

save() {
  local i reason
  TMP=$(mktemp "$DIR/.queue.XXXXXX")
  {
    printf 'fm-landing-queue.v1\n%s\n%s\n' "$COMMON" "$LANDING"
    for ((i=0; i<count; i++)); do
      reason=-
      [ "${states[i]}" != failed ] || reason=${reasons[i]}
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${ids[i]}" "${branches[i]}" "${heads[i]}" "${states[i]}" \
        "${bases[i]}" "${receipts[i]}" "${targets[i]}" "${notified[i]}" "$reason"
    done
  } > "$TMP"
  mv -f -- "$TMP" "$FILE"
  TMP=
}

# Re-read actual refs even on status: workers publish heads without a supervisor
# steer. A receipt remains usable only if its claimed head still resolves.
refresh() {
  local i live
  TIP=$(resolve "$LANDING") || die "landing branch disappeared: $LANDING"
  for ((i=0; i<count; i++)); do
    [ "${states[i]}" = active ] || continue
    if ! live=$(resolve "${branches[i]}"); then
      if git -C "$PROJECT" merge-base --is-ancestor "${heads[i]}" "$TIP"; then
        states[i]=landed
      else
        states[i]=failed reasons[i]='local branch missing' receipts[i]=- targets[i]=-
      fi
      continue
    fi
    if [ "$live" != "${heads[i]}" ]; then receipts[i]=-; targets[i]=-; fi
    heads[i]=$live
    if git -C "$PROJECT" merge-base --is-ancestor "$live" "$TIP"; then states[i]=landed; fi
  done
}

refresh
if [ "$ACTION" = ready ]; then
  valid_branch "$BRANCH" && [ "$BRANCH" != "$LANDING" ] || die 'ready requires a task branch distinct from the landing branch'
  [ -n "$HEAD" ] && [ "$(resolve "$BRANCH")" = "$HEAD" ] || die '--head must equal the full current branch SHA'
  if [ "$found" -lt 0 ] || [ "${states[found]}" = failed ]; then
    [ "$TARGET" = "$TIP" ] || die 'pre-queue target changed; rebase and test the current landing tip'
    git -C "$PROJECT" merge-base --is-ancestor "$TIP" "$HEAD" || die 'pre-queue head must contain the current landing tip'
    [ -n "$RECEIPT" ] || die 'ready requires an exact-head full-suite receipt before joining'
    fm_health_receipt_read "$RECEIPT" "$HEAD" || die 'ready requires a valid exact-head full-suite receipt'
    [ "$FM_HEALTH_COUNT" -eq 0 ] || die 'ready requires a green full-suite receipt'
    for gate_name in ${GATES[@]+"${GATES[@]}"}; do
      gate_pass=0
      for entry in ${GATE_RECEIPTS[@]+"${GATE_RECEIPTS[@]}"}; do
        [ "${entry%%=*}" = "$gate_name" ] || continue
        gate_receipt_read "${entry#*=}" "$gate_name" "$HEAD" "$TIP" || die "invalid pre-queue gate receipt: $gate_name"
        gate_pass=1
      done
      [ "$gate_pass" -eq 1 ] || die "ready requires pre-queue landing gate: $gate_name"
    done
    for entry in ${GATE_RECEIPTS[@]+"${GATE_RECEIPTS[@]}"}; do
      known=0
      for gate_name in ${GATES[@]+"${GATES[@]}"}; do [ "${entry%%=*}" != "$gate_name" ] || known=1; done
      [ "$known" -eq 1 ] || die "unconfigured pre-queue gate: ${entry%%=*}"
    done
    TMP=$(mktemp "$DIR/.pre.XXXXXX")
    printf '%s\n' "$TIP" > "$TMP"
    mv -f -- "$TMP" "$DIR/pre-$ID"
    TMP=
    rm -f -- "$DIR/full-$ID"
  fi
  if [ "$found" -lt 0 ]; then
    for ((i=0; i<count; i++)); do
      [ "${branches[i]}" != "$BRANCH" ] || die 'branch already belongs to a queue car'
    done
    ! git -C "$PROJECT" merge-base --is-ancestor "$HEAD" "$TIP" || die 'nothing to land: head is already in the landing branch'
    found=$count
    ids[count]=$ID branches[count]=$BRANCH heads[count]=$HEAD states[count]=active
    bases[count]=$(git -C "$PROJECT" merge-base "$HEAD" "$TIP") || die 'task and landing branch have no common base'
    receipts[count]=- targets[count]=- notified[count]=- reasons[count]=-
    count=$((count + 1))
    joined=1
  else
    [ "${states[found]}" != landed ] || die 'landed task cannot rejoin'
    [ "${branches[found]}" = "$BRANCH" ] || die 'cannot change a queued task branch'
    if [ "${states[found]}" = failed ]; then
      ! git -C "$PROJECT" merge-base --is-ancestor "$HEAD" "$TIP" || die 'nothing to land: head is already in the landing branch'
      for ((i=found; i<count-1; i++)); do
        ids[i]=${ids[i+1]} branches[i]=${branches[i+1]} heads[i]=${heads[i+1]}
        states[i]=${states[i+1]} bases[i]=${bases[i+1]} receipts[i]=${receipts[i+1]}
        targets[i]=${targets[i+1]} notified[i]=${notified[i+1]} reasons[i]=${reasons[i+1]}
      done
      found=$((count - 1))
      ids[found]=$ID branches[found]=$BRANCH heads[found]=$HEAD states[found]=active
      bases[found]=$(git -C "$PROJECT" merge-base "$HEAD" "$TIP") || die 'task and landing branch have no common base'
      receipts[found]=- targets[found]=- notified[found]=- reasons[found]=-
      joined=1
    fi
  fi
fi
[ "$found" -ge 0 ] || [ "$ACTION" = reconcile ] || die 'task has not joined the landing queue; run ready first'

# Compute each live assignment from bottom to top. A receipt follows SHAs rather
# than branch names, so a normal lower landing does not demand another suite.
places=() target_refs=() target_shas=() statuses=()
assign() {
  local i position=0 ref="refs/heads/$LANDING" sha=$TIP
  for ((i=0; i<count; i++)); do
    places[i]=0 target_refs[i]=- target_shas[i]=- statuses[i]=${states[i]}
    [ "${states[i]}" = active ] || continue
    position=$((position + 1))
    places[i]=$position target_refs[i]=$ref target_shas[i]=$sha
    if [ "${targets[i]}" != "$sha" ]; then receipts[i]=-; targets[i]=-; fi
    if [ "$position" -gt 1 ]; then
      statuses[i]='waiting-for-front'
      ref="refs/heads/${branches[i]}" sha=${heads[i]}
      continue
    fi
    statuses[i]=needs-rebase
    if [ "${bases[i]}" = "$sha" ] && git -C "$PROJECT" merge-base --is-ancestor "$sha" "${heads[i]}"; then
      if overlap_requires_full "${ids[i]}" "${heads[i]}" "$sha"; then
        statuses[i]=needs-full
        if [ "${receipts[i]}" != - ] && fm_health_receipt_read "$DIR/${receipts[i]}" "${heads[i]}" >/dev/null 2>&1; then
          statuses[i]=ready-to-land
        fi
      else
        statuses[i]=needs-quick
        if [ "${receipts[i]}" != - ] && fm_quick_receipt_read "$DIR/${receipts[i]}" "${heads[i]}" "$sha"; then
          statuses[i]=ready-to-land
        fi
      fi
      if [ "${statuses[i]}" != ready-to-land ]; then receipts[i]=-; targets[i]=-; fi
    fi
    ref="refs/heads/${branches[i]}" sha=${heads[i]}
  done
}
assign
if [ "$joined" -eq 1 ]; then
  bases[found]=$(git -C "$PROJECT" merge-base "$HEAD" "${target_shas[found]}") || die 'task and target have no common base'
fi

case "$ACTION" in
  ready)
    if [ "$joined" -eq 0 ] && [ -n "$TARGET" ]; then
      [ "$TARGET" = "${target_shas[found]}" ] || die 'target changed; check status and rebase again'
      git -C "$PROJECT" merge-base --is-ancestor "$TARGET" "$HEAD" || die 'head is not a fast-forward of the assigned target'
      bases[found]=$TARGET
    fi
    ;;
  receipt)
    [ "${states[found]}" = active ] || die 'only active cars can submit receipts'
    [ "${places[found]}" -eq 1 ] || die 'only the bottom car can submit final evidence; wait for the front'
    [ "$HEAD" = "${heads[found]}" ] && [ "$TARGET" = "${target_shas[found]}" ] \
      && [ "${bases[found]}" = "$TARGET" ] || die 'head or target changed; check status and prepare again'
    git -C "$PROJECT" merge-base --is-ancestor "$TARGET" "$HEAD" || die 'head is not a fast-forward of the assigned target'
    if [ -n "$REASON" ]; then
      [ -z "$RECEIPT" ] || die 'failed quick check cannot also submit a receipt'
      [ "${statuses[found]}" = needs-quick ] || die 'failure reason is for a quick check'
      TMP=$(mktemp "$DIR/.full.XXXXXX")
      printf '%s\n' "$REASON" > "$TMP"
      mv -f -- "$TMP" "$DIR/full-$ID"
      TMP=
      requeue_reason="quick check failed: $REASON"
    else
      [ -n "$RECEIPT" ] || die 'receipt requires --receipt or --reason'
      TMP=$(mktemp "$DIR/.receipt.XXXXXX")
      cp -- "$RECEIPT" "$TMP" || die 'cannot stage receipt'
      if [ "${statuses[found]}" = needs-full ]; then
        fm_health_receipt_read "$TMP" "$HEAD" || die 'invalid exact-head full receipt'
      else
        fm_quick_receipt_read "$TMP" "$HEAD" "$TARGET" || die 'invalid exact-head quick receipt'
      fi
      digest=$(git hash-object -- "$TMP")
      mv -f -- "$TMP" "$DIR/$digest.receipt"
      TMP=
      receipts[found]="$digest.receipt" targets[found]=$TARGET
    fi
    ;;
  gate)
    [ "${states[found]}" = active ] || die 'only active cars can submit gate receipts'
    [ "${places[found]}" -eq 1 ] || die 'only the bottom car can submit final evidence; wait for the front'
    [[ "$GATE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'gate requires a safe --gate name'
    configured=0
    for gate_name in ${GATES[@]+"${GATES[@]}"}; do [ "$gate_name" != "$GATE" ] || configured=1; done
    [ "$configured" -eq 1 ] || die "landing gate is not configured: $GATE"
    [ "$HEAD" = "${heads[found]}" ] && [ "$TARGET" = "${target_shas[found]}" ] \
      && [ "${bases[found]}" = "$TARGET" ] || die 'head or target changed; check status and prepare again'
    git -C "$PROJECT" merge-base --is-ancestor "$TARGET" "$HEAD" || die 'head is not a fast-forward of the assigned target'
    if [ -n "$REASON" ]; then
      [ -z "$RECEIPT" ] || die 'gate failure cannot also submit a passing receipt'
      requeue_reason="landing gate $GATE failed: $REASON"
    else
      [ -n "$RECEIPT" ] || die 'gate requires --receipt or --reason'
      TMP=$(mktemp "$DIR/.gate.XXXXXX")
      cp -- "$RECEIPT" "$TMP" || die 'cannot stage gate receipt'
      gate_receipt_read "$TMP" "$GATE" "$HEAD" "$TARGET" || die 'invalid exact-head and target gate receipt'
      mv -f -- "$TMP" "$(gate_receipt_path "$ID" "$GATE" "$HEAD" "$TARGET")"
      TMP=
    fi
    ;;
  fail)
    [ -n "$REASON" ] || die 'fail requires --reason'
    [ "${states[found]}" != landed ] || die 'cannot fail a landed car'
    states[found]=failed reasons[found]=$REASON
    receipts[found]=- targets[found]=-
    ;;
  baseline)
    [ -n "$RECEIPT" ] || die 'baseline requires --receipt'
    fm_lock_acquire_wait "$HEALTH_LOCK"
    HEALTH_HELD=1
    TMP=$(mktemp "$DIR/.baseline.XXXXXX")
    cp -- "$RECEIPT" "$TMP" || die 'cannot stage baseline receipt'
    fm_health_receipt_read "$TMP" "$TIP" || die "baseline receipt must name the landing tip $TIP"
    supplied_count=$FM_HEALTH_COUNT supplied_set=$FM_HEALTH_SET
    if fm_health_receipt_read "$DATA/landing-health/$HEALTH_KEY.receipt" "$TIP" >/dev/null 2>&1; then
      [ "$FM_HEALTH_COUNT" -eq "$supplied_count" ] && [ "$FM_HEALTH_SET" = "$supplied_set" ] \
        || die "baseline conflicts with the failing set already recorded for $TIP"
    else
      fm_health_store "$TMP" "$DATA" "$HEALTH_KEY" || die 'cannot record baseline receipt'
    fi
    rm -f -- "$TMP"
    TMP=
    fm_lock_release "$HEALTH_LOCK"
    HEALTH_HELD=0
    ;;
esac
assign

# Full fallback receipts use the current-tip failure-set policy as fm-merge-local.
for ((i=0; i<count; i++)); do
  if [ "${statuses[i]}" = ready-to-land ] && overlap_requires_full "${ids[i]}" "${heads[i]}" "${target_shas[i]}"; then
    fm_health_receipt_read "$DIR/${receipts[i]}" "${heads[i]}"
    if [ "$FM_HEALTH_COUNT" -gt 0 ]; then
      incoming=$FM_HEALTH_SET
      if ! fm_health_receipt_read "$DATA/landing-health/$HEALTH_KEY.receipt" "$TIP" >/dev/null 2>&1; then
        statuses[i]=needs-baseline reasons[i]='landing tip has no recorded landing-health baseline'
      elif [ -n "$(LC_ALL=C comm -23 <(printf '%s\n' "$incoming") <(printf '%s\n' "$FM_HEALTH_SET"))" ]; then
        statuses[i]=red-receipt reasons[i]='receipt names failures outside the landing-health baseline'
      fi
    fi
  fi
done

# A full front rerun must repeat configured landing gates on the rebased head.
for ((i=0; i<count; i++)); do
  [ "${statuses[i]}" = ready-to-land ] || continue
  overlap_requires_full "${ids[i]}" "${heads[i]}" "${target_shas[i]}" || continue
  for gate_name in ${GATES[@]+"${GATES[@]}"}; do
    if ! gate_receipt_read "$(gate_receipt_path "${ids[i]}" "$gate_name" "${heads[i]}" "${target_shas[i]}")" \
      "$gate_name" "${heads[i]}" "${target_shas[i]}"; then
      statuses[i]=needs-gate
      reasons[i]="missing landing gate: $gate_name"
      break
    fi
  done
done

# A failing final check moves only the front car behind the other active cars.
if [ -z "$requeue_reason" ] && [ "$found" -ge 0 ] && [ "${statuses[found]}" = red-receipt ]; then
  requeue_reason=${reasons[found]}
fi
if [ -n "$requeue_reason" ] && [ "$found" -ge 0 ] && [ "${places[found]}" -eq 1 ]; then
  for ((i=0; i<count; i++)); do
    [ "$i" -eq "$found" ] || [ "${states[i]}" != active ] || waiting=1
  done
  if [ "$waiting" -eq 1 ]; then
    moved_id=${ids[found]} moved_branch=${branches[found]}
    moved_head=${heads[found]} moved_base=${bases[found]}
    for ((i=found; i<count-1; i++)); do
      ids[i]=${ids[i+1]} branches[i]=${branches[i+1]} heads[i]=${heads[i+1]}
      states[i]=${states[i+1]} bases[i]=${bases[i+1]} receipts[i]=${receipts[i+1]}
      targets[i]=${targets[i+1]} notified[i]=${notified[i+1]} reasons[i]=${reasons[i+1]}
    done
    found=$((count - 1))
    ids[found]=$moved_id branches[found]=$moved_branch heads[found]=$moved_head
    states[found]=active bases[found]=$moved_base receipts[found]=- targets[found]=-
    notified[found]=- reasons[found]=-
    assign
  elif [ "$ACTION" = gate ]; then
    die "$requeue_reason; no other car is waiting, so fix the branch, rebase and retest on a new head"
  fi
fi

# Persist queue and wake publication under the wake lock. Repeated status calls
# do not ring again for an unchanged readiness/failure event.
fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
WAKE_HELD=1
if [ "$waiting" -eq 1 ]; then
  marker="$DIR/requeue-$moved_id"
  [ ! -L "$marker" ] || die "requeue marker is a symlink: $marker"
  TMP=$(mktemp "$DIR/.requeue.XXXXXX")
  printf '%s\n' "$requeue_reason" > "$TMP"
  mv -f -- "$TMP" "$marker"
  TMP=
fi
for ((i=0; i<count; i++)); do
  case "${statuses[i]}" in
    ready-to-land|needs-baseline|failed) ;;
    landed) continue ;;
    *) notified[i]=-; continue ;;
  esac
  event_tip=-
  [ "${statuses[i]}" = failed ] || event_tip=$TIP
  event=$(printf '%s\n' "${ids[i]}" "${statuses[i]}" "${heads[i]}" "$event_tip" "${receipts[i]}" | git hash-object --stdin)
  if [ "${notified[i]}" != "$event" ]; then
    fm_wake_append_locked check "landing-queue-$KEY" \
      "check: landing-queue ${statuses[i]} task=${ids[i]} project=$PRIMARY landing=$LANDING tip=$TIP head=${heads[i]} receipt=$DIR/${receipts[i]} reason=${reasons[i]}"
    notified[i]=$event
  fi
done
save
fm_lock_release "$FM_WAKE_QUEUE_LOCK"
WAKE_HELD=0

for ((i=0; i<count; i++)); do
  marker="$DIR/requeue-${ids[i]}"
  [ ! -L "$marker" ] || die "requeue marker is a symlink: $marker"
  [ -f "$marker" ] || continue
  [ -f "$STATE/${ids[i]}.meta" ] || continue
  requeue_message_reason=$(cat -- "$marker")
  if ! send_error=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 "$SCRIPT_DIR/fm-send.sh" "${ids[i]}" \
    "Landing queue: task=${ids[i]} moved to back because $requeue_message_reason. Fix your branch while waiting; run landing_queue status when you reach front, then rebase and retest." 2>&1 >/dev/null); then
    printf 'warning: could not steer %s after requeue; the next queue invocation retries: %s\n' "${ids[i]}" "$send_error" >&2
    continue
  fi
  rm -f -- "$marker"
done

for ((i=0; i<count; i++)); do
  marker="$DIR/park-${ids[i]}"
  [ ! -L "$marker" ] || die "park marker is a symlink: $marker"
  parked=-
  [ ! -f "$marker" ] || parked=$(cat -- "$marker")
  current=${statuses[i]}
  case "$current" in
    waiting-for-front|ready-to-land|needs-baseline)
      [ "$parked" != "$current" ] || continue
      steer=0
      [ "$parked:$current" != needs-baseline:ready-to-land ] || steer=1
      ;;
    *)
      [ "$parked" != - ] || continue
      steer=1
      ;;
  esac
  if [ "$steer" -eq 1 ] && [ -f "$STATE/${ids[i]}.meta" ]; then
    if ! send_error=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 "$SCRIPT_DIR/fm-send.sh" "${ids[i]}" \
      "Landing queue: task=${ids[i]} status=$current (was $parked) place=${places[i]} queue=$KEY landing=$LANDING tip=$TIP head=${heads[i]}. Run landing_queue status and continue from that status." 2>&1 >/dev/null); then
      printf 'warning: could not steer %s from %s to %s; the next queue invocation retries: %s\n' "${ids[i]}" "$parked" "$current" "$send_error" >&2
      continue
    fi
  fi
  case "$current" in
    waiting-for-front|ready-to-land|needs-baseline)
      TMP=$(mktemp "$DIR/.park.XXXXXX")
      printf '%s\n' "$current" > "$TMP"
      mv -f -- "$TMP" "$marker"
      TMP=
      ;;
    *) rm -f -- "$marker" ;;
  esac
done

[ "$ACTION" != reconcile ] || exit 0

printf 'queue=%s\ntask=%s\nbranch=%s\nhead=%s\nlanding_branch=%s\ntip=%s\nplace=%s\ntarget_ref=%s\ntarget_sha=%s\nrebase_from=%s\nstatus=%s\n' \
  "$KEY" "$ID" "${branches[found]}" "${heads[found]}" "$LANDING" "$TIP" "${places[found]}" \
  "${target_refs[found]}" "${target_shas[found]}" "${bases[found]}" "${statuses[found]}"
if [ "${receipts[found]}" = - ]; then printf 'receipt=-\n'; else printf 'receipt=%s/%s\n' "$DIR" "${receipts[found]}"; fi
printf 'reason=%s\n' "${reasons[found]}"
