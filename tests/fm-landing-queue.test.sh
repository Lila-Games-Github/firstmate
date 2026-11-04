#!/usr/bin/env bash
# Exercise pre-queue admission and front checks through the queue executable.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-landing-queue)
QUEUE="$ROOT/bin/fm-landing-queue.sh"
make_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/home" "$CASE/project"
  git init -q -b main "$CASE/project"
  printf 'first\na\nb\nc\nd\ne\nf\ng\nh\ni\nsecond\n' > "$CASE/project/shared.txt"
  git -C "$CASE/project" add .
  git -C "$CASE/project" commit -qm baseline
  BASE=$(git -C "$CASE/project" rev-parse HEAD)
}
car() {
  local id=$1
  git -C "$CASE/project" worktree add -qb "fm/$id" "$CASE/$id" main
  printf '%s\n' "$id" > "$CASE/$id/$id.txt"
  git -C "$CASE/$id" add .
  git -C "$CASE/$id" commit -qm "$id"
}
queue() { FM_HOME="$CASE/home" "$QUEUE" "$@" --project "$CASE/project" --landing-branch main; }
field() { sed -n "s/^$1=//p"; }
head_of() { git -C "$CASE/project" rev-parse "fm/$1"; }
tip() { git -C "$CASE/project" rev-parse main; }
full_receipt() { printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$(head_of "$1")" > "$CASE/$1.full"; }
join() {
  local id=$1 target
  shift
  target=$(tip)
  full_receipt "$id"
  queue ready "$id" --branch "fm/$id" --head "$(head_of "$id")" --target "$target" --receipt "$CASE/$id.full" "$@"
}
prepare() {
  local id=$1 out target previous
  out=$(queue status "$id")
  target=$(printf '%s\n' "$out" | field target_sha)
  previous=$(printf '%s\n' "$out" | field rebase_from)
  if [ "$target" != "$previous" ]; then
    git -C "$CASE/$id" rebase --onto "$target" "$previous" > "$CASE/$id.rebase.log" 2>&1
  fi
  queue ready "$id" --branch "fm/$id" --head "$(head_of "$id")" --target "$target" >/dev/null
}
quick_receipt() {
  local id=$1 target head
  target=$(queue status "$id" | field target_sha)
  head=$(head_of "$id")
  printf 'schema=fm-quick-check.v1\nsha=%s\ntarget=%s\n' "$head" "$target" > "$CASE/$id.quick"
  queue receipt "$id" --head "$head" --target "$target" --receipt "$CASE/$id.quick"
}
full_front() {
  local id=$1 target
  target=$(queue status "$id" | field target_sha)
  full_receipt "$id"
  queue receipt "$id" --head "$(head_of "$id")" --target "$target" --receipt "$CASE/$id.full"
}
expect_field() {
  local out=$1 key=$2 expected=$3 actual
  actual=$(printf '%s\n' "$out" | field "$key")
  [ "$actual" = "$expected" ] || fail "$key: expected $expected, got $actual"
}
wake_count() { if [ -f "$CASE/home/state/.wake-queue" ]; then wc -l < "$CASE/home/state/.wake-queue" | tr -d ' '; else echo 0; fi; }

# FM_LANDING_QUEUE_TEST_ONLY=farm runs only the test farm cases below, which the
# stock macOS Bash consumer in bin/fm-stock-bash-compat.sh selects.
if [ "${FM_LANDING_QUEUE_TEST_ONLY:-}" != farm ]; then
make_case admission
car a
if queue ready a --branch fm/a --head "$(head_of a)" --target "$BASE" > "$CASE/refusal" 2>&1; then
  fail 'ready admitted a car without a full pre-queue receipt'
fi
grep -q 'requires an exact-head full-suite receipt' "$CASE/refusal" || fail 'admission refusal omitted the missing receipt'
expect_field "$(join a)" status needs-quick
expect_field "$(quick_receipt a)" status ready-to-land
[ "$(wake_count)" = 1 ] || fail 'front quick receipt did not wake firstmate once'
pass 'ready requires a green exact-head full receipt and a quick front check lands'

make_case pre-gates
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"quick_suite":["related.sh"],"device":["phone.sh"],"quick_device":["short-phone.sh"],"phones":["phone"],"landing_branch":"main","landing_gates":["real-phone","m31"]}
EOF
car a
if join a > "$CASE/refusal" 2>&1; then fail 'ready admitted missing gates'; fi
grep -q 'requires pre-queue landing gate: real-phone' "$CASE/refusal" || fail 'missing gate refusal was unclear'
for gate in real-phone m31; do
  printf 'schema=fm-landing-gate.v1\ngate=%s\nsha=%s\ntarget=%s\n' "$gate" "$(head_of a)" "$BASE" > "$CASE/$gate.gate"
done
expect_field "$(join a --gate-receipt real-phone="$CASE/real-phone.gate" --gate-receipt m31="$CASE/m31.gate")" status needs-quick
expect_field "$(quick_receipt a)" status ready-to-land
pass 'configured phone and benchmark gates are required before joining'

make_case concurrent-old-tip
car a
car b
full_receipt a
full_receipt b
git -C "$CASE/project" commit -qm tip-moved --allow-empty
expect_field "$(queue ready a --branch fm/a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/a.full")" status needs-rebase
expect_field "$(queue ready b --branch fm/b --head "$(head_of b)" --target "$BASE" --receipt "$CASE/b.full")" status waiting-for-front
pre_a=$(find "$CASE/home/data/landing-queue" -name pre-a -type f -print -quit)
pre_b=$(find "$CASE/home/data/landing-queue" -name pre-b -type f -print -quit)
[ -n "$pre_a" ] && [ "$(cat "$pre_a")" = "$BASE" ] || fail 'first car lost its tested target'
[ -n "$pre_b" ] && [ "$(cat "$pre_b")" = "$BASE" ] || fail 'second car lost its tested target'
prepare a
expect_field "$(queue status a)" status needs-quick
expect_field "$(quick_receipt a)" status ready-to-land
pass 'two cars tested against the same old tip both get admitted and the front quick check runs after rebase'

make_case old-tip-gate
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"quick_suite":["related.sh"],"device":["phone.sh"],"quick_device":["short-phone.sh"],"phones":["phone"],"landing_branch":"main","landing_gates":["m31"]}
EOF
car a
full_receipt a
printf 'schema=fm-landing-gate.v1\ngate=m31\nsha=%s\ntarget=%s\n' "$(head_of a)" "$BASE" > "$CASE/m31.gate"
git -C "$CASE/project" commit -qm tip-moved --allow-empty
expect_field "$(queue ready a --branch fm/a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/a.full" --gate-receipt m31="$CASE/m31.gate")" status needs-rebase
pass 'a gate receipt for the tested older tip admits the car'

make_case wrong-head-receipt
car a
car b
full_receipt b
if queue ready a --branch fm/a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/b.full" > "$CASE/refusal" 2>&1; then
  fail 'ready admitted a full receipt for another head'
fi
grep -q 'valid exact-head full-suite receipt' "$CASE/refusal" || fail 'wrong-head refusal was unclear'
pass 'admission refuses a receipt for a different head'

make_case red-receipt
car a
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=known-red\n' "$(head_of a)" > "$CASE/a.full"
if queue ready a --branch fm/a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/a.full" > "$CASE/refusal" 2>&1; then
  fail 'ready admitted a red pre-queue receipt'
fi
grep -q 'green full-suite receipt' "$CASE/refusal" || fail 'red-receipt refusal was unclear'
pass 'admission refuses a red receipt'

make_case foreign-head
car a
git -C "$CASE/project" checkout -q --orphan foreign
git -C "$CASE/project" commit -qm foreign --allow-empty
git -C "$CASE/a" reset -q --hard foreign
git -C "$CASE/project" checkout -q main
full_receipt a
if queue ready a --branch fm/a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/a.full" > "$CASE/refusal" 2>&1; then
  fail 'ready admitted a head without the landing tip'
fi
grep -q 'pre-queue head must contain' "$CASE/refusal" || fail 'foreign-head refusal was unclear'
pass 'admission refuses a head without a landing-branch tip'

make_case unrelated-tip
car a; join a >/dev/null
git -C "$CASE/project" commit -qm unrelated --allow-empty
expect_field "$(queue status a)" status needs-rebase
prepare a
expect_field "$(queue status a)" status needs-quick
expect_field "$(quick_receipt a)" status ready-to-land
pass 'an unrelated tip change needs only the quick front check'

make_case overlapping-tip
car a
sed -i 's/first/updated-first/' "$CASE/a/shared.txt"
git -C "$CASE/a" commit -qam touch-shared
join a >/dev/null
sed -i 's/second/updated-second/' "$CASE/project/shared.txt"
git -C "$CASE/project" commit -qam outside-shared
prepare a
expect_field "$(queue status a)" status needs-full
if quick_receipt a > "$CASE/quick-refusal" 2>&1; then fail 'overlap accepted a quick receipt'; fi
grep -q 'invalid exact-head full receipt' "$CASE/quick-refusal" || fail 'overlap refusal did not require full receipt'
expect_field "$(full_front a)" status ready-to-land
pass 'a tip change to a touched file requires a full front rerun'

make_case overlap-gate
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"quick_suite":["related.sh"],"device":["phone.sh"],"quick_device":["short-phone.sh"],"phones":["phone"],"landing_branch":"main","landing_gates":["m31"]}
EOF
car a
sed -i 's/first/updated-first/' "$CASE/a/shared.txt"
git -C "$CASE/a" commit -qam touch-shared
printf 'schema=fm-landing-gate.v1\ngate=m31\nsha=%s\ntarget=%s\n' "$(head_of a)" "$BASE" > "$CASE/m31.pre"
join a --gate-receipt m31="$CASE/m31.pre" >/dev/null
sed -i 's/second/updated-second/' "$CASE/project/shared.txt"
git -C "$CASE/project" commit -qam outside-shared
prepare a
expect_field "$(full_front a)" status needs-gate
target=$(tip)
printf 'schema=fm-landing-gate.v1\ngate=m31\nsha=%s\ntarget=%s\n' "$(head_of a)" "$target" > "$CASE/m31.front"
expect_field "$(queue gate a --gate m31 --head "$(head_of a)" --target "$target" --receipt "$CASE/m31.front")" status ready-to-land
pass 'a full fallback repeats configured gates on the rebased head'

make_case failing-quick
car a; join a >/dev/null
car b; join b >/dev/null
expect_field "$(queue receipt a --head "$(head_of a)" --target "$BASE" --reason 'short phone check failed')" place 2
expect_field "$(queue status b)" place 1
expect_field "$(queue status a)" status waiting-for-front
expect_field "$(quick_receipt b)" status ready-to-land
git -C "$CASE/project" merge -q --ff-only fm/b
prepare a
expect_field "$(queue status a)" status needs-full
expect_field "$(full_front a)" status ready-to-land
pass 'a failed quick check moves back and requires a full rerun when front again'

make_case three-cars
for id in a b c; do car "$id"; join "$id" >/dev/null; done
for id in b c; do expect_field "$(queue status "$id")" status waiting-for-front; done
for id in a b c; do
  expect_field "$(queue status "$id")" place 1
  prepare "$id"
  expect_field "$(quick_receipt "$id")" status ready-to-land
  git -C "$CASE/project" merge -q --ff-only "fm/$id"
  expect_field "$(queue status "$id")" status landed
done
[ "$(wake_count)" = 3 ] || fail 'three cars did not emit exactly three readiness wakes'
pass 'three cars move through the train with one quick check each'

make_case move-waiting
for id in a b c d; do car "$id"; join "$id" >/dev/null; done
front_before=$(queue status a)
queue_file=$(find "$CASE/home/data/landing-queue" -name queue -type f -print -quit)
front_row_before=$(sed -n '4p' "$queue_file")
front_wakes_before=$(wake_count)
expect_field "$(queue move d --place 2)" place 2
expect_field "$(queue status a)" place 1
expect_field "$(queue status b)" place 3
expect_field "$(queue status c)" place 4
expect_field "$(queue status d)" status waiting-for-front
expect_field "$(queue move c --place 2)" place 2
expect_field "$(queue status d)" place 3
expect_field "$(queue status b)" place 4
[ "$(sed -n '4p' "$queue_file")" = "$front_row_before" ] || fail 'move changed the running front row'
[ "$(wake_count)" = "$front_wakes_before" ] || fail 'move changed the front check wake'
[ "$(printf '%s\n' "$front_before" | field status)" = "$(queue status a | field status)" ] || fail 'move interrupted the front check'
for id in b c d; do
  expect_field "$(queue status "$id")" status waiting-for-front
done
pass 'three waiting cars reorder while the running front check and other statuses stay intact'

reject_move() {
  if queue move "$1" --place "$2" > "$CASE/refusal" 2>&1; then fail "move accepted $1 at place $2"; fi
}
reject_move missing 2
reject_move a 2
reject_move b 1
reject_move b 5
rm -f -- "$(dirname "$queue_file")/pre-b"
if queue move b --place 2 > "$CASE/refusal" 2>&1; then fail 'move accepted missing admission evidence'; fi
grep -q 'admission evidence' "$CASE/refusal" || fail 'missing evidence refusal was unclear'
printf 'changed\n' >> "$CASE/c/c.txt"
git -C "$CASE/c" commit -qam changed
if queue move c --place 3 > "$CASE/refusal" 2>&1; then fail 'move accepted a car with a changed head'; fi
grep -q 'head changed since admission' "$CASE/refusal" || fail 'changed-head refusal was unclear'
pass 'move refuses unknown, front, invalid place, missing-evidence, and changed-head cars'

make_case missing-branch
car a; join a >/dev/null
git -C "$CASE/project" worktree remove --force "$CASE/a"
git -C "$CASE/project" branch -D fm/a >/dev/null
expect_field "$(queue status a)" status failed
expect_field "$(queue status a)" reason 'local branch missing'
pass 'a deleted unlanded branch fails visibly and keeps its reason'

make_case concurrent
car a; car b
join a > "$CASE/a.out" & first=$!
join b > "$CASE/b.out" & second=$!
wait "$first"; wait "$second"
places=$( { queue status a | field place; queue status b | field place; } | sort | tr '\n' ' ')
[ "$places" = '1 2 ' ] || fail "concurrent joins lost a car: $places"
pass 'concurrent green admission serializes without losing a car'

make_case failed-reenroll
car a; car b
join a >/dev/null; join b >/dev/null
expect_field "$(queue fail a --reason 'worker fix needed')" status failed
expect_field "$(join a)" place 2
expect_field "$(queue status b)" place 1
pass 'a failed car needs fresh pre-queue evidence and re-enrolls at the back'

make_case empty-car
git -C "$CASE/project" branch fm/empty
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$BASE" > "$CASE/empty.full"
if queue ready empty --branch fm/empty --head "$BASE" --target "$BASE" --receipt "$CASE/empty.full" > "$CASE/refusal" 2>&1; then
  fail 'a car with nothing to land was admitted'
fi
if queue status empty > "$CASE/refusal" 2>&1; then fail 'refused empty car joined the queue'; fi
pass 'a tested head already on the tip cannot join'

make_case independent-targets
git -C "$CASE/project" branch proto/landing
car a; car b
join a > "$CASE/a.out"
full_receipt b
out=$(FM_HOME="$CASE/home" "$QUEUE" ready b --project "$CASE/project" --landing-branch proto/landing \
  --branch fm/b --head "$(head_of b)" --target "$BASE" --receipt "$CASE/b.full")
expect_field "$out" place 1
[ "$(printf '%s\n' "$out" | field queue)" != "$(cat "$CASE/a.out" | field queue)" ] || fail 'landing branches shared a queue'
pass 'separate landing branches have separate queues'

make_case reconcile-without-queue
queue reconcile a > "$CASE/out"
[ ! -s "$CASE/out" ] && [ ! -e "$CASE/home/data/landing-queue" ] || fail 'reconcile created an empty train'
pass 'reconcile without a train has no queue side effects'

make_case infra-priority
for id in a b; do car "$id"; join "$id" >/dev/null; done
expect_field "$(queue status a)" place 1
expect_field "$(queue status a)" priority -
expect_field "$(queue status b)" place 2
expect_field "$(queue status b)" priority -
car c
expect_field "$(join c --priority infra)" place 2
expect_field "$(queue status c)" priority infra
expect_field "$(queue status a)" place 1
expect_field "$(queue status b)" place 3
car d
expect_field "$(join d --priority infra)" place 3
expect_field "$(queue status d)" priority infra
expect_field "$(queue status c)" place 2
expect_field "$(queue status b)" place 4
car e
expect_field "$(join e)" place 5
expect_field "$(queue status e)" priority -
expect_field "$(queue status a)" place 1
pass 'an infra car admits behind the front and ahead of waiting non-infra cars, FIFO among infra cars, non-infra cars join at the back as before'

make_case infra-reenroll
car a; join a >/dev/null
car c; join c --priority infra >/dev/null
car b; join b >/dev/null
expect_field "$(queue status c)" place 2
expect_field "$(queue fail c --reason 'fixing')" status failed
expect_field "$(queue status b)" place 2
expect_field "$(join c)" place 2
expect_field "$(queue status c)" priority infra
expect_field "$(queue status b)" place 3
pass 're-enrolling a failed infra car keeps its priority and its position behind the front'

make_case infra-stray
for id in a b; do car "$id"; join "$id" >/dev/null; done
car c
expect_field "$(join c --priority infra)" place 2
expect_field "$(queue move b --place 2)" place 2
expect_field "$(queue status c)" place 3
car d
expect_field "$(join d --priority infra)" place 2
expect_field "$(queue status b)" place 3
expect_field "$(queue status c)" place 4
pass 'an infra car admits ahead of waiting non-infra cars even when another infra car sits behind one'

make_case infra-priority-validation
car a
if queue ready a --branch fm/a --head "$(head_of a)" --target "$BASE" --priority bogus > "$CASE/refusal" 2>&1; then
  fail 'ready accepted an unknown --priority value'
fi
grep -q 'invalid --priority value' "$CASE/refusal" || fail 'unknown priority refusal was unclear'
if queue status a --priority infra > "$CASE/refusal" 2>&1; then
  fail 'status accepted --priority'
fi
grep -q 'only valid for ready' "$CASE/refusal" || fail 'non-ready priority refusal was unclear'
pass 'priority rejects an unknown value and any action other than ready'

make_case landed-then-deleted
car a; join a >/dev/null; quick_receipt a >/dev/null
git -C "$CASE/project" merge -q --ff-only fm/a
git -C "$CASE/project" worktree remove "$CASE/a"
git -C "$CASE/project" branch -D fm/a >/dev/null
expect_field "$(queue status a)" status landed
[ "$(wake_count)" = 1 ] || fail 'landed deleted branch emitted a failure wake'
pass 'a deleted branch whose head landed stays landed'
fi

# --- front check settled from the test farm, with no worker action -----------
# The fixture farm prints $CASE/farm.json as `testfarm status --json --no-probe`
# does; FM_TESTFARM_BIN points the queue at it. A worker meta and a fake tmux let
# fm-send deliver owner messages into state/<id>.inbox.
farm_case() {
  make_case "$1"
  mkdir -p "$CASE/bin" "$CASE/home/state"
  cat > "$CASE/bin/testfarm" <<'FARM'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'status --json --no-probe' ] || { echo "unexpected testfarm call: $*" >&2; exit 64; }
cat "$(dirname "$0")/../farm.json"
FARM
  chmod +x "$CASE/bin/testfarm"
  cat > "$CASE/bin/tmux" <<'TMUX'
#!/usr/bin/env bash
case "$1" in
  display-message) echo fakepane ;;
  list-windows) echo fm-notify ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  send-keys) exit 1 ;;
esac
TMUX
  chmod +x "$CASE/bin/tmux"
  export FM_TESTFARM_BIN="$CASE/bin/testfarm"
  export PATH="$CASE/bin:$ORIGINAL_PATH"
}
worker_meta() { fm_write_meta "$CASE/home/state/$1.meta" 'window=sess:fm-notify' 'kind=ship' 'harness=claude'; }
# farm_request <id> <car> <state> [error] [submitted]: one quick request for the
# car's current head and assigned target.
farm_request() {
  local id=$1 car=$2 state=$3 error=${4:-} submitted=${5:-} target
  target=$(queue status "$car" | field target_sha)
  [ -n "$submitted" ] || submitted=$(date +%s)
  python3 -I -c '
import json, sys
rid, sha, target, state, error, submitted = sys.argv[1:7]
print(json.dumps({"id": rid, "seq": 1, "sha": sha, "original_sha": sha, "state": state,
  "error": error or None, "submitted": float(submitted),
  "options": {"suite": True, "check": "quick", "target": target, "device_gate": "any"}}))
' "$id" "$(head_of "$car")" "$target" "$state" "$error" "$submitted"
}
farm_json() { { printf '{"schema":"fm-test-service.v1","requests":['; (IFS=,; printf '%s' "$*"); printf ']}\n'; } > "$CASE/farm.json"; }
inbox_count() { find "$CASE/home/state/$1.inbox" -name '*.msg' 2>/dev/null | wc -l | tr -d ' '; }
ORIGINAL_PATH=$PATH

farm_case farm-pass
car a; join a >/dev/null
worker_meta a
farm_json "$(farm_request r-running a running)"
[ -z "$(queue resolve sweep)" ] || fail 'a running farm request changed the car'
expect_field "$(queue status a)" status needs-quick
farm_json "$(farm_request r-pass a passed)"
out=$(queue resolve sweep)
case "$out" in "front-check passed task=a request=r-pass "*) ;; *) fail "resolve did not report the farm pass: $out" ;; esac
status_out=$(queue status a)
expect_field "$status_out" status ready-to-land
expect_field "$status_out" front_request r-pass:passed
[ "$(wake_count)" = 1 ] || fail 'a farm pass did not wake firstmate exactly once'
[ -z "$(queue resolve sweep)" ] || fail 'a second resolve applied the same farm pass again'
expect_field "$(quick_receipt a)" status ready-to-land
[ "$(wake_count)" = 1 ] || fail 'a duplicate worker receipt after the farm pass woke firstmate again'
if queue receipt a --head "$(head_of a)" --target "$BASE" --reason 'late failure' > "$CASE/refusal" 2>&1; then
  fail 'a worker failure contradicting the farm pass was accepted'
fi
grep -q 'already settled this front check as passed' "$CASE/refusal" || fail 'contradicting report refusal was unclear'
pass 'a farm pass settles the front car as ready-to-land with no worker action, and a duplicate worker receipt is a no-op'

farm_case farm-fail-waiting
car a; join a >/dev/null
car b; join b >/dev/null
worker_meta a
farm_json "$(farm_request r-fail a failed $'suite: \e[31mtest_merge FAILED\e[0m\nmore')"
out=$(queue resolve sweep)
case "$out" in
  "front-check failed task=a request=r-fail "*"reason=testfarm request r-fail failed: suite: test_merge FAILED more") ;;
  *) fail "resolve did not report the sanitized farm failure: $out" ;;
esac
expect_field "$(queue status a)" place 2
expect_field "$(queue status a)" front_request r-fail:failed
expect_field "$(queue status b)" place 1
[ "$(inbox_count a)" = 1 ] || fail 'the failed car owner did not receive exactly one reason message'
grep -q 'moved to back because quick check failed: testfarm request r-fail failed' "$CASE/home/state/a.inbox/"*.msg \
  || fail 'the reason message did not name the farm failure'
dup=$(queue receipt a --head "$(head_of a)" --target "$BASE" --reason 'quick check failed') \
  || fail 'a duplicate worker failure report after the farm failure was refused'
expect_field "$dup" place 2
expect_field "$(queue status b)" place 1
[ "$(inbox_count a)" = 1 ] || fail 'a duplicate worker failure report sent another message'
expect_field "$(quick_receipt b)" status ready-to-land
git -C "$CASE/project" merge -q --ff-only fm/b
prepare a
expect_field "$(queue status a)" status needs-full
pass 'a farm failure moves the front car back, messages its owner once, needs a full rerun later, and a duplicate worker report is a no-op'

farm_case farm-fail-alone
car a; join a >/dev/null
worker_meta a
farm_json "$(farm_request r-alone a conflict)"
case "$(queue resolve sweep)" in "front-check failed task=a request=r-alone "*) ;; *) fail 'a lone farm failure was not applied' ;; esac
expect_field "$(queue status a)" place 1
expect_field "$(queue status a)" status needs-full
[ "$(inbox_count a)" = 1 ] || fail 'a lone failed car owner did not receive exactly one reason message'
grep -q 'keeps the front because quick check failed: testfarm request r-alone failed: conflict' "$CASE/home/state/a.inbox/"*.msg \
  || fail 'the lone failure message did not name the farm failure'
queue resolve sweep >/dev/null
[ "$(inbox_count a)" = 1 ] || fail 'a repeat resolve messaged the lone failed car again'
pass 'a farm failure with no car waiting keeps the front, requires a full rerun, and messages its owner once'

farm_case farm-stale
car a; join a >/dev/null
farm_json "$(farm_request r-old a failed 'old run' 1)" "$(farm_request r-cancel a cancelled)"
[ -z "$(queue resolve sweep)" ] || fail 'a request from before admission or a cancelled request settled the car'
expect_field "$(queue status a)" status needs-quick
other=$(farm_request r-other a passed)
farm_json "${other/$(head_of a)/0000000000000000000000000000000000000000}"
[ -z "$(queue resolve sweep)" ] || fail 'a request for another head settled the car'
expect_field "$(queue status a)" status needs-quick
pass 'only a quick request for the exact head and target, made after admission and not cancelled, settles the car'

farm_case farm-unreachable
car a; join a >/dev/null
before=$(cat "$(find "$CASE/home/data/landing-queue" -name queue -type f -print -quit)")
printf '#!/usr/bin/env bash\necho farm down >&2\nexit 3\n' > "$CASE/bin/testfarm"
out=$(queue resolve sweep)
case "$out" in "front-check unreachable task=a "*"wake=new reason=testfarm status exited 3") ;; *) fail "unreachable farm was not reported: $out" ;; esac
expect_field "$(queue status a)" status needs-quick
[ "$(cat "$(find "$CASE/home/data/landing-queue" -name queue -type f -print -quit)")" = "$before" ] \
  || fail 'an unreachable farm changed the queue snapshot'
grep -q 'check: landing-queue testfarm-unreachable task=a ' "$CASE/home/state/.wake-queue" \
  || fail 'an unreachable farm did not queue a firstmate wake'
[ "$(wake_count)" = 1 ] || fail 'an unreachable farm did not queue exactly one wake'
case "$(queue resolve sweep)" in *'wake=repeat '*) ;; *) fail 'a repeat unreachable read was not marked repeat' ;; esac
[ "$(wake_count)" = 1 ] || fail 'a repeat unreachable read queued another wake'
printf '{"requests": "not a list"}\n' > "$CASE/farm.json"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$CASE/farm.json" > "$CASE/bin/testfarm"
case "$(queue resolve sweep)" in *'reason=testfarm status did not return a request list') ;; *) fail 'a malformed farm status was not rejected' ;; esac
FM_TESTFARM_BIN="$CASE/bin/missing-testfarm" queue resolve sweep | grep -q 'reason=testfarm command not found' \
  || fail 'a missing farm command was not reported'
farm_json "$(farm_request r-back a passed)"
case "$(queue resolve sweep)" in "front-check passed task=a "*) ;; *) fail 'the farm did not settle the car once readable again' ;; esac
pass 'an unreachable or malformed farm leaves the car unchanged and wakes firstmate once until it is readable again'

farm_case farm-sweep
car a; join a >/dev/null
farm_json "$(farm_request r-sweep a passed)"
out=$(FM_HOME="$CASE/home" "$ROOT/bin/fm-landing-queue-sweep.sh")
case "$out" in "front-check passed task=a request=r-sweep "*) ;; *) fail "the sweep did not settle the train: $out" ;; esac
expect_field "$(queue status a)" status ready-to-land
[ -z "$(FM_HOME="$CASE/home" "$ROOT/bin/fm-landing-queue-sweep.sh")" ] || fail 'the sweep ran again inside its cadence'
[ -z "$(FM_HOME="$CASE/home" "$ROOT/bin/fm-landing-queue-sweep.sh" --force)" ] || fail 'a forced sweep reported an already settled train'
[ -z "$(FM_HOME="$TMP_ROOT/no-home" "$ROOT/bin/fm-landing-queue-sweep.sh" --force)" ] || fail 'a home without trains produced output'
pass 'the watcher sweep settles every train from its own snapshot and respects its cadence'

# The real watcher poll drives the sweep and exits with one wake; stop only the
# exact child pid this case started if it has not exited on its own.
farm_case farm-watcher
car a; join a >/dev/null
farm_json "$(farm_request r-watch a passed)"
FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$CASE/watch.out" 2>&1 &
watcher_child=$!
i=0
while [ "$i" -lt 150 ] && kill -0 "$watcher_child" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$watcher_child" 2>/dev/null; then kill "$watcher_child" 2>/dev/null || true; fi
wait "$watcher_child" 2>/dev/null || true
grep -q '^check: landing-queue sweep: front-check passed task=a request=r-watch ' "$CASE/watch.out" \
  || fail "the watcher poll did not settle the front check and wake: $(cat "$CASE/watch.out")"
expect_field "$(queue status a)" status ready-to-land
pass 'the real watcher poll settles a front check from the farm and wakes firstmate'
