#!/usr/bin/env python3
"""Prepare and collect a Playbot lane's workspace-local Firstmate exchange.

Usage: fm-lane-workspace-bridge.py prepare HOME TASK WORKTREE
       fm-lane-workspace-bridge.py collect HOME TASK WORKTREE
       fm-lane-workspace-bridge.py request OP [ARG ...]

The copied request endpoint writes only below its own workspace directory.
The controller endpoint owns all reads and writes in the Firstmate home.
"""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid


TASK = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
OPS = {"base-check", "addon-guard", "uid-collisions", "test-service", "landing-queue", "ensure-agents"}
MAX_FILE = 64 * 1024 * 1024


def fail(message):
    raise ValueError(message)


def plain_dir(path):
    if path.is_symlink() or not path.is_dir():
        fail(f"unsafe lane directory: {path}")


def plain_file(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_FILE:
        fail(f"unsafe lane file: {path}")


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temp.write_bytes(data)
    os.replace(temp, path)


def safe_destination(base, relative):
    target = base / relative
    current = base
    for part in Path(relative).parts[:-1]:
        if part in {".", ".."}:
            fail("unsafe lane output path")
        current = current / part
        current.mkdir(exist_ok=True)
        plain_dir(current)
    if target.exists() or target.is_symlink():
        plain_file(target)
    return target


def exchange(root, task):
    if not TASK.fullmatch(task):
        fail("invalid lane task id")
    root = Path(root).resolve(strict=True)
    actual = subprocess.run(["git", "-C", str(root), "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    if Path(actual).resolve() != root:
        fail("lane root is not the registered worktree top level")
    return root, root / ".firstmate" / task


def prepare(home, task, root):
    root, box = exchange(root, task)
    git_dir = subprocess.run(["git", "-C", str(root), "rev-parse", "--git-common-dir"], capture_output=True, text=True, check=True).stdout.strip()
    common = Path(git_dir)
    if not common.is_absolute():
        common = root / common
    exclude = common / "info" / "exclude"
    plain_file(exclude) if exclude.exists() else plain_dir(exclude.parent)
    lines = exclude.read_text().splitlines() if exclude.exists() else []
    if "/.firstmate/" not in lines:
        with exclude.open("a") as stream:
            stream.write("\n/.firstmate/\n")
    box.parent.mkdir(exist_ok=True)
    plain_dir(box.parent)
    box.mkdir(exist_ok=True)
    plain_dir(box)
    for name in ("requests", "responses", "receipts", "captures"):
        (box / name).mkdir(exist_ok=True)
        plain_dir(box / name)
    copied = box / "fm-lane-workspace-bridge.py"
    atomic(copied, Path(__file__).resolve().read_bytes())
    copied.chmod(0o700)
    ignored = subprocess.run(["git", "-C", str(root), "check-ignore", "-q", str(copied)]).returncode == 0
    if not ignored:
        fail("workspace exchange is not Git-ignored")
    return box


def request(box, op, args):
    box = Path(box).resolve(strict=True)
    if box.name == ".firstmate" or box.parent.name != ".firstmate":
        fail("request endpoint is outside a task exchange")
    plain_dir(box)
    if op not in OPS:
        fail(f"unsupported lane request: {op}")
    ident = uuid.uuid4().hex
    payload = {"op": op, "args": args}
    atomic(box / "requests" / f"{ident}.json", (json.dumps(payload) + "\n").encode())
    response = box / "responses" / f"{ident}.json"
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if response.exists():
            plain_file(response)
            result = json.loads(response.read_text())
            (box / "requests" / f"{ident}.json").unlink(missing_ok=True)
            response.unlink()
            print(result.get("output", ""), end="")
            return int(result.get("code", 1))
        time.sleep(1)
    fail(f"lane request {ident} timed out; keep the request file for firstmate to inspect")


def inside_exchange(root, task, value):
    target = (root / value).resolve()
    box = root / ".firstmate" / task
    if target != box and box not in target.parents:
        fail("lane request names a path outside its workspace exchange")
    return str(target)


def command(home, task, root, op, args):
    code = Path(__file__).resolve().parent
    env = dict(os.environ, FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / "state"), FM_DATA_OVERRIDE=str(home / "data"))
    if op == "base-check":
        if len(args) not in (1, 2) or (len(args) == 2 and args[1] != "--publishes"):
            fail("base-check expects landing branch and optional --publishes")
        argv = [str(code / "fm-lane-base-check.sh"), *args]
    elif op == "addon-guard":
        if not args or args[0] not in {"verify", "check-index", "reset", "lane-rebase"} or len(args) > 2:
            fail("unsupported addon-guard action")
        argv = ["node", "--no-warnings", str(code / "fm-playbot-lanes.mjs"), "addon-guard", *args]
    elif op == "uid-collisions":
        if len(args) != 2 or args[0] not in {"check", "preserve"} or not re.fullmatch(r"[a-f0-9]{40}", args[1]):
            fail("uid-collisions expects check|preserve and a full SHA")
        argv = [sys.executable, str(code / "fm-playbot-uid-collisions.py"), *args]
    elif op == "ensure-agents":
        if args:
            fail("ensure-agents takes no arguments")
        argv = [str(code / "fm-ensure-agents-md.sh"), "."]
    elif op == "test-service":
        if len(args) < 3 or args[0] != "submit" or not re.fullmatch(r"[A-Za-z0-9_-]+", args[1]):
            fail("test-service supports submit only")
        options = args[2:]
        if "--receipt" not in options or options.count("--receipt") != 1:
            fail("test-service request needs one workspace receipt")
        position = options.index("--receipt")
        if position + 1 >= len(options):
            fail("test-service receipt path is missing")
        options[position + 1] = inside_exchange(root, task, options[position + 1])
        if any(value in {"--task", "--project"} or value.startswith(("--task=", "--project=", "--receipt=")) for value in options):
            fail("test-service request override or compact receipt option is refused")
        sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
        argv = [sys.executable, str(code / "fm-test-service.py"), "submit", args[1], str(root), sha, "--task", task, *options]
    elif op == "landing-queue":
        if not args or args[0] not in {"status", "ready", "receipt", "gate", "fail"}:
            fail("unsupported landing-queue action")
        if any(value in {"--project", "--task"} or value.startswith(("--project=", "--task=", "--receipt=", "--gate-receipt=")) for value in args):
            fail("landing-queue request override or compact receipt option is refused")
        for position, value in enumerate(args):
            if value in {"--receipt", "--gate-receipt"}:
                if position + 1 >= len(args):
                    fail("landing-queue receipt path is missing")
                if value == "--receipt":
                    args[position + 1] = inside_exchange(root, task, args[position + 1])
                else:
                    name, separator, receipt = args[position + 1].partition("=")
                    if not separator or not re.fullmatch(r"[A-Za-z0-9_-]+", name):
                        fail("invalid landing gate receipt")
                    args[position + 1] = name + "=" + inside_exchange(root, task, receipt)
        argv = [str(code / "fm-landing-queue.sh"), args[0], task, "--project", str(root), *args[1:]]
    else:
        fail("unsupported lane request")
    run = subprocess.run(argv, cwd=root, env=env, capture_output=True, text=True, timeout=150)
    return {"code": run.returncode, "output": (run.stdout + run.stderr)[:100_000]}


def collect(home, task, root):
    home = Path(home).resolve(strict=True)
    if not TASK.fullmatch(task):
        fail("invalid lane task id")
    lock = home / "state" / f".{task}.lane-output.lock"
    with lock.open("a+b") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        return _collect(home, task, root)


def _collect(home, task, root):
    home = Path(home).resolve(strict=True)
    root, box = exchange(root, task)
    plain_dir(box.parent)
    plain_dir(box)
    state = home / "state"
    data = home / "data" / task
    plain_dir(state)
    data.mkdir(exist_ok=True)
    plain_dir(data)
    cursor_file = state / f"{task}.lane-output-cursor"
    if cursor_file.exists() or cursor_file.is_symlink():
        plain_file(cursor_file)
    cursor = json.loads(cursor_file.read_text()) if cursor_file.exists() else {"offset": 0, "files": {}}
    if not isinstance(cursor, dict) or not isinstance(cursor.get("offset"), int) or cursor["offset"] < 0 or not isinstance(cursor.get("files"), dict):
        fail("lane output cursor is malformed")
    for area in ("receipts", "captures"):
        source = box / area
        plain_dir(source)
        for file in source.rglob("*"):
            if file.is_dir():
                plain_dir(file)
                continue
            plain_file(file)
            relative = file.relative_to(box).as_posix()
            digest = hashlib.sha256(file.read_bytes()).hexdigest()
            if cursor["files"].get(relative) != digest:
                atomic(safe_destination(data, relative), file.read_bytes())
                if relative == "receipts/suite.receipt":
                    atomic(safe_destination(data, "suite.receipt"), file.read_bytes())
                cursor["files"][relative] = digest
    handoff = box / "phase-handoff.md"
    if handoff.exists():
        plain_file(handoff)
        digest = hashlib.sha256(handoff.read_bytes()).hexdigest()
        if cursor["files"].get(handoff.name) != digest:
            atomic(safe_destination(data, handoff.name), handoff.read_bytes())
            cursor["files"][handoff.name] = digest
    status = box / "status.log"
    if status.exists():
        plain_file(status)
        raw = status.read_bytes()
        offset = cursor["offset"]
        if len(raw) < offset:
            fail("lane status log shrank; refusing to lose or replay lines")
        end = raw.rfind(b"\n") + 1
        if end > offset:
            chunk = raw[offset:end]
            if b"\0" in chunk or any(len(line) > 8_192 for line in chunk.splitlines()):
                fail("lane status log contains an invalid line")
            status_target = state / f"{task}.status"
            if status_target.exists() or status_target.is_symlink():
                plain_file(status_target)
            with status_target.open("ab") as stream:
                stream.write(chunk)
            cursor["offset"] = end
    atomic(cursor_file, (json.dumps(cursor, sort_keys=True) + "\n").encode())
    requests = box / "requests"
    responses = box / "responses"
    plain_dir(requests)
    plain_dir(responses)
    for file in sorted(requests.glob("*.json")):
        plain_file(file)
        response = responses / file.name
        if response.exists():
            continue
        try:
            payload = json.loads(file.read_text())
            if not isinstance(payload, dict) or not isinstance(payload.get("op"), str) or not isinstance(payload.get("args"), list) or any(not isinstance(arg, str) for arg in payload["args"]):
                fail("invalid lane request")
            result = command(home, task, root, payload.get("op"), payload["args"])
        except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            result = {"code": 1, "output": f"lane request failed: {exc}\n"}
        atomic(response, (json.dumps(result) + "\n").encode())
    return {"status_bytes": cursor["offset"], "files": len(cursor["files"]), "requests": len(list(requests.glob("*.json")))}


def main():
    if len(sys.argv) < 2:
        fail(__doc__)
    verb = sys.argv[1]
    if Path(__file__).resolve().parent.parent.name == ".firstmate" and verb != "request":
        fail("workspace copy supports request only")
    if verb == "request":
        if len(sys.argv) < 3:
            fail("request requires an operation")
        return request(Path(__file__).resolve().parent, sys.argv[2], sys.argv[3:])
    if len(sys.argv) != 5 or verb not in {"prepare", "collect"}:
        fail(__doc__)
    home, task, root = sys.argv[2:]
    result = prepare(home, task, root) if verb == "prepare" else collect(home, task, root)
    print(str(result) if isinstance(result, Path) else json.dumps(result))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
