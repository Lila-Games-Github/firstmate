#!/usr/bin/env bash
# Exercise the worker-owned train through its executable with real Git refs.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-landing-queue)
QUEUE="$ROOT/bin/fm-landing-queue.sh"
make_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/home" "$CASE/project"
  git init -q -b main "$CASE/project"
  git -C "$CASE/project" commit -qm baseline --allow-empty
  BASE=$(git -C "$CASE/project" rev-parse HEAD)
}
car() {
  local id=$1 base=$2
  git -C "$CASE/project" worktree add -qb "fm/$id" "$CASE/$id" "$base"
  printf '%s\n' "$id" > "$CASE/$id/$id.txt"
  git -C "$CASE/$id" add .
  git -C "$CASE/$id" commit -qm "$id"
}
queue() {
  FM_HOME="$CASE/home" "$QUEUE" "$@" --project "$CASE/project" --landing-branch main
}
field() { sed -n "s/^$1=//p"; }
head_of() { git -C "$CASE/project" rev-parse "fm/$1"; }
join() { queue ready "$1" --branch "fm/$1" --head "$(head_of "$1")"; }
prepare() {
  local id=$1 output target previous
  output=$(queue status "$id")
  target=$(printf '%s\n' "$output" | field target_sha)
  previous=$(printf '%s\n' "$output" | field rebase_from)
  git -C "$CASE/$id" rebase --onto "$target" "$previous" >/dev/null 2>&1
  queue ready "$id" --branch "fm/$id" --head "$(head_of "$id")" --target "$target" >/dev/null
}
receipt() {
  local id=$1 sha target
  sha=$(head_of "$id")
  target=$(queue status "$id" | field target_sha)
  printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$sha" > "$CASE/$id.receipt"
  queue receipt "$id" --head "$sha" --target "$target" --receipt "$CASE/$id.receipt"
}
expect_field() {
  local output=$1 key=$2 expected=$3 actual
  actual=$(printf '%s\n' "$output" | field "$key")
  [ "$actual" = "$expected" ] || fail "$key: expected $expected, got $actual"
}
wake_payloads() { cut -f5 "$CASE/home/state/.wake-queue"; }
wake_count() { if [ -f "$CASE/home/state/.wake-queue" ]; then wc -l < "$CASE/home/state/.wake-queue" | tr -d ' '; else echo 0; fi; }

make_case required-gate
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"device":["device.sh"],"phones":["phone"],"landing_branch":"main","landing_gates":["real-phone"]}
EOF
car a main; join a >/dev/null; prepare a
out=$(receipt a)
expect_field "$out" status needs-gate
expect_field "$out" reason 'missing landing gate: real-phone'
[ "$(wake_count)" = 0 ] || fail 'suite green with missing landing gate emitted readiness'
old_head=$(head_of a)
printf 'schema=fm-landing-gate.v1\ngate=real-phone\nsha=%s\ntarget=%s\n' "$old_head" "$BASE" > "$CASE/gate.receipt"
out=$(queue gate a --gate real-phone --head "$old_head" --target "$BASE" --receipt "$CASE/gate.receipt")
expect_field "$out" status ready-to-land
[ "$(wake_count)" = 1 ] || fail 'suite and gate did not emit readiness'
git -C "$CASE/a" commit -qm update --allow-empty
out=$(queue status a)
expect_field "$out" status needs-final
receipt a > "$CASE/new-suite.out"
expect_field "$(cat "$CASE/new-suite.out")" status needs-gate
[ "$(wake_count)" = 1 ] || fail 'old-head gate pass emitted new-head readiness'
if queue gate a --gate real-phone --head "$(head_of a)" --target "$BASE" --receipt "$CASE/gate.receipt" > "$CASE/stale-gate.out" 2>&1; then
  fail 'old-head gate receipt was accepted for new head'
fi
printf 'schema=fm-landing-gate.v1\ngate=real-phone\nsha=%s\ntarget=%s\n' "$(head_of a)" "$BASE" > "$CASE/gate.receipt"
out=$(queue gate a --gate real-phone --head "$(head_of a)" --target "$BASE" --receipt "$CASE/gate.receipt")
expect_field "$out" status ready-to-land
[ "$(wake_count)" = 2 ] || fail 'current suite and gate did not emit renewed readiness'
git -C "$CASE/project" merge -q --ff-only "$old_head"
expect_field "$(queue status a)" status needs-rebase
queue ready a --branch fm/a --head "$(head_of a)" --target "$old_head" >/dev/null
out=$(receipt a)
expect_field "$out" status needs-gate
expect_field "$out" reason 'missing landing gate: real-phone'
if queue gate a --gate real-phone --head "$(head_of a)" --target "$old_head" \
  --receipt "$CASE/gate.receipt" > "$CASE/old-target-gate.out" 2>&1; then
  fail 'old-target gate receipt was accepted for new target'
fi
[ "$(wake_count)" = 2 ] || fail 'old-target gate pass emitted readiness'
printf 'schema=fm-landing-gate.v1\ngate=real-phone\nsha=%s\ntarget=%s\n' "$(head_of a)" "$old_head" > "$CASE/gate.receipt"
expect_field "$(queue gate a --gate real-phone --head "$(head_of a)" --target "$old_head" --receipt "$CASE/gate.receipt")" status ready-to-land
pass 'declared gate holds suite green, invalidates on head or target change, and permits matching readiness'

make_case multiple-gates
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"device":["device.sh"],"phones":["phone"],"landing_branch":"main","landing_gates":["real-phone","device-review"]}
EOF
car a main; join a >/dev/null; prepare a; receipt a >/dev/null
for gate in real-phone device-review; do
  expect_field "$(queue status a)" reason "missing landing gate: $gate"
  printf 'schema=fm-landing-gate.v1\ngate=%s\nsha=%s\ntarget=%s\n' "$gate" "$(head_of a)" "$BASE" > "$CASE/$gate.receipt"
  out=$(queue gate a --gate "$gate" --head "$(head_of a)" --target "$BASE" --receipt "$CASE/$gate.receipt")
done
expect_field "$out" status ready-to-land
[ "$(wake_count)" = 1 ] || fail 'all-gates readiness did not emit one wake'
pass 'every configured gate must pass before readiness'

make_case unrelated-malformed-gate-config
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"device":["device.sh"],"phones":["phone"],"landing_branch":"main","landing_gates":["real-phone"]}
EOF
printf '{"half-edited":' > "$CASE/home/config/test-service/other.json"
printf '[]\n' > "$CASE/home/config/test-service/listed.json"
car a main; join a >/dev/null; prepare a
out=$(receipt a)
expect_field "$out" status needs-gate
expect_field "$out" reason 'missing landing gate: real-phone'
printf '{"half-edited":' > "$CASE/home/config/test-service/project.json"
if queue status a > "$CASE/malformed.out" 2>&1; then
  fail 'malformed matching gate config did not fail closed'
fi
grep -q 'cannot read landing gates for project' "$CASE/malformed.out" || fail 'malformed matching config error was not reported'
pass 'unrelated malformed configs are skipped while a malformed matching config fails closed'

make_case three-cars
for id in a b c; do car "$id" main; join "$id" > "$CASE/$id.out"; done
expect_field "$(cat "$CASE/a.out")" place 1
expect_field "$(cat "$CASE/b.out")" target_ref refs/heads/fm/a
expect_field "$(cat "$CASE/c.out")" place 3
expect_field "$(cat "$CASE/c.out")" target_ref refs/heads/fm/b
[ "$(wake_count)" = 0 ] || fail 'joining emitted a routine wake'
for id in b c; do
  expect_field "$(queue status "$id")" status waiting-for-front
  if receipt "$id" > "$CASE/upper.out" 2>&1; then fail 'upper car submitted final evidence'; fi
  grep -q 'only the bottom car' "$CASE/upper.out" || fail 'upper receipt refusal did not name front requirement'
done
[ "$(wake_count)" = 0 ] || fail 'upper receipt woke firstmate'
[ "$(git -C "$CASE/project" rev-parse main)" = "$BASE" ] || fail 'queue merged a car'
expected_wakes=0
for id in a b c; do
  expect_field "$(queue status "$id")" place 1
  prepare "$id"
  expect_field "$(queue status "$id")" status needs-final
  expect_field "$(receipt "$id")" status ready-to-land
  expected_wakes=$((expected_wakes + 1))
  for check_id in a b c; do queue status "$check_id" >/dev/null; done
  [ "$(wake_count)" = "$expected_wakes" ] || fail 'status repeated a readiness wake'
  git -C "$CASE/project" merge -q --ff-only "fm/$id"
  expect_field "$(queue status "$id")" status landed
done
[ "$(wake_count)" = 3 ] || fail 'landing did not wake each new bottom exactly once'
pass 'three cars validate once each at front and land in order without repeated wakes'

make_case legacy-upper-receipt
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"device":["device.sh"],"phones":["phone"],"landing_branch":"main","landing_gates":["real-phone"]}
EOF
car a main; join a >/dev/null; prepare a
car b fm/a; join b > "$CASE/b.out"
old_a=$(head_of a)
old_b=$(head_of b)
key=$(cat "$CASE/b.out" | field queue)
queue_dir="$CASE/home/data/landing-queue/$key"
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$old_b" > "$CASE/legacy.receipt"
digest=$(git hash-object "$CASE/legacy.receipt")
cp "$CASE/legacy.receipt" "$queue_dir/$digest.receipt"
# Seed an upper receipt using the pre-upgrade v1 format. No migration is owed.
python3 - "$queue_dir/queue" "$digest.receipt" "$old_a" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1]); lines=path.read_text().splitlines()
for i in range(3,len(lines)):
    fields=lines[i].split('\t')
    if fields[0]=='b':
        fields[5:7]=sys.argv[2:4]
        lines[i]='\t'.join(fields)
path.write_text('\n'.join(lines)+'\n')
PY
expect_field "$(queue status b)" status waiting-for-front
expect_field "$(queue status b)" receipt "$queue_dir/$digest.receipt"
printf 'schema=fm-landing-gate.v1\ngate=real-phone\nsha=%s\ntarget=%s\n' "$old_b" "$old_a" > "$CASE/gate.receipt"
if queue gate b --gate real-phone --head "$old_b" --target "$old_a" --receipt "$CASE/gate.receipt" > "$CASE/upper-gate.out" 2>&1; then
  fail 'upper car submitted a configured gate'
fi
grep -q 'only the bottom car' "$CASE/upper-gate.out" || fail 'upper gate refusal did not name front requirement'
for change in first second third; do
  git -C "$CASE/a" commit -qm "$change" --allow-empty
  out=$(queue status b)
  expect_field "$out" status waiting-for-front
  expect_field "$out" receipt -
  expect_field "$out" head "$old_b"
  expect_field "$out" rebase_from "$old_a"
done
[ "$(wake_count)" = 0 ] || fail 'stale legacy upper receipt became ready'
receipt a >/dev/null
printf 'schema=fm-landing-gate.v1\ngate=real-phone\nsha=%s\ntarget=%s\n' "$(head_of a)" "$BASE" > "$CASE/a-gate.receipt"
queue gate a --gate real-phone --head "$(head_of a)" --target "$BASE" --receipt "$CASE/a-gate.receipt" >/dev/null
git -C "$CASE/project" merge -q --ff-only fm/a
expect_field "$(queue status b)" status needs-rebase
prepare b
expect_field "$(receipt b)" status needs-gate
if queue gate b --gate real-phone --head "$(head_of b)" --target "$(head_of a)" --receipt "$CASE/gate.receipt" > "$CASE/legacy-stale.out" 2>&1; then
  fail 'stale legacy gate passed after reaching front'
fi
[ "$(wake_count)" = 1 ] || fail 'stale upper evidence emitted readiness after reaching front'
pass 'v1 upper receipts remain readable but repeated target moves defer validation and stale gates fail closed at front'

make_case changed-head
car a main; join a >/dev/null; prepare a; receipt a >/dev/null
car b fm/a; join b >/dev/null
old_a=$(head_of a)
old_b=$(head_of b)
printf 'amended\n' >> "$CASE/a/a.txt"
git -C "$CASE/a" commit -qam amend
out=$(queue status b)
expect_field "$out" target_sha "$(head_of a)"
expect_field "$out" rebase_from "$old_a"
expect_field "$out" status waiting-for-front
expect_field "$out" receipt -
if queue receipt b --head "$old_b" --target "$old_a" --receipt "$CASE/b.receipt" > "$CASE/stale.out" 2>&1; then
  fail 'stale target receipt was accepted'
fi
expect_field "$(queue status a)" status needs-final
[ "$(wake_count)" = 1 ] || fail 'target updates emitted routine wakes'
receipt a >/dev/null
[ "$(wake_count)" = 2 ] || fail 'changed bottom head did not ring again after validation'
git -C "$CASE/project" merge -q --ff-only fm/a
expect_field "$(queue status b)" status needs-rebase
prepare b; receipt b >/dev/null
pass 'a lower head change leaves upper validation deferred until the successor reaches front'

make_case failed-lower
car a main; join a >/dev/null; prepare a
car b fm/a; join b >/dev/null
car c fm/b; join c >/dev/null
old_a=$(head_of a)
queue fail a --reason 'suite failed' >/dev/null
out=$(queue status b)
expect_field "$out" place 1
expect_field "$out" target_sha "$BASE"
expect_field "$out" rebase_from "$old_a"
expect_field "$out" status needs-rebase
prepare b
[ ! -e "$CASE/b/a.txt" ] || fail 'rebasing the successor retained the failed car'
[ -f "$CASE/b/b.txt" ] || fail 'rebasing the successor dropped its own change'
expect_field "$(queue status c)" status waiting-for-front
receipt b >/dev/null
[ "$(wake_count)" = 2 ] || fail 'expected one failure wake and one successor-ready wake'
queue fail a --reason 'same failure' >/dev/null
queue status a >/dev/null
[ "$(wake_count)" = 2 ] || fail 'failed car emitted repeated wakes'
if join a > "$CASE/rejoin.out" 2>&1; then fail 'failed task silently rejoined'; fi
pass 'a failed lower car is removed from targets and successors retain only their own work'
git -C "$CASE/project" merge -q --ff-only fm/b
expect_field "$(queue status c)" status needs-rebase
prepare c; receipt c >/dev/null
[ "$(wake_count)" = 3 ] || fail 'a later landing repeated the failed car wake'

make_case receipt-race
car a main; join a >/dev/null; prepare a
old_head=$(head_of a)
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$old_head" > "$CASE/old.receipt"
git -C "$CASE/a" commit -qm changed --allow-empty
if queue receipt a --head "$old_head" --target "$BASE" --receipt "$CASE/old.receipt" > "$CASE/race.out" 2>&1; then
  fail 'receipt for old head was accepted'
fi
expect_field "$(queue status a)" status needs-final
[ "$(wake_count)" = 0 ] || fail 'invalid receipt emitted a ready wake'
# The same shared Git repository viewed from a worker must address the same queue.
from_worker=$(FM_HOME="$CASE/home" "$QUEUE" status a --project "$CASE/a" --landing-branch main)
expect_field "$from_worker" queue "$(queue status a | field queue)"
pass 'receipts bind full current heads and worktrees share queue identity'

make_case missing-branch
car a main; join a >/dev/null
git -C "$CASE/project" worktree remove "$CASE/a"
git -C "$CASE/project" branch -D fm/a >/dev/null
expect_field "$(queue status a)" status failed
queue status a >/dev/null
[ "$(wake_count)" = 1 ] || fail 'missing branch did not emit one failure wake'
pass 'a missing local branch fails visibly rather than silently retargeting a receipt'

make_case concurrent
car a main; car b main
join a > "$CASE/a.out" &
first=$!
join b > "$CASE/b.out" &
second=$!
wait "$first"; wait "$second"
places=$( { queue status a | field place; queue status b | field place; } | sort | tr '\n' ' ')
[ "$places" = '1 2 ' ] || fail "concurrent joins lost a car: $places"
pass 'concurrent worker admission serializes without losing either car'

make_case independent-targets
git -C "$CASE/project" branch proto/landing
car a main; join a > "$CASE/a.out"
car b main
out=$(FM_HOME="$CASE/home" "$QUEUE" ready b --project "$CASE/project" --landing-branch proto/landing \
  --branch fm/b --head "$(head_of b)")
expect_field "$out" place 1
[ "$(printf '%s\n' "$out" | field queue)" != "$(cat "$CASE/a.out" | field queue)" ] || fail 'two landing branches shared one queue'
mkdir -p "$CASE/home/state"
printf 'landing_branch=proto/landing\n' > "$CASE/home/state/b.meta"
out=$(FM_HOME="$CASE/home" "$QUEUE" status b --project "$CASE/b")
expect_field "$out" landing_branch proto/landing
pass 'landing branches have independent queues and recorded targets work from worker checkouts'

make_case known-red
car a main; join a >/dev/null; prepare a
health_key=$(printf '%s\n%s\n' "$CASE/project" main | git hash-object --stdin)
mkdir -p "$CASE/home/data/landing-health"
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=known-red\n' "$BASE" \
  > "$CASE/home/data/landing-health/$health_key.receipt"
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=known-red\n' "$(head_of a)" > "$CASE/red.receipt"
out=$(queue receipt a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/red.receipt")
expect_field "$out" status ready-to-land
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=new-red\n' "$(head_of a)" > "$CASE/new-red.receipt"
out=$(queue receipt a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/new-red.receipt")
expect_field "$out" status red-receipt
expect_field "$out" reason 'receipt names failures outside the landing-health baseline'
[ "$(wake_count)" = 1 ] || fail 'new failures emitted readiness'
out=$(queue receipt a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/red.receipt")
expect_field "$out" status ready-to-land
[ "$(wake_count)" = 2 ] || fail 'renewed valid readiness did not emit a fresh transition'
pass 'queue readiness preserves the merge gate policy for existing red baselines'

make_case interrupted
car a main; join a >/dev/null
mkdir -p "$CASE/tools"
cat > "$CASE/tools/mv" <<'EOF'
#!/usr/bin/env bash
touch "$FM_TEST_QUEUE_BARRIER"
sleep 0.3
exec "$FM_TEST_REAL_MV" "$@"
EOF
chmod +x "$CASE/tools/mv"
FM_TEST_REAL_MV=$(command -v mv)
export FM_TEST_REAL_MV
FM_HOME="$CASE/home" FM_TEST_QUEUE_BARRIER="$CASE/barrier" PATH="$CASE/tools:$PATH" \
  "$QUEUE" status a --project "$CASE/project" --landing-branch main > "$CASE/interrupted.out" 2>&1 &
interrupted=$!
for ((attempt=0; attempt<100; attempt++)); do
  [ ! -f "$CASE/barrier" ] || break
  sleep 0.1
done
[ -f "$CASE/barrier" ] || fail 'queue did not reach snapshot publication'
for ((attempt=0; attempt<50; attempt++)); do
  kill -TERM "$interrupted" 2>/dev/null || true
  sleep 0.01
done
rc=0
wait "$interrupted" || rc=$?
expect_code 143 "$rc" 'signal barrage must preserve the protected shutdown result'
expect_field "$(queue status a)" status needs-final
if find "$CASE/home/data/landing-queue" -name '.queue.*' | grep -q .; then fail 'signal left a snapshot publisher temp'; fi
pass 'repeated shutdown signals preserve the snapshot and release both locks for the next worker'

make_case red-without-baseline
car a main; join a >/dev/null; prepare a
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=known-red\n' "$(head_of a)" > "$CASE/red.receipt"
out=$(queue receipt a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/red.receipt")
expect_field "$out" status needs-baseline
expect_field "$out" reason 'landing tip has no recorded landing-health baseline'
for id in a a; do queue status "$id" >/dev/null; done
[ "$(wake_count)" = 1 ] || fail 'missing baseline did not emit exactly one wake'
case "$(wake_payloads)" in
  "check: landing-queue needs-baseline task=a "*"tip=$BASE "*) ;;
  *) fail "unexpected baseline wake: $(wake_payloads)" ;;
esac
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=known-red\n' "$(head_of a)" > "$CASE/not-tip.receipt"
if queue baseline a --receipt "$CASE/not-tip.receipt" > "$CASE/not-tip.out" 2>&1; then fail 'a non-tip baseline was accepted'; fi
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=known-red\n' "$BASE" > "$CASE/tip.receipt"
out=$(queue baseline a --receipt "$CASE/tip.receipt")
expect_field "$out" status ready-to-land
[ "$(git -C "$CASE/project" rev-parse main)" = "$BASE" ] || fail 'recording a baseline moved the landing branch'
[ "$(wake_count)" = 2 ] || fail 'recorded baseline did not ring readiness'
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$BASE" > "$CASE/conflict.receipt"
if queue baseline a --receipt "$CASE/conflict.receipt" > "$CASE/conflict.out" 2>&1; then fail 'a conflicting baseline was accepted'; fi
expect_field "$(queue status a)" status ready-to-land
pass 'a red receipt on an unrecorded red tip wakes firstmate once and resolves from a recorded tip baseline'

make_case baseline-regression
car a main; join a >/dev/null; prepare a
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=2\nfailure=known-red\nfailure=new-red\n' "$(head_of a)" > "$CASE/red.receipt"
expect_field "$(queue receipt a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/red.receipt")" status needs-baseline
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=known-red\n' "$BASE" > "$CASE/tip.receipt"
out=$(queue baseline a --receipt "$CASE/tip.receipt")
expect_field "$out" status red-receipt
expect_field "$out" reason 'receipt names failures outside the landing-health baseline'
git -C "$CASE/a" commit -qm fix --allow-empty
expect_field "$(queue status a)" status needs-final
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=known-red\n' "$(head_of a)" > "$CASE/fixed.receipt"
out=$(queue receipt a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/fixed.receipt")
expect_field "$out" status ready-to-land
[ "$(wake_count)" = 2 ] || fail 'expected one baseline wake and one readiness wake'
pass 'a regression found after recording a missing baseline stays with its worker under the same task id'

make_case empty-car
git -C "$CASE/project" branch fm/empty
if queue ready empty --branch fm/empty --head "$BASE" > "$CASE/empty.out" 2>&1; then fail 'a car with nothing to land was admitted'; fi
if queue status empty > "$CASE/empty-status.out" 2>&1; then fail 'a refused empty car joined the queue'; fi
pass 'a head already in the landing tip is refused at admission rather than reported landed'

make_case red-receipt-fix
car a main; join a >/dev/null; prepare a
health_key=$(printf '%s\n%s\n' "$CASE/project" main | git hash-object --stdin)
mkdir -p "$CASE/home/data/landing-health"
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$BASE" > "$CASE/home/data/landing-health/$health_key.receipt"
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=new-red\n' "$(head_of a)" > "$CASE/red.receipt"
out=$(queue receipt a --head "$(head_of a)" --target "$BASE" --receipt "$CASE/red.receipt")
expect_field "$out" status red-receipt
expect_field "$(queue status a)" status red-receipt
[ "$(wake_count)" = 0 ] || fail 'a worker-owned regression woke firstmate'
git -C "$CASE/a" commit -qm fix --allow-empty
expect_field "$(queue status a)" status needs-final
receipt a >/dev/null
expect_field "$(queue status a)" status ready-to-land
pass 'a regression receipt stays with the worker until a fixed head is finalized'

make_case landed-then-deleted
car a main; join a >/dev/null; prepare a; receipt a >/dev/null
git -C "$CASE/project" merge -q --ff-only fm/a
git -C "$CASE/project" worktree remove "$CASE/a"
git -C "$CASE/project" branch -D fm/a >/dev/null
out=$(queue status a)
expect_field "$out" status landed
expect_field "$out" reason -
[ "$(wake_count)" = 1 ] || fail 'a landed and deleted branch emitted a failure wake'
pass 'a branch deleted after landing reconciles as landed rather than failed'

make_case distinct-reasons
car a main; join a >/dev/null
car b main; join b >/dev/null
git -C "$CASE/project" worktree remove "$CASE/b"
git -C "$CASE/project" branch -D fm/b >/dev/null
out=$(queue fail a --reason 'suite failed')
expect_field "$out" status failed
expect_field "$out" reason 'suite failed'
expect_field "$(queue status b)" status failed
[ "$(wake_count)" = 2 ] || fail 'expected one failure wake per car'
wake_payloads | grep -qx 'check: landing-queue failed task=a .* reason=suite failed' \
  || fail "explicit failure reason missing: $(wake_payloads)"
wake_payloads | grep -qx 'check: landing-queue failed task=b .* reason=local branch missing' \
  || fail "missing-branch reason misattributed: $(wake_payloads)"
pass 'one invocation attributes explicit and missing-branch failure reasons to their own cars'
out=$(queue status b)
expect_field "$out" status failed
expect_field "$out" reason 'local branch missing'
pass 'a detected missing-branch reason survives into later status calls'

make_case persisted-reason
car a main; join a >/dev/null; prepare a
if queue fail a --reason $'two\nlines' > "$CASE/multiline.out" 2>&1; then fail 'multi-line reason was accepted'; fi
if queue fail a --reason $'tab\there' > "$CASE/tab.out" 2>&1; then fail 'tabbed reason was accepted'; fi
expect_field "$(queue status a)" status needs-final
queue fail a --reason 'new-red: failure=parser, failure=io' >/dev/null
out=$(FM_HOME="$CASE/home" "$QUEUE" status a --project "$CASE/a" --landing-branch main)
expect_field "$out" status failed
expect_field "$out" reason 'new-red: failure=parser, failure=io'
[ "$(wake_count)" = 1 ] || fail 'the worker status repeated the failure wake'
pass 'a supervisor-recorded failure reason reaches the worker through a later status call'
