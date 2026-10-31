#!/usr/bin/env bash
# Worker-owned local landing train. Never merges, rebases, pushes, or runs tests.
# Usage: fm-landing-queue.sh <ready|status|receipt|gate|fail|baseline|reconcile> <task-id>
#          --project <checkout> [--landing-branch <branch>]
#          [--branch <branch> --head <full-sha>] [--target <full-sha>]
#          [--receipt <file>] [--gate <name>] [--reason <text>]
# FM_HOME must explicitly select the owning home; FM_STATE_OVERRIDE and
# FM_DATA_OVERRIDE optionally select its state and data directories.
# Without --landing-branch, use this task's recorded landing_branch, else the
# repository's origin/HEAD, main, or master. All branches must be local refs.
#
# ready joins at the back, or updates an active car, with --branch and --head.
# A head already contained in the landing tip has nothing to land and is refused.
# After rebasing, repeat ready with --target from status to acknowledge the new
# base. The target must still be current and an ancestor of the submitted head.
# status reconciles the whole queue and prints this car as key=value lines:
# place (bottom=1), target_ref, target_sha, rebase_from, head, status, receipt,
# and reason (a failed car's recorded reason or this invocation's red-receipt
# reason, else '-').
# Use git rebase --onto <target_sha> <rebase_from> when the base changes, retaining
# only this car's commits, then ready --target before the exact-head suite.
# Only the bottom car prepares final evidence on the live landing tip. Upper
# cars return waiting-for-front, regardless of receipts or target movement, and
# their workers pause instead of polling. When a car that was observed above
# bottom becomes bottom, any invocation that observes it sends that task one
# durable steering message through fm-send.sh (FM_SEND_IDEMPOTENT=1, a frozen
# body naming the task and queue), unless that car is the invoking task, which
# reads its own status. A per-car front-<id> marker beside the queue snapshot
# records waiting, then sent; a failed send stays waiting and is retried by the
# next invocation. A task without a .meta file is not steered.
# reconcile refreshes and persists the whole queue, emitting due wakes and front
# steers, without requiring <task-id> to be a car; it prints nothing and is a
# no-op when the landing branch has no queue. fm-merge-local.sh runs it after
# every landing, so a lower landing advances sleeping upper workers.
# receipt requires --head, --target and --receipt. It snapshots an fm-full-suite.v1
# receipt (parser: fm-landing-health-lib.sh) only for the bottom car's current
# head and target. Upper-car receipt and gate submissions are refused.
# A target/head race refuses the submission; status then supplies the new work.
# gate requires --gate, --head, --target, and --receipt for a configured landing
# gate. Its receipt is exactly four lines: schema=fm-landing-gate.v1,
# gate=<name>, sha=<full head SHA>, target=<full target SHA>. The worker submits
# it only after that check passes. The queue snapshots the claim and accepts it
# only for the current head and target. A missing gate yields needs-gate with
# the gate name in reason; it never emits a readiness wake.
# fail removes a car from the active train with --reason, a single line without
# control characters other than '-', recorded for later status calls; it cannot silently
# rejoin. Start a new task id after resolving a failed car. Landed ids also stay
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
# car preserves the next car's exact-SHA receipt. Failed cars are skipped; their
# successors retain rebase_from so they can drop the failed car's commits.
# Known-red acceptance uses the current landing-health baseline, as the local
# merge gate does. A red bottom receipt is needs-baseline when the live tip has
# no recorded baseline, or red-receipt when it names failures outside that
# baseline; neither demands another suite run on the same head. Once firstmate
# records the baseline, the car becomes ready-to-land, needs-gate, or red-receipt.
# red-receipt is the worker's to fix on a new head or fail.
# Existing v1 rows and still-matching receipts remain readable without migration.
# Only ready-to-land (bottom, acceptable receipt, every configured gate passed,
# fast-forward of the live tip),
# needs-baseline, and failed transitions append durable `check: landing-queue`
# wakes, deduplicated per event. A wake is an event: firstmate rechecks status
# before acting, following the landing-queue agent skill.
# Only firstmate invokes fm-merge-local.sh and pushes, subject
# to the existing merge authority. This tool has no daemon; front steers are
# its only steering messages.
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
mapfile -t GATES <<< "$GATES_OUTPUT"
[ -n "$GATES_OUTPUT" ] || GATES=()
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
  local path=$1 gate=$2 head=$3 target=$4 lines=()
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mapfile -t lines < "$path"
  [ "${#lines[@]}" -eq 4 ] && [ "${lines[0]}" = schema=fm-landing-gate.v1 ] \
    && [ "${lines[1]}" = "gate=$gate" ] && [ "${lines[2]}" = "sha=$head" ] \
    && [ "${lines[3]}" = "target=$target" ]
}
gate_receipt_path() { printf '%s/gate-%s-%s-%s-%s.receipt' "$DIR" "$1" "$2" "$3" "$4"; }
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
count=0 found=-1 joined=0
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
    [ "${states[found]}" = active ] || die "task is already ${states[found]}; use a new task id"
    [ "${branches[found]}" = "$BRANCH" ] || die 'cannot change a queued task branch'
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
      statuses[i]=waiting-for-front
      ref="refs/heads/${branches[i]}" sha=${heads[i]}
      continue
    fi
    statuses[i]=needs-rebase
    if [ "${bases[i]}" = "$sha" ] && git -C "$PROJECT" merge-base --is-ancestor "$sha" "${heads[i]}"; then
      statuses[i]=needs-final
      if [ "${receipts[i]}" != - ] && fm_health_receipt_read "$DIR/${receipts[i]}" "${heads[i]}" >/dev/null 2>&1; then
        statuses[i]=ready-to-land
      else
        receipts[i]=-; targets[i]=-
      fi
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
    if [ -n "$TARGET" ]; then
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
    TMP=$(mktemp "$DIR/.receipt.XXXXXX")
    cp -- "$RECEIPT" "$TMP" || die 'cannot stage receipt'
    fm_health_receipt_read "$TMP" "$HEAD" || die 'invalid exact-head receipt'
    digest=$(git hash-object -- "$TMP")
    mv -f -- "$TMP" "$DIR/$digest.receipt"
    TMP=
    receipts[found]="$digest.receipt" targets[found]=$TARGET
    ;;
  gate)
    [ "${states[found]}" = active ] || die 'only active cars can submit gate receipts'
    [ "${places[found]}" -eq 1 ] || die 'only the bottom car can submit final evidence; wait for the front'
    [[ "$GATE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'gate requires a safe --gate name'
    configured=0
    for gate_name in "${GATES[@]}"; do [ "$gate_name" != "$GATE" ] || configured=1; done
    [ "$configured" -eq 1 ] || die "landing gate is not configured: $GATE"
    [ "$HEAD" = "${heads[found]}" ] && [ "$TARGET" = "${target_shas[found]}" ] \
      && [ "${bases[found]}" = "$TARGET" ] || die 'head or target changed; check status and prepare again'
    git -C "$PROJECT" merge-base --is-ancestor "$TARGET" "$HEAD" || die 'head is not a fast-forward of the assigned target'
    [ -n "$RECEIPT" ] || die 'gate requires --receipt'
    TMP=$(mktemp "$DIR/.gate.XXXXXX")
    cp -- "$RECEIPT" "$TMP" || die 'cannot stage gate receipt'
    gate_receipt_read "$TMP" "$GATE" "$HEAD" "$TARGET" || die 'invalid exact-head and target gate receipt'
    mv -f -- "$TMP" "$(gate_receipt_path "$ID" "$GATE" "$HEAD" "$TARGET")"
    TMP=
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

# Readiness uses the same current-tip failure-set policy as fm-merge-local.
# Legacy upper-car receipts are considered only when their car reaches front.
for ((i=0; i<count; i++)); do
  if [ "${statuses[i]}" = ready-to-land ]; then
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

# A passing suite still waits for every declared project landing gate.
for ((i=0; i<count; i++)); do
  case "${statuses[i]}" in ready-to-land) ;; *) continue ;; esac
  for gate_name in "${GATES[@]}"; do
    if ! gate_receipt_read "$(gate_receipt_path "${ids[i]}" "$gate_name" "${heads[i]}" "${target_shas[i]}")" \
      "$gate_name" "${heads[i]}" "${target_shas[i]}"; then
      statuses[i]=needs-gate
      reasons[i]="missing landing gate: $gate_name"
      break
    fi
  done
done

# Persist queue and wake publication under the wake lock. Repeated status calls
# do not ring again for an unchanged readiness/failure event.
fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
WAKE_HELD=1
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
  [ "${states[i]}" = active ] || continue
  marker="$DIR/front-${ids[i]}"
  [ ! -L "$marker" ] || die "front marker is a symlink: $marker"
  front=-
  [ ! -f "$marker" ] || front=$(cat -- "$marker")
  if [ "${places[i]}" -gt 1 ]; then
    [ "$front" != waiting ] || continue
    next=waiting
  else
    [ "$front" = waiting ] || continue
    if [ "${ids[i]}" != "$ID" ]; then
      [ -f "$STATE/${ids[i]}.meta" ] || continue
      if ! send_error=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 "$SCRIPT_DIR/fm-send.sh" "${ids[i]}" \
        "Landing queue: task=${ids[i]} is now bottom (place=1) of queue=$KEY landing=$LANDING. Run landing_queue status and finalize at bottom on the live tip." 2>&1 >/dev/null); then
        printf 'warning: could not steer %s at the front; the next queue invocation retries: %s\n' "${ids[i]}" "$send_error" >&2
        continue
      fi
    fi
    next=sent
  fi
  TMP=$(mktemp "$DIR/.front.XXXXXX")
  printf '%s\n' "$next" > "$TMP"
  mv -f -- "$TMP" "$marker"
  TMP=
done

[ "$ACTION" != reconcile ] || exit 0

printf 'queue=%s\ntask=%s\nbranch=%s\nhead=%s\nlanding_branch=%s\ntip=%s\nplace=%s\ntarget_ref=%s\ntarget_sha=%s\nrebase_from=%s\nstatus=%s\n' \
  "$KEY" "$ID" "${branches[found]}" "${heads[found]}" "$LANDING" "$TIP" "${places[found]}" \
  "${target_refs[found]}" "${target_shas[found]}" "${bases[found]}" "${statuses[found]}"
if [ "${receipts[found]}" = - ]; then printf 'receipt=-\n'; else printf 'receipt=%s/%s\n' "$DIR" "${receipts[found]}"; fi
printf 'reason=%s\n' "${reasons[found]}"
