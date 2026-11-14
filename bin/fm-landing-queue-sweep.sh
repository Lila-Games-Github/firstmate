#!/usr/bin/env bash
# fm-landing-queue-sweep.sh - settle every landing train's candidate checks from the
# test farm, from the watcher poll, so no train waits on a worker's turn.
#
# Usage: fm-landing-queue-sweep.sh [--force]
#
# Runs `fm-landing-queue.sh resolve` once for each train recorded under
# data/landing-queue/<key>/queue, naming the train's own repository and landing
# branch from its snapshot. fm-landing-queue.sh's header owns what resolve does.
# bin/fm-watch.sh calls this every poll; the sweep runs at most once per
# FM_LANDING_SWEEP_SECS (default 30, valid 5..600) per home, tracked by the
# epoch recorded in state/.last-landing-sweep, so a candidate check settles within about
# 30 seconds plus one poll of its farm result. --force skips that cadence.
# Each train is bounded by FM_LANDING_SWEEP_BOUND (default 60, valid 1..120)
# seconds; a train that times out or errors is skipped until the next sweep.
#
# In sequential mode, prints a passed front check or the first unreadable farm
# report; in speculative mode, resolve appends its readiness, failure, and farm
# outage wakes directly and prints nothing. Failed sequential checks already
# moved their car and messaged its owner, and repeat unreachable reports are
# already queued, so both stay silent here. The watcher turns any output into
# one `check: landing-queue` wake. Exits nonzero, with one error line on
# stderr, only when the sweep itself cannot run (bad usage, or an unwritable
# cadence stamp); a single train's failure is skipped, never an exit status.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
  ''|--force) ;;
  *) echo "error: unknown option $1" >&2; exit 2 ;;
esac
[ -n "${FM_HOME:-}" ] || { echo 'error: FM_HOME must explicitly select the owning home' >&2; exit 2; }
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
SECS=${FM_LANDING_SWEEP_SECS:-30}
BOUND=${FM_LANDING_SWEEP_BOUND:-60}
case "$SECS" in ''|*[!0-9]*) SECS=30 ;; esac
[ "$SECS" -ge 5 ] && [ "$SECS" -le 600 ] || SECS=30
case "$BOUND" in ''|*[!0-9]*) BOUND=60 ;; esac
[ "$BOUND" -ge 1 ] && [ "$BOUND" -le 120 ] || BOUND=60

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

[ -d "$DATA/landing-queue" ] && [ ! -L "$DATA/landing-queue" ] || exit 0
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0
STAMP="$STATE/.last-landing-sweep"
now=$(date +%s)
if [ "${1:-}" != --force ] && [ -f "$STAMP" ] && [ ! -L "$STAMP" ]; then
  last=$(head -n 1 "$STAMP" 2>/dev/null || true)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  # A stamp from the future (clock step back) counts as due rather than wedging.
  [ "$last" -gt "$now" ] || [ $((now - last)) -ge "$SECS" ] || exit 0
fi
if [ -L "$STAMP" ] || ! printf '%s\n' "$now" 2>/dev/null > "$STAMP"; then
  echo "error: cannot record the sweep stamp $STAMP" >&2
  exit 1
fi

for file in "$DATA"/landing-queue/*/queue; do
  [ -f "$file" ] && [ ! -L "$file" ] || continue
  schema='' repository='' landing=''
  { IFS= read -r schema; IFS= read -r repository; IFS= read -r landing; } < "$file" || true
  [ "$schema" = fm-landing-queue.v1 ] && [ -d "$repository" ] && [ -n "$landing" ] || continue
  out=$(fm_run_timed "$BOUND" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-landing-queue.sh" resolve landing-sweep \
    --project "$repository" --landing-branch "$landing" 2>/dev/null </dev/null) || continue
  while IFS= read -r line; do
    case "$line" in
      'front-check passed '*|'front-check unreachable '*' wake=new '*) printf '%s\n' "$line" ;;
    esac
  done <<EOF
$out
EOF
done
exit 0
