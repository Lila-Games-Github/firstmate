#!/usr/bin/env bash
# Real-tmux demo: worker's window vanishes (server restart), then fm-control relaunch resumes it.
set -u
ROOT=$1
S=$(mktemp -d /tmp/fm-demo.XXXXXX)
export TMUX_TMPDIR=$S/tmuxsock; mkdir -p $TMUX_TMPDIR; unset TMUX TMUX_PANE
trap 'tmux kill-server 2>/dev/null; rm -rf "$S"' EXIT
mkdir -p $S/fakebin $S/home/state $S/home/data/demo1 $S/user-home
cat > $S/fakebin/codex <<EOF
#!/usr/bin/env bash
echo "replacement agent started in \$PWD" > "$S/agent-started"
exec -a codex sleep 300
EOF
chmod +x $S/fakebin/codex
P=$S/project; WT=$S/worktree
git init -q $P; echo base > $P/base.txt; git -C $P add .; git -C $P -c user.name=t -c user.email=t@x commit -qm init
git -C $P worktree add -q -b task-demo1 $WT
echo committed > $WT/done.txt; git -C $WT add .; git -C $WT -c user.name=t -c user.email=t@x commit -qm "worker progress"
echo unfinished > $WT/unfinished.txt
printf '# Task\n## Captain'"'"'s intent\nContinue the work.\n\n## Firstmate spec\nKeep going.\n' > $S/home/data/demo1/brief.md
mkdir -p $S/home/state/demo1.inbox/handled; echo 'Pending steer from captain.' > $S/home/state/demo1.inbox/001.msg
cat > $S/home/state/demo1.meta <<EOF
window=fmses:fm-demo1
endpoint_task_id=demo1
worktree=$WT
project=$P
harness=codex
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
EOF
tmux new-session -d -s fmses -c $WT
tmux new-window -d -t fmses -n fm-demo1 -c $WT "PATH=$S/fakebin:\$PATH codex"
sleep 0.5
echo "### before restart: tmux windows"; tmux list-windows -t fmses -F '#W'
echo "### worker HEAD: $(git -C $WT log --oneline -1)  status: $(git -C $WT status --porcelain | tr '\n' ' ')"
echo "### simulating terminal-server restart (tmux kill-server)"; tmux kill-server; sleep 0.3
tmux list-windows -t fmses 2>&1 | sed 's/^/    /'
echo "### \$ fm-control.sh demo1 relaunch --note 'Resume after server restart'"
env PATH="$S/fakebin:$PATH" FM_HOME=$S/home HOME=$S/user-home FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
  FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=15 \
  "$ROOT/bin/fm-control.sh" demo1 relaunch --note 'Resume after server restart' 2>&1; echo "exit=$?"
sleep 0.5
echo "### after relaunch: tmux windows (pane cwd, command)"; tmux list-windows -t fmses -F '#W  #{pane_current_path}  #{pane_current_command}' 2>&1
echo "### $(cat $S/agent-started 2>/dev/null || echo 'agent NOT started')"
echo "### meta: $(grep -E '^(window|worktree|harness)=' $S/home/state/demo1.meta | tr '\n' ' ')"
echo "### worktrees for project:"; git -C $P worktree list
echo "### worker HEAD: $(git -C $WT log --oneline -1)  status: $(git -C $WT status --porcelain | tr '\n' ' ')"
echo "### inbox: $(ls $S/home/state/demo1.inbox)  -> $(cat $S/home/state/demo1.inbox/001.msg 2>/dev/null)"
echo "### brief tail:"; tail -n 12 $S/home/data/demo1/brief.md
