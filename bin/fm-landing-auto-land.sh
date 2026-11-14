#!/usr/bin/env bash
# Settle verified speculative front cars from the watcher's poll without an agent turn.
# Usage: FM_HOME=<home> fm-landing-auto-land.sh
# The queue's status is rechecked before each guarded candidate merge. Only a
# registered local-only +yolo project qualifies. ProjectWhite/prototype-game's
# existing published landing path is pushed fast-forward after a local landing;
# other local-only projects stay local. A pending push record survives a failed
# publication and is retried without repeating the merge.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
FM_HOME=${FM_HOME:?select the owning FM_HOME explicitly}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
[ -d "$DATA/landing-queue" ] && [ ! -L "$DATA/landing-queue" ] || exit 0

field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
fail() { echo "error: auto-land: $*" >&2; exit 1; }

for queue in "$DATA"/landing-queue/*/queue; do
  [ -f "$queue" ] && [ ! -L "$queue" ] || continue
  dir=${queue%/queue}
  schema='' common='' landing=''
  { IFS= read -r schema; IFS= read -r common; IFS= read -r landing; } < "$queue" || true
  [ "$schema" = fm-landing-queue.v1 ] && [ -d "$common" ] && [ -n "$landing" ] || continue
  primary=$(git -C "$common" worktree list --porcelain | sed -n '1s/^worktree //p') || continue
  [ -n "$primary" ] && [ -d "$primary" ] || continue
  primary=$(cd "$primary" && pwd -P) || continue
  git -C "$primary" check-ref-format "refs/heads/$landing" >/dev/null 2>&1 \
    || fail "invalid landing branch in $queue"
  name=${primary##*/}
  registered=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$name" 2>/dev/null) || continue
  [ "$registered" = 'local-only on' ] || continue
  registered_path=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" --path "$name" 2>/dev/null) || continue
  [ "$registered_path" = "$primary" ] || continue

  publish=0
  case "$name" in ProjectWhite|prototype-game) publish=1 ;; esac
  for pending in "$dir"/pending-push-*; do
    [ -e "$pending" ] || continue
    [ -f "$pending" ] && [ ! -L "$pending" ] || fail "invalid pending push record $pending"
    pending_sha=$(sed -n 's/^sha=//p' "$pending")
    pending_landing=$(sed -n 's/^landing=//p' "$pending")
    [ "$publish" -eq 1 ] && [ "$pending_landing" = "$landing" ] \
      && [[ "$pending_sha" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] \
      || fail "invalid pending push record $pending"
    current=$(git -C "$primary" rev-parse "refs/heads/$landing^{commit}") || fail "landing branch $landing disappeared"
    [ "$current" = "$pending_sha" ] || fail "landing tip moved before publication of $pending_sha"
    fm_run_timed 60 env GIT_TERMINAL_PROMPT=0 git -C "$primary" push origin "$pending_sha:refs/heads/$landing" \
      || fail "push of $landing at $pending_sha failed"
    rm -f -- "$pending"
  done

  # A merge reconciles the queue and can expose another already-tested car.
  while :; do
    front=$(awk -F '\t' 'NR > 3 && $4 == "active" { print $1; exit }' "$queue")
    [ -n "$front" ] || break
    display=$(awk -F '\t' 'NR > 3 && $1 == id { print $13; exit }' id="$front" "$queue")
    [ "$display" = ready-to-land ] || break
    status=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-landing-queue.sh" status "$front" --project "$primary" --landing-branch "$landing") \
      || fail "cannot recheck $front"
    [ "$(field "$status" status)" = ready-to-land ] || break
    candidate=$(field "$status" candidate_sha)
    receipt=$(field "$status" receipt)
    [ -n "$candidate" ] && [ "$candidate" != - ] && [ -f "$receipt" ] \
      || break
    pending="$dir/pending-push-$front"
    if [ "$publish" -eq 1 ]; then
      [ ! -e "$pending" ] || fail "pending push already exists for $front"
      tmp=$(mktemp "$dir/.pending-push.XXXXXX") || fail 'cannot stage pending push'
      printf 'sha=%s\nlanding=%s\n' "$candidate" "$landing" > "$tmp"
      mv -f -- "$tmp" "$pending"
    fi
    if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-merge-local.sh" "$front" --receipt "$receipt" --candidate "$candidate"; then
      current=$(git -C "$primary" rev-parse "refs/heads/$landing^{commit}") || fail "landing branch $landing disappeared"
      if [ "$current" != "$candidate" ]; then
        [ "$publish" -eq 0 ] || rm -f -- "$pending"
      fi
      fail "guarded candidate merge refused $front at $candidate"
    fi
    if [ "$publish" -eq 1 ]; then
      fm_run_timed 60 env GIT_TERMINAL_PROMPT=0 git -C "$primary" push origin "$candidate:refs/heads/$landing" \
        || fail "push of $landing at $candidate failed"
      rm -f -- "$pending"
    fi
  done
done
