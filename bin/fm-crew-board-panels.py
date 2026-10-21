#!/usr/bin/env python3
"""Project local fleet records into the crew board's optional panels.

Usage: fm-crew-board-panels.py <fleet-snapshot.json>
       fm-crew-board-panels.py --refresh-allowance|--allowance-loop

Connected phones come from a bounded local adb query. Playbot lane rows come
from local persisted state. AI allowance uses a separately scheduled quota-axi
snapshot, never the fast board refresh. The optional
data/crew-board-cache.json supplies phone observations such as locks and panels
without a cheap local source (builds, daily routines, and Rocketboard bugs),
plus optional allowance overlays. The fast projection never queries a network service;
the separately launched allowance sampler may ask quota-axi for provider data.
Its output is embedded in crew-board.json by fm-crew-board.sh refresh.
"""

import csv
import datetime as dt
import io
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
QUOTA = STATE / "crew-board-quota.json"
QUOTA_ERROR = STATE / ".crew-board-quota-error"


def item(title, detail="", status="", link="", alert=False, item_id=""):
    return {"id": item_id, "title": title, "detail": detail, "status": status,
            "link": link, "alert": alert}


def question_entries(path):
    if not path.is_file():
        return []
    rows = []
    section = None
    entry = []

    def flush():
        if not entry:
            return
        title = re.sub(r"^\[[ xX]\]\s*", "", entry[0]).strip()
        bold = re.match(r"^\*\*(.+?)\*\*", title)
        if bold:
            title = bold.group(1)
        rows.append(item(title, "\n".join(entry).strip(), item_id=f"question-{len(rows)}"))
        entry.clear()

    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            flush()
            section = line[3:].strip()
            rows.append(item(section.upper(), status="section"))
            continue
        if line.strip() == "---":
            flush()
            continue
        if section is None:
            continue
        bold = re.match(r"^\*\*(.+?)\*\*", line)
        if bold:
            flush()
            entry.append(line.strip())
            continue
        if line.startswith("- ") or line.startswith("* "):
            flush()
            entry.append(line[2:].strip())
        elif entry:
            entry.append(line.strip())
    flush()
    return rows


def questions(path):
    return [row for row in question_entries(path) if row["status"] != "section"]


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


def tasks_axi_full(state):
    try:
        run = subprocess.run(
            [str(SCRIPT_DIR / "fm-tasks-axi.sh"), "list", "--state", state,
             "--fields", "body,hold_reason,hold_kind,hold_until"],
            capture_output=True, text=True, timeout=3, check=False,
            env={**os.environ, "FM_HOME": str(HOME), "FM_DATA_OVERRIDE": str(DATA)},
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if run.returncode:
        return None
    lines = run.stdout.splitlines()
    start = next((i for i, line in enumerate(lines) if re.match(
        r"^tasks\[\d+\]\{id,state,kind,repo,title,body,hold_reason,hold_kind,hold_until\}:$", line)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("help[")), len(lines))
    try:
        records = list(csv.reader(io.StringIO("\n".join(lines[start + 1:end]))))
    except csv.Error:
        return None
    result = []
    for fields in records:
        if len(fields) != 9:
            continue
        task_id, _, _, repo, title, body, reason, kind, until = fields
        result.append({"id": task_id, "repo": repo, "title": title,
                       "body": "" if body == "-" else body,
                       "reason": "" if reason == "-" else reason,
                       "kind": kind,
                       "until": "" if until == "-" else until})
    return result


def full_backlog():
    in_flight = tasks_axi_full("in_flight")
    held = tasks_axi_full("held")
    queued = tasks_axi_full("queued")
    if in_flight is None or held is None or queued is None:
        return [item("Backlog unavailable", "Could not read bin/fm-tasks-axi.sh", "error")]
    captain_held = [task for task in held if task["kind"] == "captain"]
    other_held = [task for task in held if task["kind"] != "captain"]
    held_ids = {task["id"] for task in held}
    groups = [
        ("IN FLIGHT", [task for task in in_flight if task["id"] not in held_ids]),
        ("HELD FOR THE CAPTAIN", captain_held),
        ("HELD (OTHER)", other_held),
        ("QUEUED", [task for task in queued if task["id"] not in held_ids]),
    ]
    rows = []
    for heading, tasks in groups:
        rows.append(item(heading, status="section"))
        for task in tasks:
            title = f"{task['title']} [{task['repo']}]" if task["repo"] not in ("", "-") else task["title"]
            if heading == "HELD FOR THE CAPTAIN" and task["reason"]:
                title += f" - {task['reason']}"
            elif heading == "HELD (OTHER)":
                hold = task["reason"] or (f"until {task['until']}" if task["until"] else "")
                if hold:
                    title += f" - {hold}"
            detail = task["body"]
            if task["until"]:
                detail = (f"Held until: {task['until']}\n" + detail).strip()
            if task["reason"]:
                detail = (f"Hold: {task['reason']}\n" + detail).strip()
            rows.append(item(title, detail, item_id=task["id"]))
    return rows


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


def local_phones():
    try:
        run = subprocess.run(["adb", "devices", "-l"], capture_output=True,
                             text=True, timeout=2, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return []
    if run.returncode:
        return []
    rows = []
    for line in run.stdout.splitlines():
        fields = line.split()
        if len(fields) < 2 or fields[1] not in ("device", "unauthorized", "offline"):
            continue
        serial, state = fields[:2]
        model = next((field.removeprefix("model:").replace("_", " ")
                      for field in fields[2:] if field.startswith("model:")), serial)
        rows.append(item(model, serial, "connected" if state == "device" else state,
                         alert=state != "device", item_id=serial))
    return rows


def phone_entries(cache):
    cached = entries(cache, "phones")
    rows = local_phones()
    for row in rows:
        match = next((index for index, entry in enumerate(cached)
                      if entry["id"] == row["id"] or entry["title"] == row["title"]), None)
        if match is not None:
            entry = cached.pop(match)
            row.update(status=entry["status"] or row["status"],
                       detail=entry["detail"] or row["detail"],
                       link=entry["link"], alert=entry["alert"] or row["alert"])
    return rows + cached


def playbot_workers():
    try:
        run = subprocess.run(["node", "--no-warnings", str(SCRIPT_DIR / "fm-playbot-lanes.mjs"),
                              "board-lanes", str(STATE)], capture_output=True, text=True,
                             timeout=1.5, check=False)
        if run.returncode == 0:
            rows = json.loads(run.stdout)
            return rows if isinstance(rows, list) else []
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass
    return []


def refresh_allowance():
    temp = None
    try:
        run = subprocess.run(["quota-axi", "--json", "--no-credential-refresh"],
                             capture_output=True, text=True, timeout=15, check=False)
        if run.returncode:
            raise ValueError("quota-axi failed")
        payload = json.loads(run.stdout)
        if not isinstance(payload, dict) or not isinstance(payload.get("providers"), list):
            raise ValueError("quota-axi returned no providers")
        data = json.dumps({"observed_at": time.time(), "payload": payload})
        temp = QUOTA.with_name(f".{QUOTA.name}.{os.getpid()}.tmp")
        with os.fdopen(os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
            output.write(data)
        os.replace(temp, QUOTA)
        QUOTA_ERROR.unlink(missing_ok=True)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        try:
            if temp is not None:
                temp.unlink(missing_ok=True)
            QUOTA_ERROR.touch()
        except OSError:
            pass


def quota_entries():
    try:
        snapshot = json.loads(QUOTA.read_text(encoding="utf-8"))
        age = max(0, int(time.time() - float(snapshot["observed_at"])))
        providers = snapshot["payload"]["providers"]
        failed = QUOTA_ERROR.is_file() and QUOTA_ERROR.stat().st_mtime >= QUOTA.stat().st_mtime
    except (OSError, ValueError, KeyError, TypeError):
        return []
    if not isinstance(providers, list):
        return []
    stale = failed or age > 360
    age_label = f"{age // 60}m ago" + (" (stale)" if stale else "")
    rows = []
    unavailable = []
    for provider in providers:
        if not isinstance(provider, dict):
            continue
        name = str(provider.get("provider") or "provider")
        raw_windows = provider.get("windows")
        windows = {window.get("id"): window for window in (raw_windows if isinstance(raw_windows, list) else [])
                   if isinstance(window, dict)}
        semantics = provider.get("quotaSemantics")
        scopes = semantics.get("effectiveAvailability") if isinstance(semantics, dict) else []
        scopes = scopes if isinstance(scopes, list) else []
        for scope in scopes:
            if not isinstance(scope, dict):
                continue
            percent = scope.get("effectivePercentRemaining")
            if not isinstance(percent, (int, float)):
                continue
            window_ids = scope.get("limitingWindowIds")
            limits = [windows.get(key, {}) for key in window_ids] if isinstance(window_ids, list) else []
            limit = ", ".join(str(window.get("label") or window.get("id")) for window in limits) or "unknown"
            reset = ", ".join(str(window.get("resetsAt") or window.get("resetText") or "unknown")
                              for window in limits) or "unknown"
            runway_info = scope.get("runway")
            runway = runway_info.get("status") if isinstance(runway_info, dict) else "unknown"
            runway = runway or "unknown"
            title = name if scope.get("scope") == "all_models" else f"{name} / {scope.get('scope')}"
            detail = f"limit: {limit}; reset: {reset}; runway: {runway}; observed: {age_label}"
            rows.append(item(title, detail, f"{percent:g}% left · {age_label}",
                             alert=runway == "projected_exhaustion"))
        if scopes:
            continue
        credits = provider.get("credits")
        credits = credits if isinstance(credits, dict) else {}
        remaining = credits.get("remaining")
        if isinstance(remaining, (int, float)):
            unit = credits.get("unit") or "credits"
            credit_window = next((window for window in windows.values()
                                  if window.get("kind") == "credits"), next(iter(windows.values()), {}))
            limit = credit_window.get("label") or credit_window.get("id") or "unknown"
            reset = credit_window.get("resetsAt") or credit_window.get("resetText") or "unknown"
            detail = f"limit: {limit}; reset: {reset}; runway: unknown; observed: {age_label}"
            rows.append(item(name, detail,
                             f"{remaining:g} {unit} · {age_label}"))
        else:
            state_info = provider.get("state")
            state = state_info.get("status") if isinstance(state_info, dict) else "unavailable"
            state = state or "unavailable"
            unavailable.append(f"{name}: {state}")
    if unavailable:
        rows.append(item(f"{len(unavailable)} providers unavailable",
                         "\n".join(unavailable) + f"\nobserved: {age_label}", "unavailable"))
    return rows


def allowance_entries(cache):
    rows = quota_entries()
    live = {row["title"].split(" / ", 1)[0].strip().casefold() for row in rows}
    return rows + [entry for entry in entries(cache, "allowance")
                   if entry["title"].split(" / ", 1)[0].strip().casefold() not in live]


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
    phones = phone_entries(cache)
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
        "full_questions": question_entries(DATA / "captain-questions.md"),
        "full_backlog": full_backlog(),
        "ready": ready,
        "phones": phones,
        "playbot_workers": playbot_workers(),
        "test_queue": entries(cache, "test_queue"),
        "landings": landed_today(snapshot) + entries(cache, "landings"),
        "builds": entries(cache, "builds"),
        "routines": entries(cache, "routines"),
        "bugs": entries(cache, "bugs"),
        "backlog": backlog,
        "allowance": allowance_entries(cache),
        "cached_at": str(cache.get("observed_at", "")),
    }


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--refresh-allowance":
        refresh_allowance()
        return
    if len(sys.argv) == 2 and sys.argv[1] == "--allowance-loop":
        while True:
            refresh_allowance()
            time.sleep(300)
    if len(sys.argv) != 2:
        raise SystemExit("usage: fm-crew-board-panels.py <fleet-snapshot.json>")
    snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    if snapshot.get("schema") != "fm-fleet-snapshot.v1":
        raise SystemExit("unsupported fleet snapshot")
    print(json.dumps(project(snapshot), separators=(",", ":")))


if __name__ == "__main__":
    main()
