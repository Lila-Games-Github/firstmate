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
const location = {pathname, search: '', hash: ''};
const history = {replaceState(_state, _title, url) { location.pathname = new URL(url, 'https://host' + location.pathname).pathname; }};
const fetch = async url => { fetched.push(new URL(url, 'https://host' + location.pathname).pathname); return {ok: true, json: async () => board}; };
new Function('document', 'location', 'history', 'fetch', 'setInterval', source)(document, location, history, fetch, () => 0);
setTimeout(() => console.log(JSON.stringify({pathname: location.pathname, fetched,
  needs: (nodes.needs?.children ?? []).length, moreNeedsHidden: nodes['more-needs']?.hidden ?? null})), 20);
"""


def run_page(html, pathname, board):
    result = subprocess.run([NODE, "-e", PAGE_HARNESS, html, pathname, json.dumps(board)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def status(url, login=None, data=None, origin=None):
    headers = {} if login is None else {"Tailscale-User-Login": login}
    if origin is not None:
        headers["Origin"] = origin
    if data is not None:
        headers["Content-Type"] = "application/json"
    try:
        response = urlopen(Request(url, headers=headers, data=json.dumps(data).encode() if data is not None else None), timeout=3)
        return response.status, response.read()
    except HTTPError as error:
        return error.code, error.read()


root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as temporary:
    home = Path(temporary)
    (home / "state").mkdir()
    (home / "data").mkdir()
    (home / "data" / "captain-questions.md").write_text("""# Open questions
## Your decisions
**FL1. Choose the flash.** A full flash slows the phone. Options: (a) keep it; (b) local flash. Recommendation: (b). "FL1: a" or "FL1: b".
## For Design
**D2. Update the workbook.** Please refresh it.
""")
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
    server.home = home
    server.state = home / "state"
    server.questions = home / "data" / "captain-questions.md"
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
        cards = json.loads(status(base + "/api/decisions", OWNER)[1])["cards"]
        assert len(cards) == 2 and cards[0]["recommendation"] == "b", cards
        assert cards[0]["replies"] == ["FL1: a", "FL1: b"], cards
        assert cards[1]["options"] == [] and cards[1]["section"] == "For Design", cards
        original = server.questions.read_text()
        server.questions.write_text("## Bad\n**unfinished\n### odd\n**X. Safe.** plain\n")
        malformed = json.loads(status(base + "/api/decisions", OWNER)[1])["cards"]
        assert len(malformed) == 1 and malformed[0]["label"] == "X", malformed
        server.questions.write_text("""## Your decisions
- **A. Which release?** Pick one. Options:
- (a) Play
- (b) App Store
Recommendation: (b).

- [ ] Which phone?
---
**C. Ship it?** Options: (a) yes; (b) no. Recommendation: (a).
## For Tarun
- **T1. Check the build.** Please look.
""")
        bulleted = json.loads(status(base + "/api/decisions", OWNER)[1])["cards"]
        assert [(card["section"], card["label"], card["title"]) for card in bulleted] == [
            ("Your decisions", "A", "Which release?"), ("Your decisions", "", "Which phone?"),
            ("Your decisions", "C", "Ship it?"), ("For Tarun", "T1", "Check the build.")], bulleted
        assert bulleted[0]["options"] == [{"key": "a", "text": "Play"}, {"key": "b", "text": "App Store"}], bulleted
        assert bulleted[0]["recommendation"] == "b" and bulleted[1]["body"] == "", bulleted
        assert bulleted[2]["options"] == [{"key": "a", "text": "yes"}, {"key": "b", "text": "no"}], bulleted
        assert status(base + "/api/answer", OWNER, {"label": "", "answer": "b"}, base)[0] == 400
        server.questions.write_text(original)
        assert json.loads(status(base + "/api/phone-mode", OWNER)[1]) == {"enabled": False}
        assert status(base + "/api/answer", None, {"label":"FL1", "answer":"b"}, base)[0] == 403
        assert status(base + "/api/answer", OWNER, {"label":"FL1", "answer":"b"}, "https://evil.example")[0] == 403
        assert status(base + "/api/answer", OWNER, {"label":"FL1", "answer":"b"}, base)[0] == 200
        notes = list((home / "state" / "inbox").glob("*.note"))
        assert len(notes) == 1 and "FL1: b" in notes[0].read_text(), notes
        assert status(base + "/api/phone-mode", OWNER, {"enabled":True}, base)[0] == 200
        assert json.loads(status(base + "/api/phone-mode", OWNER)[1]) == {"enabled": True}
        assert (home / "state" / "crew-board-phone-mode").read_text() == "on\n"

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
            for entry in ("/crew-board", "/crew-board/"):
                overview = run_page(page, entry, board)
                assert overview["pathname"] == "/crew-board/", overview
                assert overview["fetched"] == ["/crew-board/api/board"], overview
            assert run_page(page, "/crew-board/details/", board)["pathname"] == "/crew-board/details"
            assert overview["moreNeedsHidden"] is True, overview
            assert run_page(page, "/crew-board/details", board)["fetched"] == ["/crew-board/api/board"]
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
