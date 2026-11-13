#!/usr/bin/env python3
"""Enumerate active task branches and trial-merge them after a landing.

Usage: fm-landing-conflicts.py <home> <state> <project> <landing-branch> [--remote]
Output is tab-separated: task, branch, head, tip, result, JSON path list.
Only conflict and unknown rows are emitted. --remote reads the landed tip from
the project's origin into a disposable clone; no project ref is fetched.
"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


TASK = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def meta(path):
    values = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def default_branch(project):
    result = git(project, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    if result.returncode == 0:
        return result.stdout.decode().strip()[len("origin/"):]
    for branch in ("main", "master"):
        if git(project, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}").returncode == 0:
            return branch
    return None


def commit(repo, ref):
    result = git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    return result.stdout.decode().strip() if result.returncode == 0 else None


def emit(task, branch, head, tip, result, paths=None):
    print("\t".join((task, branch, head or "-", tip or "-", result,
                     json.dumps(paths or [], ensure_ascii=True, separators=(",", ":")))))


def main():
    if len(sys.argv) not in (5, 6) or (len(sys.argv) == 6 and sys.argv[5] != "--remote"):
        raise SystemExit(__doc__)
    _, home, state_arg, project_arg, landing = sys.argv[:5]
    remote = len(sys.argv) == 6
    state = Path(state_arg)
    project = Path(project_arg).resolve()
    if not state.is_dir() or not project.is_dir():
        raise SystemExit("error: state or project directory unavailable")
    if git(project, "check-ref-format", f"refs/heads/{landing}").returncode:
        raise SystemExit("error: invalid landing branch")
    tasks = []
    for path in sorted(state.glob("*.meta")):
        task = path.name[:-5]
        if not TASK.fullmatch(task) or path.is_symlink():
            continue
        try:
            fields = meta(path)
        except OSError:
            continue
        recorded = fields.get("project")
        if not recorded or Path(recorded).resolve() != project:
            continue
        kind = fields.get("kind", "ship")
        if kind not in ("ship", "lane"):
            continue
        target = fields.get("landing_branch") or default_branch(project)
        if target != landing:
            continue
        branch = fields.get("lane_branch") if kind == "lane" else f"fm/{task}"
        if kind == "lane" and not branch:
            worktree = fields.get("worktree")
            if worktree:
                result = git(worktree, "symbolic-ref", "--quiet", "--short", "HEAD")
                if result.returncode == 0:
                    branch = result.stdout.decode().strip()
        tasks.append((task, branch or "-"))
    if not tasks:
        return
    with tempfile.TemporaryDirectory(prefix="fm-landing-conflicts-") as scratch:
        clone = Path(scratch) / "repo"
        cloned = subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout",
                                 str(project), str(clone)], capture_output=True)
        if cloned.returncode:
            for task, branch in tasks:
                emit(task, branch, None, None, "unknown")
            return
        if remote:
            source = git(project, "remote", "get-url", "origin")
            if source.returncode:
                tip = None
            else:
                fetched = git(clone, "fetch", "--quiet", "--no-tags",
                              source.stdout.decode().strip(), f"refs/heads/{landing}")
                tip = commit(clone, "FETCH_HEAD") if fetched.returncode == 0 else None
        else:
            tip = commit(project, f"refs/heads/{landing}")
        for task, branch in tasks:
            valid = branch != "-" and git(project, "check-ref-format", f"refs/heads/{branch}").returncode == 0
            head = commit(project, f"refs/heads/{branch}") if valid else None
            if not head or not tip:
                emit(task, branch, head, tip, "unknown")
                continue
            if git(clone, "merge-base", "--is-ancestor", head, tip).returncode == 0:
                continue
            merged = git(clone, "merge-tree", "--write-tree", "--name-only", "-z", tip, head)
            if merged.returncode == 0:
                continue
            if merged.returncode != 1:
                emit(task, branch, head, tip, "unknown")
                continue
            parts = merged.stdout.split(b"\0")
            if not parts or not re.fullmatch(rb"[0-9a-f]{40,64}", parts[0]):
                emit(task, branch, head, tip, "unknown")
                continue
            paths = []
            for part in parts[1:]:
                if not part:
                    break
                paths.append(os.fsdecode(part))
            if paths:
                emit(task, branch, head, tip, "conflict", paths)
            else:
                emit(task, branch, head, tip, "unknown")


if __name__ == "__main__":
    main()
