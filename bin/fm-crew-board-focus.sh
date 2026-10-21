#!/usr/bin/env bash
# Focus the exact recorded pane for a worker selected in the crew board.
# Usage: fm-crew-board-focus.sh <task-id>
# Prints a one-line result for the board footer. A board outside the selected
# runtime gets an exact attach command instead of changing a detached client.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

id=${1:-}
case "$id" in ''|*[!A-Za-z0-9._-]*) echo 'Select a recorded worker first' >&2; exit 1 ;; esac
meta="$STATE/$id.meta"
fm_backend_validate_task_endpoint "$meta" "$id" || exit 1
[ -z "$(fm_meta_get "$meta" remote_host)" ] || {
  echo "Worker $id is on a remote host; open its pane there" >&2
  exit 1
}
backend=$FM_BACKEND_VALIDATED_BACKEND
target=$FM_BACKEND_VALIDATED_TARGET

case "$backend" in
  tmux)
    session=${target%%:*}
    window=${target#*:}
    if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
      printf 'Open the worker pane with: tmux attach-session -t %q\n' "=$session:=$window"
      exit 0
    fi
    fm_backend_source tmux
    current=$(tmux display-message -p '#S') || exit 1
    if [ "$current" != "$session" ]; then
      tmux switch-client -t "=$session" || exit 1
    fi
    tmux select-window -t "=$session:=$window"
    printf 'Focused worker %s in tmux\n' "$id"
    ;;
  herdr)
    session=$(fm_backend_meta_exact_value "$meta" herdr_session)
    tab=$(fm_backend_meta_exact_value "$meta" herdr_tab_id)
    pane=$(fm_backend_meta_exact_value "$meta" herdr_pane_id)
    if [ "${HERDR_ENV:-}" != 1 ] || [ -n "${TMUX:-}" ] || [ "${HERDR_SESSION:-default}" != "$session" ]; then
      printf 'Open the worker pane with: herdr session attach %q\n' "$session"
      exit 0
    fi
    fm_backend_source herdr
    info=$(fm_backend_herdr_cli "$session" pane get "$pane") || exit 1
    printf '%s' "$info" | jq -e --arg pane "$pane" --arg tab "$tab" --arg workspace "$(fm_backend_meta_exact_value "$meta" herdr_workspace_id)" \
      '.result.pane.pane_id == $pane and .result.pane.tab_id == $tab and .result.pane.workspace_id == $workspace' >/dev/null \
      || { echo "Worker $id pane no longer matches its recorded tab and workspace" >&2; exit 1; }
    fm_backend_herdr_cli "$session" tab focus "$tab" >/dev/null
    printf 'Focused worker %s in Herdr\n' "$id"
    ;;
  *)
    printf 'Jump is unavailable for the recorded %s backend\n' "$backend" >&2
    exit 1
    ;;
esac
