#!/usr/bin/env bash
# Exercise pre-queue admission and front checks through the queue executable.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_SKIP_TESTFARM:-}" = 1 ] && [ "${FM_LANDING_QUEUE_TEST_ONLY:-}" != spec ]; then
  printf '%s\n' 'skip: landing queue compatibility checks require the private testfarm checkout'
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-landing-queue)
QUEUE="$ROOT/bin/fm-landing-queue.sh"
export FM_LANDING_TRAIN=off
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
queue() { FM_HOME="$CASE/home" FM_LANDING_TRAIN=off "$QUEUE" "$@" --project "$CASE/project" --landing-branch main; }
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
if [ "${FM_LANDING_QUEUE_TEST_ONLY:-}" != farm ] && [ "${FM_LANDING_QUEUE_TEST_ONLY:-}" != spec ]; then
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

make_case rebase-basis
car a
admitted=$(head_of a)
join a >/dev/null
printf 'unrelated landing change\n' > "$CASE/project/landing.txt"
git -C "$CASE/project" add landing.txt
git -C "$CASE/project" commit -qm landing
prepare a
out=$(queue status a)
expect_field "$out" status needs-quick
expect_field "$out" rebase_basis "$admitted"
pre_receipt=$(find "$CASE/home/data/landing-queue" -name pre-receipt-a -type f -print -quit)
[ -n "$pre_receipt" ] || fail 'admission receipt was not retained'
rm "$pre_receipt"
out=$(queue status a)
expect_field "$out" status needs-full
expect_field "$out" rebase_basis -
pass 'a clean rebased front car exposes its admitted full-suite basis, and missing evidence requires a full rerun'

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
out=$(join a --gate-receipt real-phone="$CASE/real-phone.gate" --gate-receipt m31="$CASE/m31.gate")
expect_field "$out" status needs-quick
expect_field "$out" gate_exemption -
expect_field "$(queue status a)" gate_exemption -
expect_field "$(quick_receipt a)" status ready-to-land
pass 'non-exempt front quick check retains the phone gate after admission'

make_case docs-only-phone-exemption
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"landing_branch":"main","landing_gates":["real-phone"],"documentation_path_globs":["**/*.md"]}
EOF
git -C "$CASE/project" worktree add -qb fm/docs "$CASE/docs-only" main
mkdir -p "$CASE/docs-only/docs"
printf 'guide\n' > "$CASE/docs-only/docs/guide.md"
git -C "$CASE/docs-only" add .
git -C "$CASE/docs-only" commit -qm docs
full_receipt docs
out=$(queue ready docs --branch fm/docs --head "$(head_of docs)" --target "$BASE" --receipt "$CASE/docs.full")
expect_field "$out" status needs-quick
expect_field "$out" gate_exemption 'real-phone: all changed paths match documentation_path_globs'
expect_field "$(queue status docs)" gate_exemption 'real-phone: all changed paths match documentation_path_globs'
queue_file=$(find "$CASE/home/data/landing-queue" -name queue -type f -print -quit)
[ "$(tail -1 "$queue_file" | cut -f 12)" = 'real-phone: all changed paths match documentation_path_globs' ] \
  || fail 'docs exemption was not persisted on the queue row'
expect_field "$(quick_receipt docs)" status ready-to-land
pass 'a docs-only car admits on its suite receipt and records the phone exemption'

make_case phone-path-required
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"landing_branch":"main","landing_gates":["real-phone"],"documentation_path_globs":["**/*.md"],"real_phone_path_globs":["**/*.tscn","**/input/*.gd"]}
EOF
git -C "$CASE/project" worktree add -qb fm/ui "$CASE/ui" main
mkdir -p "$CASE/ui/scenes"
printf 'scene\n' > "$CASE/ui/scenes/main.tscn"
git -C "$CASE/ui" add .
git -C "$CASE/ui" commit -qm ui
if join ui > "$CASE/refusal" 2>&1; then fail 'phone-relevant scene skipped real-phone'; fi
grep -q 'requires pre-queue landing gate: real-phone' "$CASE/refusal" || fail 'phone path gate refusal was unclear'
printf 'schema=fm-landing-gate.v1\ngate=real-phone\nsha=%s\ntarget=%s\n' "$(head_of ui)" "$BASE" > "$CASE/real-phone.gate"
expect_field "$(join ui --gate-receipt real-phone="$CASE/real-phone.gate")" gate_exemption -
pass 'a phone-relevant scene requires the real-phone gate'

make_case phone-path-exempt
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"landing_branch":"main","landing_gates":["real-phone"],"documentation_path_globs":["**/*.md"],"real_phone_path_globs":["**/*.tscn","**/input/*.gd"]}
EOF
git -C "$CASE/project" worktree add -qb fm/rules "$CASE/rules" main
mkdir -p "$CASE/rules/src"
printf 'rules\n' > "$CASE/rules/src/rules.gd"
git -C "$CASE/rules" add .
git -C "$CASE/rules" commit -qm rules
out=$(join rules)
expect_field "$out" status needs-quick
expect_field "$out" gate_exemption 'real-phone: no changed paths match real_phone_path_globs'
queue_file=$(find "$CASE/home/data/landing-queue" -name queue -type f -print -quit)
[ "$(tail -1 "$queue_file" | cut -f 12)" = 'real-phone: no changed paths match real_phone_path_globs' ] \
  || fail 'phone path exemption was not persisted on the queue row'
pass 'a nonmatching rules change is exempt even when it is not documentation'

make_case phone-path-invalid
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"landing_branch":"main","landing_gates":["real-phone"],"real_phone_path_globs":["../unsafe/*.tscn"]}
EOF
car a
if join a > "$CASE/refusal" 2>&1; then fail 'unsafe phone path glob admitted a car'; fi
grep -q 'real_phone_path_globs must list safe relative globs' "$CASE/refusal" || fail 'unsafe phone path glob rejection was unclear'
if python3 "$ROOT/bin/fm-docs-gate.py" "$CASE/home/config/test-service" project "$CASE/project" deadbeef "$(head_of a)" > "$CASE/bad-diff" 2>&1; then
  fail 'unsafe phone path glob allowed an invalid Git diff'
fi
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"landing_branch":"main","landing_gates":["real-phone"],"real_phone_path_globs":["**/*.tscn"]}
EOF
if python3 "$ROOT/bin/fm-docs-gate.py" "$CASE/home/config/test-service" project "$CASE/project" deadbeef "$(head_of a)" > "$CASE/bad-diff" 2>&1; then
  fail 'invalid Git diff qualified for phone path exemption'
fi
grep -q 'cannot read changed paths from Git diff' "$CASE/bad-diff" || fail 'invalid Git diff rejection was unclear'
pass 'invalid phone path glob and Git diff fail closed'

make_case docs-other-gate-required
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"landing_branch":"main","landing_gates":["real-phone","m31"],"documentation_path_globs":["**/*.md"]}
EOF
git -C "$CASE/project" worktree add -qb fm/guide "$CASE/guide" main
printf 'guide\n' > "$CASE/guide/guide.md"
git -C "$CASE/guide" add .
git -C "$CASE/guide" commit -qm guide
if join guide > "$CASE/refusal" 2>&1; then fail 'docs-only car skipped a non-phone gate'; fi
grep -q 'requires pre-queue landing gate: m31' "$CASE/refusal" || fail 'docs-only car lacked benchmark refusal'
pass 'docs-only exemption preserves other configured gates'

make_case docs-front-full
mkdir -p "$CASE/home/config/test-service" "$CASE/project/docs"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"landing_branch":"main","landing_gates":["real-phone"],"documentation_path_globs":["**/*.md"]}
EOF
printf 'one\ntwo\nthree\n' > "$CASE/project/docs/guide.md"
git -C "$CASE/project" add .
git -C "$CASE/project" commit -qm guide-baseline
BASE=$(tip)
git -C "$CASE/project" worktree add -qb fm/frontdocs "$CASE/frontdocs" main
sed -i 's/one/changed-one/' "$CASE/frontdocs/docs/guide.md"
git -C "$CASE/frontdocs" commit -qam docs-edit
join frontdocs >/dev/null
sed -i 's/three/changed-three/' "$CASE/project/docs/guide.md"
git -C "$CASE/project" commit -qam tip-docs-edit
prepare frontdocs
expect_field "$(queue status frontdocs)" status needs-full
expect_field "$(full_front frontdocs)" status ready-to-land
pass 'a docs-only full front rerun keeps its phone exemption'

make_case mixed-phone-required
mkdir -p "$CASE/home/config/test-service"
cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"landing_branch":"main","landing_gates":["real-phone"],"documentation_path_globs":["**/*.md"]}
EOF
git -C "$CASE/project" worktree add -qb fm/mixed "$CASE/docs" main
printf 'guide\n' > "$CASE/docs/guide.md"
printf 'code\n' > "$CASE/docs/code.txt"
git -C "$CASE/docs" add .
git -C "$CASE/docs" commit -qm mixed
if join mixed > "$CASE/refusal" 2>&1; then fail 'mixed car skipped real-phone'; fi
grep -q 'requires pre-queue landing gate: real-phone' "$CASE/refusal" || fail 'mixed car lacked phone refusal'
pass 'one non-documentation path keeps the phone gate'

for extension in gd tscn; do
  make_case "docs-non-markdown-$extension"
  mkdir -p "$CASE/home/config/test-service"
  cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"landing_branch":"main","landing_gates":["real-phone"],"documentation_path_globs":["**/*.md"]}
EOF
  git -C "$CASE/project" worktree add -qb fm/nonmarkdown "$CASE/docs" main
  mkdir -p "$CASE/docs/docs"
  printf 'scene\n' > "$CASE/docs/docs/scene.$extension"
  git -C "$CASE/docs" add .
  git -C "$CASE/docs" commit -qm nonmarkdown
  if join nonmarkdown > "$CASE/refusal" 2>&1; then fail "docs/$extension skipped real-phone"; fi
  grep -q 'requires pre-queue landing gate: real-phone' "$CASE/refusal" || fail "docs/$extension lacked phone refusal"
done
pass '.gd and .tscn files under docs retain the phone gate'

cat > "$CASE/home/config/test-service/project.json" <<'EOF'
{"suite":["suite.sh"],"landing_branch":"main","landing_gates":["real-phone"],"documentation_path_globs":["../unsafe/*.md"]}
EOF
if python3 "$ROOT/bin/fm-docs-gate.py" "$CASE/home/config/test-service" project "$CASE/project" "$BASE" "$(head_of nonmarkdown)" > "$CASE/bad-config.out" 2>&1; then
  fail 'unsafe documentation glob was accepted'
fi
grep -q 'must list safe relative globs' "$CASE/bad-config.out" || fail 'bad glob rejection was unclear'
pass 'an unsafe documentation glob is rejected'

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

make_case unblock-priority
for id in a b; do car "$id"; join "$id" >/dev/null; done
car i; expect_field "$(join i --priority infra)" place 2
car u; expect_field "$(join u --priority unblock)" place 2
expect_field "$(queue status u)" priority unblock
car v; expect_field "$(join v --priority unblock)" place 3
car j; expect_field "$(join j --priority infra)" place 5
expect_field "$(queue status a)" place 1
expect_field "$(queue status i)" place 4
expect_field "$(queue status b)" place 6
pass 'an unblock car admits directly behind the front, FIFO among unblock cars, and infra cars queue behind unblock cars'

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

if [ "${FM_LANDING_QUEUE_TEST_ONLY:-}" != spec ]; then
# --- front check settled from the test farm, with no worker action -----------
# The fixture farm prints $CASE/farm.json as `testfarm status --json --no-probe`
# does; FM_TESTFARM_BIN points the queue at it. A worker meta and a fake tmux let
# fm-send deliver owner messages into state/<id>.inbox.
farm_case() {
  make_case "$1"
  mkdir -p "$CASE/bin" "$CASE/compat" "$CASE/home/state"
  cat > "$CASE/compat/fm-test-service.py" <<'SERVICE'
import sys
if sys.argv[1] != 'landing-gates-for-repo':
    raise SystemExit('unexpected compatibility call')
SERVICE
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
farm_rebase_request() {
  local id=$1 car=$2 state=$3 basis=$4 target
  target=$(queue status "$car" | field target_sha)
  python3 -I -c '
import json, sys, time
rid, sha, target, state, basis = sys.argv[1:6]
print(json.dumps({"id": rid, "seq": 2, "sha": sha, "original_sha": sha, "state": state,
  "submitted": time.time() + 5, "options": {"suite": False, "check": "full",
  "device_gate": "any", "rebase_basis": basis,
  "phone_admission": {"kind": "rebased-quick", "basis": basis, "target": target}}}))
' "$id" "$(head_of "$car")" "$target" "$state" "$basis"
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

farm_case farm-rebase-basis
car a
admitted=$(head_of a)
join a >/dev/null
printf 'unrelated landing change\n' > "$CASE/project/landing.txt"
git -C "$CASE/project" add landing.txt
git -C "$CASE/project" commit -qm landing
prepare a
expect_field "$(queue status a)" rebase_basis "$admitted"
worker_meta a
farm_json "$(farm_request r-exempt-quick a passed)"
[ -z "$(queue resolve sweep)" ] || fail 'exempt quick request completed the queue before rebase phone admission'
expect_field "$(queue status a)" status needs-quick
farm_json "$(farm_request r-exempt-quick a passed)" "$(farm_rebase_request r-rebased-phone a passed "$admitted")"
case "$(queue resolve sweep)" in "front-check passed task=a request=r-rebased-phone "*) ;; *) fail 'accepted rebase phone result did not settle the front car' ;; esac
expect_field "$(queue status a)" status ready-to-land
pass 'the farm accepted rebase phone request settles only after the earlier quick result'

# Submit through the Firstmate shim into a stub farm. Its refusal preserves the
# farm's reason, and the worker's exact-head fallback produces queue evidence.
farm_case farm-refused-patch
car a
admitted=$(head_of a)
join a >/dev/null
printf 'unrelated landing change\n' > "$CASE/project/landing.txt"
git -C "$CASE/project" add landing.txt
git -C "$CASE/project" commit -qm landing
prepare a
printf 'changed patch\n' > "$CASE/a/a.txt"
git -C "$CASE/a" commit -qam changed-patch
queue ready a --branch fm/a --head "$(head_of a)" --target "$(tip)" >/dev/null
mkdir -p "$CASE/farm-checkout/compat"
cat > "$CASE/farm-checkout/compat/fm-test-service.py" <<'FARM_STUB'
import os, pathlib, subprocess, sys
args = sys.argv[1:]
with open(os.environ['STUB_FARM_LOG'], 'a') as log:
    log.write(' '.join(args) + '\n')
if args[0] != 'submit':
    raise SystemExit('unexpected stub farm command')
sha = args[3]
if '--rebase-basis' in args:
    basis = args[args.index('--rebase-basis') + 1]
    repo = args[2]
    if os.environ.get('STUB_FARM_MISSING') == '1':
        raise SystemExit('error: phone gate requires a passed full suite for this project and exact commit; rebase basis has no green farm full suite')
    old = subprocess.check_output(['git', '-C', repo, 'show', basis + ':a.txt'])
    new = subprocess.check_output(['git', '-C', repo, 'show', sha + ':a.txt'])
    if old != new:
        raise SystemExit('error: phone gate requires a passed full suite for this project and exact commit; rebase changed the patch')
    print('admitted-phone')
elif '--suite' in args:
    path = pathlib.Path(args[args.index('--receipt') + 1])
    path.write_text('schema=fm-full-suite.v1\nsha=' + sha + '\nfailures=0\n')
    print('fallback-full')
else:
    raise SystemExit('unexpected stub farm request')
FARM_STUB
export STUB_FARM_LOG="$CASE/farm-submits.log"
if TESTFARM_CHECKOUT="$CASE/farm-checkout" "$ROOT/bin/fm-test-service.py" submit project "$CASE/a" "$(head_of a)" \
  --task a --device-gate any --rebase-basis "$admitted" > "$CASE/refusal" 2>&1; then
  fail 'stub farm accepted a changed rebased patch'
fi
grep -q 'rebase changed the patch' "$CASE/refusal" || fail 'farm refusal reason was hidden by the shim'
TESTFARM_CHECKOUT="$CASE/farm-checkout" "$ROOT/bin/fm-test-service.py" submit project "$CASE/a" "$(head_of a)" \
  --task a --suite --device-gate any --receipt "$CASE/fallback.full" > "$CASE/fallback.request"
[ "$(cat "$CASE/fallback.request")" = fallback-full ] || fail 'exact-head fallback did not submit'
out=$(queue receipt a --head "$(head_of a)" --target "$(tip)" --receipt "$CASE/fallback.full")
expect_field "$out" status ready-to-land
grep -q -- "--rebase-basis $admitted" "$STUB_FARM_LOG" || fail 'shim did not pass the basis SHA through'
pass 'stub farm rejects a changed patch with its reason, and an exact-head full suite settles the front car'

stub_checkout="$CASE/farm-checkout"
farm_case farm-missing-basis
car a
admitted=$(head_of a)
join a >/dev/null
printf 'unrelated landing change\n' > "$CASE/project/landing.txt"
git -C "$CASE/project" add landing.txt
git -C "$CASE/project" commit -qm landing
prepare a
cp -a "$stub_checkout" "$CASE/farm-checkout"
export STUB_FARM_LOG="$CASE/farm-submits.log"
accepted=$(TESTFARM_CHECKOUT="$CASE/farm-checkout" "$ROOT/bin/fm-test-service.py" submit project "$CASE/a" "$(head_of a)" \
  --task a --device-gate any --rebase-basis "$admitted")
[ "$accepted" = admitted-phone ] || fail 'stub farm did not accept a clean rebased patch'
if STUB_FARM_MISSING=1 TESTFARM_CHECKOUT="$CASE/farm-checkout" "$ROOT/bin/fm-test-service.py" submit project "$CASE/a" "$(head_of a)" \
  --task a --device-gate any --rebase-basis "$admitted" > "$CASE/refusal" 2>&1; then
  fail 'stub farm accepted a basis without its green full-suite result'
fi
grep -q 'rebase basis has no green farm full suite' "$CASE/refusal" || fail 'missing basis refusal reason was hidden by the shim'
pass 'stub farm accepts a clean rebase and refuses a basis missing its farm full-suite result'

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
expect_field "$(FM_TESTFARM_TIMEOUT=bogus queue status a)" status needs-quick
FM_TESTFARM_TIMEOUT=0 queue resolve sweep | grep -q 'reason=FM_TESTFARM_TIMEOUT must be a whole number of seconds from 1 to 60' \
  || fail 'an invalid farm timeout was not reported as an unreadable farm'
expect_field "$(queue status a)" status needs-quick
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

# A sweep that cannot run (here its cadence stamp is unwritable) wakes once per
# distinct error, not on every poll.
# Each round acknowledges what the watcher delivered, as firstmate's handling
# turn does, so the next round starts from a clean wake queue.
ack_delivered() {
  local err="$CASE/drain.err" sequence generation
  FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 0
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 0
  FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}
watch_round() { # <output> <tenths>
  FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$1" 2>&1 &
  watcher_child=$!
  i=0
  while [ "$i" -lt "$2" ] && kill -0 "$watcher_child" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$watcher_child" 2>/dev/null; then kill "$watcher_child" 2>/dev/null || true; fi
  wait "$watcher_child" 2>/dev/null || true
  ack_delivered
}
farm_case farm-watcher-error
car a; join a >/dev/null
mkdir "$CASE/home/state/.last-landing-sweep"
watch_round "$CASE/watch-1.out" 100
watch_round "$CASE/watch-2.out" 40
if grep -q '^check: ' "$CASE/watch-2.out"; then fail "the second round still woke: $(cat "$CASE/watch-2.out")"; fi
grep -q '^check: landing-queue sweep failed: error: cannot record the sweep stamp ' "$CASE/watch-1.out" \
  || fail "a failing sweep did not wake firstmate: $(cat "$CASE/watch-1.out")"
if grep -q 'landing-queue sweep failed' "$CASE/watch-2.out"; then fail 'an unchanged sweep failure woke firstmate again'; fi
rmdir "$CASE/home/state/.last-landing-sweep"
farm_json "$(farm_request r-recover a passed)"
watch_round "$CASE/watch-3.out" 150
grep -q '^check: landing-queue sweep: front-check passed task=a request=r-recover ' "$CASE/watch-3.out" \
  || fail "the watcher did not resume settling after the sweep recovered: $(cat "$CASE/watch-3.out")"
[ ! -e "$CASE/home/state/.last-landing-sweep-error" ] || fail 'a successful sweep did not clear the recorded failure'
pass 'a sweep that cannot run wakes firstmate once per distinct error and recovers on its own'

# --- firstmate steps the front car back without failing it --------------------
evidence_digest() { # <car>: every admission and history record the car keeps
  local dir
  dir=$(dirname "$(find "$CASE/home/data/landing-queue" -name queue -type f -print -quit)")
  for name in pre-$1 pre-head-$1 full-$1 farm-$1; do
    printf '%s:' "$name"
    if [ -f "$dir/$name" ]; then cat -- "$dir/$name"; else printf 'absent\n'; fi
  done
}
farm_case stepback
car a; join a --priority infra >/dev/null
car b; join b >/dev/null
worker_meta a; worker_meta b
farm_json "$(farm_request r-a a passed)"
case "$(queue resolve sweep)" in "front-check passed task=a request=r-a "*) ;; *) fail 'the front check did not pass before the step-back' ;; esac
expect_field "$(queue status a)" status ready-to-land
evidence_before=$(evidence_digest a)
wakes_before=$(wake_count)
out=$(queue step-back a --reason 'the stall fix must land first')
expect_field "$out" place 2
expect_field "$out" status waiting-for-front
expect_field "$out" receipt -
expect_field "$out" reason -
expect_field "$out" priority infra
expect_field "$out" front_request r-a:passed
expect_field "$(queue status b)" place 1
expect_field "$(queue status b)" status needs-quick
[ "$(evidence_digest a)" = "$evidence_before" ] || fail 'step-back changed the admission evidence or farm history'
[ "$(wake_count)" = "$wakes_before" ] || fail 'step-back woke firstmate as if the car had failed'
[ "$(inbox_count a)" = 1 ] || fail 'the stepped-back owner did not receive exactly one message'
grep -q 'task=a stepped back from the front to place 2 because the stall fix must land first. It is not failed' \
  "$CASE/home/state/a.inbox/"*.msg || fail 'the step-back message did not name the step-back and its reason'
[ "$(inbox_count b)" = 1 ] || fail 'the new front car did not receive its parked-car message'
queue status a >/dev/null; queue status b >/dev/null
[ "$(inbox_count a)" = 1 ] || fail 'a later invocation messaged the stepped-back car again'
pass 'step-back sends the front car to place 2 with its evidence and history intact, unfailed, and messages its owner once'

if queue step-back a > "$CASE/refusal" 2>&1; then fail 'step-back accepted a car that is not at the front'; fi
grep -q 'only the front car can step back' "$CASE/refusal" || fail 'non-front refusal was unclear'
if queue step-back missing > "$CASE/refusal" 2>&1; then fail 'step-back accepted an unknown car'; fi
[ "$(queue status a | field place)" = 2 ] || fail 'a refused step-back moved a car'
make_case stepback-alone
car a; join a >/dev/null
if queue step-back a > "$CASE/refusal" 2>&1; then fail 'step-back accepted a front car with nobody waiting'; fi
grep -q 'no other car is waiting' "$CASE/refusal" || fail 'lone-car refusal was unclear'
expect_field "$(queue status a)" status needs-quick
car b; join b >/dev/null
queue fail a --reason 'leaving' >/dev/null
if queue step-back a > "$CASE/refusal" 2>&1; then fail 'step-back accepted a failed car'; fi
pass 'step-back refuses a waiting car, an unknown car, a lone front car, and a failed car'

# Back at the front against the same target, the car must check again: neither
# its old receipt, its applied farm pass, nor a request made before it stepped
# back settles it.
farm_case stepback-recheck
car a; join a >/dev/null
car b; join b >/dev/null
worker_meta a
farm_json "$(farm_request r-a a passed)"
queue resolve sweep >/dev/null
expect_field "$(queue status a)" status ready-to-land
late_at=$(date +%s)
farm_json "$(farm_request r-a a passed)" "$(farm_request r-late a running '' "$late_at")"
queue step-back a >/dev/null
expect_field "$(queue fail b --reason 'its own fix needed')" status failed
expect_field "$(queue status a)" place 1
expect_field "$(queue status a)" status needs-quick
farm_json "$(farm_request r-a a passed)" "$(farm_request r-late a passed '' "$late_at")"
[ -z "$(queue resolve sweep)" ] || fail 'a request from before the step-back settled the returning car'
expect_field "$(queue status a)" status needs-quick
expect_field "$(quick_receipt a)" status ready-to-land
pass 'a stepped-back car returning against the same target redoes its quick check'

farm_case stepback-farm-recheck
car a; join a >/dev/null
car b; join b >/dev/null
queue step-back a >/dev/null
expect_field "$(quick_receipt b)" status ready-to-land
git -C "$CASE/project" merge -q --ff-only fm/b
expect_field "$(queue status a)" status needs-rebase
prepare a
expect_field "$(queue status a)" status needs-quick
farm_json "$(farm_rebase_request r-new a passed "$(queue status a | field rebase_basis)")"
case "$(queue resolve sweep)" in "front-check passed task=a request=r-new "*) ;; *) fail 'a fresh farm check did not settle the returning car' ;; esac
expect_field "$(queue status a)" status ready-to-land
pass 'a stepped-back car returning behind a landing rebases and a fresh farm check settles it'
fi

if [ "${FM_LANDING_QUEUE_TEST_ONLY:-}" != farm ]; then
# Speculation drives the real queue and real Git object graph. The stub replaces
# only the external test service and stores every submitted request durably.
spec_case() {
  make_case "spec-$1"
  mkdir -p "$CASE/bin" "$CASE/fm-root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE/fm-root/bin/fm-guard.sh"
  chmod +x "$CASE/fm-root/bin/fm-guard.sh"
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
  cat > "$CASE/bin/test-service" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
path = pathlib.Path(os.environ['STUB_FARM_STATE'])
state = json.loads(path.read_text()) if path.exists() else {'next': 1, 'requests': []}
cmd = sys.argv[1]
if cmd == 'landing-gates-for-repo':
    print(os.environ.get('STUB_GATES', ''), end='')
    sys.exit(0)
if cmd == 'project-for-repo':
    print('project')
    sys.exit(0)
if cmd == 'status':
    calls = path.with_suffix('.calls')
    calls.write_text(str(int(calls.read_text()) + 1 if calls.exists() else 1))
    if path.with_suffix('.down').exists():
        sys.exit(3)
    print(json.dumps(state))
    sys.exit(0)
if cmd == 'cancel':
    for row in state['requests']:
        if row['id'] == sys.argv[2] and row['state'] not in ('passed', 'failed'):
            row['state'] = 'cancelled'
    path.write_text(json.dumps(state))
    sys.exit(0)
if cmd != 'submit':
    sys.exit(2)
args = sys.argv[5:]
def option(name):
    return args[args.index(name) + 1] if name in args else None
rid = 'r' + str(state['next'])
state['next'] += 1
state['requests'].append({'id': rid, 'sha': sys.argv[4], 'state': 'queued',
    'task': option('--task'), 'check': option('--check') or 'full',
    'target': option('--target'), 'receipt': option('--receipt'), 'options':
    {'suite': '--suite' in args, 'check': option('--check') or 'full',
     'target': option('--target'), 'device_gate': option('--device-gate')}})
path.write_text(json.dumps(state))
print(rid)
PY
  chmod +x "$CASE/bin/test-service"
}
spec_queue() {
  PATH="$CASE/bin:$PATH" FM_ROOT_OVERRIDE="$CASE/fm-root" FM_HOME="$CASE/home" FM_LANDING_TRAIN="${SPEC_TEST_SETTING-3}" FM_TEST_SERVICE_BIN="$CASE/bin/test-service" STUB_FARM_STATE="$CASE/farm.json" STUB_GATES="${SPEC_TEST_GATES:-}" \
    "$QUEUE" "$@" --project "$CASE/project" --landing-branch main
}
spec_join() {
  local id=$1
  full_receipt "$id"
  spec_queue ready "$id" --branch "fm/$id" --head "$(head_of "$id")" --target "$(tip)" --receipt "$CASE/$id.full"
}
spec_auto_land() {
  PATH="$CASE/bin:$PATH" FM_ROOT_OVERRIDE="$CASE/fm-root" FM_HOME="$CASE/home" \
    FM_LANDING_TRAIN="${SPEC_TEST_SETTING-3}" FM_TEST_SERVICE_BIN="$CASE/bin/test-service" \
    STUB_FARM_STATE="$CASE/farm.json" "$ROOT/bin/fm-landing-auto-land.sh"
}
spec_register() { # on|off
  mkdir -p "$CASE/home/data" "$CASE/home/state"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$CASE/home/data/backlog.md"
  printf '%s\n' "- project [local-only +yolo] - test at $CASE/project (added 2026-11-14)" > "$CASE/home/data/projects.md"
  if [ "$1" = off ]; then
    printf '%s\n' "- project [local-only] - test at $CASE/project (added 2026-11-14)" > "$CASE/home/data/projects.md"
  fi
  fm_write_meta "$CASE/home/state/a.meta" "project=$CASE/project" 'mode=local-only' 'landing_branch=main' \
    'kind=ship' 'harness=claude' 'window=sess:fm-notify'
}
spec_mark() { # task, full|quick, passed|failed
  python3 - "$CASE/farm.json" "$1" "$2" "$3" <<'PY'
import json, pathlib, sys
path, task, check, verdict = sys.argv[1:]
path = pathlib.Path(path)
data = json.loads(path.read_text())
matches = [row for row in data['requests'] if row['task'] == 'landing_' + task
           and row['check'] == check and row['state'] != 'cancelled']
assert matches, (task, check, verdict)
row = matches[-1]
row['state'] = verdict
if verdict == 'passed':
    receipt = pathlib.Path(row['receipt'])
    if check == 'full':
        receipt.write_text(f"schema=fm-full-suite.v1\nsha={row['sha']}\nfailures=0\n")
    else:
        receipt.write_text(f"schema=fm-quick-check.v1\nsha={row['sha']}\ntarget={row['target']}\n")
else:
    row['error'] = 'intentional test failure'
path.write_text(json.dumps(data))
PY
}
spec_count() { # check, optional state
  python3 - "$CASE/farm.json" "$1" "${2:-all}" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(sum(row['check'] == sys.argv[2] and (sys.argv[3] == 'all' or row['state'] == sys.argv[3])
          for row in data['requests']))
PY
}

spec_case all-pass
mkdir -p "$CASE/home/data" "$CASE/home/state"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$CASE/home/data/backlog.md"
for id in a b c d; do car "$id"; spec_join "$id" >/dev/null; done
[ "$(spec_count full)" -eq 3 ] || fail 'depth three did not submit exactly three editor suites'
[ "$(spec_count quick)" -eq 0 ] || fail 'phone checks started before editor suites passed'
expect_field "$(spec_queue status d)" status waiting-for-front
for id in a b c; do spec_mark "$id" full passed; done
spec_queue resolve sweep >/dev/null
[ "$(spec_count quick)" -eq 3 ] || fail 'editor passes did not launch three short phone checks'
for id in a b c; do spec_mark "$id" quick passed; done
spec_queue resolve sweep >/dev/null
for id in a b c; do
  out=$(spec_queue status "$id")
  candidate=$(printf '%s\n' "$out" | field candidate_sha)
  if [ "$id" = a ]; then expect_field "$out" status ready-to-land; fi
  fm_write_meta "$CASE/home/state/$id.meta" "project=$CASE/project" 'mode=local-only' 'landing_branch=main' \
    'kind=ship' 'harness=claude' 'window=sess:fm-notify'
  receipt=$(printf '%s\n' "$out" | field receipt)
  if [ "$id" = a ]; then
    if PATH="$CASE/bin:$PATH" FM_ROOT_OVERRIDE="$CASE/fm-root" FM_HOME="$CASE/home" FM_LANDING_TRAIN=3 \
      FM_TEST_SERVICE_BIN="$CASE/bin/test-service" STUB_FARM_STATE="$CASE/farm.json" \
      "$ROOT/bin/fm-merge-local.sh" "$id" --receipt "$CASE/a.full" > "$CASE/omitted-candidate" 2>&1; then
      fail 'local merge accepted the worker branch while a tested queue candidate existed'
    fi
    grep -q 'requires --candidate' "$CASE/omitted-candidate" \
      || fail 'local merge did not explain its candidate requirement'
    quick=$(printf '%s\n' "$out" | field candidate_phone_receipt)
    cp "$quick" "$CASE/valid-quick.receipt"
    printf 'schema=fm-quick-check.v1\nsha=%s\ntarget=%s\n' "$BASE" "$BASE" > "$quick"
    if PATH="$CASE/bin:$PATH" FM_ROOT_OVERRIDE="$CASE/fm-root" FM_HOME="$CASE/home" FM_LANDING_TRAIN=3 \
      FM_TEST_SERVICE_BIN="$CASE/bin/test-service" STUB_FARM_STATE="$CASE/farm.json" \
      "$ROOT/bin/fm-merge-local.sh" "$id" --receipt "$receipt" --candidate "$candidate" > "$CASE/bad-merge" 2>&1; then
      fail 'local merge accepted a candidate with a wrong-SHA short-phone receipt'
    fi
    [ "$(tip)" = "$BASE" ] || fail 'wrong-SHA phone receipt moved the landing tip'
    mv "$CASE/valid-quick.receipt" "$quick"
  fi
  PATH="$CASE/bin:$PATH" FM_ROOT_OVERRIDE="$CASE/fm-root" FM_HOME="$CASE/home" FM_LANDING_TRAIN=3 \
    FM_TEST_SERVICE_BIN="$CASE/bin/test-service" STUB_FARM_STATE="$CASE/farm.json" \
    "$ROOT/bin/fm-merge-local.sh" "$id" --receipt "$receipt" --candidate "$candidate" > "$CASE/$id.merge" \
    || { cat "$CASE/$id.merge" >&2; fail "local merge did not land tested candidate $id"; }
  [ "$(tip)" = "$candidate" ] || fail "landed $id at a SHA other than its tested candidate"
  grep -q 'status=landed' "$CASE/home/state/$id.inbox/"*.msg \
    || fail "the worker for $id was not told it landed"
done
expect_field "$(spec_queue status d)" status checking-candidate
pass 'three candidates start together, pass editor then short phone checks, and land in tested order at exact SHAs'

spec_case pre-join-phone-gate
SPEC_TEST_GATES=real-phone
car a
full_receipt a
if spec_queue ready a --branch fm/a --head "$(head_of a)" --target "$(tip)" --receipt "$CASE/a.full" \
  > "$CASE/missing-phone" 2>&1; then
  fail 'speculative ready admitted a car without its worker phone gate'
fi
printf 'schema=fm-landing-gate.v1\ngate=real-phone\nsha=%s\ntarget=%s\n' "$(head_of a)" "$BASE" > "$CASE/a.phone-gate"
spec_queue ready a --branch fm/a --head "$(head_of a)" --target "$(tip)" --receipt "$CASE/a.full" \
  --gate-receipt real-phone="$CASE/a.phone-gate" >/dev/null
expect_field "$(spec_queue status a)" status checking-candidate
SPEC_TEST_GATES=
pass 'speculative admission retains worker editor and phone-gate receipts'

spec_case front-failure
mkdir -p "$CASE/home/state"
fm_write_meta "$CASE/home/state/a.meta" 'window=sess:fm-notify' 'kind=ship' 'harness=claude'
for id in a b c; do car "$id"; spec_join "$id" >/dev/null; done
old_b=$(spec_queue status b | field candidate_sha)
spec_mark a full failed
spec_queue resolve sweep >/dev/null
expect_field "$(spec_queue status a)" status failed
grep -q 'status=failed.*reason=intentional test failure' "$CASE/home/state/a.inbox/"*.msg \
  || fail 'front failure did not tell its worker the reason'
expect_field "$(spec_queue status b)" place 1
new_b=$(spec_queue status b | field candidate_sha)
[ "$new_b" != "$old_b" ] || fail 'front failure did not rebuild the surviving suffix'
[ "$(spec_count full cancelled)" -ge 2 ] || fail 'front failure did not cancel requests that included it'
for id in b c; do spec_mark "$id" full passed; done
spec_queue resolve sweep >/dev/null
for id in b c; do spec_mark "$id" quick passed; done
spec_queue resolve sweep >/dev/null
for id in b c; do
  out=$(spec_queue status "$id")
  expect_field "$out" status ready-to-land
  git -C "$CASE/project" merge -q --ff-only "$(printf '%s\n' "$out" | field candidate_sha)"
  spec_queue reconcile sweep >/dev/null
done
pass 'front failure removes only the failed car and rebuilds the suffix from the live tip'

spec_case auto-yolo
spec_register on
ln -s project "$CASE/registered-project"
printf '%s\n' "- project [local-only +yolo] - test at $CASE/registered-project (added 2026-11-14)" > "$CASE/home/data/projects.md"
car a
if spec_queue ready a --branch fm/a --head "$(head_of a)" --target "$(tip)" > "$CASE/no-suite" 2>&1; then
  fail 'speculative ready admitted without a worker full editor receipt'
fi
spec_join a >/dev/null
candidate=$(spec_queue status a | field candidate_sha)
spec_mark a full passed
spec_queue resolve sweep >/dev/null
spec_mark a quick passed
spec_queue resolve sweep >/dev/null
spec_auto_land > "$CASE/auto-land.log" 2>&1 || { cat "$CASE/auto-land.log" >&2; fail 'yolo candidate did not auto-land'; }
if [ "$(tip)" != "$candidate" ]; then
  cat "$CASE/auto-land.log" >&2
  FM_HOME="$CASE/home" "$ROOT/bin/fm-project-mode.sh" project >&2
  FM_HOME="$CASE/home" "$ROOT/bin/fm-project-mode.sh" --path project >&2
  git -C "$CASE/project" worktree list --porcelain >&2
  find "$CASE/home/data/landing-queue" -name queue -exec sed -n '1,5p' {} \; >&2
  fail 'auto-land moved tip to a SHA other than the tested candidate'
fi
expect_field "$(spec_queue status a)" status landed
pass 'speculative ready needs a worker editor receipt and +yolo auto-lands the tested candidate'

spec_case auto-publish
mv "$CASE/project" "$CASE/ProjectWhite"
ln -s ProjectWhite "$CASE/project"
spec_register on
printf '%s\n' "- ProjectWhite [local-only +yolo] - test at $CASE/ProjectWhite (added 2026-11-14)" > "$CASE/home/data/projects.md"
fm_write_meta "$CASE/home/state/a.meta" "project=$CASE/ProjectWhite" 'mode=local-only' 'landing_branch=main' \
  'kind=ship' 'harness=claude' 'window=sess:fm-notify'
git init -q --bare "$CASE/origin.git"
git -C "$CASE/ProjectWhite" remote add origin "$CASE/origin.git"
git -C "$CASE/ProjectWhite" push -q origin main
car a; spec_join a >/dev/null
candidate=$(spec_queue status a | field candidate_sha)
spec_mark a full passed
spec_queue resolve sweep >/dev/null
spec_mark a quick passed
spec_queue resolve sweep >/dev/null
spec_auto_land > "$CASE/auto-land.log" 2>&1 || { cat "$CASE/auto-land.log" >&2; fail 'published yolo candidate did not auto-land'; }
[ "$(tip)" = "$candidate" ] || fail 'published local tip differs from tested candidate'
[ "$(git -C "$CASE/origin.git" rev-parse refs/heads/main)" = "$candidate" ] \
  || fail 'published landing branch differs from tested candidate'
pass 'authorized published landing branch fast-forward pushes the tested candidate'

spec_case auto-push-retry
mv "$CASE/project" "$CASE/ProjectWhite"
ln -s ProjectWhite "$CASE/project"
spec_register on
printf '%s\n' "- ProjectWhite [local-only +yolo] - test at $CASE/ProjectWhite (added 2026-11-14)" > "$CASE/home/data/projects.md"
fm_write_meta "$CASE/home/state/a.meta" "project=$CASE/ProjectWhite" 'mode=local-only' 'landing_branch=main' \
  'kind=ship' 'harness=claude' 'window=sess:fm-notify'
git -C "$CASE/ProjectWhite" remote add origin "$CASE/recovered-origin.git"
car a; spec_join a >/dev/null
candidate=$(spec_queue status a | field candidate_sha)
spec_mark a full passed
spec_queue resolve sweep >/dev/null
spec_mark a quick passed
spec_queue resolve sweep >/dev/null
if spec_auto_land > "$CASE/first-auto-land.log" 2>&1; then fail 'missing remote did not defer publication'; fi
[ "$(tip)" = "$candidate" ] || fail 'failed push lost the local tested landing'
[ -f "$(find "$CASE/home/data/landing-queue" -name pending-push-a -print -quit)" ] \
  || fail 'failed publication left no durable retry record'
git init -q --bare "$CASE/recovered-origin.git"
spec_auto_land > "$CASE/retry-auto-land.log" 2>&1 || { cat "$CASE/retry-auto-land.log" >&2; fail 'pending publication did not retry'; }
[ "$(git -C "$CASE/recovered-origin.git" rev-parse refs/heads/main)" = "$candidate" ] \
  || fail 'retried publication pushed a SHA other than the tested candidate'
pass 'a failed authorized push retries the tested landing without repeating the merge'

spec_case auto-failed
spec_register on
car a; spec_join a >/dev/null
spec_mark a full failed
spec_queue resolve sweep >/dev/null
spec_auto_land > "$CASE/auto-land.log" 2>&1 || fail 'failed candidate caused an auto-land error'
[ "$(tip)" = "$BASE" ] || fail 'failed candidate auto-landed'
expect_field "$(spec_queue status a)" status failed
pass 'failed candidate does not auto-land'

spec_case auto-no-yolo
spec_register off
car a; spec_join a >/dev/null
spec_mark a full passed
spec_queue resolve sweep >/dev/null
spec_mark a quick passed
spec_queue resolve sweep >/dev/null
before=$(wake_count)
spec_auto_land > "$CASE/auto-land.log" 2>&1 || fail 'no-yolo scan failed'
[ "$(tip)" = "$BASE" ] || fail 'no-yolo candidate auto-landed'
[ "$(wake_count)" -eq "$before" ] || fail 'no-yolo scan emitted an extra wake'
expect_field "$(spec_queue status a)" status ready-to-land
pass 'project without +yolo retains the ordinary ready wake without auto-land'

spec_case merge-commit
car a; spec_join a >/dev/null
git -C "$CASE/project" worktree add -qb fm/b "$CASE/b" main
printf 'batch core\n' > "$CASE/b/b.txt"
git -C "$CASE/b" add b.txt
git -C "$CASE/b" commit -qm 'batch core'
git -C "$CASE/project" worktree add -qb fm/b-side "$CASE/b-side" main
printf 'batch side\n' > "$CASE/b-side/b-side.txt"
git -C "$CASE/b-side" add b-side.txt
git -C "$CASE/b-side" commit -qm 'batch side'
git -C "$CASE/b" merge -q --no-ff -m 'combine batch' fm/b-side
spec_join b >/dev/null
[ "$(git -C "$CASE/b" rev-list --parents -n 1 HEAD | wc -w)" -eq 3 ] || fail 'merge-commit fixture has no merge commit'
expect_field "$(spec_queue status b)" status waiting-for-front
b_candidate=$(spec_queue status b | field candidate_sha)
[ "$b_candidate" != - ] || fail 'merge-commit candidate was not built'
[ "$(git -C "$CASE/project" rev-list --parents -n 1 "$b_candidate" | wc -w)" -eq 3 ] \
  || fail 'candidate replay flattened the batch merge commit'
spec_mark a full passed
spec_queue resolve sweep >/dev/null
spec_mark a quick passed
spec_queue resolve sweep >/dev/null
out=$(spec_queue status a)
git -C "$CASE/project" merge -q --ff-only "$(printf '%s\n' "$out" | field candidate_sha)"
spec_queue reconcile sweep >/dev/null
expect_field "$(spec_queue status b)" status checking-candidate
pass 'a no-ff merge-commit batch replays after the previous car lands'

spec_case already-based-merge
git -C "$CASE/project" worktree add -qb fm/a "$CASE/a" main
printf 'merged core\n' > "$CASE/a/a.txt"
git -C "$CASE/a" add a.txt
git -C "$CASE/a" commit -qm core
git -C "$CASE/project" worktree add -qb fm/a-side "$CASE/a-side" main
printf 'merged side\n' > "$CASE/a-side/a-side.txt"
git -C "$CASE/a-side" add a-side.txt
git -C "$CASE/a-side" commit -qm side
git -C "$CASE/a" merge -q --no-ff -m 'combine' fm/a-side
spec_join a >/dev/null
[ "$(spec_queue status a | field candidate_sha)" = "$(head_of a)" ] \
  || fail 'already-based merge-commit head was not used directly as candidate'
pass 'an already-based merge-commit branch is its own candidate'

spec_case middle-failure
for id in a b c; do car "$id"; spec_join "$id" >/dev/null; done
old_a=$(spec_queue status a | field candidate_sha)
old_c=$(spec_queue status c | field candidate_sha)
spec_mark b full failed
spec_queue resolve sweep >/dev/null
expect_field "$(spec_queue status b)" status failed
[ "$(spec_queue status a | field candidate_sha)" = "$old_a" ] || fail 'middle failure rebuilt the unaffected prefix'
[ "$(spec_queue status c | field candidate_sha)" != "$old_c" ] || fail 'middle failure did not rebuild the suffix'
for id in a c; do spec_mark "$id" full passed; done
spec_queue resolve sweep >/dev/null
for id in a c; do spec_mark "$id" quick passed; done
spec_queue resolve sweep >/dev/null
for id in a c; do
  out=$(spec_queue status "$id")
  expect_field "$out" status ready-to-land
  git -C "$CASE/project" merge -q --ff-only "$(printf '%s\n' "$out" | field candidate_sha)"
  spec_queue reconcile sweep >/dev/null
done
pass 'middle failure preserves the tested prefix and rebuilds only its surviving suffix'

spec_case replay-conflict
git -C "$CASE/project" worktree add -qb fm/a "$CASE/a" main
sed 's/^first$/changed-by-a/' "$CASE/a/shared.txt" > "$CASE/a/shared.new"
mv "$CASE/a/shared.new" "$CASE/a/shared.txt"
git -C "$CASE/a" commit -qam a
spec_join a >/dev/null
git -C "$CASE/project" worktree add -qb fm/b "$CASE/b" main
sed 's/^first$/changed-by-b/' "$CASE/b/shared.txt" > "$CASE/b/shared.new"
mv "$CASE/b/shared.new" "$CASE/b/shared.txt"
git -C "$CASE/b" commit -qam b
spec_join b >/dev/null
expect_field "$(spec_queue status b)" status failed
expect_field "$(spec_queue status a)" status checking-candidate
pass 'candidate replay conflict fails only the car that introduced it'

spec_case moving-tip
for id in a b; do car "$id"; spec_join "$id" >/dev/null; done
old_a=$(spec_queue status a | field candidate_sha)
printf 'outside\n' > "$CASE/project/outside.txt"
git -C "$CASE/project" add outside.txt
git -C "$CASE/project" commit -qm outside
spec_queue reconcile sweep >/dev/null
[ "$(spec_queue status a | field candidate_sha)" != "$old_a" ] || fail 'tip move did not rebuild candidates'
[ "$(spec_count full cancelled)" -ge 2 ] || fail 'tip move did not cancel stale requests'
pass 'moving landing tip invalidates old results and rebuilds candidates'

spec_case farm-unreachable
car a; spec_join a >/dev/null
touch "$CASE/farm.down"
before=$(wake_count)
spec_queue resolve sweep >/dev/null
[ "$(wake_count)" -eq "$((before + 1))" ] || fail 'speculative farm outage did not wake firstmate'
spec_queue resolve sweep >/dev/null
[ "$(wake_count)" -eq "$((before + 1))" ] || fail 'repeat speculative farm outage woke firstmate again'
status_calls=$(cat "$CASE/farm.calls")
expect_field "$(spec_queue status a)" status checking-candidate
[ "$(cat "$CASE/farm.calls")" -eq "$status_calls" ] || fail 'status observation polled the test service'
spec_queue resolve sweep >/dev/null
[ "$(wake_count)" -eq "$((before + 1))" ] || fail 'status recheck reset the farm outage dedupe marker'
rm "$CASE/farm.down"
spec_queue resolve sweep >/dev/null
pass 'unreachable test service leaves candidates unlandable and wakes firstmate once'

spec_case off-switch
SPEC_TEST_SETTING=
mkdir -p "$CASE/home/config/landing-train"
printf 'off\n' > "$CASE/home/config/landing-train/default"
car a
if spec_queue ready a --branch fm/a --head "$(head_of a)" --target "$(tip)" > "$CASE/no-receipt" 2>&1; then
  fail 'off switch admitted a car without its worker full-suite receipt'
fi
full_receipt a
out=$(spec_queue ready a --branch fm/a --head "$(head_of a)" --target "$(tip)" --receipt "$CASE/a.full")
expect_field "$out" status needs-quick
[ ! -f "$CASE/farm.json" ] || fail 'off switch submitted a speculative request'
pass 'per-home off switch keeps the sequential front check'

spec_case switch-off-running
car a; spec_join a >/dev/null
[ "$(spec_count full)" -eq 1 ] || fail 'running switch case did not submit a candidate'
mkdir -p "$CASE/home/config/landing-train"
printf 'off\n' > "$CASE/home/config/landing-train/default"
SPEC_TEST_SETTING=
expect_field "$(spec_queue status a)" status needs-quick
[ "$(spec_count full cancelled)" -eq 1 ] || fail 'switching off did not cancel the in-flight candidate'
[ -z "$(git -C "$CASE/project" for-each-ref refs/landing-candidates --format='%(refname)')" ] \
  || fail 'switching off left a candidate ref behind'
pass 'switching speculation off retires in-flight checks and returns to sequential status'

spec_case project-off
mkdir -p "$CASE/home/config/landing-train"
printf '3\n' > "$CASE/home/config/landing-train/default"
printf 'off\n' > "$CASE/home/config/landing-train/project"
SPEC_TEST_SETTING=
car a
full_receipt a
out=$(spec_queue ready a --branch fm/a --head "$(head_of a)" --target "$(tip)" --receipt "$CASE/a.full")
expect_field "$out" status needs-quick
[ ! -f "$CASE/farm.json" ] || fail 'project off switch submitted a speculative request'
rm "$CASE/home/config/landing-train/project"
spec_queue reconcile sweep >/dev/null
expect_field "$(spec_queue status a)" status checking-candidate
[ "$(spec_count full)" -eq 1 ] || fail 'lifting the project switch did not submit a candidate'
pass 'per-project off switch overrides the home depth and can be lifted'
fi
