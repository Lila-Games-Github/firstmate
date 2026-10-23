#!/usr/bin/env bash
# Exercise Editor suite discovery through the panel's executable interface.
set -euo pipefail

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(fm_test_tmproot fm-crew-board-editor-parallel)
python3 - "$ROOT/bin/fm-crew-board-panels.py" "$tmp" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

panel, base = sys.argv[1], Path(sys.argv[2])
state, proc, queue, service = (base / name for name in ("state", "proc", "queue", "service"))
for path in (state, proc, queue / "tickets", service):
    path.mkdir(parents=True)
now = time.time()
trees = []
for number in range(1, 6):
    tree = base / f"wt-{number}"
    tree.mkdir()
    subprocess.run(["git", "init", "-q", str(tree)], check=True)
    subprocess.run(["git", "-C", str(tree), "-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "-q", "--allow-empty", "-m", "fixture"], check=True)
    trees.append(tree)
    if number < 5:
        (state / f"task-{number}.meta").write_text(f"worktree={tree}\n")

snapshot = base / "snapshot.json"
snapshot.write_text(json.dumps({"schema": "fm-fleet-snapshot.v1", "tasks": []}))
env = {**os.environ, "FM_HOME": str(base), "FM_STATE_OVERRIDE": str(state),
       "FM_DATA_OVERRIDE": str(base / "data"), "FM_CREW_BOARD_PROC_ROOT": str(proc),
       "FROGPILE_SUITE_QUEUE": str(queue), "FROGPILE_SUITE_LOCK_HOLDER": str(base / "absent-holder"),
       "FM_CREW_BOARD_PHONE_QUEUE_ROOT": str(base / "phone-queues"), "FM_TEST_SERVICE_STATE": str(service)}

def spawn(pid, tree, script="tests/run_tests.gd", progress="38/100 tests", extra=()):
    process = proc / str(pid)
    (process / "fd").mkdir(parents=True)
    (process / "cmdline").write_bytes(b"godot\0--headless\0--script\0" + script.encode() + b"\0"
                                        + b"\0".join(arg.encode() for arg in extra))
    (process / "stat").write_text(f"{pid} (godot) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n")
    (process / "started").write_text(str(now - pid % 300))
    (process / "cwd").symlink_to(tree)
    log = base / f"{pid}.log"
    log.write_text("starting\n" + progress + "\n")
    (process / "fd/1").symlink_to(log)

def read():
    result = subprocess.run([sys.executable, panel, str(snapshot)], env=env,
                            capture_output=True, text=True, check=True)
    return [row for row in json.loads(result.stdout)["test_queue"] if row["id"].startswith("suite-")]

assert read()[0]["title"] == "EDITOR: 0 running, 0 waiting"
spawn(900001, trees[0])
rows = read()
assert rows[0]["title"] == "EDITOR: 1 running, 0 waiting", rows
assert "task-1" in rows[1]["title"] and "38/100 tests" in rows[1]["title"], rows
assert "Version: " in rows[1]["detail"] and "for " in rows[1]["detail"], rows
for number in range(2, 5):
    spawn(900000 + number, trees[number - 1])
assert read()[0]["title"] == "EDITOR: 4 running, 0 waiting"
spawn(900005, trees[4])
rows = read()
assert rows[0]["title"] == "EDITOR: 5 running, 0 waiting" and "wt-5" in rows[-1]["title"], rows
spawn(900006, trees[0], "tests/run_focused.gd")
spawn(900008, trees[0], extra=("--", "--focused=SomeTest"))
spawn(900009, trees[0], extra=("--", "--focused", "SomeTest"))
spawn(900010, trees[0], extra=("--", "--lock-check-only"))
assert read()[0]["title"] == "EDITOR: 5 running, 0 waiting"
spawn(900011, trees[3], progress="Loaded 3 of 12 scenes\n2026/10/23 build")
rows = read()
assert rows[0]["title"] == "EDITOR: 6 running, 0 waiting", rows
assert not any("tests" in row["title"] for row in rows if row["id"] == "suite-running-900011"), rows
shutil.rmtree(proc / "900011")

(service / "status.json").write_text(json.dumps({"schema": "fm-test-service.v1", "requests": [
    {"id": "bad1", "state": "running", "options": {"suite": True}, "steps": None},
    {"id": "bad2", "state": "running", "options": {"suite": True}, "steps": ["x", {"name": "suite", "state": "running", "started": "-inf"}]},
    {"id": "bad3", "state": "queued", "source": str(trees[2]), "options": {"suite": True}, "wait_seconds": "soon", "steps": 7}]}))
rows = read()
assert rows[0]["title"] == "EDITOR: 6 running, 1 waiting", rows
assert any(row["id"] == "suite-wait-service-bad3" and row["status"] == "waiting unknown time" for row in rows), rows
(service / "status.json").write_text(json.dumps({"schema": "fm-test-service.v1", "requests": 5}))
assert read()[0]["title"] == "EDITOR: 5 running, 0 waiting"

# A service suite running from its private copy is the same process, not a sixth run.
run_copy = service / "runs/r1"
run_copy.parent.mkdir(parents=True)
subprocess.run(["git", "clone", "--quiet", str(trees[0]), str(run_copy)], check=True)
(run_copy / "prototype-game").mkdir()
spawn(900007, run_copy / "prototype-game")
(service / "status.json").write_text(json.dumps({"schema": "fm-test-service.v1", "requests": [
    {"id": "r1", "state": "running", "source": str(trees[0]), "sha": "abc1234", "generation": 0,
     "options": {"suite": True}, "steps": [{"name": "suite", "state": "running", "started": now - 60}]},
    {"id": "r2", "state": "queued", "source": str(trees[1]), "sha": "def5678",
     "options": {"suite": True}, "wait_seconds": 90, "steps": []}]}))
rows = read()
assert rows[0]["title"] == "EDITOR: 6 running, 1 waiting", rows
assert len([row for row in rows if row["id"].startswith("suite-running-")]) == 6, rows
assert any(row["id"] == "suite-running-900007" and "task-1" in row["title"] for row in rows), rows
assert any(row["id"] == "suite-wait-service-r2" for row in rows), rows
shutil.rmtree(proc / "900007")
rows = read()
assert rows[0]["title"] == "EDITOR: 6 running, 1 waiting", rows
assert any("test service request r1" in row["detail"] for row in rows), rows
print("ok - Editor lists zero, one, four, unknown, focused, and service suites")
PY
