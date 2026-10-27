#!/usr/bin/env python3
"""Owner-only phone view of the published crew board and open questions.

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
import subprocess
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
BOLD = re.compile(r"^\*\*(.+?)\*\*\s*(.*)$")
LABELED = re.compile(r"^([A-Za-z0-9]+)\.\s+(.+)$")
OPTION = re.compile(r"\(([a-z])\)\s*(.*?)(?=[;\n]\s*(?:[-*]\s*)?\([a-z]\)|\.\s+Recommendation|\n\s*Recommendation|$)", re.S)
MAX_BODY = 4096


def question_lines(source):
    """Split the register into (section, lines) entries the way the crew board does."""
    entries = []
    entry = []
    section = "Open questions"
    options_open = False

    def flush():
        nonlocal options_open
        options_open = False
        if entry:
            entries.append((section, list(entry)))
            entry.clear()

    for line in source.splitlines():
        if line.startswith("## "):
            flush()
            section = line[3:].strip()
            continue
        if line.strip() == "---":
            flush()
            continue
        if BOLD.match(line):
            flush()
            entry.append(line.strip())
            options_open = True
            continue
        if line.startswith("- ") or line.startswith("* "):
            if options_open and not BOLD.match(line[2:].strip()):
                entry.append(line.strip())
                continue
            flush()
            entry.append(line[2:].strip())
            options_open = bool(BOLD.match(line[2:].strip()))
        elif entry:
            if not line.strip():
                options_open = False
            entry.append(line.strip())
    flush()
    return entries


def questions(source):
    """Read the human register without requiring optional option syntax."""
    cards = []
    for section, lines in question_lines(source):
        first = re.sub(r"^\[[ xX]\]\s*", "", lines[0]).strip()
        bold = BOLD.match(first)
        heading, rest = (bold[1].strip(), bold[2].strip()) if bold else (first, "")
        labeled = LABELED.match(heading)
        label, title = (labeled[1], labeled[2]) if labeled else ("", heading)
        body = "\n".join([rest] + lines[1:]).strip()
        options = body.split("Options:", 1)[1].split("Recommendation", 1)[0] if "Options:" in body else ""
        recommendation = re.search(r"Recommendation(?: now)?:\s*\(([a-z])\)", body)
        cards.append({
            "section": section, "label": label, "title": title, "body": body,
            "options": [{"key": key, "text": " ".join(desc.split()).rstrip(". ;")}
                        for key, desc in OPTION.findall(options)],
            "recommendation": recommendation.group(1) if recommendation else "",
            "replies": re.findall(r'"(' + re.escape(label) + r': [^"\n]+)"', body) if label else [],
        })
    return cards


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
        self.home = HERE.parent
        self.state = self.home / "state"
        self.questions = self.home / "data" / "captain-questions.md"
        super().__init__(address, handler)


class Handler(BaseHTTPRequestHandler):
    def respond(self, code, payload, mime="application/json; charset=utf-8"):
        body = json.dumps(payload).encode("utf-8") if isinstance(payload, dict) else payload
        self.send_response(code)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        self.wfile.write(body)

    def owner_ok(self):
        return self.headers.get(OWNER_HEADER, "").strip().casefold() == self.server.owner

    def same_origin(self):
        origin = self.headers.get("Origin", "")
        parsed = urlsplit(origin)
        return (parsed.scheme in ("https", "http") and parsed.netloc.lower() ==
                self.headers.get("Host", "").lower() and not parsed.path and
                not parsed.query and not parsed.fragment)

    def do_GET(self):
        route = urlsplit(self.path).path.rstrip("/") or "/"
        if not self.owner_ok():
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
        elif route == "/api/decisions":
            try:
                cards = questions(self.server.questions.read_text(encoding="utf-8"))
                body = json.dumps({"cards": cards}).encode("utf-8")
                code = 200
            except OSError:
                body, code = b'{"error":"Questions unavailable"}', 503
            mime = "application/json; charset=utf-8"
        elif route == "/api/phone-mode":
            try:
                enabled = (self.server.state / "crew-board-phone-mode").read_text().strip() == "on"
            except OSError:
                enabled = False
            body, code, mime = json.dumps({"enabled": enabled}).encode(), 200, "application/json; charset=utf-8"
        else:
            body, mime, code = b"Not found", "text/plain; charset=utf-8", 404
        self.respond(code, body, mime)

    def do_POST(self):
        route = urlsplit(self.path).path.rstrip("/")
        if not self.owner_ok():
            return self.respond(403, {"error": "Forbidden"})
        if route not in ("/api/answer", "/api/phone-mode"):
            return self.respond(404, {"error": "Not found"})
        if not self.same_origin():
            return self.respond(403, {"error": "Origin rejected"})
        try:
            size = int(self.headers.get("Content-Length", ""))
            if size < 1 or size > MAX_BODY or self.headers.get("Content-Type", "").split(";", 1)[0] != "application/json":
                raise ValueError()
            data = json.loads(self.rfile.read(size))
            if not isinstance(data, dict):
                raise ValueError()
        except (ValueError, json.JSONDecodeError):
            return self.respond(400, {"error": "Invalid request"})
        if route == "/api/phone-mode":
            if type(data.get("enabled")) is not bool:
                return self.respond(400, {"error": "Invalid phone mode"})
            path = self.server.state / "crew-board-phone-mode"
            try:
                temp = path.with_suffix(".tmp")
                temp.write_text("on\n" if data["enabled"] else "off\n")
                temp.replace(path)
            except OSError:
                return self.respond(503, {"error": "Phone mode unavailable"})
            return self.respond(200, {"enabled": data["enabled"]})
        label, answer = data.get("label"), data.get("answer")
        if not isinstance(label, str) or not isinstance(answer, str) or not answer.strip() or len(answer) > 500 or "\n" in answer:
            return self.respond(400, {"error": "Invalid answer"})
        try:
            known = {card["label"] for card in questions(self.server.questions.read_text(encoding="utf-8")) if card["label"]}
        except OSError:
            return self.respond(503, {"error": "Questions unavailable"})
        if label not in known:
            return self.respond(400, {"error": "Unknown question"})
        body = f"{label}: {answer.strip()}"
        try:
            env = dict(os.environ, FM_HOME=str(self.server.home))
            result = subprocess.run([str(HERE / "fm-inbox.sh"), "note", body], env=env,
                                    capture_output=True, timeout=10, check=False)
            if result.returncode:
                raise OSError("inbox note failed")
        except (OSError, subprocess.TimeoutExpired):
            return self.respond(503, {"error": "Could not send answer"})
        self.respond(200, {"sent": True})


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
    server.home = home
    server.state = state
    server.questions = home / "data" / "captain-questions.md"
    print(f"Crew board phone page on http://127.0.0.1:{server.server_port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
