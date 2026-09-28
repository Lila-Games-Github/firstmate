#!/usr/bin/env bash
# Tests for bounded foreground watcher checkpoints and legacy signal baselines.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

# This is the size:mtime format emitted by the watcher before the status
# presentation-signature update. Keep the fixture independent of its new writer.
seed_legacy_baseline() {
  local home=$1 file=$2 signature marker
  if [ "$(uname -s)" = Darwin ]; then
    signature=$(/usr/bin/stat -f '%z:%Fm' "$file")
  else
    signature=$(stat -c '%s:%Y' "$file")
  fi
  marker=$(basename "$file" | tr '.' '_')
  printf '%s' "$signature" > "$home/state/.seen-$marker"
}

run_baseline_checkpoint() {
  local home=$1 seconds=$2
  # Checkpoint expiry is intentional downtime; its recovery notification is
  # covered separately by fm-watch-recovery-loop.test.sh. Exercise signals here.
  PATH="$home/fakebin:$PATH" FM_BACKEND=tmux FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$CHECKPOINT" --seconds "$seconds" > "$home/out.txt" 2> "$home/err.txt"
}

test_restart_after_legacy_baseline_update_is_quiet() {
  local home i status
  home=$(make_case legacy-restart)
  mkdir -p "$home/data" "$home/config"
  for ((i=1; i<=54; i++)); do
    printf 'done: historical task %s\n' "$i" > "$home/state/old-$i.status"
    seed_legacy_baseline "$home" "$home/state/old-$i.status"
  done
  # Also preserve the turn-ended signature, which did not change format.
  touch "$home/state/old-1.turn-ended"
  seed_legacy_baseline "$home" "$home/state/old-1.turn-ended"
  status=0
  run_baseline_checkpoint "$home" 30 || status=$?
  if [ "$status" -ne 124 ]; then
    fail "legacy restart replayed $(awk -F '\t' '$3 == "signal" { keys[$4]=1 } END { for (k in keys) n++; print n+0 }' "$home/state/.wake-queue") historical status files"
  fi
  expect_code 124 "$status" "legacy restart must be silent"
  [ ! -s "$home/state/.wake-queue" ] || fail "historical signals were queued"
  # A second process proves that the adopted baseline survives watcher restarts.
  status=0
  run_baseline_checkpoint "$home" 2 || status=$?
  [ "$status" -eq 124 ] || fail "second restart woke: $(cat "$home/out.txt") $(cat "$home/err.txt")"
  expect_code 124 "$status" "second restart must remain silent"
  printf 'blocked: new line written with watcher down\n' >> "$home/state/old-27.status"
  run_baseline_checkpoint "$home" 30 || fail "post-migration downtime write was lost"
  [ "$(awk -F '\t' '$3 == "signal" { keys[$4]=1 } END { for (k in keys) n++; print n+0 }' "$home/state/.wake-queue")" = 1 ] \
    || fail "a downtime append replayed unchanged sibling logs"
  assert_contains "$(cat "$home/out.txt")" 'old-27.status' "downtime file was not surfaced"
  pass "54 legacy logs re-baseline silently across restarts and a downtime append wakes alone"
}

test_upgrade_with_pending_downtime_write() {
  local home status
  home=$(make_case legacy-pending)
  mkdir -p "$home/data" "$home/config"
  printf 'done: already reported\n' > "$home/state/old.status"
  seed_legacy_baseline "$home" "$home/state/old.status"
  printf 'done: already reported\n' > "$home/state/changed.status"
  seed_legacy_baseline "$home" "$home/state/changed.status"
  # Write while the old watcher is down, BEFORE the new watcher ever runs.
  printf 'needs-decision [key=down]: real pending line\n' >> "$home/state/changed.status"
  status=0
  run_baseline_checkpoint "$home" 8 || status=$?
  expect_code 0 "$status" "upgrade must retain a pending downtime write"
  [ "$(awk -F '\t' '$3 == "signal" { keys[$4]=1 } END { for (k in keys) n++; print n+0 }' "$home/state/.wake-queue")" = 1 ] \
    || fail "upgrade replayed an unchanged historical log alongside the pending write"
  assert_contains "$(cat "$home/state/.wake-queue")" $'\tsignal\tchanged.status\t' \
    "pending downtime write was not queued"
  pass "first upgraded cycle wakes only the log with a real pending downtime append"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_restart_after_legacy_baseline_update_is_quiet
test_upgrade_with_pending_downtime_write
