#!/usr/bin/env python3
"""Receive testfarm-owned notifications for an immutable submitting worker.

fm-test-service.py captures FM_FARM_WORKER_BINDING before submitting. Testfarm
freezes that JSON in its local notification binding, and sends only its SHA-256
owner and an opaque endpoint to the server. No executable or home path crosses
the remote gateway. state/farm-bindings/<owner>.json is the fallback's binding.

Usage: fm-farm-deliver.py deliver (message on stdin; TESTFARM_NOTIFY_REQUEST and
TESTFARM_NOTIFY_TASK from testfarm). Exit 0 means accepted (the JSON receipt
distinguishes queued/unknown from delivered), 3 means the bound worker retired
or changed, and 1 means retry. No watcher, chat turn or Firstmate timer runs.

The receiver and fallback serialize through .farm-results.lock. Durable receipts
under farm-delivery/<owner>/<request>.json suppress replay by request identity,
even if the fallback reconstructed a different body. A sending receipt left by
a killed receiver is reported as unknown, never blindly resent: Playbot has no
transactional send/receipt interface. Retain that audit for reconciliation.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

IDENTITY = ("kind", "spawn_gen", "playbot_project", "playbot_workspace", "playbot_thread")
SAFE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")


def durable_directory(path):
    missing, current = [], path
    while not current.exists():
        missing.append(current)
        current = current.parent
    for directory in reversed(missing):
        directory.mkdir(exist_ok=True, mode=0o700)
        descriptor = os.open(directory.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def atomic_json(path, value):
    durable_directory(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=".tmp-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def meta_identity(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("worker metadata is absent or symlinked")
    raw = path.read_text()
    fields = dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)
    if fields.get("kind") == "lane":
        if not all(fields.get(key) for key in ("playbot_project", "playbot_workspace", "playbot_thread")):
            raise ValueError("lane has no exact project/workspace/thread identity")
        return {key: fields.get(key, "") for key in IDENTITY}
    # fm-send validates this generation again under its final metadata lock.
    if fields.get("spawn_gen"):
        return {"kind": fields.get("kind", ""), "spawn_gen": fields["spawn_gen"]}
    raise ValueError("ordinary worker has no spawn_gen; cannot bind its incarnation safely")


def owner_for(raw):
    return hashlib.sha256(raw.encode()).hexdigest()


def capture(home, state, task):
    if Path(state).is_symlink() or not Path(state).is_dir():
        raise ValueError("worker state is absent or symlinked")
    binding = {"schema": "fm-farm-worker.v1", "home": str(Path(home).resolve()),
               "state": str(Path(state).resolve()), "task": task,
               "identity": meta_identity(Path(state) / (task + ".meta"))}
    raw = json.dumps(binding, sort_keys=True, separators=(",", ":"))
    atomic_json(Path(state) / "farm-bindings" / (owner_for(raw) + ".json"), binding)
    return raw


def holds(state, task, rid):
    needle = ("Test service completion: request=" + rid + " ").encode()
    for folder in (state / (task + ".inbox"), state / (task + ".inbox/handled"), state / (task + ".lane-sent")):
        if not folder.is_dir() or folder.is_symlink():
            continue
        for entry in folder.iterdir():
            if entry.is_file() and not entry.is_symlink() and not entry.name.startswith("."):
                if needle in entry.read_bytes():
                    return True
    return False


def validate(binding):
    if binding.get("schema") != "fm-farm-worker.v1" or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", binding.get("task", "")):
        raise ValueError("invalid worker binding")
    state = Path(binding["state"])
    if not state.is_absolute() or state.is_symlink() or not state.is_dir():
        raise ValueError("bound worker state is absent or symlinked")
    if meta_identity(state / (binding["task"] + ".meta")) != binding["identity"]:
        raise ValueError("bound worker identity changed; refusing task-label reuse")


def deliver_locked(binding, owner, rid, message):
    """Public fallback interface; caller holds the home's .farm-results.lock."""
    validate(binding)
    if not SAFE_ID.fullmatch(rid):
        raise ValueError("invalid request identity")
    state, task = Path(binding["state"]), binding["task"]
    path = state / "farm-delivery" / owner / (rid + ".json")
    if path.is_file():
        try:
            receipt = json.loads(path.read_text())
            if receipt.get("schema") != "fm-farm-delivery.v1" or receipt.get("owner") != owner or receipt.get("request") != rid:
                raise ValueError("receipt identity mismatch")
        except (ValueError, AttributeError) as exc:
            raise RuntimeError("corrupt delivery receipt; refusing an unsafe replay") from exc
        if receipt["state"] != "retry":
            if receipt["state"] == "sending":
                receipt.update(state="already-held" if holds(state, task, rid) else "unknown",
                               note="receiver stopped during delivery; do not blindly resend")
                atomic_json(path, receipt)
            return receipt
    receipt = {"schema": "fm-farm-delivery.v1", "owner": owner, "request": rid, "task": task,
               "identity": binding["identity"], "message_sha256": hashlib.sha256(message.encode()).hexdigest(),
               "at": time.time(), "state": "accepted"}
    if holds(state, task, rid):
        receipt["state"] = "already-held"
        atomic_json(path, receipt)
        return receipt
    code = Path(__file__).resolve().parent
    env = dict(os.environ, FM_HOME=binding["home"], FM_STATE_OVERRIDE=str(state), FM_SEND_IDEMPOTENT="1")
    if binding["identity"].get("spawn_gen"):
        env["FM_SEND_EXPECTED_SPAWN_GEN"] = binding["identity"]["spawn_gen"]
    if binding["identity"].get("kind") == "lane":
        # Always target the frozen chat, even if teardown replaces metadata
        # between the identity check and the send.
        frozen = state / "farm-bindings" / owner / (task + ".meta")
        durable_directory(frozen.parent)
        frozen.write_text("".join(key + "=" + value + "\n" for key, value in binding["identity"].items()))
        command = [str(code / "fm-lane-send.sh"), str(frozen), message]
    else:
        command = [str(code / "fm-send.sh"), task, message]
    receipt["state"] = "sending"
    atomic_json(path, receipt)
    try:
        sent = subprocess.run(command, env=env, stdin=subprocess.DEVNULL, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except subprocess.TimeoutExpired:
        receipt.update(state="unknown", note="delivery timed out; do not blindly resend")
        atomic_json(path, receipt)
        return receipt
    except OSError as exc:
        receipt.update(state="retry", error=str(exc))
        atomic_json(path, receipt)
        raise RuntimeError(str(exc)) from exc
    if sent.returncode:
        receipt.update(state="retry", error=sent.stderr.strip())
        atomic_json(path, receipt)
        raise RuntimeError(sent.stderr.strip() or "worker delivery refused")
    verdict = re.search(r": delivery (delivered|sending|steering|queued|unknown)\b", sent.stdout)
    receipt.update(state=verdict.group(1) if verdict else "accepted", output=sent.stdout.strip())
    atomic_json(path, receipt)
    return receipt


def main():
    if sys.argv[1:] != ["deliver"]:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    raw = os.environ["FM_FARM_WORKER_BINDING"]
    binding = json.loads(raw)
    if os.environ["TESTFARM_NOTIFY_TASK"] != binding["task"]:
        raise ValueError("notification task does not match frozen worker")
    validate(binding)
    with (Path(binding["state"]) / ".farm-results.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        receipt = deliver_locked(binding, owner_for(raw), os.environ["TESTFARM_NOTIFY_REQUEST"], sys.stdin.read())
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError) as error:
        print("error:", error, file=sys.stderr)
        sys.exit(3)
    except (OSError, RuntimeError) as error:
        print("error:", error, file=sys.stderr)
        sys.exit(1)
