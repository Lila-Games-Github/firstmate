#!/usr/bin/env bash
# Exercise the phone HTTP boundary with a hostile published board fixture.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

OWNER = "owner@example.com"
NODE = shutil.which("node")
PAGE_HARNESS = r"""
const [html, pathname, board] = [process.argv[1], process.argv[2], JSON.parse(process.argv[3])];
const source = html.match(/<script>([\s\S]*)<\/script>/)[1];
const nodes = {};
const element = () => ({hidden: false, className: '', textContent: '', children: [], dataset: {},
  replaceChildren() { this.children = []; }, append(...kids) { this.children.push(...kids); },
  get firstChild() { return this.children[0]; }});
const document = {documentElement: element(), getElementById: id => nodes[id] ??= element(),
  createElement: () => element()};
const fetched = [];
const location = {pathname, search: '', hash: '', replaced: null, replace(url) { this.replaced = url; }};
const fetch = async url => { fetched.push(url); return {ok: true, json: async () => board}; };
new Function('document', 'location', 'fetch', 'setInterval', source)(document, location, fetch, () => 0);
setTimeout(() => console.log(JSON.stringify({replaced: location.replaced, fetched,
  needs: (nodes.needs?.children ?? []).length, moreNeedsHidden: nodes['more-needs']?.hidden ?? null})), 20);
"""


def run_page(html, pathname, board):
    result = subprocess.run([NODE, "-e", PAGE_HARNESS, html, pathname, json.dumps(board)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def status(url, login=None):
    headers = {} if login is None else {"Tailscale-User-Login": login}
    try:
        response = urlopen(Request(url, headers=headers), timeout=3)
        return response.status, response.read()
    except HTTPError as error:
        return error.code, error.read()


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
    env.pop("FM_STATE_OVERRIDE", None)
    env.pop("FM_CONFIG_OVERRIDE", None)
    unowned = subprocess.run([sys.executable, str(root / "bin/fm-crew-board-phone.py"), "--port", "0"],
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
    assert unowned.returncode != 0 and "crew-board-phone-owner" in unowned.stderr, unowned.stderr
    (home / "config").mkdir()
    (home / "config" / "crew-board-phone-owner").write_text(OWNER + "\n")
    bad = subprocess.run([sys.executable, str(root / "bin/fm-crew-board-phone.py"),
                          "--bind", "0.0.0.0", "--port", "0"], env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
    assert bad.returncode != 0 and "only binds to loopback" in bad.stderr, bad.stderr

    import importlib.util
    spec = importlib.util.spec_from_file_location("phone", root / "bin/fm-crew-board-phone.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    from threading import Thread
    server = module.LoopbackServer(("127.0.0.1", 0), module.Handler, OWNER)
    server.board = home / "state" / "crew-board.json"
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base = f"http://127.0.0.1:{server.server_port}"
        for path in ("/", "/details", "/api/board"):
            for login in (None, "", "intruder@example.com"):
                code, denied = status(base + path, login)
                assert code == 403 and b"Forbidden" in denied and b"Needs you" not in denied, (path, login, code)
                assert b"Ship phone view" not in denied, denied
        code, body = status(base + "/api/board", "Owner@Example.com")
        assert code == 200, code
        body = body.decode()
        data = json.loads(body)
        assert data["workers"] == [{"title": "Ship phone view", "state": "building"}], data
        assert any(row["link"] == "https://github.com/example/repo/pull/7" for row in data["needs"]), data
        assert any(row["title"] == "Choose build target" for row in data["needs"]), data
        assert not any("Worker-internal failure" in row["title"] for row in data["needs"]), data
        assert all(s not in body for s in ("SECRET123", "1234", "/private/", "raw worker output",
                                             "fm-internal-worker", "device-serial", "secret_key", "path")), body
        html = status(base + "/", OWNER)[1]
        assert b"Needs you" in html
        assert b"Recent landings" in status(base + "/details", OWNER)[1]

        held_board = dict(payload)
        held_board["panels"] = {
            "full_backlog": [{"title": "Held for the captain", "status": "section"},
                             {"id": "task-9", "title": "Polish onboarding - preview the build", "status": ""}],
            "ready": [{"id": "task-9", "title": "Polish onboarding", "status": "preview"},
                      {"id": "task-10", "title": "Approve the release branch", "status": "land?"}],
        }
        needs = module.project(held_board)["needs"]
        assert [row["title"] for row in needs] == ["Polish onboarding - preview the build",
                                                  "Approve the release branch"], needs

        titled = dict(payload)
        titled["rows"] = [{"id": str(n), "title": title, "phase": "building"} for n, title in enumerate((
            "Rotate token handling", "Fix password reset flow", "Pin the node version",
            "Unlock with PIN 1234", "Use token=abc rotation", "Set password: hunter2 now"))]
        shown = [row["title"] for row in module.project(titled)["workers"]]
        assert shown == ["Rotate token handling", "Fix password reset flow", "Pin the node version",
                         "Unlock with [redacted]", "Use [redacted] rotation", "Set [redacted] now"], shown

        if NODE:
            page = html.decode()
            board = json.loads(status(base + "/api/board", OWNER)[1])
            assert run_page(page, "/crew-board", board)["replaced"] == "/crew-board/"
            assert run_page(page, "/crew-board/details/", board)["replaced"] == "/crew-board/details"
            overview = run_page(page, "/crew-board/", board)
            assert overview["replaced"] is None and overview["fetched"] == ["api/board"], overview
            assert overview["moreNeedsHidden"] is True, overview
            assert run_page(page, "/crew-board/details", board)["replaced"] is None
            many = dict(board, needs=[{"title": f"Merge {n}", "status": "Merge ready", "kind": "merge",
                                       "link": "https://github.com/example/repo/pull/1"} for n in range(6)])
            crowded = run_page(page, "/crew-board/", many)
            assert crowded["needs"] == 5 and crowded["moreNeedsHidden"] is False, crowded
        else:
            print("skip: node not found for the phone page script checks")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
print("ok: phone endpoint strips private data, requires the owner login, and refuses public binding")
PY
