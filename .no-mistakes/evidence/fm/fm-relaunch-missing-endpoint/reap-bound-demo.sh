#!/usr/bin/env bash
# Sources wait_live + reap verbatim from tests/fm-watch-triage.test.sh and reaps
# a TERM-ignoring child and a normal child, timing each.
src=${1:?triage test path}
eval "$(sed -n '/^wait_live() {/,/^}/p' "$src")"
eval "$(sed -n '/^reap() {/,/^}/p' "$src")"
bash -c 'trap "" TERM; while :; do sleep 0.2; done' & p=$!; sleep 0.5; s=$SECONDS; reap "$p"
kill -0 "$p" 2>/dev/null && echo "TERM-ignoring child: STILL ALIVE" || echo "TERM-ignoring child reaped in $((SECONDS-s))s"
sleep 1000 & p=$!; sleep 0.5; s=$SECONDS; reap "$p"
kill -0 "$p" 2>/dev/null && echo "normal child: STILL ALIVE" || echo "normal child reaped in $((SECONDS-s))s"
