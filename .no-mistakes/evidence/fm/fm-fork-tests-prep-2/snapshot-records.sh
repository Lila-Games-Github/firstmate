#!/usr/bin/env bash
# Poll the live fm-playbot-lanes fixture state dir and keep the first on-disk
# copy of each fork-only teardown task record, exactly as the product's
# teardown / lane-publication code sees it.
set -u
watch_root=$1
out=$2
deadline=$3
mkdir -p "$out"
ids="fm-autoarm-retired-remote fm-autoarm-retired-remote-pr fm-autoarm-retired-remote-receipt fm-autoarm-retired-local-pr fm-autoarm-partial-remote"
while [ "$(date +%s)" -lt "$deadline" ]; do
  for state in "$watch_root"/fm-playbot-lanes.*/fixture/fmhome/state; do
    [ -d "$state" ] || continue
    for id in $ids; do
      [ -f "$state/$id.meta" ] || continue
      [ -f "$out/$id.meta" ] && continue
      cp "$state/$id.meta" "$out/$id.meta" 2>/dev/null || true
    done
  done
  sleep 0.02
done
