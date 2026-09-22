#!/usr/bin/env bash
# End-to-end reproduction of the 2026-09-21 incident, driven through the real
# Firstmate scripts of whatever tree it is pointed at.
#
#   usage: reboot-slot-reuse-demo.sh <firstmate-tree-root> <scratch-dir>
#
# The world it builds is the one the incident describes: a Treehouse pool with
# one slot, a live crewmate task record naming that slot, and a host that has
# just rebooted - so every process lease is gone and Treehouse reports the slot
# free while the task record naming it is untouched.
#
# ACT 1  a second task is spawned and Treehouse hands it that same slot
# ACT 2  session start (bin/fm-bootstrap.sh) runs on the home
# ACT 3  both records name one slot: teardown, --force, --reconcile-slot
#
# Every external tool is a stub on PATH (tmux, treehouse, gh, ...), so nothing
# outside the scratch directory is touched.
set -u

ROOT=${1:?tree root}
W=${2:?scratch dir}
ROOT=$(cd "$ROOT" && pwd -P)
rm -rf "$W"
mkdir -p "$W"
W=$(cd "$W" && pwd -P)

PIPELINE=frogpile-ui-pipeline
SCOUT=frogpile-jev-usecases-research
HOME_DIR="$W/home"
PROJ="$W/project"
SLOT="$W/pool/1/repo"
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
TASKS_AXI_BIN=${TASKS_AXI_BIN:-}
# The same bypass tests/lib.sh exports: this demo drives the real fleet scripts
# from inside a no-mistakes gate worktree, which they otherwise refuse outright.
export FM_GATE_REFUSE_BYPASS=1

banner() { printf '\n==================== %s ====================\n' "$*"; }
step()   { printf '\n--- %s\n' "$*"; }
cmd()    { printf '\n$ %s\n' "$*"; }
note()   { printf '# %s\n' "$*"; }
show()   { "$@" 2>&1 || true; }

git_q() { git -C "$1" -c user.name='Firstmate Demo' -c user.email='demo@example.invalid' "${@:2}"; }

# ---------------------------------------------------------------- the world --
banner "SETUP: a pool slot held by a live task, and then the host reboots"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$W/pool/1"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
touch "$HOME_DIR/state/.last-watcher-beat"

git init -q -b main "$PROJ"
printf '# demo project\n' > "$PROJ/README.md"
git_q "$PROJ" add README.md
git_q "$PROJ" commit -qm initial
printf 'the pipeline feature\n' > "$PROJ/pipeline-feature.txt"
git_q "$PROJ" add pipeline-feature.txt
git_q "$PROJ" commit -qm 'pipeline work (landed on main)'
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
git -C "$PROJ" fetch -q origin
# The pipeline task's branch: long landed, i.e. it adds nothing main does not
# already have - what a squash-merged task looks like afterwards. The slot is
# that branch's clean checkout, which is what the restored worker is sitting in.
git -C "$PROJ" branch "fm/$PIPELINE" main
git -C "$PROJ" worktree add -q "$SLOT" "fm/$PIPELINE"
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$W/pool/treehouse-state.json"
printf 'task=%s\nhome=%s\n' "$PIPELINE" "$HOME_DIR" > "$W/pool/1/.fm-slot-owner"

cat > "$HOME_DIR/state/$PIPELINE.meta" <<EOF
window=firstmate:fm-$PIPELINE
endpoint_task_id=$PIPELINE
worktree=$SLOT
project=$PROJ
kind=ship
EOF

note "firstmate home ....... $HOME_DIR"
note "shared project ....... $PROJ"
note "treehouse pool slot 1  $SLOT"
cmd "cat state/$PIPELINE.meta"
cat "$HOME_DIR/state/$PIPELINE.meta"
cmd "cat pool/1/.fm-slot-owner"
show cat "$W/pool/1/.fm-slot-owner"
cmd "git -C <slot> status -sb"
show git -C "$SLOT" status -sb
note "09:00 - the host reboots. Every Treehouse lease process dies with it, so"
note "treehouse now reports slot 1 as free. The task record above is untouched,"
note "and Herdr has restored the pipeline worker's pane in that same copy."

SLOT_HEAD_BEFORE=$(git -C "$SLOT" rev-parse HEAD)

# ------------------------------------------------------- ACT 1: fm-spawn.sh --
banner "ACT 1: spawning $SCOUT - treehouse hands it slot 1"

mkdir -p "$HOME_DIR/data/$SCOUT" "$W/spawn-fakebin"
cat > "$HOME_DIR/data/$SCOUT/brief.md" <<'EOF'
# Task
## Captain's intent
Research the jev use cases.

## Firstmate spec
Work in the slot treehouse hands out.
EOF

cat > "$W/spawn-fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
cat > "$W/spawn-fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$W/spawn-fakebin/tmux" "$W/spawn-fakebin/treehouse"

cmd "bin/fm-spawn.sh $SCOUT $PROJ --mode no-mistakes --yolo off"
set +e
FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$SLOT" \
  PATH="$W/spawn-fakebin:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$SCOUT" "$PROJ" --mode no-mistakes --yolo off 2>&1
printf 'exit=%s\n' "$?"
set -e

step "what happened to the slot the live record still names"
cmd "cat pool/1/.fm-slot-owner   # whose claim is on the slot now"
show cat "$W/pool/1/.fm-slot-owner"
cmd "git -C <slot> status -sb   # is the pipeline's branch still checked out"
show git -C "$SLOT" status -sb
cmd "git -C <slot> rev-parse HEAD   # before: $SLOT_HEAD_BEFORE"
show git -C "$SLOT" rev-parse HEAD
cmd "ls state/   # did the refused spawn publish a record"
show ls "$HOME_DIR/state"

# --------------------------------------------------- ACT 2: fm-bootstrap.sh --
banner "ACT 2: session start on that home (bin/fm-bootstrap.sh)"

mkdir -p "$W/boot-fakebin"
for t in tmux node chrome-devtools-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/boot-fakebin/$t"
done
cat > "$W/boot-fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
for t in gh-axi quota-axi; do
  cat > "$W/boot-fakebin/$t" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { printf '0.1.29\n'; exit 0; }
exit 0
SH
done
cat > "$W/boot-fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { printf '0.1.46\n'; exit 0; }
exit 0
SH
cat > "$W/boot-fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { printf 'no-mistakes version v1.46.0 (fake) 2026-06-27T00:02:18Z\n'; exit 0; }
exit 0
SH
cat > "$W/boot-fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { printf '0.2.5\n'; exit 0; }
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf 'usage: tasks-axi update <id> [flags]\n  --body-file <path>\n  --archive-body\n'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>\n'
  exit 0
fi
exit 0
SH
# The post-reboot treehouse: slot 1 is reported free, because the lease process
# that held it died with the host.
cat > "$W/boot-fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = get ] && [ "\${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  exit 0
fi
if [ "\${1:-}" = status ] && [ "\${2:-}" = --json ]; then
  printf '[{"name":"1","path":"%s","status":"%s","lease_id":"","lease_holder":"%s","leased_at":null,"processes":[]}]\n' \
    '$SLOT' "\${FM_DEMO_SLOT_STATUS:-available}" "\${FM_DEMO_SLOT_LEASE_HOLDER:-}"
  exit 0
fi
exit 0
SH
chmod +x "$W"/boot-fakebin/*

cmd "treehouse status --json   # what treehouse thinks of the pool after the reboot"
PATH="$W/boot-fakebin:$BASE_PATH" treehouse status --json

cmd "bin/fm-bootstrap.sh"
set +e
env PATH="$W/boot-fakebin:$BASE_PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
  "$ROOT/bin/fm-bootstrap.sh" 2>&1
printf 'exit=%s\n' "$?"
set -e

step "the same session start once treehouse reports the slot in use again (healthy)"
cmd "bin/fm-bootstrap.sh   # FM_DEMO_SLOT_STATUS=in-use"
set +e
env PATH="$W/boot-fakebin:$BASE_PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
  FM_DEMO_SLOT_STATUS=in-use "$ROOT/bin/fm-bootstrap.sh" 2>&1
printf 'exit=%s\n' "$?"
set -e

step "and when a refused seed left a durable lease stranded on that copy"
cmd "bin/fm-bootstrap.sh   # treehouse: status=leased, lease_holder=refused-seed"
set +e
env PATH="$W/boot-fakebin:$BASE_PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
  FM_DEMO_SLOT_STATUS=leased FM_DEMO_SLOT_LEASE_HOLDER=refused-seed \
  "$ROOT/bin/fm-bootstrap.sh" 2>&1
printf 'exit=%s\n' "$?"
set -e

# ------------------------------------------------- ACT 3: the stuck records --
banner "ACT 3: the deadlock that was left behind - two records, one slot"

note "This is the state the incident actually reached: the spawn took the slot,"
note "so the scout's record names it too and now holds its claim, while the"
note "pipeline's record still names the same copy. The scout has finished and"
note "its report is in the firstmate home; the pipeline task landed long ago."

note "(the spawn that took the slot re-prepared it onto a detached base, which"
note "is what replaced the pipeline branch checkout in the incident)"
git -C "$SLOT" checkout -q --detach main
cat > "$HOME_DIR/state/$SCOUT.meta" <<EOF
window=firstmate:fm-$SCOUT
endpoint_task_id=$SCOUT
worktree=$SLOT
project=$PROJ
kind=scout
EOF
printf 'task=%s\nhome=%s\n' "$SCOUT" "$HOME_DIR" > "$W/pool/1/.fm-slot-owner"
mkdir -p "$HOME_DIR/data/$SCOUT"
printf '# Findings\n\nthe scout report, safely in the firstmate home\n' > "$HOME_DIR/data/$SCOUT/report.md"

mkdir -p "$W/teardown-fakebin"
for t in tmux treehouse; do
  cat > "$W/teardown-fakebin/$t" <<SH
#!/usr/bin/env bash
printf '$t' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$W/teardown-fakebin/$t"
done
: > "$W/runtime.log"

run_teardown() {
  set +e
  env PATH="$W/teardown-fakebin:${TASKS_AXI_BIN:+$TASKS_AXI_BIN:}$PATH" \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$W/runtime.log" \
    "$ROOT/bin/fm-teardown.sh" "$@" 2>&1
  printf 'exit=%s\n' "$?"
  set -e
}

step "1. the ordinary command, on the long-landed pipeline record"
cmd "bin/fm-teardown.sh $PIPELINE"
run_teardown "$PIPELINE"

step "2. the same thing from the other side, on the finished scout"
cmd "bin/fm-teardown.sh $SCOUT"
run_teardown "$SCOUT"

step "3. --force, which is what an operator reaches for next"
cmd "bin/fm-teardown.sh $PIPELINE --force"
run_teardown "$PIPELINE" --force

step "4. the sanctioned way out"
cmd "bin/fm-teardown.sh $PIPELINE --reconcile-slot"
run_teardown "$PIPELINE" --reconcile-slot

step "what the reconciliation touched"
cmd "ls state/"
ls "$HOME_DIR/state"
cmd "cat pool/1/.fm-slot-owner"
cat "$W/pool/1/.fm-slot-owner"
cmd "ls <slot>"
ls "$SLOT"
cmd "git -C $PROJ branch --list 'fm/*'   # the landed branch is still there"
git -C "$PROJ" branch --list 'fm/*'
cmd "cat runtime.log   # no treehouse call at all: the slot was never returned here"
cat "$W/runtime.log"

step "5. the survivor now tears down normally and returns the slot"
if [ -n "$TASKS_AXI_BIN" ]; then
  cmd "bin/fm-captain-hold.sh complete $SCOUT --none"
  set +e
  env PATH="$TASKS_AXI_BIN:$W/teardown-fakebin:$PATH" FM_HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$SCOUT" --none 2>&1
  printf 'exit=%s\n' "$?"
  set -e
else
  note "tasks-axi not provided (TASKS_AXI_BIN unset); the scout's captain-call"
  note "inventory cannot be recorded, so step 5 is skipped."
fi
: > "$W/runtime.log"
cmd "bin/fm-teardown.sh $SCOUT"
run_teardown "$SCOUT"
cmd "ls state/"
ls "$HOME_DIR/state"
cmd "cat runtime.log"
cat "$W/runtime.log"

banner "END"

# ------------------------------------------- ACT 4: relaunch into that copy --
banner "ACT 4: bin/fm-control.sh <id> relaunch, into a copy another record owns"

note "The other way into the same deadlock: the captain relaunches the agent of"
note "a task whose record still names a slot a different live record now owns."
note "Relaunch stops the running agent first, so the refusal has to come before"
note "that - otherwise the worker is dead and cannot be brought back."

C="$W/control"
C_HOME="$C/home"
C_SLOT="$C/pool/1/repo"
mkdir -p "$C_HOME/state" "$C_HOME/data/rl-pipeline" "$C/fake" "$C/fakebin" \
  "$C/pool/1" "$C/user-home"
git init -q -b main "$C/proj"
printf '# control demo\n' > "$C/proj/README.md"
git_q "$C/proj" add README.md
git_q "$C/proj" commit -qm initial
git clone --quiet --bare "$C/proj" "$C/proj.origin.git"
git -C "$C/proj" remote add origin "file://$C/proj.origin.git"
git -C "$C/proj" worktree add -q --detach "$C_SLOT"
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$C_SLOT" > "$C/pool/treehouse-state.json"

# The modelled session provider: `command` is what the pane is running, so
# "claude" means the agent is alive and "zsh" means it was stopped.
cat > "$C/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
cat > "$C/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$C/fakebin/tmux" "$C/fakebin/sleep"
: > "$C/fake/literal"
: > "$C/fake/keys"
printf 'claude' > "$C/fake/command"
printf 'claude' > "$C/fake/becomes"
printf 'fm-rl-pipeline\n' > "$C/fake/windows"
printf '%s' "$C_SLOT" > "$C/fake/cwd"
cat > "$C_HOME/data/rl-pipeline/brief.md" <<'EOF'
# Task
## Captain's intent
Keep the pipeline moving.

## Firstmate spec
Replace the agent process, never the task.
EOF
{
  echo "window=fmses:fm-rl-pipeline"
  echo "endpoint_task_id=rl-pipeline"
  echo "worktree=$C_SLOT"
  echo "project=$C/proj"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "tasktmp=$C/tasktmp"
  echo "model=default"
  echo "effort=default"
} > "$C_HOME/state/rl-pipeline.meta"
{
  echo "window=fmses:fm-rl-scout"
  echo "endpoint_task_id=rl-scout"
  echo "worktree=$C_SLOT"
  echo "project=$C/proj"
  echo "kind=ship"
} > "$C_HOME/state/rl-scout.meta"

run_control() {
  set +e
  env PATH="$C/fakebin:$PATH" FM_HOME="$C_HOME" FM_FAKE_DIR="$C/fake" \
    HOME="$C/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
  printf 'exit=%s\n' "$?"
  set -e
}

cmd "cat state/rl-pipeline.meta | grep worktree; cat state/rl-scout.meta | grep worktree"
show grep '^worktree=' "$C_HOME/state/rl-pipeline.meta"
show grep '^worktree=' "$C_HOME/state/rl-scout.meta"
cmd "tmux display-message -p '#{pane_current_command}'   # the running agent"
show cat "$C/fake/command"; printf '\n'

cmd "bin/fm-control.sh rl-pipeline relaunch --note 'carry this forward'"
run_control rl-pipeline relaunch --note 'carry this forward'

step "what the refusal left behind"
cmd "tmux display-message -p '#{pane_current_command}'   # is the agent still running"
show cat "$C/fake/command"; printf '\n'
cmd "cat fake/literal   # anything typed into the pane at all"
show cat "$C/fake/literal"
cmd "tail -3 data/rl-pipeline/brief.md   # was the progress note appended"
show tail -3 "$C_HOME/data/rl-pipeline/brief.md"
cmd "ls state/"
show ls "$C_HOME/state"

step "once the other record is reconciled, the same relaunch goes through"
cmd "rm state/rl-scout.meta   # the captain reconciled the stale record"
rm -f "$C_HOME/state/rl-scout.meta"
cmd "bin/fm-control.sh rl-pipeline relaunch --note 'carry this forward'"
run_control rl-pipeline relaunch --note 'carry this forward'
cmd "tmux display-message -p '#{pane_current_command}'   # the replacement agent"
show cat "$C/fake/command"; printf '\n'

banner "END OF ACT 4"
