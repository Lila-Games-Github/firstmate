#!/usr/bin/env bash
# Runs the in-tree incarnation reader, bin/fm-pr-lib.sh::fm_task_spawn_gen_capture,
# over the six fork-only teardown task records, before and after this change.
#
# That function IS the acceptance predicate the upstream teardown gate is
# described as using: 0 spawn_gen lines -> "legacy" (no incarnation named),
# exactly 1 -> "value:<incarnation>", more than one -> non-zero exit.
set -u
ROOT=$1            # repo worktree
TARGET=$2          # dir of records captured live from the fixtures on this branch
BASE=$3            # same records with the added line removed = the base-commit shape
. "$ROOT/bin/fm-pr-lib.sh"

verdict() {
  local dir=$1 id=$2 capture rc
  capture=$(fm_task_spawn_gen_capture "$dir" "$id"); rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'capture=<error rc=%s>  post-sync teardown: REFUSE (not exactly one spawn_gen)' "$rc"
  elif [ "$capture" = legacy ]; then
    printf 'capture=legacy                                   post-sync teardown: REFUSE (record names no incarnation)'
  else
    printf 'capture=%-40s post-sync teardown: ACCEPT (incarnation unambiguous)' "$capture"
  fi
}

for id in fm-autoarm-retired-remote fm-autoarm-retired-remote-pr \
          fm-autoarm-retired-remote-receipt fm-autoarm-retired-local-pr \
          fm-autoarm-partial-remote cleanup-source; do
  printf '%s\n' "$id"
  printf '  base   592d4bc  %s\n' "$(verdict "$BASE" "$id")"
  printf '  change 0be7799  %s\n' "$(verdict "$TARGET" "$id")"
done
