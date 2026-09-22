#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
#
# A settled, isolated worktree is still not necessarily an UNOWNED one. A
# Treehouse pool slot is held by a live process lease, so a host restart frees
# every slot while the task records naming them survive; Treehouse then hands a
# live task's slot to the next spawn, which prepares it and replaces that task's
# checkout (observed 2026-09-21). The last cases below drive that shape: a pool
# slot another live record already names must refuse before anything is claimed
# or prepared, while a slot no record names still launches.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 2 ] || fail "already-settled pane took $reads reads to confirm - expected the first read plus one confirmation"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}


# --- pool-slot ownership ----------------------------------------------------

# make_pool_settle_case <name> <id>: the settle fixture with its worktree laid
# out as a real Treehouse pool slot - the fixed <pool>/<slot>/<repo> shape plus
# the pool's own state file, which is what bin/fm-slot-record-lib.sh requires
# before it will treat a worktree as a slot at all. Without that layout the
# ownership guard correctly does not apply, so an ordinary linked worktree
# cannot stand in for this case.
make_pool_settle_case() {
  local name=$1 id=$2 case_dir home proj pool wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  pool="$case_dir/pool"
  wt="$pool/1/repo"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$pool/1"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$proj.origin.git"
  git -C "$proj" worktree add --quiet --detach "$wt"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$wt" > "$pool/treehouse-state.json"
  fm_test_spawn_brief "$home" "$id" "Exercise pool-slot ownership for $id."
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$case_dir/unused-stale|$fakebin|$countfile|0"
}

# A slot a live task record still names refuses before the claim is written and
# before the base is freshened - the two steps that would take the slot from its
# owner and replace its copy.
test_pool_slot_owned_by_a_live_record_refuses() {
  local rec id owner out status claim head_before
  id='pool-owned-slot-z5'
  owner=live-pipeline-task
  rec=$(make_pool_settle_case pool-owned "$id")
  read_settle_record "$rec"
  fm_write_meta "$HOME_DIR/state/$owner.meta" \
    "window=firstmate:fm-$owner" "endpoint_task_id=$owner" \
    "worktree=$WT_DIR" "project=$PROJ_DIR" "kind=ship"
  printf 'task=%s\nhome=%s\n' "$owner" "$HOME_DIR" > "$(dirname "$WT_DIR")/.fm-slot-owner"
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn prepared a pool slot a live task record still owns"$'\n'"$out"
  assert_contains "$out" "$owner" \
    "the refusal did not name the task that still records the slot"
  assert_contains "$out" "$WT_DIR" \
    "the refusal did not name the slot it declined to prepare"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn published task metadata"
  assert_present "$HOME_DIR/state/$owner.meta" \
    "the refused spawn removed the owning task's record"
  claim=$(cat "$(dirname "$WT_DIR")/.fm-slot-owner")
  assert_contains "$claim" "task=$owner" \
    "the refused spawn overwrote the owning task's slot claim"
  [ "$(git -C "$WT_DIR" rev-parse HEAD)" = "$head_before" ] \
    || fail "the refused spawn re-prepared the slot it declined to take"
  pass "fm-spawn: a pool slot a live task record still names refuses before it is claimed or prepared"
}

# The same collision recorded on a secondmate home= line is the same slot, and
# a record in a locally registered secondmate home is just as reachable as one
# in this home - the pool is shared across both.
test_pool_slot_owned_across_record_shapes_refuses() {
  local rec id owner out status second_home case_dir
  for owner in home-field-owner cross-home-owner; do
    id="pool-owned-$owner-z6"
    rec=$(make_pool_settle_case "pool-owned-$owner" "$id")
    read_settle_record "$rec"
    if [ "$owner" = home-field-owner ]; then
      fm_write_meta "$HOME_DIR/state/$owner.meta" \
        "window=firstmate:fm-$owner" "endpoint_task_id=$owner" \
        "worktree=$WT_DIR" "home=$WT_DIR" "project=$PROJ_DIR" "kind=secondmate"
    else
      case_dir=$(dirname "$(dirname "$(dirname "$WT_DIR")")")
      second_home="$case_dir/secondmate-home"
      mkdir -p "$second_home/state" "$second_home/data"
      printf '%s\n' "- mate - fixture (home: $second_home; scope: test; projects: project; added 2026-01-01)" \
        > "$HOME_DIR/data/secondmates.md"
      fm_write_meta "$second_home/state/$owner.meta" \
        "window=firstmate:fm-$owner" "endpoint_task_id=$owner" \
        "worktree=$WT_DIR" "project=$PROJ_DIR" "kind=scout"
    fi

    out=$(run_settle_spawn "$id")
    status=$?
    [ "$status" -ne 0 ] \
      || fail "spawn prepared a slot recorded by $owner"$'\n'"$out"
    assert_contains "$out" "$owner" \
      "the refusal did not name $owner as the record still holding the slot"
    assert_absent "$HOME_DIR/state/$id.meta" \
      "the spawn refused for $owner still published task metadata"
  done
  pass "fm-spawn: a slot recorded as a secondmate home, or by another local home, refuses the same way"
}

# The guard must not turn every pooled spawn into a refusal: a slot no record
# names still launches, and a neighbouring record on its OWN slot is not a
# collision.
test_unowned_pool_slot_still_launches() {
  local rec id out status case_dir
  id='pool-unowned-slot-z7'
  rec=$(make_pool_settle_case pool-unowned "$id")
  read_settle_record "$rec"
  case_dir=$(dirname "$(dirname "$(dirname "$WT_DIR")")")
  mkdir -p "$case_dir/other-slot"
  fm_write_meta "$HOME_DIR/state/neighbour.meta" \
    "window=firstmate:fm-neighbour" "endpoint_task_id=neighbour" \
    "worktree=$case_dir/other-slot" "project=$PROJ_DIR" "kind=ship"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "an unowned pool slot should still launch"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "the launched spawn did not record the pool slot it took"
  assert_grep "task=$id" "$(dirname "$WT_DIR")/.fm-slot-owner" \
    "the launched spawn did not claim the slot it took"
  pass "fm-spawn: a pool slot no live record names still launches and is claimed"
}

test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_pool_slot_owned_by_a_live_record_refuses
test_pool_slot_owned_across_record_shapes_refuses
test_unowned_pool_slot_still_launches

echo "# all fm-spawn-worktree-settle tests passed"
