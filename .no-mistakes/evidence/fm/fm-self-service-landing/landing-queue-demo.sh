#!/usr/bin/env bash
# Demo: workers drive the landing train themselves; firstmate only gets check wakes.
set -eu
ROOT=$1; Q="$ROOT/bin/fm-landing-queue.sh"
W=$(mktemp -d); mkdir -p "$W/home"; git init -q -b main "$W/project"
git -C "$W/project" commit -qm baseline --allow-empty; BASE=$(git -C "$W/project" rev-parse HEAD)
q() { echo "\$ fm-landing-queue.sh $*" | sed "s#$W#<tmp>#g"; FM_HOME="$W/home" "$Q" "$@" --project "$W/project" --landing-branch main 2>&1 | sed "s#$W#<tmp>#g;s/^/    /"; }
qv() { FM_HOME="$W/home" "$Q" "$@" --project "$W/project" --landing-branch main | sed -n "s/^$1=//p"; }
f() { FM_HOME="$W/home" "$Q" status "$1" --project "$W/project" --landing-branch main | sed -n "s/^$2=//p"; }
h() { git -C "$W/project" rev-parse "fm/$1"; }
wakes() { echo "--- firstmate wake queue:"; if [ -f "$W/home/state/.wake-queue" ]; then cut -f5 "$W/home/state/.wake-queue" | sed "s#$W#<tmp>#g;s/^/    /"; else echo "    (empty)"; fi; }
for id in a b; do git -C "$W/project" worktree add -qb fm/$id "$W/$id" main; echo $id > "$W/$id/$id.txt"; git -C "$W/$id" add .; git -C "$W/$id" commit -qm $id; done
echo "## Two workers join the train on their own (no firstmate message)"
q ready a --branch fm/a --head "$(h a)"; q ready b --branch fm/b --head "$(h b)"; wakes
echo "## Worker b reads its own target from the queue and rebases onto it"
t=$(f b target_sha); r=$(f b rebase_from); git -C "$W/b" rebase -q --onto "$t" "$r"
q ready b --branch fm/b --head "$(h b)" --target "$t"
q ready a --branch fm/a --head "$(h a)" --target "$(f a target_sha)"
echo "## Upper worker b finishes its full suite first: no wake"
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$(h b)" > "$W/b.r"; q receipt b --head "$(h b)" --target "$(f b target_sha)" --receipt "$W/b.r"; wakes
echo "## Bottom worker a submits receipt: exactly one ready-to-land wake for firstmate"
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$(h a)" > "$W/a.r"; q receipt a --head "$(h a)" --target "$BASE" --receipt "$W/a.r"; wakes
echo "## Firstmate lands a (ff-only); queue reconciles, b becomes bottom and wakes once"
git -C "$W/project" merge -q --ff-only fm/a; q status a; q status b; wakes
echo "## Firstmate tears down a (branch deleted): still reported landed, not failed"
git -C "$W/project" worktree remove --force "$W/a"; git -C "$W/project" branch -D -q fm/a; q status a
echo "## Empty car refused at admission"
git -C "$W/project" branch fm/empty; q ready empty --branch fm/empty --head "$(git -C "$W/project" rev-parse main)" || true
echo "## Failure reason persists to a separate invocation (supervisor -> worker handoff)"
git -C "$W/project" merge -q --ff-only fm/b
git -C "$W/project" worktree add -qb fm/c "$W/c" main; echo c > "$W/c/c.txt"; git -C "$W/c" add .; git -C "$W/c" commit -qm c
q ready c --branch fm/c --head "$(h c)" >/dev/null; FM_HOME="$W/home" "$Q" fail c --reason 'new-red: suite x' --project "$W/project" --landing-branch main >/dev/null
q status c
echo "## Missing baseline: red tip, red car receipt -> needs-baseline; firstmate records tip baseline (lands nothing) -> red-receipt stays with worker"
git -C "$W/project" worktree add -qb fm/d "$W/d" main; echo d > "$W/d/d.txt"; git -C "$W/d" add .; git -C "$W/d" commit -qm d
TIP=$(git -C "$W/project" rev-parse main)
q ready d --branch fm/d --head "$(h d)" >/dev/null; FM_HOME="$W/home" "$Q" ready d --branch fm/d --head "$(h d)" --target "$TIP" --project "$W/project" --landing-branch main >/dev/null
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=2\nfailure=known-red\nfailure=new-red\n' "$(h d)" > "$W/d.r"
q receipt d --head "$(h d)" --target "$TIP" --receipt "$W/d.r"
printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=1\nfailure=known-red\n' "$TIP" > "$W/tip.r"
q baseline d --receipt "$W/tip.r"
echo "landing branch still at tip: $([ "$(git -C "$W/project" rev-parse main)" = "$TIP" ] && echo yes || echo NO)"
wakes
rm -rf "$W"
