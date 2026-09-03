#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin/main tip or stops when origin is
# unreachable.
# A ship task given --landing-branch must instead start from that branch's
# fetched tip, and must refuse rather than fall back to the default branch when
# the landing base cannot be fetched or the refreshed HEAD does not match it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

LANDING=proto/godot/frog-pile

# Publish a landing branch that diverges from the default branch, then make the
# project clone (whose refs the pooled worktree shares) aware of it so the
# spawn's landing-branch resolution check passes. Echoes the landing tip.
add_landing_branch() {  # <case-dir> <default>
  local case_dir=$1 default=$2 publisher="$1/publisher"
  git -C "$publisher" checkout --quiet -b "$LANDING" "$INITIAL_SHA"
  printf 'lane work lands here\n' > "$publisher/landing.txt"
  git -C "$publisher" add landing.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm landing-tip
  git -C "$publisher" push --quiet origin "$LANDING"
  git -C "$publisher" checkout --quiet "$default"
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" rev-parse "origin/$LANDING"
}

add_task_record() {  # <id>
  mkdir -p "$HOME_DIR/data/$1"
  printf 'brief for %s\n' "$1" > "$HOME_DIR/data/$1/brief.md"
}

assert_no_half_launched_task() {  # <id> <label>
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "$2 left a task record behind after refusing to launch"
  [ ! -e "$HOME_DIR/state/$1.status" ] || fail "$2 left a status log behind after refusing to launch"
}

test_landing_branch_bases_task_on_landing_tip() {
  local rec id out status landing_tip main_tip branch_head parent
  id='pool-landing-base-r6'
  rec=$(make_case landing-base "$id")
  read_case_record "$rec"
  landing_tip=$(add_landing_branch "$CASE_DIR" "$DEFAULT_BRANCH")
  main_tip=$(git -C "$PROJECT_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  [ "$landing_tip" != "$main_tip" ] || fail "fixture did not make the landing tip differ from the default tip"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --landing-branch "$LANDING")
  status=$?
  expect_code 0 "$status" "spawn with a landing branch should launch"$'\n'"$out"
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$landing_tip" ] || fail "spawn based the task on '$branch_head', not the landing tip '$landing_tip'"
  [ "$branch_head" != "$main_tip" ] || fail "spawn based the task on the default branch despite --landing-branch"
  assert_grep 'lane work lands here' "$POOL_DIR/landing.txt" "the landing branch content is missing from the task base"
  [ ! -e "$POOL_DIR/advanced-main.txt" ] || fail "default-branch-only content leaked into a landing-branch base"
  [ "$(grep -c '^landing_branch=' "$HOME_DIR/state/$id.meta")" = 1 ] \
    || fail "the task record did not record the landing branch exactly once"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  printf 'first lane commit\n' > "$POOL_DIR/lane.txt"
  git -C "$POOL_DIR" add lane.txt
  git -C "$POOL_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm lane
  parent=$(git -C "$POOL_DIR" rev-parse HEAD^)
  [ "$parent" = "$landing_tip" ] || fail "the task branch's first commit parent is '$parent', not the landing tip '$landing_tip'"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed landing base: HEAD=%s origin/%s=%s origin/%s=%s\n' \
      "$branch_head" "$LANDING" "$landing_tip" "$DEFAULT_BRANCH" "$main_tip"
  fi

  id='pool-landing-absent-r6'
  add_task_record "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn without a landing branch should still launch"$'\n'"$out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$main_tip" ] \
    || fail "a spawn without --landing-branch did not keep basing the task on the default branch"
  pass "a ship spawn with --landing-branch starts from the landing tip while the default path is unchanged"
}

test_unfetchable_landing_branch_refuses_without_default_fallback() {
  local rec id out status before local_only
  id='pool-landing-unfetchable-r7'
  rec=$(make_case landing-unfetchable "$id")
  read_case_record "$rec"
  local_only=local/only-here
  git -C "$PROJECT_DIR" branch --quiet "$local_only" "$INITIAL_SHA"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --landing-branch "$local_only")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although the landing branch does not exist on origin"
  assert_contains "$out" "could not fetch 'origin/$local_only'" \
    "spawn did not name the unfetchable landing branch: $out"
  assert_contains "$out" "refusing to launch from a potentially stale base" \
    "spawn did not refuse in the stale-base style: $out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the pooled worktree after failing to fetch the landing branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" != "$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")" ] \
    || fail "spawn fell back to the default branch after failing to fetch the landing branch"
  assert_no_half_launched_task "$id" "an unfetchable landing branch"
  pass "a landing branch missing from origin refuses the spawn instead of falling back to the default branch"
}

test_landing_base_mismatch_refuses_naming_both_commits() {
  local rec id out status landing_tip main_tip real_git
  id='pool-landing-mismatch-r8'
  rec=$(make_case landing-mismatch "$id")
  read_case_record "$rec"
  landing_tip=$(add_landing_branch "$CASE_DIR" "$DEFAULT_BRANCH")
  main_tip=$(git -C "$PROJECT_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  real_git=$(command -v git)
  # Inject the defect under test: the reset lands on the default tip instead of
  # the landing tip, as if the base moved between fetch and reset.
  cat > "$FAKEBIN_DIR/git" <<SH
#!/usr/bin/env bash
case "\$*" in
  *" reset --hard origin/$LANDING")
    rewritten=()
    for arg in "\$@"; do
      [ "\$arg" != "origin/$LANDING" ] || arg="origin/$DEFAULT_BRANCH"
      rewritten+=("\$arg")
    done
    set -- "\${rewritten[@]}" ;;
esac
exec "$real_git" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/git"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --landing-branch "$LANDING")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although the refreshed base did not match the landing tip"
  assert_contains "$out" "refusing to launch from a potentially stale base" \
    "spawn did not refuse in the stale-base style: $out"
  assert_contains "$out" "$landing_tip" "the refusal did not name the expected landing tip: $out"
  assert_contains "$out" "$main_tip" "the refusal did not name the actual mismatched commit: $out"
  assert_contains "$out" "origin/$LANDING" "the refusal did not name the landing branch: $out"
  assert_no_half_launched_task "$id" "a landing base mismatch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed landing mismatch refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "a refreshed base that does not match the landing tip refuses the spawn naming both commits"
}

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-base-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn left the pooled worktree on stale history"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  id='pool-current-base-repeat-r1'
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the pool away from current origin/main"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "a branch created after spawn differs from current origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "the branch created after spawn omitted advanced-main content"
  pass "a stale pooled worktree refreshes to current origin/main before a crew branch is created"
}

test_non_main_default_branch_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree on a non-main default branch"
  current=$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to current origin/$DEFAULT_BRANCH"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced past the pool base"
  pass "a stale pooled worktree resolves and refreshes a non-main default branch"
}

test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin refuses a potentially stale pooled worktree"
}

test_direct_pr_and_scout_refresh_before_launch() {
  local rec id out status contract current
  for contract in direct-pr scout; do
    id="pool-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a stale pooled worktree"
    current=$(git -C "$POOL_DIR" rev-parse origin/main)
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
      "$contract spawn omitted advanced-main content"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "direct-PR ships and scouts both refresh stale pooled worktrees before launch"
}

test_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-dirty-refusal-r4'
  rec=$(make_case dirty-refusal "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the pool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed dirty refusal: %s; preserved=%s\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$(cat "$POOL_DIR/uncommitted.txt")"
  fi
  pass "a dirty pooled worktree is refused without discarding its local work"
}

test_unresolved_remote_default_refuses_pool() {
  local rec id out status before
  id='pool-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remote default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolved-default refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unresolved remote default branch refuses the pooled worktree"
}

test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_landing_branch_bases_task_on_landing_tip
test_unfetchable_landing_branch_refuses_without_default_fallback
test_landing_base_mismatch_refuses_naming_both_commits

echo "# all fm-spawn-pool-base-freshen tests passed"
