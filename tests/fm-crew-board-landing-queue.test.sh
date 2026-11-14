#!/usr/bin/env bash
# The crew board projects a local-only car's place and last reconciled status
# from the queue snapshot without waiting for per-car status subprocesses.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SKIP_TESTFARM:-}" = 1 ]; then
  printf '%s\n' 'skip: crew board landing queue check requires the private testfarm checkout'
  exit 0
fi

PANELS="$ROOT/bin/fm-crew-board-panels.py"
QUEUE="$ROOT/bin/fm-landing-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-board-landing-queue)
TESTFARM_CHECKOUT=$(python3 -c 'import os, shutil; print(os.path.dirname(os.path.dirname(os.path.realpath(shutil.which("testfarm")))))')

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

run_panels() {
  local home=$1 snapshot=$2
  FM_CREW_BOARD_PROC_ROOT="$home/empty-proc" FM_TEST_SERVICE_STATE="$home/empty-service" \
    FM_CREW_BOARD_PHONE_QUEUE_ROOT="$home/empty-locks" FROGPILE_SUITE_LOCK="$home/empty-locks/suite.lock" \
    FROGPILE_SUITE_LOCK_HOLDER="$home/empty-locks/suite.holder" PATH="$home/stub-bin:$PATH" \
    TESTFARM_CHECKOUT="$TESTFARM_CHECKOUT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    python3 "$PANELS" "$snapshot"
}

run_panels_with_slow_queue_status() {
  local home=$1 snapshot=$2
  FM_CREW_BOARD_PROC_ROOT="$home/empty-proc" FM_TEST_SERVICE_STATE="$home/empty-service" \
    FM_CREW_BOARD_PHONE_QUEUE_ROOT="$home/empty-locks" FROGPILE_SUITE_LOCK="$home/empty-locks/suite.lock" \
    FROGPILE_SUITE_LOCK_HOLDER="$home/empty-locks/suite.holder" PATH="$home/stub-bin:$PATH" \
    TESTFARM_CHECKOUT="$TESTFARM_CHECKOUT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    python3 - "$PANELS" "$snapshot" <<'PY'
import runpy
import subprocess
import sys
import time

original = subprocess.run
def slow_queue_status(args, *other, **kwargs):
    if isinstance(args, (list, tuple)) and args and str(args[0]).endswith("fm-landing-queue.sh"):
        time.sleep(4.5)
    return original(args, *other, **kwargs)
subprocess.run = slow_queue_status
start = time.monotonic()
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
if time.monotonic() - start > 3.0:
    raise SystemExit("board projection waited on slow queue status")
PY
}

field() { sed -n "s/^$1=//p"; }
full_receipt() { printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$(git -C "$1" rev-parse HEAD)"; }

test_landing_queue_place_and_front_beat_stale_phase() {
  local home project a b c out status queue empty
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

  c="$home/c"
  git -C "$project" worktree add -qb fm/c "$c" main
  printf 'c\n' > "$c/c.txt"
  git -C "$c" add .
  git -C "$c" -c user.name=t -c user.email=t@example.invalid commit -qm c

  full_receipt "$a" > "$home/a.full"
  FM_HOME="$home" "$QUEUE" ready a --project "$project" --landing-branch main \
    --branch fm/a --head "$(git -C "$a" rev-parse HEAD)" --target "$(git -C "$project" rev-parse main)" \
    --receipt "$home/a.full" >/dev/null || fail 'car a failed to join the landing queue'

  full_receipt "$b" > "$home/b.full"
  FM_HOME="$home" "$QUEUE" ready b --project "$project" --landing-branch main \
    --branch fm/b --head "$(git -C "$b" rev-parse HEAD)" --target "$(git -C "$project" rev-parse main)" \
    --receipt "$home/b.full" >/dev/null || fail 'car b failed to join the landing queue'

  full_receipt "$c" > "$home/c.full"
  FM_HOME="$home" "$QUEUE" ready c --project "$project" --landing-branch main \
    --branch fm/c --head "$(git -C "$c" rev-parse HEAD)" --target "$(git -C "$project" rev-parse main)" \
    --receipt "$home/c.full" --priority infra >/dev/null || fail 'infra car failed to join the landing queue'

  out=$(FM_HOME="$home" "$QUEUE" status a --project "$project" --landing-branch main)
  status=$(printf '%s\n' "$out" | field status)
  [ "$status" = needs-quick ] || fail "expected car a at needs-quick, got $status"
  out=$(FM_HOME="$home" "$QUEUE" status b --project "$project" --landing-branch main)
  status=$(printf '%s\n' "$out" | field status)
  [ "$status" = waiting-for-front ] || fail "expected car b waiting-for-front, got $status"

  snapshot="$home/snapshot.json"
  jq -n --arg a "$a" --arg b "$b" --arg c "$c" '{schema: "fm-fleet-snapshot.v1", tasks: [
    {id: "a", mode: "local-only", paths: {worktree: {path: $a}},
     phase: {name: "validating", note: ""}},
    {id: "b", mode: "local-only", paths: {worktree: {path: $b}},
     phase: {name: "ready-to-merge", note: "LANDING-QUEUE FRONT"},
     current_state: {state: "paused", detail: "waiting for the front of the landing queue"}},
    {id: "c", mode: "local-only", paths: {worktree: {path: $c}}}]}' \
    > "$snapshot"
  run_panels "$home" "$snapshot" > "$home/panels.json" || fail 'landing queue worker tag projection failed'
  assert_equals 'LANDING QUEUE FRONT · NEEDS QUICK' "$(jq -r '.worker_tags.a' "$home/panels.json")" \
    'the true front car names its place and live front-check state'
  assert_equals 'LANDING QUEUE #3' "$(jq -r '.worker_tags.b' "$home/panels.json")" \
    'an upper car reads its live place, never its own stale "front" self-report, and drops the redundant pause word'
  assert_equals '3' "$(jq '[.landing_queue[] | select(.status != "section")] | length' "$home/panels.json")" \
    'all active queue cars appear in the live panel'
  assert_equals '#1 a|#2 c · infra|#3 b' "$(jq -r '[.landing_queue[] | select(.status != "section") | .title] | join("|")' "$home/panels.json")" \
    'infra car appears ahead of the waiting product car'
  assert_equals 'needs-quick|waiting-for-front|waiting-for-front' "$(jq -r '[.landing_queue[] | select(.status != "section") | .status] | join("|")' "$home/panels.json")" \
    'queue status comes from the live status helper'
  assert_equals 'Front check: none · none' "$(jq -r '.landing_queue[] | select(.id == "a") | .detail' "$home/panels.json")" \
    'the front car exposes its check state'
  run_panels_with_slow_queue_status "$home" "$snapshot" > "$home/slow-panels.json" \
    || fail 'slow queue status delayed board projection'
  assert_equals '#1 a|#2 c · infra|#3 b' \
    "$(jq -r '[.landing_queue[] | select(.status != "section") | .title] | join("|")' "$home/slow-panels.json")" \
    'all active cars remain visible when queue status would take 4.5 seconds'
  queue=$(find "$home/data/landing-queue" -name queue -type f -print -quit)
  assert_equals '3' "$(tail -n +4 "$queue" | wc -l | tr -d ' ')" \
    'fixture source has three cars, matching the observed three panel cars'
  sed -i '1s/.*/bad-schema/' "$queue"
  if FM_HOME="$home" "$QUEUE" status a --project "$project" --landing-branch main > "$home/bad-status" 2>&1; then
    fail 'landing queue validator accepted a known-bad schema'
  fi
  assert_contains "$(cat "$home/bad-status")" 'invalid queue schema' \
    'the authoritative queue status rejects the known-bad fixture'
  empty=$(mktemp -d "$TMP_ROOT/landing-queue-empty.XXXXXX")
  mkdir -p "$empty/state" "$empty/data" "$empty/stub-bin"
  cp "$home/stub-bin/testfarm" "$empty/stub-bin/testfarm"
  jq -n '{schema: "fm-fleet-snapshot.v1", tasks: []}' > "$empty/snapshot.json"
  run_panels "$empty" "$empty/snapshot.json" > "$empty/panels.json" || fail 'empty landing queue projection failed'
  assert_equals '0' "$(jq '.landing_queue | length' "$empty/panels.json")" \
    'empty source produces no active cars'
  pass 'a landing-queue car tag comes from its live place and front-check state, not a stale self-reported phase'
}

test_landing_queue_place_and_front_beat_stale_phase

test_landing_queue_many_landed_rows_do_not_hide_active_car() {
  local home project a queue sha i out
  home=$(mktemp -d "$TMP_ROOT/landing-queue-landed.XXXXXX")
  mkdir -p "$home/state" "$home/data" "$home/stub-bin"
  printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"schema\":\"fm-test-service.v1\",\"requests\":[]}'" > "$home/stub-bin/testfarm"
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
  full_receipt "$a" > "$home/a.full"
  FM_HOME="$home" "$QUEUE" ready a --project "$project" --landing-branch main \
    --branch fm/a --head "$(git -C "$a" rev-parse HEAD)" --target "$(git -C "$project" rev-parse main)" \
    --receipt "$home/a.full" >/dev/null || fail 'active car failed to join the landing queue'
  queue=$(find "$home/data/landing-queue" -name queue -type f -print -quit)
  sha=$(git -C "$project" rev-parse main)
  {
    head -n 3 "$queue"
    for i in $(seq 1 100); do
      printf 'old-%s\tfm/old-%s\t%s\tlanded\t%s\t%s.receipt\t%s\t%s\t-\t-\t-\n' "$i" "$i" "$sha" "$sha" "$sha" "$sha" "$sha"
    done
    tail -n +4 "$queue"
  } > "$queue.new"
  mv "$queue.new" "$queue"
  jq -n '{schema: "fm-fleet-snapshot.v1", tasks: []}' > "$home/snapshot.json"
  run_panels "$home" "$home/snapshot.json" > "$home/panels.json" || fail 'projection with many landed rows failed'
  out=$(jq -r '[.landing_queue[] | select(.status != "section") | .title + ":" + .status] | join("|")' "$home/panels.json")
  assert_equals '#1 a:needs-quick' "$out" 'the one active car shows behind 100 landed rows'
  pass 'a queue of many landed rows still shows its active car'
}

test_landing_queue_many_landed_rows_do_not_hide_active_car
