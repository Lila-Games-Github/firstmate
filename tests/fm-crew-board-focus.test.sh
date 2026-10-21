#!/usr/bin/env bash
# The board jump uses recorded endpoint identity and gives attach hints outside a client.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-crew-board-focus)
mkdir -p "$tmp/home/state" "$tmp/bin"
focus="$ROOT/bin/fm-crew-board-focus.sh"

cat > "$tmp/home/state/alpha.meta" <<'EOF'
window=ship:fm-alpha
project=/projects/example
worktree=/worktrees/alpha
EOF
cat > "$tmp/home/state/beta.meta" <<'EOF'
backend=herdr
endpoint_task_id=beta
window=lab:w1:p2
herdr_session=lab
herdr_workspace_id=w1
herdr_tab_id=w1:t2
herdr_pane_id=w1:p2
project=/projects/example
worktree=/worktrees/beta
EOF

run_focus() { FM_HOME="$tmp/home" FM_STATE_OVERRIDE="$tmp/home/state" PATH="$tmp/bin:$PATH" "$focus" "$1"; }

out=$(env -u TMUX -u TMUX_PANE FM_HOME="$tmp/home" FM_STATE_OVERRIDE="$tmp/home/state" "$focus" alpha) \
  || fail 'tmux hint failed'
assert_equals 'Open the worker pane with: tmux attach-session -t =ship:=fm-alpha' "$out" 'tmux attach hint'
out=$(env -u HERDR_ENV -u TMUX FM_HOME="$tmp/home" FM_STATE_OVERRIDE="$tmp/home/state" "$focus" beta) \
  || fail 'Herdr hint failed'
assert_equals 'Open the worker pane with: herdr session attach lab' "$out" 'Herdr attach hint'

cat > "$tmp/bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_CALLS"
case "$1" in
  display-message) printf 'other\n' ;;
esac
EOF
chmod +x "$tmp/bin/tmux"
out=$(TMUX_CALLS="$tmp/calls" TMUX=inside TMUX_PANE=%1 run_focus alpha) || fail 'tmux jump failed'
assert_equals 'Focused worker alpha in tmux' "$out" 'tmux focus result'
assert_contains "$(cat "$tmp/calls")" 'switch-client -t =ship' 'switch to recorded session'
assert_contains "$(cat "$tmp/calls")" 'select-window -t =ship:=fm-alpha' 'focus recorded window'

printf 'window=other:fm-alpha\n' >> "$tmp/home/state/alpha.meta"
if TMUX_CALLS="$tmp/calls" TMUX=inside TMUX_PANE=%1 run_focus alpha >/dev/null 2>&1; then
  fail 'ambiguous endpoint was accepted'
fi
assert_equals 3 "$(wc -l < "$tmp/calls" | tr -d ' ')" 'ambiguous endpoint touched tmux'
pass 'board jump resolves exact metadata and hints when outside the runtime'
