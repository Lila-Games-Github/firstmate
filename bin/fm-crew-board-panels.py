#!/usr/bin/env python3
"""Project local fleet records into the crew board's optional panels.

Usage: fm-crew-board-panels.py <fleet-snapshot.json>

The optional data/crew-board-cache.json is maintained by firstmate, not this
script. It supplies observations that have no cheap local source (phone locks,
builds, daily routines, Rocketboard bugs, and provider allowance). This script
never queries a network service. Its output is embedded in crew-board.json by
fm-crew-board.sh refresh.
"""

import csv
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

SCRIPT_DIR = Path(__file__).resolve().parent
HOME = Path(os.environ.get("FM_HOME", SCRIPT_DIR.parent))
DATA = Path(os.environ.get("FM_DATA_OVERRIDE", HOME / "data"))
STATE = Path(os.environ.get("FM_STATE_OVERRIDE", HOME / "state"))
SOURCE = DATA / "crew-board-cache.json"


def item(title, detail="", status="", link="", alert=False, item_id=""):
    return {"id": item_id, "title": title, "detail": detail, "status": status,
            "link": link, "alert": alert}


def questions(path):
    if not path.is_file():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("- ") or line.startswith("* "):
            rows.append(item(line[2:].strip()))
        elif rows and line.startswith(("  ", "\t")) and line.strip():
            rows[-1]["detail"] += (" " if rows[-1]["detail"] else "") + line.strip()
    return rows


def tasks_axi_list(state):
    try:
        run = subprocess.run(
            [str(SCRIPT_DIR / "fm-tasks-axi.sh"), "list", "--state", state, "--limit", "8"],
            capture_output=True, text=True, timeout=2, check=False,
            env={**os.environ, "FM_HOME": str(HOME), "FM_DATA_OVERRIDE": str(DATA)},
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if run.returncode:
        return None
    count = None
    rows = []
    in_rows = False
    for line in run.stdout.splitlines():
        if line.startswith("count: "):
            try:
                count = int(line.split(":", 1)[1].strip())
            except ValueError:
                return None
        elif re.match(r"^tasks\[\d+\]\{id,state,kind,repo,title\}:$", line):
            in_rows = True
        elif in_rows and line.startswith("  "):
            fields = next(csv.reader([line.strip()]))
            if len(fields) >= 5:
                rows.append(item(fields[4], f"{fields[3]} / {fields[2]}", state,
                                 item_id=fields[0]))
        elif in_rows:
            in_rows = False
    return {"count": count if count is not None else len(rows), "items": rows}


def source_cache():
    if not SOURCE.is_file():
        return {}
    try:
        cache = json.loads(SOURCE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(cache, dict) or cache.get("schema") != "fm-crew-board-cache.v1":
        return {}
    return cache


def entries(cache, key):
    raw = cache.get(key, [])
    if not isinstance(raw, list):
        return []
    rows = []
    for entry in raw[:100]:
        if isinstance(entry, dict) and isinstance(entry.get("title"), str):
            rows.append(item(entry["title"], str(entry.get("detail", "")),
                             str(entry.get("status", "")), str(entry.get("link", "")),
                             bool(entry.get("alert", False)), str(entry.get("id", ""))))
    return rows


def watcher_alert():
    beat = STATE / ".last-watcher-beat"
    try:
        age = time.time() - beat.stat().st_mtime
    except OSError:
        return item("Monitoring status unavailable", "No watcher heartbeat was found.", alert=True)
    if age > 45:
        return item("Monitoring down", f"Last watcher heartbeat {int(age)}s ago.", alert=True)
    return None


def landed_today(snapshot):
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()
    rows = []
    for record in snapshot.get("backlog", {}).get("records", []):
        if not isinstance(record, dict) or record.get("state") != "done":
            continue
        completed = record.get("completion") or {}
        if not str(completed.get("date", "")).startswith(today):
            continue
        detail = str(record.get("delivery_state") or "push status unknown")
        rows.append(item(str(record.get("title") or record.get("id") or "Landed task"),
                         detail, "landed", item_id=str(record.get("id", ""))))
    return rows


def project(snapshot):
    cache = source_cache()
    rows = snapshot.get("tasks", [])
    alerts = entries(cache, "alerts")
    warning = watcher_alert()
    if warning:
        alerts.append(warning)
    for task in rows:
        if not isinstance(task, dict):
            continue
        phase = task.get("phase") or {}
        name = phase.get("name", "")
        if name in ("paused", "blocked", "failed"):
            alerts.append(item(f"{task.get('id', 'worker')}: {name}",
                               str(phase.get("note", "")), name, alert=True,
                               item_id=str(task.get("id", ""))))
    phones = entries(cache, "phones")
    for phone in phones:
        if phone["status"] in ("locked", "unavailable"):
            alerts.append(item(f"Phone {phone['title']} {phone['status']}",
                               phone["detail"], phone["status"], alert=True))
    ready = entries(cache, "ready")
    for task in rows:
        if not isinstance(task, dict) or (task.get("phase") or {}).get("name") != "ready-to-merge":
            continue
        pr = task.get("pr") or {}
        ready.append(item(str((task.get("backlog") or {}).get("title") or task.get("id")),
                          str((task.get("phase") or {}).get("note", "")), "ready-to-merge",
                          str(pr.get("url") or ""), item_id=str(task.get("id", ""))))
    queued = tasks_axi_list("queued")
    in_flight = tasks_axi_list("in_flight")
    backlog = {
        "queued": queued["count"] if queued else None,
        "in_flight": in_flight["count"] if in_flight else None,
        "next": queued["items"] if queued else [],
        "source": "fm-tasks-axi.sh" if queued and in_flight else "unavailable",
    }
    return {
        "alerts": alerts,
        "questions": questions(DATA / "captain-questions.md"),
        "ready": ready,
        "phones": phones,
        "test_queue": entries(cache, "test_queue"),
        "landings": landed_today(snapshot) + entries(cache, "landings"),
        "builds": entries(cache, "builds"),
        "routines": entries(cache, "routines"),
        "bugs": entries(cache, "bugs"),
        "backlog": backlog,
        "allowance": entries(cache, "allowance"),
        "cached_at": str(cache.get("observed_at", "")),
    }


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: fm-crew-board-panels.py <fleet-snapshot.json>")
    snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    if snapshot.get("schema") != "fm-fleet-snapshot.v1":
        raise SystemExit("unsupported fleet snapshot")
    print(json.dumps(project(snapshot), separators=(",", ":")))


if __name__ == "__main__":
    main()
