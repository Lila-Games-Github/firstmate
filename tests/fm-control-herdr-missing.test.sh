#!/usr/bin/env bash
# A real Herdr lab case for relaunch after the recorded workspace disappears.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }

fail() { echo "not ok - $*" >&2; exit 1; }
SESSION=$("$HERDR_LAB_HELPER" name fm-relaunch-missing-endpoint) || exit 1
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr-missing.XXXXXX") || exit 1
cleanup() {
  local rc=$?
  trap - EXIT
  "$HERDR_LAB_HELPER" teardown "$SESSION" || rc=1
  rm -rf "$SCRATCH"
  exit "$rc"
}
trap cleanup EXIT

unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
export HERDR_SESSION=$SESSION FM_GATE_REFUSE_BYPASS=1
mkdir -p "$SCRATCH/fakebin" "$SCRATCH/home/state" "$SCRATCH/home/data/hmissing"
cat > "$SCRATCH/fakebin/codex" <<EOF
#!/usr/bin/env bash
"$HERDR_LAB_HELPER" run "$SESSION" pane report-agent "\${HERDR_PANE_ID:?}" --source fm-control-herdr-missing --agent replacement --state idle >/dev/null
: > "$SCRATCH/agent-started"
exec -a codex "$(command -v sleep)" 120
EOF
chmod +x "$SCRATCH/fakebin/codex"

# Provision the named lab server with the inert harness first in its shell PATH.
PATH="$SCRATCH/fakebin:$PATH" "$HERDR_LAB_HELPER" provision "$SESSION" \
  || fail 'could not provision isolated Herdr session'

PROJ="$SCRATCH/project"
WT="$SCRATCH/worktree"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf 'base\n' > "$PROJ/base.txt"
git -C "$PROJ" add base.txt
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b missing-case "$WT"
printf 'unfinished\n' > "$WT/unfinished.txt"
printf '%s\n' '# Task' "## Captain's intent" "Continue the work in $WT." '' \
  '## Firstmate spec' 'Preserve the recorded worktree and pending steer.' \
  > "$SCRATCH/home/data/hmissing/brief.md"
mkdir -p "$SCRATCH/home/state/hmissing.inbox/handled"
printf 'Keep this pending steer.\n' > "$SCRATCH/home/state/hmissing.inbox/001.msg"

CREATE=$("$HERDR_LAB_HELPER" run "$SESSION" workspace create --cwd "$WT" --label firstmate --no-focus) \
  || fail 'could not create the recorded workspace'
OLD_WORKSPACE=$(printf '%s' "$CREATE" | jq -r '.result.workspace.workspace_id // empty')
OLD_PANE=$(printf '%s' "$CREATE" | jq -r '.result.root_pane.pane_id // .result.tab.root_pane.pane_id // empty')
OLD_TAB=$(printf '%s' "$CREATE" | jq -r '.result.tab.tab_id // empty')
[ -n "$OLD_WORKSPACE" ] && [ -n "$OLD_TAB" ] || fail 'workspace create returned no workspace or tab id'
if [ -z "$OLD_PANE" ]; then
  OLD_PANE=$("$HERDR_LAB_HELPER" run "$SESSION" tab list --workspace "$OLD_WORKSPACE" \
    | jq -r '.result.tabs[0].root_pane.pane_id // .result.tabs[0].root_pane_id // empty')
fi
[ -n "$OLD_PANE" ] || fail 'could not resolve the recorded pane'

{
  echo "window=$SESSION:$OLD_PANE"
  echo 'endpoint_task_id=hmissing'
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo 'harness=codex'
  echo 'kind=ship'
  echo 'mode=no-mistakes'
  echo 'yolo=off'
  echo 'model=default'
  echo 'effort=default'
  echo 'backend=herdr'
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$OLD_WORKSPACE"
  echo "herdr_tab_id=$OLD_TAB"
  echo "herdr_pane_id=$OLD_PANE"
} > "$SCRATCH/home/state/hmissing.meta"

"$HERDR_LAB_HELPER" run "$SESSION" workspace close "$OLD_WORKSPACE" >/dev/null \
  || fail 'could not close the recorded workspace'
"$HERDR_LAB_HELPER" run "$SESSION" workspace list \
  | jq -e --arg id "$OLD_WORKSPACE" '[.result.workspaces[]? | select(.workspace_id == $id)] | length == 0' >/dev/null \
  || fail 'the recorded workspace still exists after close'
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
OLD_STATE=$(fm_backend_agent_state herdr "$SESSION:$OLD_PANE")
[ "$OLD_STATE" = missing ] \
  || fail "closed workspace reads '$OLD_STATE' instead of missing (pane: $("$HERDR_LAB_HELPER" run "$SESSION" pane get "$OLD_PANE"))"

OUT=$(env PATH="$SCRATCH/fakebin:$PATH" \
  FM_HOME="$SCRATCH/home" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=12 \
  "$ROOT/bin/fm-control.sh" hmissing relaunch --note 'Resume from the recorded copy and pending steer' 2>&1) \
  || fail "relaunch after workspace loss failed: $OUT"
case "$OUT" in *'relaunched hmissing'*) ;; *) fail "relaunch did not confirm the replacement: $OUT" ;; esac

NEW_WORKSPACE=$(sed -n 's/^herdr_workspace_id=//p' "$SCRATCH/home/state/hmissing.meta")
NEW_PANE=$(sed -n 's/^herdr_pane_id=//p' "$SCRATCH/home/state/hmissing.meta")
[ -n "$NEW_WORKSPACE" ] && [ "$NEW_WORKSPACE" != "$OLD_WORKSPACE" ] \
  || fail 'relaunch did not publish a new workspace id'
[ -n "$NEW_PANE" ] && [ "$NEW_PANE" != "$OLD_PANE" ] \
  || fail 'relaunch did not publish a new pane id'
[ "$(sed -n 's/^worktree=//p' "$SCRATCH/home/state/hmissing.meta")" = "$WT" ] \
  || fail 'relaunch changed the recorded worktree'
[ "$(cat "$WT/unfinished.txt")" = unfinished ] || fail 'relaunch changed unfinished work'
[ -f "$SCRATCH/home/state/hmissing.inbox/001.msg" ] || fail 'relaunch lost the pending steer'
grep -Fq 'First, check your instruction inbox' "$SCRATCH/home/data/hmissing/brief.md" \
  || fail 'the replacement brief did not point at the pending inbox'
[ -f "$SCRATCH/agent-started" ] || fail 'the inert replacement harness did not start'
"$HERDR_LAB_HELPER" run "$SESSION" workspace list \
  | jq -e --arg id "$NEW_WORKSPACE" '[.result.workspaces[]? | select(.workspace_id == $id)] | length == 1' >/dev/null \
  || fail 'the replacement workspace is absent'
echo 'ok - real Herdr: a missing workspace relaunches in a new endpoint on the same worktree'
