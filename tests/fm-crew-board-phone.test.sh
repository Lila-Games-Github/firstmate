#!/usr/bin/env bash
# Exercise the phone HTTP boundary with a hostile published board fixture.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as temporary:
    home = Path(temporary)
    (home / "state").mkdir()
    payload = {
        "schema": "fm-crew-board.v1", "generated_epoch": int(time.time()),
        "rows": [{"id": "fm-internal-worker", "title": "Ship phone view", "phase": "building",
                  "note": "raw worker output /private/worktree token=SECRET123", "gone": False,
                  "secret_key": "SECRET123", "path": "/private/worktree"}],
        "panels": {
            "full_questions": [{"title": "Choose release", "status": "decision",
                                "detail": "PIN: 1234 /private/path raw worker output"}],
            "full_backlog": [{"title": "Held for the captain", "status": "section"},
                             {"title": "Choose build target", "status": "held", "detail": "secret=SECRET123"},
                             {"title": "Waiting on others", "status": "section"}],
            "merge_waiting": {"fm-internal-worker": "https://github.com/example/repo/pull/7"},
            "alerts": [{"title": "fm-internal-worker: blocked", "status": "blocked",
                        "detail": "Worker-internal failure"}],
            "ready": [{"title": "Ship phone view", "status": "merge?", "link": "https://github.com/example/repo/pull/7"}],
            "phones": [{"title": "Galaxy S22", "status": "idle", "id": "device-serial", "pin": "1234"}],
            "allowance": [{"title": "Codex", "status": "50%", "detail": "api_key=SECRET123"}],
        },
        "raw_output": "SECRET123 /private/path"
    }
    (home / "state" / "crew-board.json").write_text(json.dumps(payload))
    env = os.environ.copy()
    env["FM_HOME"] = str(home)
    bad = subprocess.run([sys.executable, str(root / "bin/fm-crew-board-phone.py"),
                          "--bind", "0.0.0.0", "--port", "0"], env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
    assert bad.returncode != 0 and "only binds to loopback" in bad.stderr, bad.stderr

    import importlib.util
    spec = importlib.util.spec_from_file_location("phone", root / "bin/fm-crew-board-phone.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    from threading import Thread
    server = module.LoopbackServer(("127.0.0.1", 0), module.Handler)
    server.board = home / "state" / "crew-board.json"
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base = f"http://127.0.0.1:{server.server_port}"
        body = urlopen(base + "/api/board", timeout=3).read().decode()
        data = json.loads(body)
        assert data["workers"] == [{"title": "Ship phone view", "state": "building"}], data
        assert any(row["link"] == "https://github.com/example/repo/pull/7" for row in data["needs"]), data
        assert any(row["title"] == "Choose build target" for row in data["needs"]), data
        assert not any("Worker-internal failure" in row["title"] for row in data["needs"]), data
        assert all(s not in body for s in ("SECRET123", "1234", "/private/", "raw worker output",
                                             "fm-internal-worker", "device-serial", "secret_key", "path")), body
        assert b"Needs you" in urlopen(base + "/", timeout=3).read()
        assert b"Recent landings" in urlopen(base + "/details", timeout=3).read()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
print("ok: phone endpoint strips private data and refuses public binding")
PY
