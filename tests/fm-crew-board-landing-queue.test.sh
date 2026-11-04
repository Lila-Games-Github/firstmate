#!/usr/bin/env bash
# The crew board's worker tag must read a local-only car's live landing-queue
# place and front-check state through fm-landing-queue.sh status, never a
# worker's stale self-reported phase text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PANELS="$ROOT/bin/fm-crew-board-panels.py"
QUEUE="$ROOT/bin/fm-landing-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-board-landing-queue)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

run_panels() {
  local home=$1 snapshot=$2
  FM_CREW_BOARD_PROC_ROOT="$home/empty-proc" FM_TEST_SERVICE_STATE="$home/empty-service" \
    FM_CREW_BOARD_PHONE_QUEUE_ROOT="$home/empty-locks" FROGPILE_SUITE_LOCK="$home/empty-locks/suite.lock" \
    FROGPILE_SUITE_LOCK_HOLDER="$home/empty-locks/suite.holder" PATH="$home/stub-bin:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    python3 "$PANELS" "$snapshot"
}

field() { sed -n "s/^$1=//p"; }
full_receipt() { printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$(git -C "$1" rev-parse HEAD)"; }

test_landing_queue_place_and_front_beat_stale_phase() {
  local home project a b out status
  home=$(mktemp -d "$TMP_ROOT/landing-queue.XXXXXX")
  mkdir -p "$home/state" "$home/data" "$home/stub-bin"
  cat > "$home/stub-bin/testfarm" <<'EOF'
#!/usr/bin/env bash
printf '{"schema":"fm-test-service.v1","requests":[]}\n'
EOF
  chmod +x "$home/stub-bin/testfarm"

  project="$home/project"
  git init -q -b main "$project"
  printf 'first\n' > "$project/shared.txt"
  git -C "$project" add .
  git -C "$project" -c user.name=t -c user.email=t@example.invalid commit -qm baseline

  a="$home/a"
  git -C "$project" worktree add -qb fm/a "$a" main
  printf 'a\n' > "$a/a.txt"
  git -C "$a" add .
  git -C "$a" -c user.name=t -c user.email=t@example.invalid commit -qm a

  b="$home/b"
  git -C "$project" worktree add -qb fm/b "$b" main
  printf 'b\n' > "$b/b.txt"
  git -C "$b" add .
  git -C "$b" -c user.name=t -c user.email=t@example.invalid commit -qm b

  full_receipt "$a" > "$home/a.full"
  FM_HOME="$home" "$QUEUE" ready a --project "$project" --landing-branch main \
    --branch fm/a --head "$(git -C "$a" rev-parse HEAD)" --target "$(git -C "$project" rev-parse main)" \
    --receipt "$home/a.full" >/dev/null || fail 'car a failed to join the landing queue'

  full_receipt "$b" > "$home/b.full"
  FM_HOME="$home" "$QUEUE" ready b --project "$project" --landing-branch main \
    --branch fm/b --head "$(git -C "$b" rev-parse HEAD)" --target "$(git -C "$project" rev-parse main)" \
    --receipt "$home/b.full" >/dev/null || fail 'car b failed to join the landing queue'

  out=$(FM_HOME="$home" "$QUEUE" status a --project "$project" --landing-branch main)
  status=$(printf '%s\n' "$out" | field status)
  [ "$status" = needs-quick ] || fail "expected car a at needs-quick, got $status"
  out=$(FM_HOME="$home" "$QUEUE" status b --project "$project" --landing-branch main)
  status=$(printf '%s\n' "$out" | field status)
  [ "$status" = waiting-for-front ] || fail "expected car b waiting-for-front, got $status"

  snapshot="$home/snapshot.json"
  jq -n --arg a "$a" --arg b "$b" '{schema: "fm-fleet-snapshot.v1", tasks: [
    {id: "a", mode: "local-only", paths: {worktree: {path: $a}},
     phase: {name: "validating", note: ""}},
    {id: "b", mode: "local-only", paths: {worktree: {path: $b}},
     phase: {name: "ready-to-merge", note: "LANDING-QUEUE FRONT"},
     current_state: {state: "paused", detail: "waiting for the front of the landing queue"}}]}' \
    > "$snapshot"
  run_panels "$home" "$snapshot" > "$home/panels.json" || fail 'landing queue worker tag projection failed'
  assert_equals 'LANDING QUEUE FRONT · NEEDS QUICK' "$(jq -r '.worker_tags.a' "$home/panels.json")" \
    'the true front car names its place and live front-check state'
  assert_equals 'LANDING QUEUE #2' "$(jq -r '.worker_tags.b' "$home/panels.json")" \
    'an upper car reads its live place, never its own stale "front" self-report, and drops the redundant pause word'
  pass 'a landing-queue car tag comes from its live place and front-check state, not a stale self-reported phase'
}

test_landing_queue_place_and_front_beat_stale_phase
