#!/usr/bin/env python3
"""Build and settle one bounded landing train window under fm-landing-queue.sh's lock.

The queue header owns the protocol. Input rows are id, branch, source SHA,
replay base SHA, and owner task; output rows are id, phase, candidate SHA, suite receipt, quick
receipt, and reason. This helper never advances the landing branch.
"""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def run(*args, check=True, timeout=20, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout, **kwargs)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed: {result.stderr.strip()[:300]}")
    return result


def git(repo, *args, check=True):
    return run("git", "-C", str(repo), *args, check=check)


def atomic_json(path, data):
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=".candidate.", delete=False) as handle:
        json.dump(data, handle, sort_keys=True)
        handle.write("\n")
        name = handle.name
    os.replace(name, path)


def read_state(path):
    if not path.exists():
        return None
    if path.is_symlink():
        raise RuntimeError(f"candidate state is a symlink: {path}")
    data = json.loads(path.read_text())
    if data.get("schema") != "fm-landing-candidate.v1":
        raise RuntimeError(f"invalid candidate state: {path}")
    return data


def receipt(path, schema, sha, target=None):
    if path.is_symlink() or not path.is_file():
        return False
    expected = [f"schema={schema}", f"sha={sha}"]
    if schema == "fm-full-suite.v1":
        expected.append("failures=0")
    else:
        expected.append(f"target={target}")
    return path.read_text().splitlines() == expected


def farm_timeout():
    raw = os.environ.get("FM_TESTFARM_TIMEOUT", "10")
    return int(raw) if raw.isdigit() and 1 <= int(raw) <= 60 else 10


def fetch_receipt(request, path, schema, sha, target=None):
    """Fetch a passed request's farm receipt when the local file is missing.

    The text is checked against the exact candidate before an atomic publish.
    An unreadable farm or a receipt naming another SHA leaves the path untouched.
    """
    if receipt(path, schema, sha, target):
        return True
    if path.is_symlink() or not isinstance(request, str):
        return False
    try:
        result = run(os.environ.get("FM_TESTFARM_BIN") or "testfarm", "receipt", "get", request, check=False, timeout=farm_timeout())
    except (subprocess.TimeoutExpired, OSError):
        return False
    if result.returncode:
        return False
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=".candidate-receipt.", delete=False) as handle:
        handle.write(result.stdout)
        name = handle.name
    if receipt(Path(name), schema, sha, target):
        os.replace(name, path)
        return True
    os.unlink(name)
    return False


def cancel(service, state):
    for key in ("suite_request", "quick_request"):
        rid = state.get(key)
        if rid:
            try:
                run(service, "cancel", rid, check=False, timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                pass


def retire(repo, service, state_path, state, ref):
    if state:
        cancel(service, state)
    state_path.unlink(missing_ok=True)
    git(repo, "update-ref", "-d", ref, check=False)


def build(repo, scratch_root, source, base, parent, ref):
    if git(repo, "merge-base", "--is-ancestor", base, source, check=False).returncode:
        raise RuntimeError("replay base is not an ancestor of the source head")
    if not git(repo, "merge-base", "--is-ancestor", parent, source, check=False).returncode:
        if source == parent:
            raise RuntimeError("candidate replay produced no new commit")
        git(repo, "update-ref", ref, source)
        return source
    with tempfile.TemporaryDirectory(prefix=".build-", dir=scratch_root) as tmp:
        scratch = Path(tmp) / "worktree"
        git(repo, "worktree", "add", "--detach", "--quiet", str(scratch), source)
        try:
            result = git(scratch, "-c", "user.name=Landing Train", "-c",
                         "user.email=landing-train@localhost", "rebase", "--force-rebase",
                         "--keep-empty", "--empty=keep", "--rebase-merges",
                         "--onto", parent, base, source, check=False)
            if result.returncode:
                conflict = bool(git(scratch, "ls-files", "-u").stdout.strip())
                if conflict:
                    return None
                raise RuntimeError(f"candidate rebase failed: {result.stderr.strip()[:300]}")
            sha = git(scratch, "rev-parse", "HEAD").stdout.strip()
            if sha == parent:
                raise RuntimeError("candidate replay produced no new commit")
            git(repo, "update-ref", ref, sha)
            return sha
        finally:
            git(scratch, "rebase", "--abort", check=False)
            git(repo, "worktree", "remove", "--force", str(scratch))


def request_status(service):
    try:
        result = run(service, "status", "--json", check=False, timeout=10)
    except (subprocess.TimeoutExpired, json.JSONDecodeError):
        return None
    if result.returncode:
        return None
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("requests"), list):
        return None
    return {row.get("id"): row for row in data["requests"] if isinstance(row, dict)}


def submit_timeout():
    raw = os.environ.get("FM_TESTFARM_SUBMIT_TIMEOUT", "120")
    if not raw.isdigit() or not 1 <= int(raw) <= 900:
        raise RuntimeError("FM_TESTFARM_SUBMIT_TIMEOUT must be a whole number of seconds from 1 to 900")
    return int(raw)


def find_accepted(live, project_name, sha, task, check, target=None):
    """Return the id of a farm request already accepted for this exact work."""
    for rid, row in sorted((live or {}).items(), key=lambda item: str(item[0])):
        options = row.get("options") if isinstance(row.get("options"), dict) else {}
        label = row.get("task") or options.get("task")
        if label != task or row.get("state") in ("failed", "conflict", "cancelled"):
            continue
        if row.get("project") not in (None, project_name):
            continue
        if matches_request(row, sha, check, target) and isinstance(rid, str):
            return rid
    return None


def submit(service, project_name, repo, sha, task, *options, live=None):
    """Submit once, adopting an accepted duplicate before and after a slow submit."""
    check = options[options.index("--check") + 1] if "--check" in options else "full"
    target = options[options.index("--target") + 1] if "--target" in options else None
    existing = find_accepted(live, project_name, sha, task, check, target)
    if existing:
        return existing
    try:
        result = run(service, "submit", project_name, str(repo), sha, "--task", task, *options,
                     timeout=submit_timeout())
    except subprocess.TimeoutExpired:
        adopted = find_accepted(request_status(service), project_name, sha, task, check, target)
        if adopted:
            return adopted
        raise RuntimeError("test service submit timed out and no accepted request was found")
    rid = result.stdout.strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", rid):
        raise RuntimeError("test service returned an invalid request id")
    return rid


def failure_reason(value, fallback):
    clean = " ".join(str(value or fallback).split())[:250]
    return clean.replace("\t", " ") or fallback


def matches_request(row, sha, check, target=None):
    if not isinstance(row, dict) or row.get("sha") != sha:
        return False
    options = row.get("options")
    if not isinstance(options, dict) or options.get("suite") is not True:
        return False
    if check == "quick":
        return options.get("check") == "quick" and options.get("target") == target \
            and bool(options.get("device_gate"))
    return options.get("check") in (None, "full") and not options.get("device_gate")


def main(observe=False):
    args = sys.argv[2:10] if observe else sys.argv[1:9]
    repo, directory, key, tip, depth, service, project_name, rows_file = args
    repo, directory = Path(repo), Path(directory)
    depth = int(depth)
    rows = [line.split("\t") for line in Path(rows_file).read_text().splitlines()]
    if any(len(row) != 5 for row in rows):
        raise RuntimeError("invalid train input")
    if not observe:
        # A bounded sweep may have killed a prior build. The queue lock
        # guarantees every scratch directory belongs to an inactive call.
        for stale_build in directory.glob(".build-*"):
            if stale_build.is_dir() and not stale_build.is_symlink():
                scratch = stale_build / "worktree"
                if scratch.exists():
                    git(repo, "worktree", "remove", "--force", str(scratch), check=False)
                shutil.rmtree(stale_build)
        active = {row[0] for row in rows}
        for stale in directory.glob("candidate-*.json"):
            task = stale.name.removeprefix("candidate-").removesuffix(".json")
            if task not in active:
                retire(repo, service, stale, read_state(stale),
                       f"refs/landing-candidates/{key}/{task}")
    live = {} if observe else request_status(service)
    if live is None:
        print("!farm\tunreachable\t-\t-\t-\tstatus unavailable")
    parent = tip
    output = []
    for place, (task, branch, source, base, owner) in enumerate(rows, 1):
        path = directory / f"candidate-{task}.json"
        ref = f"refs/landing-candidates/{key}/{task}"
        state = read_state(path)
        if place > depth:
            if state and not observe:
                retire(repo, service, path, state, ref)
            output.append((task, "waiting", "-", "-", "-", "-"))
            continue
        valid = state and state.get("branch") == branch and state.get("owner") == owner and state.get("source") == source \
            and state.get("base") == base and state.get("parent") == parent \
            and git(repo, "rev-parse", "--verify", ref, check=False).stdout.strip() == state.get("sha")
        if observe:
            if not valid:
                output.append((task, "checking", "-", "-", "-", "-"))
                parent = "-"
                continue
            sha = state["sha"]
            full = directory / f"candidate-{task}-{sha}.full.receipt"
            quick = directory / f"candidate-{task}-{sha}.quick.receipt"
            phase = "ready" if state.get("verified") is True \
                and receipt(full, "fm-full-suite.v1", sha) \
                and receipt(quick, "fm-quick-check.v1", sha, parent) else "checking"
            output.append((task, phase, sha, str(full), str(quick), "-"))
            parent = sha
            continue
        if not valid:
            if state:
                retire(repo, service, path, state, ref)
            sha = build(repo, directory, source, base, parent, ref)
            if sha is None:
                output.append((task, "failed", "-", "-", "-", "candidate merge conflict"))
                continue
            state = {"schema": "fm-landing-candidate.v1", "branch": branch, "owner": owner,
                     "source": source, "base": base, "parent": parent, "sha": sha,
                     "suite_request": None, "quick_request": None, "verified": False}
            atomic_json(path, state)
        sha = state["sha"]
        full = directory / f"candidate-{task}-{sha}.full.receipt"
        quick = directory / f"candidate-{task}-{sha}.quick.receipt"
        if live is None:
            output.append((task, "checking", sha, "-", "-", "-"))
            parent = sha
            continue
        if not state["suite_request"]:
            state["suite_request"] = submit(service, project_name, repo, sha,
                                             owner, "--suite", "--receipt", str(full), live=live)
            atomic_json(path, state)
        suite_row = live.get(state["suite_request"]) if live else None
        if not matches_request(suite_row, sha, "full"):
            suite_row = None
        if suite_row and suite_row.get("state") in ("failed", "conflict", "cancelled"):
            reason = failure_reason(suite_row.get("error"), "editor suite failed")
            retire(repo, service, path, state, ref)
            output.append((task, "failed", "-", "-", "-", reason))
            continue
        if not (suite_row and suite_row.get("state") == "passed" and
                suite_row.get("sha") == sha
                and fetch_receipt(state["suite_request"], full, "fm-full-suite.v1", sha)):
            output.append((task, "checking", sha, "-", "-", "-"))
            parent = sha
            continue
        if not state["quick_request"]:
            state["quick_request"] = submit(service, project_name, repo, sha,
                                             owner, "--suite", "--check", "quick",
                                             "--target", state["parent"], "--device-gate", "any",
                                             "--receipt", str(quick), live=live)
            atomic_json(path, state)
        quick_row = live.get(state["quick_request"]) if live else None
        if not matches_request(quick_row, sha, "quick", state["parent"]):
            quick_row = None
        if quick_row and quick_row.get("state") in ("failed", "conflict", "cancelled"):
            reason = failure_reason(quick_row.get("error"), "short phone check failed")
            retire(repo, service, path, state, ref)
            output.append((task, "failed", "-", "-", "-", reason))
            continue
        phase = "checking"
        if quick_row and quick_row.get("state") == "passed" and quick_row.get("sha") == sha \
                and fetch_receipt(state["quick_request"], quick, "fm-quick-check.v1",
                                  sha, state["parent"]):
            phase = "ready"
            if not state.get("verified"):
                state["verified"] = True
                atomic_json(path, state)
        output.append((task, phase, sha, str(full), str(quick), "-"))
        parent = sha
    for row in output:
        print("\t".join(row))


def retire_all():
    _, repo, directory, key, service = sys.argv[1:6]
    repo, directory = Path(repo), Path(directory)
    for path in directory.glob("candidate-*.json"):
        task = path.name.removeprefix("candidate-").removesuffix(".json")
        retire(repo, service, path, read_state(path),
               f"refs/landing-candidates/{key}/{task}")


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["retire"]:
            retire_all()
        elif sys.argv[1:2] == ["observe"]:
            main(observe=True)
        else:
            main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"error: landing train: {exc}", file=sys.stderr)
        sys.exit(1)
