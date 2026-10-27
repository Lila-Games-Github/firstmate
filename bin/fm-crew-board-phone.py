#!/usr/bin/env python3
"""Read-only phone view of the published crew board.

Usage: FM_HOME=/path/to/home bin/fm-crew-board-phone.py [--port 8765]
       bin/fm-crew-board-phone.py --bind 127.0.0.1 --port 8765

The server reads state/crew-board.json, published by fm-crew-board.sh refresh.
It never refreshes the board or reads task files. Bind is fixed to loopback.
config/crew-board-phone-owner must name the product owner's Tailscale login;
every request must carry a matching Tailscale-User-Login header, which
tailscale serve adds, or it gets 403. Startup refuses without that file.
With an owner-only tailnet ACL, mount beside an existing / proxy using:
    tailscale serve --bg --set-path /crew-board http://127.0.0.1:8765
Do not use tailscale funnel. The host operator applies the Serve rule.
"""

import argparse
import json
import os
from pathlib import Path
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


SCHEMA = "fm-crew-board-phone.v1"
HERE = Path(__file__).resolve().parent
OWNER_FILE = "crew-board-phone-owner"
OWNER_HEADER = "Tailscale-User-Login"
HTML = HERE / "fm-crew-board-phone.html"
PATH = re.compile(r"(?<!\w)(?:/(?:[^\s/]+/?)+|[A-Za-z]:\\(?:[^\s\\]+\\?)+)")
SECRET = re.compile(r"(?i)\b(?:pin|password|secret|api[_ -]?key|token)(?:\s*[:=]\s*\S+|\s+(?=\S*\d)\S+)")
INTERNAL = re.compile(r"\[key=[^\]]+\]|\bfm-[a-z0-9-]{8,}\b", re.I)
URL = re.compile(r"^https://github\.com/[^/\s]+/[^/\s]+/pull/[0-9]+/?$")


def clean(value, limit=120):
    """Display short plain text only; details and arbitrary payload keys never cross the API."""
    if not isinstance(value, str):
        return ""
    value = SECRET.sub("[redacted]", value)
    value = PATH.sub("[path]", value)
    value = INTERNAL.sub("[task]", value)
    value = " ".join(value.split())
    return value[:limit].rstrip()


def link(value):
    return value if isinstance(value, str) and URL.fullmatch(value) else ""


def entries(value):
    return value if isinstance(value, list) else []


def item(value):
    if not isinstance(value, dict):
        return None
    title = clean(value.get("title"))
    if not title:
        return None
    return {"title": title, "status": clean(value.get("status"), 45),
            "link": link(value.get("link"))}


def project(payload):
    """One explicit allowlist for every byte delivered to a phone."""
    if not isinstance(payload, dict) or payload.get("schema") != "fm-crew-board.v1":
        raise ValueError("unsupported crew board payload")
    panels = payload.get("panels") or {}
    if not isinstance(panels, dict):
        panels = {}
    rows = entries(payload.get("rows"))
    workers = []
    for row in rows:
        if not isinstance(row, dict) or row.get("gone") is True:
            continue
        title = clean(row.get("title"))
        if not title or title == clean(row.get("id")):
            title = "Untitled task"
        workers.append({"title": title, "state": clean(row.get("phase"), 35) or "unknown"})

    needs = []
    for question in entries(panels.get("full_questions")):
        if isinstance(question, dict) and question.get("status") == "decision":
            shown = item(question)
            if shown:
                shown.update({"kind": "decision", "link": "details#decisions"})
                needs.append(shown)
    captain_section = False
    held_ids = set()
    for held in entries(panels.get("full_backlog")):
        if not isinstance(held, dict):
            continue
        if held.get("status") == "section":
            captain_section = held.get("title") == "Held for the captain"
        elif captain_section:
            title = clean(held.get("title"))
            if title and not any(title.startswith(entry["title"]) for entry in needs):
                needs.append({"title": title, "status": "Held for you", "kind": "blocker",
                              "link": "details#decisions"})
            if title and held.get("id"):
                held_ids.add(held["id"])
    merge_waiting = panels.get("merge_waiting") or {}
    if isinstance(merge_waiting, dict):
        by_id = {row.get("id"): row for row in rows if isinstance(row, dict)}
        for task_id, raw_url in merge_waiting.items():
            url = link(raw_url)
            if not url:
                continue
            row = by_id.get(task_id) or {}
            title = clean(row.get("title"))
            if not title or title == clean(task_id):
                title = "PR awaiting merge"
            needs.append({"title": title, "status": "Merge ready", "kind": "merge", "link": url})
    # Only explicit owner holds qualify. A worker's blocked phase alone does not.
    for ready in entries(panels.get("ready")):
        if not isinstance(ready, dict) or ready.get("status") not in ("land?", "preview"):
            continue
        if ready.get("id") and ready.get("id") in held_ids:
            continue
        shown = item(ready)
        if shown:
            shown.update({"kind": "owner action", "status": "Approval needed",
                          "link": "details#landing-detail"})
            needs.append(shown)

    landing = []
    for ready in entries(panels.get("ready")):
        if isinstance(ready, dict) and ready.get("status") in ("merge?", "land?"):
            shown = item(ready)
            if shown:
                shown["status"] = "Awaiting merge" if ready.get("status") == "merge?" else "Awaiting approval"
                shown["link"] = shown["link"] or "details#landing-detail"
                landing.append(shown)
    phones = [shown for raw in entries(panels.get("phones")) if (shown := item(raw))]
    allowance = [shown for raw in entries(panels.get("allowance")) if (shown := item(raw))]
    landings = [shown for raw in entries(panels.get("landings")) if (shown := item(raw))]
    try:
        updated = int(payload.get("generated_epoch"))
    except (TypeError, ValueError):
        updated = 0
    return {"schema": SCHEMA, "updated": updated, "needs": needs,
            "workers": workers, "landing": landing, "phones": phones,
            "allowance": allowance, "recent_landings": landings}


def read_owner(config):
    try:
        owner = (config / OWNER_FILE).read_text(encoding="utf-8").strip()
    except OSError:
        owner = ""
    if not owner or len(owner.split()) != 1:
        raise ValueError(f"set the product owner's Tailscale login in {config / OWNER_FILE}")
    return owner


class LoopbackServer(ThreadingHTTPServer):
    def __init__(self, address, handler, owner):
        if address[0] not in ("127.0.0.1", "::1"):
            raise ValueError("phone board only binds to loopback")
        if not isinstance(owner, str) or not owner.strip():
            raise ValueError("phone board needs the product owner's Tailscale login")
        self.owner = owner.strip().casefold()
        super().__init__(address, handler)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        route = urlsplit(self.path).path.rstrip("/") or "/"
        login = self.headers.get(OWNER_HEADER, "").strip().casefold()
        if login != self.server.owner:
            if route == "/api/board":
                body, mime = b'{"error":"Forbidden"}', "application/json; charset=utf-8"
            else:
                body, mime = b"Forbidden", "text/plain; charset=utf-8"
            code = 403
        elif route in ("/", "/details"):
            body = HTML.read_bytes()
            mime = "text/html; charset=utf-8"
            code = 200
        elif route == "/api/board":
            try:
                body = json.dumps(project(json.loads(self.server.board.read_text(encoding="utf-8"))),
                                  ensure_ascii=True).encode("utf-8")
                code = 200
            except (OSError, ValueError, json.JSONDecodeError):
                body = b'{"error":"Crew board unavailable"}'
                code = 503
            mime = "application/json; charset=utf-8"
        else:
            body, mime, code = b"Not found", "text/plain; charset=utf-8", 404
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    home = Path(os.environ.get("FM_HOME", HERE.parent))
    state = Path(os.environ.get("FM_STATE_OVERRIDE", home / "state"))
    config = Path(os.environ.get("FM_CONFIG_OVERRIDE", home / "config"))
    try:
        server = LoopbackServer((args.bind, args.port), Handler, read_owner(config))
    except ValueError as error:
        parser.exit(2, f"fm-crew-board-phone: {error}\n")
    server.board = state / "crew-board.json"
    print(f"Crew board phone page on http://127.0.0.1:{server.server_port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
