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
wake_count() { if [ -f "$CASE/home/state/.wake-queue" ]; then wc -l < "$CASE/home/state/.wake-queue" | tr -d ' '; else echo 0; fi; }

make_case three-cars
for id in a b c; do car "$id" main; join "$id" > "$CASE/$id.out"; done
expect_field "$(cat "$CASE/a.out")" place 1
expect_field "$(cat "$CASE/b.out")" target_ref refs/heads/fm/a
expect_field "$(cat "$CASE/c.out")" place 3
expect_field "$(cat "$CASE/c.out")" target_ref refs/heads/fm/b
[ "$(wake_count)" = 0 ] || fail 'joining emitted a routine wake'
for id in a b c; do prepare "$id"; done
# Higher workers may finish first; only the bottom one rings readiness.
receipt c > "$CASE/c.out"
expect_field "$(cat "$CASE/c.out")" status waiting-to-land
receipt b >/dev/null
[ "$(wake_count)" = 0 ] || fail 'upper receipt woke firstmate'
receipt a > "$CASE/a.out"
expect_field "$(cat "$CASE/a.out")" status ready-to-land
[ "$(wake_count)" = 1 ] || fail 'bottom receipt did not emit exactly one wake'
for id in a b c a; do queue status "$id" >/dev/null; done
[ "$(wake_count)" = 1 ] || fail 'status repeated a readiness wake'
[ "$(git -C "$CASE/project" rev-parse main)" = "$BASE" ] || fail 'queue merged a car'
for id in a b c; do
  git -C "$CASE/project" merge -q --ff-only "fm/$id"
  expect_field "$(queue status "$id")" status landed
done
[ "$(wake_count)" = 3 ] || fail 'landing did not wake each new bottom exactly once'
pass 'three cars stack and land in order without repeated wakes or receipt reruns'

make_case changed-head
car a main; join a >/dev/null; prepare a; receipt a >/dev/null
car b fm/a; join b >/dev/null; prepare b; receipt b >/dev/null
old_a=$(head_of a)
old_b=$(head_of b)
printf 'amended\n' >> "$CASE/a/a.txt"
git -C "$CASE/a" commit -qam amend
out=$(queue status b)
expect_field "$out" target_sha "$(head_of a)"
expect_field "$out" rebase_from "$old_a"
expect_field "$out" status needs-rebase
expect_field "$out" receipt -
if queue receipt b --head "$old_b" --target "$old_a" --receipt "$CASE/b.receipt" > "$CASE/stale.out" 2>&1; then
  fail 'stale target receipt was accepted'
fi
prepare b
receipt b >/dev/null
expect_field "$(queue status a)" status needs-final
[ "$(wake_count)" = 1 ] || fail 'target updates emitted routine wakes'
receipt a >/dev/null
[ "$(wake_count)" = 2 ] || fail 'changed bottom head did not ring again after validation'
pass 'a lower head change invalidates its receipt and assigns the successor a fresh target'

make_case failed-lower
car a main; join a >/dev/null; prepare a
car b fm/a; join b >/dev/null; prepare b; receipt b >/dev/null
car c fm/b; join c >/dev/null; prepare c; receipt c >/dev/null
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
expect_field "$(queue status c)" status needs-rebase
receipt b >/dev/null
prepare c; receipt c >/dev/null
[ "$(wake_count)" = 2 ] || fail 'expected one failure wake and one successor-ready wake'
queue fail a --reason 'same failure' >/dev/null
queue status a >/dev/null
[ "$(wake_count)" = 2 ] || fail 'failed car emitted repeated wakes'
if join a > "$CASE/rejoin.out" 2>&1; then fail 'failed task silently rejoined'; fi
pass 'a failed lower car is removed from targets and successors retain only their own work'
git -C "$CASE/project" merge -q --ff-only fm/b
queue status c >/dev/null
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
expect_field "$out" status needs-final
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
