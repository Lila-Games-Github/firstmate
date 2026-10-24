#!/usr/bin/env bash
# Reproduce the 2026-10-25 FrogPile incident with the real queue CLI, before and after the change.
set -eu
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.com GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.com
WT=$1 BASECOMMIT=$2
T=$(mktemp -d /tmp/fm-gate-demo.XXXX)
git -C "$WT" archive "$BASECOMMIT" bin | tar -x -C "$T" && mv "$T/bin" "$T/base-bin"
run() { echo "\$ $*" | sed "s#$T#\$DEMO#g"; "$@" 2>&1 | sed "s#$T#\$DEMO#g"; echo "(exit ${PIPESTATUS[0]})"; }
setup() { # <label>
  R=$T/$1; mkdir -p "$R/home/config/test-service"
  cp "$WT/docs/examples/fm-test-service-frogpile.json" "$R/home/config/test-service/frogpile.json"
  git init -q -b proto/godot/frog-pile "$R/FrogPile"
  git -C "$R/FrogPile" commit -qm baseline --allow-empty
  git -C "$R/FrogPile" worktree add -qb fm/car1 "$R/car1" proto/godot/frog-pile
  echo change > "$R/car1/x.txt"; git -C "$R/car1" add .; git -C "$R/car1" commit -qm car1
  HEAD_SHA=$(git -C "$R/car1" rev-parse HEAD); TGT=$(git -C "$R/FrogPile" rev-parse HEAD)
  printf 'schema=fm-full-suite.v1\nsha=%s\nfailures=0\n' "$HEAD_SHA" > "$R/suite.receipt"
}
q() { FM_HOME="$R/home" "$QUEUE" "$@" --project "$R/car1" --landing-branch proto/godot/frog-pile; }
wakes() { echo "wake-queue entries: $( [ -f "$R/home/state/.wake-queue" ] && wc -l < "$R/home/state/.wake-queue" || echo 0)"; }

echo "=== BEFORE (base $BASECOMMIT): FrogPile config with real-phone gate, green suite only ==="
setup before; QUEUE=$T/base-bin/fm-landing-queue.sh
run q ready car1 --branch fm/car1 --head "$HEAD_SHA" >/dev/null
run q ready car1 --branch fm/car1 --head "$HEAD_SHA" --target "$TGT"
run q receipt car1 --head "$HEAD_SHA" --target "$TGT" --receipt "$R/suite.receipt"
wakes
echo
echo "=== AFTER (this change): same scenario ==="
setup after; QUEUE=$WT/bin/fm-landing-queue.sh
run q ready car1 --branch fm/car1 --head "$HEAD_SHA" >/dev/null
run q ready car1 --branch fm/car1 --head "$HEAD_SHA" --target "$TGT"
run q receipt car1 --head "$HEAD_SHA" --target "$TGT" --receipt "$R/suite.receipt"
wakes
echo "--- worker tries a gate receipt for the wrong head (fails closed) ---"
printf 'schema=fm-landing-gate.v1\ngate=real-phone\nsha=%s\ntarget=%s\n' "$TGT" "$TGT" > "$R/bad.receipt"
run q gate car1 --gate real-phone --head "$TGT" --target "$TGT" --receipt "$R/bad.receipt"
echo "--- worker tries an undeclared gate ---"
run q gate car1 --gate made-up --head "$HEAD_SHA" --target "$TGT" --receipt "$R/bad.receipt"
echo "--- phones back: worker runs real-phone check and submits the gate receipt ---"
printf 'schema=fm-landing-gate.v1\ngate=real-phone\nsha=%s\ntarget=%s\n' "$HEAD_SHA" "$TGT" > "$R/gate.receipt"
echo "gate.receipt:"; sed 's/^/  /' "$R/gate.receipt" | sed "s/$HEAD_SHA/<head>/;s/$TGT/<target>/"
run q gate car1 --gate real-phone --head "$HEAD_SHA" --target "$TGT" --receipt "$R/gate.receipt"
wakes
echo "--- repeated status does not re-ring ---"
run q status car1 >/dev/null; wakes
echo "--- an unrelated half-edited config doesn't break the FrogPile queue ---"
printf '{"half-edited":' > "$R/home/config/test-service/other-project.json"
run q status car1
rm -rf "$T"
