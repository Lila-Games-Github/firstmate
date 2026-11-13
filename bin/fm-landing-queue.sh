#!/usr/bin/env bash
# Worker-owned local landing train. Never merges, rebases, pushes, or runs tests.
# Usage: fm-landing-queue.sh <ready|status|receipt|gate|fail|baseline|move|step-back|reconcile|resolve> <task-id>
#          --project <checkout> [--landing-branch <branch>]
#          [--branch <branch> --head <full-sha>] [--target <full-sha>]
#          [--receipt <file>] [--gate-receipt <name>=<file>]...
#          [--gate <name>] [--reason <text>] [--owner-task <task-id>]
#          [--place <number>] [--priority infra|unblock]
# FM_HOME must explicitly select the owning home; FM_STATE_OVERRIDE and
# FM_DATA_OVERRIDE optionally select its state and data directories.
# Without --landing-branch, use this task's recorded landing_branch, else the
# repository's origin/HEAD, main, or master. All branches must be local refs.
#
# ready joins at the back, or behind the front with --priority infra or unblock,
# only with --branch, --head, --target, a green exact-head full-suite --receipt,
# and one --gate-receipt for each configured landing gate, except real-phone
# when every changed path matches documentation_path_globs in project config,
# or, when real_phone_path_globs is present, no changed path matches that list.
# The tested target must be an ancestor of the current landing tip and head.
# Each gate receipt is four lines: schema=fm-landing-gate.v1, gate=<name>,
# sha=<full head SHA>, target=<full target SHA>. A failed car must pass these
# checks again before re-enrolling. Active cars use ready without a receipt to
# acknowledge their one front-of-line rebase.
# ready also accepts --priority infra, for test-infrastructure work the captain's
# standing rule proves in isolation and lands ahead of product work. Such a car
# admits behind the current front car and the unbroken run of infra cars that
# directly follows it, ahead of every waiting non-infra car; an infra car left
# behind product work by a requeue or move is not counted, and the front car is
# never displaced.
# --priority unblock is for a car other cars are waiting on, such as the fix for
# a check that fails everywhere. It admits directly behind the front car and any
# unblock cars already directly behind it, so ahead of infra and ordinary cars;
# an infra car's run behind the front counts unblock cars as well as infra cars.
# The priority is recorded durably on the row, shown by status as priority=-,
# priority=infra, or priority=unblock, and kept across a fail/ready re-enrollment unless that
# later ready repeats --priority with a different value.
# A head already contained in the landing tip has nothing to land and is refused.
# After rebasing, repeat ready with --target from status to acknowledge the new
# base. The target must still be current and an ancestor of the submitted head.
# status reconciles the whole queue and prints this car as key=value lines:
# place (bottom=1), target_ref, target_sha, rebase_from, head, status, receipt,
# reason (a failed car's recorded reason or this invocation's red-receipt
# reason, else '-'), priority ('-', infra, or unblock), and front_request (the last test
# farm request resolve applied to this car, as <request>:<passed|failed>, else
# '-').
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
# marker for the next invocation to retry. The car's recorded owner receives
# the steer; legacy rows resolve a unique owner by project and lane branch.
# A task without a .meta file is not steered.
# reconcile refreshes and persists the whole queue, emitting due wakes and park
# steers, without requiring <task-id> to be a car; it prints nothing and is a
# no-op when the landing branch has no queue. fm-merge-local.sh runs it after
# every landing, so a landing steers its own car and advances sleeping cars.
# resolve does everything reconcile does, then settles a front car at
# needs-quick from the test farm itself, so the line never waits on a worker to
# report its result. It reads `testfarm status --json --no-probe`
# (FM_TESTFARM_BIN, default testfarm; bounded by FM_TESTFARM_TIMEOUT, default
# 10 seconds, valid 1..60; an invalid value counts as an unreadable farm and
# affects no other action) and selects the newest non-cancelled quick request
# for exactly the car's head and assigned target, submitted after the car's
# latest admission and not already applied. A passed request records the farm's
# fm-quick-check.v1 receipt exactly as receipt --receipt does; a failed or
# conflict request takes the receipt --reason path with the farm's first failure
# line, so the car moves to the back when another waits and its owner receives
# one durable reason message either way. A queued or running request, or no
# matching request, changes nothing. Each applied request is recorded with the
# car in farm-<id> beside the queue snapshot, and status prints it as
# front_request. A later worker receipt or quick failure for that same head and
# target is a no-op that prints status; a report contradicting the farm's
# verdict is refused. When the farm cannot be read the car is unchanged, and
# resolve appends one `check: landing-queue testfarm-unreachable` wake per
# car, head, and target until a read succeeds. resolve prints one line per
# outcome: `front-check passed|failed|unreachable task=<id> ...`, with
# `wake=new|repeat` on unreachable. fm-landing-queue-sweep.sh runs it for every
# train from the watcher poll.
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
# ready with the same id and branch re-enrolls it at its priority position,
# keeping its recorded priority unless that ready repeats --priority with a
# different value. Landed ids stay terminal. A missing branch whose recorded
# head is in the landing tip is landed; any other missing branch becomes a
# failed car on reconciliation.
# move is for firstmate only. It places an active waiting car at --place in the
# active train (front=1), preserving every row's state and evidence. Place 1
# and moving the current front car are refused so its running check is untouched.
# A car whose admitted evidence is missing or whose head changed is refused.
# Only cars whose status changes receive the existing parked-car steer.
# step-back is for firstmate only. It sends the active front car to place 2,
# behind the next active car, without a failed mark, for a front car whose
# check is held up by something that is not its own fault. A car not at the
# front, or a front car with no other active car waiting, is refused. The car
# keeps its branch, owner, priority, admission evidence, full-rerun requirement,
# gate receipts, and test farm ledger; only its front-check receipt is cleared,
# so it redoes its front check when it returns to the front, even against an
# unchanged target. A stepback-<id> marker beside the queue snapshot records
# the step-back: farm ledger outcomes and quick requests from before it never
# settle the returning car's check. Its owner receives one durable steer
# naming the step-back and the optional --reason (a stepped-<id> marker retries
# a failed send on the next invocation); the new front car gets the existing
# parked-car steer. A later fail and fresh ready clears the marker.
# baseline requires --receipt for exactly the live landing tip and records it as
# that tip's landing-health baseline, under the same lock as fm-merge-local.sh,
# without moving any ref. It refuses a set conflicting with one already recorded.
# A queued task id names the car whose needs-baseline wake prompted it.
#
# Durable format: data/landing-queue/<hash>/queue is a versioned TSV snapshot,
# identified by the canonical common Git directory and landing branch. Rows in
# append order hold id, branch, head, state, acknowledged base, receipt file,
# receipt target, last notified event hash, failure reason (failed rows only),
# owner task id, admission priority ('-', infra, or unblock), and the
# phone-gate exemption reason. Nine-field legacy rows resolve their owner on
# refresh; ten-field legacy rows default priority to '-'.
# '-' means absent. Row order is queue order: assignment walks rows top to
# bottom and gives each active row the next place, so an admitted infra car's
# row sits after the front row and its contiguous infra run. Immutable
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
case "$ACTION" in ready|status|receipt|gate|fail|baseline|move|step-back|reconcile|resolve) ;; *) die "unknown queue command $ACTION" ;; esac
[[ "$ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid task id'
[ -n "${FM_HOME:-}" ] || die 'FM_HOME must explicitly select the owning home'
PROJECT='' LANDING='' BRANCH='' HEAD='' TARGET='' RECEIPT='' REASON='' GATE='' OWNER_TASK='' PLACE='' PRIORITY=''
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
    --owner-task) OWNER_TASK=$2 ;;
    --gate) GATE=$2 ;;
    --gate-receipt) GATE_RECEIPTS[${#GATE_RECEIPTS[@]}]=$2 ;;
    --place) PLACE=$2 ;;
    --priority) PRIORITY=$2 ;;
    *) die "unknown queue option $1" ;;
  esac
  shift 2
done
[ -n "$PROJECT" ] || die '--project is required'
[ -z "$OWNER_TASK" ] || [[ "$OWNER_TASK" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid owner task id'
case "$PRIORITY" in ''|infra|unblock) ;; *) die 'invalid --priority value' ;; esac
[ -z "$PRIORITY" ] || [ "$ACTION" = ready ] || die '--priority is only valid for ready'
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
DOCS_CONFIG_ROOT=${FM_TEST_SERVICE_CONFIG_ROOT:-$FM_HOME/config/test-service}
phone_gate_configured=0
for gate_name in ${GATES[@]+"${GATES[@]}"}; do
  [ "$gate_name" != real-phone ] || phone_gate_configured=1
done
phone_gate_exemption() { # <head> <target>; print reason, fail closed on invalid configuration
  local outcome=0
  [ "$phone_gate_configured" -eq 1 ] || return 1
  python3 "$SCRIPT_DIR/fm-docs-gate.py" "$DOCS_CONFIG_ROOT" "$REPO_NAME" "$PROJECT" "$2" "$1" || outcome=$?
  return "$outcome"
}
phone_gate_exempt() { # <head> <target>; fail closed in the calling shell
  local outcome=0
  phone_gate_exemption "$1" "$2" >/dev/null || outcome=$?
  [ "$outcome" -ne 2 ] || die 'invalid phone gate path glob configuration or Git diff'
  [ "$outcome" -eq 0 ]
}
exemption_reason() { # <head> <target>
  local reason outcome=0
  reason=$(phone_gate_exemption "$1" "$2") || outcome=$?
  [ "$outcome" -ne 2 ] || die 'invalid phone gate path glob configuration or Git diff'
  if [ "$outcome" -eq 0 ]; then printf '%s' "$reason"; return; fi
  printf '%s' -
}
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
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
KEY=$(fm_health_key "$COMMON" "$LANDING")
HEALTH_KEY=$(fm_health_key "$PRIMARY" "$LANDING")
DIR="$DATA/landing-queue/$KEY"
case "$ACTION" in reconcile|resolve) [ -e "$DIR/queue" ] || exit 0 ;; esac
FARM_BIN=${FM_TESTFARM_BIN:-testfarm}
FARM_TIMEOUT=${FM_TESTFARM_TIMEOUT:-10}
for path in "$DATA" "$DATA/landing-queue" "$DIR"; do
  [ ! -L "$path" ] || die "queue directory is a symlink: $path"
done
mkdir -p "$DIR"
LOCK="$STATE/.landing-queue-$KEY.lock"
HEALTH_LOCK="$STATE/.landing-health-$HEALTH_KEY.lock"
TMP='' FARM_TMP='' WAKE_HELD=0 HEALTH_HELD=0
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
admitted_head() {
  local path="$DIR/pre-head-$1" value
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
# The farm ledger farm-<id> holds one applied request per line:
# <request>\t<head>\t<target>\t<passed|failed>.
farm_ledger() { printf '%s/farm-%s' "$DIR" "$1"; }
# A step-back marker stepback-<id> holds two lines: the farm ledger's line count
# and the epoch second at the step-back. Older ledger lines and older requests
# never settle the car's later front check.
stepback_field() { # <id> <line>; prints that marker line, else 0
  local path="$DIR/stepback-$1" value
  [ ! -L "$path" ] || die "step-back marker is a symlink: $path"
  value=$( { [ -f "$path" ] && sed -n "$2p" "$path"; } || true)
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  printf '%s' "$value"
}
farm_recorded() { # <id> <head> <target>; prints the applied outcome
  local ledger outcome skip
  ledger=$(farm_ledger "$1")
  [ ! -L "$ledger" ] || die "test farm ledger is a symlink: $ledger"
  [ -f "$ledger" ] || return 1
  skip=$(stepback_field "$1" 1)
  outcome=$(awk -F '\t' -v head="$2" -v target="$3" -v skip="$skip" 'NR > skip && $2 == head && $3 == target { last = $4 } END { print last }' "$ledger")
  [ -n "$outcome" ] || return 1
  printf '%s' "$outcome"
}
farm_last() { # <id>; prints <request>:<outcome> or '-'
  local ledger last
  ledger=$(farm_ledger "$1")
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || { printf -- '-'; return 0; }
  last=$(awk -F '\t' 'NF >= 4 { last = $1 ":" $4 } END { print last }' "$ledger")
  printf '%s' "${last:--}"
}
farm_record() { # <id> <request> <head> <target> <outcome>
  local ledger
  ledger=$(farm_ledger "$1")
  [ ! -L "$ledger" ] || die "test farm ledger is a symlink: $ledger"
  TMP=$(mktemp "$DIR/.farm.XXXXXX")
  [ ! -f "$ledger" ] || cat -- "$ledger" > "$TMP"
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$TMP"
  mv -f -- "$TMP" "$ledger"
  TMP=
}
# Select the car's quick request from one farm status read. Prints one line:
# none | pending <request> <state> | passed <request> | failed <request> <reason>.
# shellcheck disable=SC2016 # Python source, not shell expansions.
FARM_SELECT='
import json, os, re, sys
path, head, target, admission, ledger, stepped = sys.argv[1:7]
with open(path) as handle:
    data = json.load(handle)
requests = data.get("requests") if isinstance(data, dict) else None
if not isinstance(requests, list):
    sys.exit(3)
since = 0.0
try:
    since = float(int(os.stat(admission).st_mtime))
except OSError:
    pass
consumed = set()
try:
    with open(ledger) as handle:
        for line in handle:
            consumed.add(line.split("\t", 1)[0])
except OSError:
    pass
stepped = int(stepped)
best = None
for row in requests:
    if not isinstance(row, dict):
        continue
    options = row.get("options")
    if not isinstance(options, dict) or options.get("check") != "quick" or not options.get("suite"):
        continue
    if row.get("sha") != head or options.get("target") != target or row.get("state") == "cancelled":
        continue
    rid = row.get("id")
    if not isinstance(rid, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", rid) or rid in consumed:
        continue
    submitted = row.get("submitted")
    submitted = float(submitted) if isinstance(submitted, (int, float)) else 0.0
    if submitted < since or (stepped and submitted <= stepped):
        continue
    seq = row.get("seq") if isinstance(row.get("seq"), int) else 0
    if best is None or (submitted, seq) > best[0]:
        best = ((submitted, seq), row)
if best is None:
    print("none")
    sys.exit(0)
row = best[1]
state = row.get("state")
if state == "passed":
    print("passed", row["id"])
elif state in ("failed", "conflict"):
    error = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", str(row.get("error") or ""))
    error = " ".join(re.sub(r"[\x00-\x1f\x7f]+", " ", error).split())[:300]
    print("failed", row["id"], error or state)
else:
    print("pending", row["id"], re.sub(r"[^A-Za-z0-9_-]", "", str(state)) or "unknown")
'
FARM_RESULT='' FARM_REQUEST='' FARM_DETAIL='' FARM_ERROR=''
farm_query() { # <id> <head> <target>; returns 1 when the farm cannot be read
  local rc=0 line stepped_at
  FARM_RESULT='' FARM_REQUEST='' FARM_DETAIL='' FARM_ERROR=''
  # Only this read uses the bound, so a bad value never blocks other actions.
  case "$FARM_TIMEOUT" in ''|*[!0-9]*) FARM_TIMEOUT=0 ;; esac
  if [ "$FARM_TIMEOUT" -lt 1 ] || [ "$FARM_TIMEOUT" -gt 60 ]; then
    FARM_ERROR='FM_TESTFARM_TIMEOUT must be a whole number of seconds from 1 to 60'
    return 1
  fi
  if ! command -v "$FARM_BIN" >/dev/null 2>&1; then
    FARM_ERROR="testfarm command not found: $FARM_BIN"
    return 1
  fi
  stepped_at=$(stepback_field "$1" 2)
  FARM_TMP=$(mktemp "$DIR/.farm-status.XXXXXX")
  fm_run_timed "$FARM_TIMEOUT" "$FARM_BIN" status --json --no-probe > "$FARM_TMP" 2>/dev/null </dev/null || rc=$?
  if [ "$rc" -eq 124 ]; then
    FARM_ERROR="testfarm status timed out after ${FARM_TIMEOUT}s"
  elif [ "$rc" -ne 0 ]; then
    FARM_ERROR="testfarm status exited $rc"
  elif ! line=$(python3 -I -c "$FARM_SELECT" "$FARM_TMP" "$2" "$3" "$DIR/pre-head-$1" "$(farm_ledger "$1")" "$stepped_at" 2>/dev/null); then
    FARM_ERROR='testfarm status did not return a request list'
  fi
  rm -f -- "$FARM_TMP"
  FARM_TMP=
  [ -z "$FARM_ERROR" ] || return 1
  FARM_RESULT=${line%% *}
  line=${line#"$FARM_RESULT"}
  line=${line# }
  FARM_REQUEST=${line%% *}
  FARM_DETAIL=${line#"$FARM_REQUEST"}
  FARM_DETAIL=${FARM_DETAIL# }
  case "$FARM_RESULT" in
    none|pending|passed) ;;
    failed) valid_reason "$FARM_DETAIL" || FARM_DETAIL='failed' ;;
    *) FARM_ERROR='testfarm status selection was unreadable'; return 1 ;;
  esac
}
cleanup() {
  trap '' TERM INT HUP
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ -z "$FARM_TMP" ] || rm -f -- "$FARM_TMP"
  [ "$HEALTH_HELD" -eq 0 ] || fm_lock_release "$HEALTH_LOCK" || true
  [ "$WAKE_HELD" -eq 0 ] || fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
  fm_lock_release "$LOCK" || true
}
trap cleanup EXIT
trap 'trap "" TERM INT HUP; exit 143' TERM INT HUP
fm_lock_acquire_wait "$LOCK"
FILE="$DIR/queue"
ids=() branches=() heads=() states=() bases=() receipts=() targets=() notified=() reasons=() owners=() priorities=()
count=0 found=-1 joined=0 requeue_reason='' waiting=0
if [ -e "$FILE" ]; then
  [ -f "$FILE" ] && [ ! -L "$FILE" ] || die 'invalid queue snapshot'
  {
    IFS= read -r schema && [ "$schema" = fm-landing-queue.v1 ] || die 'invalid queue schema'
    IFS= read -r repository && [ "$repository" = "$COMMON" ] || die 'queue repository mismatch'
    IFS= read -r landing && [ "$landing" = "$LANDING" ] || die 'queue landing branch mismatch'
    while IFS=$'\t' read -r row_id row_branch row_head row_state row_base row_receipt row_target row_notified row_reason row_owner row_priority row_exemption extra; do
      [[ "$row_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid queue task id'
      valid_branch "$row_branch" || die 'invalid queue branch'
      [ -n "$row_notified" ] && [ -n "$row_reason" ] && [ -z "$extra" ] || die 'incomplete queue row'
      case "${row_exemption:--}" in -|'real-phone: all changed paths match documentation_path_globs'|'real-phone: no changed paths match real_phone_path_globs') ;; *) die 'invalid gate exemption' ;; esac
      row_owner=${row_owner:--}
      [ "$row_owner" = - ] || [[ "$row_owner" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid queue owner task id'
      row_priority=${row_priority:--}
      case "$row_priority" in -|infra|unblock) ;; *) die 'invalid queue priority' ;; esac
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
      reasons[count]=$row_reason owners[count]=$row_owner priorities[count]=$row_priority
      if [ "$row_id" = "$ID" ]; then found=$count; fi
      count=$((count + 1))
    done
  } < "$FILE"
fi

owner_for_branch() { # <branch>; only a unique task in this project can own a legacy car
  local branch=$1 meta candidate project match=-
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    candidate=$(sed -n 's/^lane_branch=//p' "$meta" | tail -1)
    [ "$candidate" = "$branch" ] || continue
    project=$(sed -n 's/^project=//p' "$meta" | tail -1)
    [ "$project" = "$PRIMARY" ] || continue
    candidate=${meta##*/}
    candidate=${candidate%.meta}
    [ "$match" = - ] || return 1
    match=$candidate
  done
  [ "$match" != - ] || return 1
  printf '%s' "$match"
}
for ((i=0; i<count; i++)); do
  [ "${owners[i]}" = - ] || continue
  if owner=$(owner_for_branch "${branches[i]}"); then
    owners[i]=$owner
  elif [ -f "$STATE/${ids[i]}.meta" ]; then
    owners[i]=${ids[i]}
  fi
done

save() {
  local i reason exemption tested_target
  TMP=$(mktemp "$DIR/.queue.XXXXXX")
  {
    printf 'fm-landing-queue.v1\n%s\n%s\n' "$COMMON" "$LANDING"
    for ((i=0; i<count; i++)); do
      reason=-
      [ "${states[i]}" != failed ] || reason=${reasons[i]}
      exemption=-
      if [ "${states[i]}" = active ]; then
        tested_target=$(pre_target "${ids[i]}" || true)
        if [ "${places[i]:-0}" -eq 1 ] && git -C "$PROJECT" merge-base --is-ancestor "${target_shas[i]}" "${heads[i]}"; then
          tested_target=${target_shas[i]}
        fi
        [ -z "$tested_target" ] || exemption=$(exemption_reason "${heads[i]}" "$tested_target")
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${ids[i]}" "${branches[i]}" "${heads[i]}" "${states[i]}" \
        "${bases[i]}" "${receipts[i]}" "${targets[i]}" "${notified[i]}" "$reason" "${owners[i]}" "${priorities[i]}" "$exemption"
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

recorded_head=-
[ "$found" -lt 0 ] || recorded_head=${heads[found]}
refresh
if [ "$ACTION" = ready ]; then
  valid_branch "$BRANCH" && [ "$BRANCH" != "$LANDING" ] || die 'ready requires a task branch distinct from the landing branch'
  [ -n "$HEAD" ] && [ "$(resolve "$BRANCH")" = "$HEAD" ] || die '--head must equal the full current branch SHA'
  if [ "$found" -lt 0 ] || [ "${states[found]}" = failed ]; then
    if [ -z "$TARGET" ] || ! git -C "$PROJECT" merge-base --is-ancestor "$TARGET" "$TIP"; then
      die 'pre-queue target must be an ancestor of the current landing tip'
    fi
    git -C "$PROJECT" merge-base --is-ancestor "$TARGET" "$HEAD" \
      || die 'pre-queue head must contain the tested landing tip'
    [ -n "$RECEIPT" ] || die 'ready requires an exact-head full-suite receipt before joining'
    fm_health_receipt_read "$RECEIPT" "$HEAD" || die 'ready requires a valid exact-head full-suite receipt'
    [ "$FM_HEALTH_COUNT" -eq 0 ] || die 'ready requires a green full-suite receipt'
    for gate_name in ${GATES[@]+"${GATES[@]}"}; do
      if [ "$gate_name" = real-phone ] && phone_gate_exempt "$HEAD" "$TARGET"; then continue; fi
      gate_pass=0
      for entry in ${GATE_RECEIPTS[@]+"${GATE_RECEIPTS[@]}"}; do
        [ "${entry%%=*}" = "$gate_name" ] || continue
        gate_receipt_read "${entry#*=}" "$gate_name" "$HEAD" "$TARGET" || die "invalid pre-queue gate receipt: $gate_name"
        gate_pass=1
      done
      [ "$gate_pass" -eq 1 ] || die "ready requires pre-queue landing gate: $gate_name"
    done
    for entry in ${GATE_RECEIPTS[@]+"${GATE_RECEIPTS[@]}"}; do
      known=0
      for gate_name in ${GATES[@]+"${GATES[@]}"}; do [ "${entry%%=*}" != "$gate_name" ] || known=1; done
      [ "$known" -eq 1 ] || die "unconfigured pre-queue gate: ${entry%%=*}"
      gate_receipt_read "${entry#*=}" "${entry%%=*}" "$HEAD" "$TARGET" \
        || die "invalid pre-queue gate receipt: ${entry%%=*}"
    done
    TMP=$(mktemp "$DIR/.pre.XXXXXX")
    printf '%s\n' "$TARGET" > "$TMP"
    mv -f -- "$TMP" "$DIR/pre-$ID"
    TMP=
    TMP=$(mktemp "$DIR/.pre-head.XXXXXX")
    printf '%s\n' "$HEAD" > "$TMP"
    mv -f -- "$TMP" "$DIR/pre-head-$ID"
    TMP=
    rm -f -- "$DIR/full-$ID" "$(farm_ledger "$ID")" "$DIR/stepback-$ID"
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
    priorities[count]=${PRIORITY:--}
    if [ -n "$OWNER_TASK" ]; then
      owners[count]=$OWNER_TASK
    elif owner=$(owner_for_branch "$BRANCH"); then
      owners[count]=$owner
    else
      owners[count]=$ID
    fi
    count=$((count + 1))
    joined=1
  else
    [ "${states[found]}" != landed ] || die 'landed task cannot rejoin'
    [ "${branches[found]}" = "$BRANCH" ] || die 'cannot change a queued task branch'
    if [ "${states[found]}" = failed ]; then
      ! git -C "$PROJECT" merge-base --is-ancestor "$HEAD" "$TIP" || die 'nothing to land: head is already in the landing branch'
      moved_owner=${owners[found]} moved_priority=${priorities[found]}
      for ((i=found; i<count-1; i++)); do
        ids[i]=${ids[i+1]} branches[i]=${branches[i+1]} heads[i]=${heads[i+1]}
        states[i]=${states[i+1]} bases[i]=${bases[i+1]} receipts[i]=${receipts[i+1]}
        targets[i]=${targets[i+1]} notified[i]=${notified[i+1]} reasons[i]=${reasons[i+1]} owners[i]=${owners[i+1]}
        priorities[i]=${priorities[i+1]}
      done
      found=$((count - 1))
      ids[found]=$ID branches[found]=$BRANCH heads[found]=$HEAD states[found]=active
      bases[found]=$(git -C "$PROJECT" merge-base "$HEAD" "$TIP") || die 'task and landing branch have no common base'
      receipts[found]=- targets[found]=- notified[found]=- reasons[found]=-
      owners[found]=${OWNER_TASK:-$moved_owner}
      priorities[found]=${PRIORITY:-$moved_priority}
      joined=1
    fi
  fi
fi
[ "$found" -ge 0 ] || [ "$ACTION" = reconcile ] || [ "$ACTION" = resolve ] \
  || die 'task has not joined the landing queue; run ready first'
if [ -n "$OWNER_TASK" ] && [ "$found" -ge 0 ]; then
  [ "${owners[found]}" = - ] || [ "${owners[found]}" = "$OWNER_TASK" ] \
    || die 'queue car belongs to a different owner task'
  owners[found]=$OWNER_TASK
fi

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
    if [ "$position" -gt 1 ]; then
      statuses[i]='waiting-for-front'
      ref="refs/heads/${branches[i]}" sha=${heads[i]}
      continue
    fi
    if [ "${targets[i]}" != "$sha" ]; then receipts[i]=-; targets[i]=-; fi
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
# Swap a car's full row with its active neighbor, place by place, until it
# reaches <target place>. assign() recomputes places after every swap. Shared
# by the move command and by infra-priority admission below.
shift_car_to_place() { # <target place>
  local target=$1 neighbor saved
  while [ "${places[found]}" -ne "$target" ]; do
    neighbor=-1
    if [ "${places[found]}" -gt "$target" ]; then
      for ((i=found-1; i>=0; i--)); do
        [ "${states[i]}" != active ] || { neighbor=$i; break; }
      done
    else
      for ((i=found+1; i<count; i++)); do
        [ "${states[i]}" != active ] || { neighbor=$i; break; }
      done
    fi
    [ "$neighbor" -ge 0 ] || die 'cannot locate adjacent active car'
    saved=${ids[found]}; ids[found]=${ids[neighbor]}; ids[neighbor]=$saved
    saved=${branches[found]}; branches[found]=${branches[neighbor]}; branches[neighbor]=$saved
    saved=${heads[found]}; heads[found]=${heads[neighbor]}; heads[neighbor]=$saved
    saved=${states[found]}; states[found]=${states[neighbor]}; states[neighbor]=$saved
    saved=${bases[found]}; bases[found]=${bases[neighbor]}; bases[neighbor]=$saved
    saved=${receipts[found]}; receipts[found]=${receipts[neighbor]}; receipts[neighbor]=$saved
    saved=${targets[found]}; targets[found]=${targets[neighbor]}; targets[neighbor]=$saved
    saved=${notified[found]}; notified[found]=${notified[neighbor]}; notified[neighbor]=$saved
    saved=${reasons[found]}; reasons[found]=${reasons[neighbor]}; reasons[neighbor]=$saved
    saved=${owners[found]}; owners[found]=${owners[neighbor]}; owners[neighbor]=$saved
    saved=${priorities[found]}; priorities[found]=${priorities[neighbor]}; priorities[neighbor]=$saved
    found=$neighbor
    assign
  done
}
assign
if [ "$joined" -eq 1 ]; then
  # A priority car admits behind the front and the unbroken run of cars it may
  # not pass: unblock cars for an unblock car, unblock or infra cars for infra.
  if [ "${priorities[found]}" != - ] && [ "${places[found]}" -gt 1 ]; then
    run_ahead=0
    while :; do
      run_match=0
      for ((i=0; i<count; i++)); do
        [ "$i" != "$found" ] || continue
        [ "${states[i]}" = active ] || continue
        [ "${places[i]}" -eq "$((run_ahead + 2))" ] || continue
        case "${priorities[found]}:${priorities[i]}" in
          unblock:unblock|infra:unblock|infra:infra) run_match=1 ;;
        esac
        break
      done
      [ "$run_match" -eq 1 ] || break
      run_ahead=$((run_ahead + 1))
    done
    shift_car_to_place "$((run_ahead + 2))"
  fi
  bases[found]=$(git -C "$PROJECT" merge-base "$HEAD" "${target_shas[found]}") || die 'task and target have no common base'
fi

# Settle the front car's last check from HEAD, TARGET, and RECEIPT or REASON.
# A worker's receipt command and resolve's test farm verdict share this path.
submit_front_result() {
  local digest
  [ "${states[found]}" = active ] || die 'only active cars can submit receipts'
  [ "${places[found]}" -eq 1 ] || die 'only the bottom car can submit final evidence; wait for the front'
  [ "$HEAD" = "${heads[found]}" ] && [ "$TARGET" = "${target_shas[found]}" ] \
    && [ "${bases[found]}" = "$TARGET" ] || die 'head or target changed; check status and prepare again'
  git -C "$PROJECT" merge-base --is-ancestor "$TARGET" "$HEAD" || die 'head is not a fast-forward of the assigned target'
  if [ -n "$REASON" ]; then
    [ "${statuses[found]}" = needs-quick ] || die 'failure reason is for a quick check'
    TMP=$(mktemp "$DIR/.full.XXXXXX")
    printf '%s\n' "$REASON" > "$TMP"
    mv -f -- "$TMP" "$DIR/full-${ids[found]}"
    TMP=
    requeue_reason="quick check failed: $REASON"
  else
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
}
farm_unreachable=0 farm_failed=0 farm_line='' stepped_back=0
case "$ACTION" in
  ready)
    if [ "$joined" -eq 0 ] && [ -n "$TARGET" ]; then
      [ "$TARGET" = "${target_shas[found]}" ] || die 'target changed; check status and rebase again'
      git -C "$PROJECT" merge-base --is-ancestor "$TARGET" "$HEAD" || die 'head is not a fast-forward of the assigned target'
      bases[found]=$TARGET
    fi
    ;;
  receipt)
    [ -n "$REASON" ] || [ -n "$RECEIPT" ] || die 'receipt requires --receipt or --reason'
    [ -z "$REASON" ] || [ -z "$RECEIPT" ] || die 'failed quick check cannot also submit a receipt'
    if farm_outcome=$(farm_recorded "${ids[found]}" "$HEAD" "$TARGET"); then
      reported=passed
      [ -z "$REASON" ] || reported=failed
      [ "$farm_outcome" = "$reported" ] \
        || die "the test farm already settled this front check as $farm_outcome; check status"
    else
      submit_front_result
    fi
    ;;
  resolve)
    front=-1
    for ((i=0; i<count; i++)); do
      [ "${states[i]}" != active ] || [ "${places[i]}" -ne 1 ] || { front=$i; break; }
    done
    if [ "$front" -ge 0 ] && [ "${statuses[front]}" = needs-quick ]; then
      farm_id=${ids[front]} farm_head=${heads[front]} farm_target=${target_shas[front]}
      if ! farm_query "$farm_id" "$farm_head" "$farm_target"; then
        farm_unreachable=1
      elif [ "$FARM_RESULT" = passed ] || [ "$FARM_RESULT" = failed ]; then
        found=$front HEAD=$farm_head TARGET=$farm_target
        if [ "$FARM_RESULT" = passed ]; then
          FARM_TMP=$(mktemp "$DIR/.farm-receipt.XXXXXX")
          printf 'schema=fm-quick-check.v1\nsha=%s\ntarget=%s\n' "$HEAD" "$TARGET" > "$FARM_TMP"
          RECEIPT=$FARM_TMP
          submit_front_result
          rm -f -- "$FARM_TMP"
          FARM_TMP=
        else
          REASON="testfarm request $FARM_REQUEST failed: $FARM_DETAIL"
          submit_front_result
          farm_failed=1
        fi
        farm_record "$farm_id" "$FARM_REQUEST" "$HEAD" "$TARGET" "$FARM_RESULT"
        farm_line="front-check $FARM_RESULT task=$farm_id request=$FARM_REQUEST head=$HEAD target=$TARGET"
        [ "$FARM_RESULT" = passed ] || farm_line="$farm_line reason=$REASON"
      fi
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
  move)
    [ "${states[found]}" = active ] || die 'only active cars can move'
    [ "${places[found]}" -gt 1 ] || die 'the front car cannot move during its check'
    [[ "$PLACE" =~ ^[0-9]+$ ]] || die 'move requires a numeric --place'
    [ "$PLACE" -gt 1 ] || die 'place 1 is reserved for the current front car'
    active_count=0
    for ((i=0; i<count; i++)); do [ "${states[i]}" != active ] || active_count=$((active_count + 1)); done
    [ "$PLACE" -le "$active_count" ] || die 'place exceeds the active train'
    admission_head=$(admitted_head "$ID") || admission_head=$recorded_head
    [ "$recorded_head" = "${heads[found]}" ] && [ "$admission_head" = "${heads[found]}" ] \
      || die 'car head changed since admission; re-enroll with fresh evidence first'
    admitted_target=$(pre_target "$ID") || die 'car has no ready admission evidence'
    git -C "$PROJECT" merge-base --is-ancestor "$admitted_target" "${heads[found]}" \
      || die 'car no longer contains its admitted target'
    shift_car_to_place "$PLACE"
    ;;
  step-back)
    [ "${states[found]}" = active ] || die 'only an active car can step back'
    [ "${places[found]}" -eq 1 ] || die 'only the front car can step back; use move for a waiting car'
    behind=0
    for ((i=0; i<count; i++)); do
      [ "$i" -eq "$found" ] || [ "${states[i]}" != active ] || behind=1
    done
    [ "$behind" -eq 1 ] || die 'no other car is waiting, so the front car has nothing to step behind'
    receipts[found]=- targets[found]=-
    shift_car_to_place 2
    stepped_back=1
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
    if [ "$gate_name" = real-phone ] && phone_gate_exempt "${heads[i]}" "${target_shas[i]}"; then continue; fi
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
    moved_id=${ids[found]} moved_branch=${branches[found]} moved_owner=${owners[found]}
    moved_head=${heads[found]} moved_base=${bases[found]} moved_priority=${priorities[found]}
    for ((i=found; i<count-1; i++)); do
      ids[i]=${ids[i+1]} branches[i]=${branches[i+1]} heads[i]=${heads[i+1]}
      states[i]=${states[i+1]} bases[i]=${bases[i+1]} receipts[i]=${receipts[i+1]}
      targets[i]=${targets[i+1]} notified[i]=${notified[i+1]} reasons[i]=${reasons[i+1]} owners[i]=${owners[i+1]}
      priorities[i]=${priorities[i+1]}
    done
    found=$((count - 1))
    ids[found]=$moved_id branches[found]=$moved_branch heads[found]=$moved_head
    states[found]=active bases[found]=$moved_base receipts[found]=- targets[found]=-
    notified[found]=- reasons[found]=- owners[found]=$moved_owner priorities[found]=$moved_priority
    assign
  elif [ "$ACTION" = gate ]; then
    die "$requeue_reason; no other car is waiting, so fix the branch, rebase and retest on a new head"
  fi
fi

# Persist queue and wake publication under the wake lock. Repeated status calls
# do not ring again for an unchanged readiness/failure event.
fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
WAKE_HELD=1
if [ "$stepped_back" -eq 1 ]; then
  for marker in "$DIR/stepback-$ID" "$DIR/stepped-$ID"; do
    [ ! -L "$marker" ] || die "step-back marker is a symlink: $marker"
  done
  ledger_lines=0
  [ ! -f "$(farm_ledger "$ID")" ] || ledger_lines=$(wc -l < "$(farm_ledger "$ID")" | tr -d ' ')
  TMP=$(mktemp "$DIR/.stepback.XXXXXX")
  printf '%s\n%s\n' "$ledger_lines" "$(date +%s)" > "$TMP"
  mv -f -- "$TMP" "$DIR/stepback-$ID"
  TMP=$(mktemp "$DIR/.stepped.XXXXXX")
  printf '%s\n' "${REASON:--}" > "$TMP"
  mv -f -- "$TMP" "$DIR/stepped-$ID"
  TMP=
fi
if [ "$waiting" -eq 1 ]; then
  marker="$DIR/requeue-$moved_id"
  [ ! -L "$marker" ] || die "requeue marker is a symlink: $marker"
  TMP=$(mktemp "$DIR/.requeue.XXXXXX")
  printf '%s\n' "$requeue_reason" > "$TMP"
  mv -f -- "$TMP" "$marker"
  TMP=
elif [ "$farm_failed" -eq 1 ]; then
  # Nobody waits, so the car keeps the front; its owner still hears why once.
  marker="$DIR/notice-${ids[found]}"
  [ ! -L "$marker" ] || die "notice marker is a symlink: $marker"
  TMP=$(mktemp "$DIR/.notice.XXXXXX")
  printf '%s\n' "$requeue_reason" > "$TMP"
  mv -f -- "$TMP" "$marker"
  TMP=
fi
if [ "$ACTION" = resolve ]; then
  marker="$DIR/testfarm-unreachable"
  [ ! -L "$marker" ] || die "test farm marker is a symlink: $marker"
  if [ "$farm_unreachable" -eq 1 ]; then
    episode="$farm_id $farm_head $farm_target"
    farm_wake=repeat
    if [ ! -f "$marker" ] || [ "$(cat -- "$marker")" != "$episode" ]; then
      fm_wake_append_locked check "landing-queue-$KEY" \
        "check: landing-queue testfarm-unreachable task=$farm_id project=$PRIMARY landing=$LANDING tip=$TIP head=$farm_head receipt=- reason=$FARM_ERROR"
      TMP=$(mktemp "$DIR/.farm-unreachable.XXXXXX")
      printf '%s\n' "$episode" > "$TMP"
      mv -f -- "$TMP" "$marker"
      TMP=
      farm_wake=new
    fi
    farm_line="front-check unreachable task=$farm_id head=$farm_head target=$farm_target wake=$farm_wake reason=$FARM_ERROR"
  else
    rm -f -- "$marker"
  fi
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
  [ -f "$STATE/${owners[i]}.meta" ] || continue
  requeue_message_reason=$(cat -- "$marker")
  if ! send_error=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 "$SCRIPT_DIR/fm-send.sh" "${owners[i]}" \
    "Landing queue: task=${ids[i]} moved to back because $requeue_message_reason. Fix your branch while waiting; run landing_queue status when you reach front, then rebase and retest." 2>&1 >/dev/null); then
    printf 'warning: could not steer %s after requeue; the next queue invocation retries: %s\n' "${ids[i]}" "$send_error" >&2
    continue
  fi
  rm -f -- "$marker"
done

for ((i=0; i<count; i++)); do
  marker="$DIR/stepped-${ids[i]}"
  [ ! -L "$marker" ] || die "step-back marker is a symlink: $marker"
  [ -f "$marker" ] || continue
  [ -f "$STATE/${owners[i]}.meta" ] || continue
  stepped_reason=$(cat -- "$marker")
  stepped_because=''
  [ "$stepped_reason" = - ] || stepped_because=" because $stepped_reason"
  if ! send_error=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 "$SCRIPT_DIR/fm-send.sh" "${owners[i]}" \
    "Landing queue: task=${ids[i]} stepped back from the front to place 2$stepped_because. It is not failed and keeps its admission evidence; it must redo its front check when it returns to the front. Run landing_queue status and continue from that status." 2>&1 >/dev/null); then
    printf 'warning: could not steer %s after its step-back; the next queue invocation retries: %s\n' "${ids[i]}" "$send_error" >&2
    continue
  fi
  rm -f -- "$marker"
done

for ((i=0; i<count; i++)); do
  marker="$DIR/notice-${ids[i]}"
  [ ! -L "$marker" ] || die "notice marker is a symlink: $marker"
  [ -f "$marker" ] || continue
  [ -f "$STATE/${owners[i]}.meta" ] || continue
  notice_reason=$(cat -- "$marker")
  if ! send_error=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 "$SCRIPT_DIR/fm-send.sh" "${owners[i]}" \
    "Landing queue: task=${ids[i]} keeps the front because $notice_reason. Run landing_queue status: it now requires a full rerun on this head; fix your branch first if needed." 2>&1 >/dev/null); then
    printf 'warning: could not steer %s after its front check failed; the next queue invocation retries: %s\n' "${ids[i]}" "$send_error" >&2
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
  if [ "$steer" -eq 1 ]; then
    [ -f "$STATE/${owners[i]}.meta" ] || continue
    if ! send_error=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_IDEMPOTENT=1 "$SCRIPT_DIR/fm-send.sh" "${owners[i]}" \
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
if [ "$ACTION" = resolve ]; then
  [ -z "$farm_line" ] || printf '%s\n' "$farm_line"
  exit 0
fi

printf 'queue=%s\ntask=%s\nbranch=%s\nhead=%s\nlanding_branch=%s\ntip=%s\nplace=%s\ntarget_ref=%s\ntarget_sha=%s\nrebase_from=%s\nstatus=%s\n' \
  "$KEY" "$ID" "${branches[found]}" "${heads[found]}" "$LANDING" "$TIP" "${places[found]}" \
  "${target_refs[found]}" "${target_shas[found]}" "${bases[found]}" "${statuses[found]}"
if [ "${receipts[found]}" = - ]; then printf 'receipt=-\n'; else printf 'receipt=%s/%s\n' "$DIR" "${receipts[found]}"; fi
printf 'reason=%s\n' "${reasons[found]}"
printf 'priority=%s\n' "${priorities[found]}"
tested_target=$(pre_target "${ids[found]}" || true)
if [ "${states[found]}" = active ] && [ "${places[found]}" -eq 1 ] \
  && git -C "$PROJECT" merge-base --is-ancestor "${target_shas[found]}" "${heads[found]}"; then
  tested_target=${target_shas[found]}
fi
if [ -n "$tested_target" ]; then
  exemption=$(exemption_reason "${heads[found]}" "$tested_target")
  printf 'gate_exemption=%s\n' "$exemption"
else
  printf 'gate_exemption=-\n'
fi
printf 'front_request=%s\n' "$(farm_last "${ids[found]}")"
