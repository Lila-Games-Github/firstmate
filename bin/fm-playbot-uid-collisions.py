#!/usr/bin/env python3
"""Preserve only untracked Godot UID sidecars that a target commit would track.

Usage: fm-playbot-uid-collisions.py check|preserve <full-target-sha>
Run at the registered lane worktree root before a front-of-queue rebase.
The target tree and real untracked inventory are authoritative inputs; the JSON
result reports both source counts and the exact collision count. Non-UID
collisions, nonregular files, malformed UIDs, and unignored backup storage fail
closed. Preserve writes backups under ignored .task_tmp/ in this same worktree,
then removes only the backed-up colliding paths. It never rebases or restores.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import uuid

UID = re.compile(rb"uid://[a-z0-9]+\n?\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")


def git(root, *args):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_REPLACE_OBJECTS="1")
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, env=env, check=False)
    if result.returncode:
        raise ValueError((result.stderr or result.stdout).decode("utf-8", "replace").strip())
    return result.stdout


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in {"check", "preserve"} or not SHA.fullmatch(sys.argv[2]):
        raise ValueError("usage: fm-playbot-uid-collisions.py check|preserve <full-target-sha>")
    action, target = sys.argv[1:]
    root = Path.cwd().resolve()
    if Path(git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve() != root:
        raise ValueError("run from the lane worktree top level")
    if git(root, "rev-parse", "--verify", f"{target}^{{commit}}").decode().strip() != target:
        raise ValueError("target is not a local commit")
    untracked = set(filter(None, git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")))
    target_paths = set(filter(None, git(root, "ls-tree", "-r", "--name-only", "-z", target).split(b"\0")))
    collisions = sorted(untracked & target_paths)
    if any(not name.endswith(b".gd.uid") for name in collisions):
        raise ValueError("target collides with non-UID untracked work: " + ", ".join(os.fsdecode(name) for name in collisions if not name.endswith(b".gd.uid")))
    files = []
    for name in collisions:
        path = root / os.fsdecode(name)
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError(f"UID collision is not a regular file: {path}")
        data = path.read_bytes()
        if not UID.fullmatch(data):
            raise ValueError(f"UID collision has unexpected content: {path}")
        files.append((name, data))
    result = {"target": target, "source_untracked_count": len(untracked), "source_target_tracked_count": len(target_paths), "collision_count": len(files), "collisions": [os.fsdecode(name) for name, _ in files]}
    if action == "preserve" and files:
        backup_root = root / ".task_tmp" / "fm-playbot-uid-collisions"
        for component in (root / ".task_tmp", backup_root):
            if component.is_symlink():
                raise ValueError(f"UID backup path is a symlink: {component}")
        probe = backup_root / "probe"
        if subprocess.run(["git", "-C", str(root), "check-ignore", "-q", "--", str(probe)], check=False, capture_output=True).returncode != 0:
            raise ValueError(".task_tmp/ backup destination is not Git-ignored")
        backup = backup_root / f"{target[:12]}-{uuid.uuid4().hex}"
        backup.mkdir(parents=True, mode=0o700)
        manifest = []
        for name, data in files:
            destination = backup / os.fsdecode(name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            if destination.read_bytes() != data:
                raise ValueError(f"UID backup verification failed: {destination}")
            manifest.append({"path": os.fsdecode(name), "sha256": hashlib.sha256(data).hexdigest()})
        (backup / "manifest.json").write_text(json.dumps({"target": target, "files": manifest}, indent=2) + "\n")
        for name, data in files:
            path = root / os.fsdecode(name)
            if path.read_bytes() != data:
                raise ValueError(f"UID changed before removal; complete backup retained at {backup}")
        for name, _ in files:
            (root / os.fsdecode(name)).unlink()
        result["backup"] = str(backup)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
