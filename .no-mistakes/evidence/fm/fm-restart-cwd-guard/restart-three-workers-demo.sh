# Demo: after a host restart, three restored workers resume in the primary
# checkout. Sourced after tests/fm-bootstrap.test.sh helpers (lines 1-2022).
demo() {
  local rec case_dir home proj wt fakebin id ids="pw-alpha pw-beta pw-gamma" n=1 out
  rec=$(make_crew_cwd_case restart-demo)
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  mkdir -p "$case_dir/panes"
  # Per-window fake tmux: each window answers its own pane root pid.
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list-windows) ls '$case_dir/panes'; exit 0 ;;
  display-message) t=''; prev=''
    for a in "\$@"; do [ "\$prev" = -t ] && t=\$a; prev=\$a; done
    cat '$case_dir/panes/'"\${t#*:}"; exit 0 ;;
esac
exit 0
SH
  # fm-control stub that really "relaunches": moves the pane to a fresh agent in the copy.
  cat > "$home/bin/fm-control.sh" <<SH
#!/usr/bin/env bash
printf 'fm-control.sh %s (FM_HOME=%s FM_SPAWN_NO_GUARD=%s)\n' "\$*" "\$FM_HOME" "\$FM_SPAWN_NO_GUARD" >> '$case_dir/control.log'
wt=\$(sed -n 's/^worktree=//p' "\$FM_HOME/state/\$1.meta")
( cd "\$wt" && exec '$case_dir/agentbin/claude' 300 ) </dev/null >/dev/null 2>&1 &
echo \$! > '$case_dir/panes/fm-'"\$1"
sleep 1
SH
  chmod +x "$home/bin/fm-control.sh"
  : > "$case_dir/control.log"
  local pids=""
  for id in $ids; do
    local w="$case_dir/pool/$n/repo"
    [ "$n" = 1 ] || git -C "$proj" worktree add -q --detach "$w"
    write_crew_cwd_meta "$home" "$id" "$w" "$proj"
    local tree root agent
    tree=$(start_crew_cwd_tree "$case_dir" "$proj" "$proj")
    read -r root agent <<EOF
$tree
EOF
    echo "$root" > "$case_dir/panes/fm-$id"
    pids="$pids $root $agent"
    n=$((n + 1))
  done
  echo "### Before: agent working directories (as firstmate had to list by hand)"
  for id in $ids; do p=$(cat "$case_dir/panes/fm-$id"); a=$(pgrep -P "$p"); printf '%s agent pid %s cwd=%s\n' "$id" "$a" "$(readlink /proc/$a/cwd)"; done
  echo; echo "### bin/fm-bootstrap.sh output (locked session)"
  out=$(env PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_SLOT_STATUS=in-use "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  printf '%s\n' "$out" | grep CREW_CWD
  echo; echo "### waiting for the detached relaunch worker"
  local t=0; while [ "$(cat "$home/state/.wake-queue" 2>/dev/null | grep -c crew-cwd)" -lt 3 ] && [ $t -lt 600 ]; do sleep 0.1; t=$((t+1)); done
  while pgrep -f "fm-crew-cwd-relaunch .*$home/bin" >/dev/null; do sleep 0.2; done
  echo; echo "### fm-control calls made by the background worker"; cat "$case_dir/control.log"
  echo; echo "### Outcome wakes queued (state/.wake-queue)"; cat "$home/state/.wake-queue"
  echo; echo "### After: agent working directories"
  for id in $ids; do a=$(cat "$case_dir/panes/fm-$id"); printf '%s agent pid %s cwd=%s\n' "$id" "$a" "$(readlink /proc/$a/cwd)"; pids="$pids $a"; done
  echo; echo "### Second session start (rerun): no further relaunch"
  : > "$case_dir/control.log"
  out=$(env PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_TREEHOUSE_SLOT_STATUS=in-use "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  printf 'CREW_CWD lines: %s\n' "$(printf '%s\n' "$out" | grep -c CREW_CWD)"
  printf 'fm-control calls: %s\n' "$(wc -l < "$case_dir/control.log")"
  kill $pids 2>/dev/null
}
demo
