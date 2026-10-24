#!/usr/bin/env bash
# End-to-end demo: two workers self-serve a stacked local landing train; firstmate only reacts to wakes.
set -eu
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.com GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.com
ROOT=$1; Q="$ROOT/bin/fm-landing-queue.sh"; W=$(mktemp -d)
mkdir -p "$W/home"; git init -q -b main "$W/project"; git -C "$W/project" commit -qm base --allow-empty
q() { echo "\$ fm-landing-queue.sh $*"; FM_HOME="$W/home" "$Q" "$@" --project "$W/project" --landing-branch main | sed 's/^/    /'; }
qs() { FM_HOME="$W/home" "$Q" "$@" --project "$W/project" --landing-branch main; }
f() { sed -n "s/^$1=//p"; }
wakes() { echo "--- firstmate wake queue:"; if [ -f "$W/home/state/.wake-queue" ]; then cut -f5 "$W/home/state/.wake-queue" | sed 's/^/    /'; else echo "    (empty)"; fi; }
for id in a b; do git -C "$W/project" worktree add -qb fm/$id "$W/$id" main; echo $id > "$W/$id/$id.txt"; git -C "$W/$id" add .; git -C "$W/$id" commit -qm $id; done
h() { git -C "$W/project" rev-parse fm/$1; }
echo "=== Both workers join the train (no firstmate message) ==="
q ready a --branch fm/a --head "$(h a)"; q ready b --branch fm/b --head "$(h b)"; wakes
echo "=== Worker b reads its own target and rebases onto car a ==="
out=$(qs status b); t=$(echo "$out" | f target_sha); rf=$(echo "$out" | f rebase_from)
git -C "$W/b" rebase -q --onto "$t" "$rf"; q ready b --branch fm/b --head "$(h b)" --target "$t"
rcpt() { local id=$1 t; t=$(qs status $id | f target_sha); printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$(h $id)" > "$W/$id.r"; q receipt $id --head "$(h $id)" --target "$t" --receipt "$W/$id.r"; }
echo "=== Worker b finishes its suite first: it waits, no wake ==="; rcpt b; wakes
echo "=== Worker a (bottom car) submits receipt: one ready-to-land wake ==="; rcpt a; wakes
echo "=== Firstmate fast-forwards main to a (simulating fm-merge-local) and tears down a ==="
git -C "$W/project" merge -q --ff-only fm/a; git -C "$W/project" worktree remove "$W/a"; git -C "$W/project" branch -qD fm/a
q status a; q status b; wakes
echo "=== Firstmate lands b; b observes landed ==="; git -C "$W/project" merge -q --ff-only fm/b; q status b
echo "=== Failure handoff: supervisor fails car c, worker c reads reason in a separate call ==="
git -C "$W/project" worktree add -qb fm/c "$W/c" main; echo c > "$W/c/c.txt"; git -C "$W/c" add .; git -C "$W/c" commit -qm c
q ready c --branch fm/c --head "$(h c)" >/dev/null; q fail c --reason "new-red: suite.x regressed" >/dev/null; q status c; wakes
