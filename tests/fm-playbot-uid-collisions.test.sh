#!/usr/bin/env bash
# Exercise UID collision preservation against a real Git tree and untracked files.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-playbot-uid-collisions)
repo="$TMP_ROOT/lane"
mkdir -p "$repo"
git -C "$repo" init -qb main
git -C "$repo" config user.name Fixture
git -C "$repo" config user.email fixture@example.invalid
printf '.task_tmp/\n' > "$repo/.gitignore"
printf 'base\n' > "$repo/README.md"
git -C "$repo" add .
git -C "$repo" commit -qm base
base=$(git -C "$repo" rev-parse HEAD)
mkdir -p "$repo/tools/a" "$repo/tools/b"
printf 'uid://abc123\n' > "$repo/tools/a/one.gd.uid"
printf 'uid://xyz789\n' > "$repo/tools/b/two.gd.uid"
git -C "$repo" add .
git -C "$repo" commit -qm target
target=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" reset -q --hard "$base"
mkdir -p "$repo/tools/a" "$repo/tools/b"
printf 'uid://abc123\n' > "$repo/tools/a/one.gd.uid"
printf 'uid://xyz789\n' > "$repo/tools/b/two.gd.uid"
printf 'keep me\n' > "$repo/unrelated.txt"
source_untracked=$(git -C "$repo" ls-files --others --exclude-standard | wc -l | tr -d ' ')
source_tracked=$(git -C "$repo" ls-tree -r --name-only "$target" | wc -l | tr -d ' ')
(cd "$repo" && "$ROOT/bin/fm-playbot-uid-collisions.py" check "$target") > "$TMP_ROOT/check.json"
(cd "$repo" && "$ROOT/bin/fm-playbot-uid-collisions.py" preserve "$target") > "$TMP_ROOT/preserve.json"
SOURCE_UNTRACKED="$source_untracked" SOURCE_TRACKED="$source_tracked" CHECK="$TMP_ROOT/check.json" PRESERVE="$TMP_ROOT/preserve.json" python3 - <<'PY'
import hashlib,json,os,pathlib
check=json.loads(pathlib.Path(os.environ['CHECK']).read_text())
preserved=json.loads(pathlib.Path(os.environ['PRESERVE']).read_text())
assert check['source_untracked_count']==int(os.environ['SOURCE_UNTRACKED'])==3
assert check['source_target_tracked_count']==int(os.environ['SOURCE_TRACKED'])==4
assert check['collision_count']==preserved['collision_count']==2
assert check['collisions']==['tools/a/one.gd.uid','tools/b/two.gd.uid']
backup=pathlib.Path(preserved['backup'])
manifest=json.loads((backup/'manifest.json').read_text())
assert len(manifest['files'])==2
for entry in manifest['files']:
    data=(backup/entry['path']).read_bytes()
    assert hashlib.sha256(data).hexdigest()==entry['sha256']
print(f"uid-collisions: source untracked={check['source_untracked_count']}, target tracked={check['source_target_tracked_count']}, observed collisions={check['collision_count']}, verified backups={len(manifest['files'])}")
PY
[ ! -e "$repo/tools/a/one.gd.uid" ] && [ ! -e "$repo/tools/b/two.gd.uid" ] || fail 'colliding UIDs remain after preservation'
[ "$(cat "$repo/unrelated.txt")" = 'keep me' ] || fail 'unrelated untracked file was moved'
# A target that would replace unrelated untracked work must fail before any move.
printf 'new tracked file\n' > "$repo/unrelated.txt"
git -C "$repo" add unrelated.txt
git -C "$repo" commit -qm bad-target
bad_target=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" reset -q --hard "$base"
printf 'user work\n' > "$repo/unrelated.txt"
if (cd "$repo" && "$ROOT/bin/fm-playbot-uid-collisions.py" preserve "$bad_target") > "$TMP_ROOT/bad.out" 2> "$TMP_ROOT/bad.err"; then
  fail 'non-UID collision was accepted'
fi
rg -q 'non-UID untracked work' "$TMP_ROOT/bad.err" || fail 'non-UID rejection did not name its cause'
[ "$(cat "$repo/unrelated.txt")" = 'user work' ] || fail 'non-UID collision was damaged'
pass 'fm-playbot-uid-collisions: real inventories and backups match source counts; non-UID fixture is rejected'
