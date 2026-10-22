#!/usr/bin/env python3
"""Project local fleet records into the crew board's optional panels.

Usage: fm-crew-board-panels.py <fleet-snapshot.json>
       fm-crew-board-panels.py --refresh-allowance|--allowance-loop

Connected phones come from a bounded local adb query, and whether each one is
testing comes from the shared FrogPile phone FIFO under
/tmp/frogpile-phone-<serial>.queue (FM_CREW_BOARD_PHONE_QUEUE_ROOT overrides
/tmp). The test queue reads that FIFO plus the full-suite lock named by
FROGPILE_SUITE_LOCK and its holder sidecar FROGPILE_SUITE_LOCK_HOLDER, with the
defaults tests/run_suite.sh uses; waiters on the suite lock come from
/proc/locks. Daily routines come from this home's state/*-daily.check.sh
scripts and their state/.<name>-last markers. Ready-for-you rows come from the
fleet snapshot: a PR whose recorded run reports green checks, a finished
local-only branch, an unrelayed scout report, or a captain hold whose reason
names a preview. Each worker's tag names what it is doing: a phone or full
suite it holds or waits on, else its live no-mistakes run's active step from a
bounded local axi status read, else its own phase note shortened. Playbot lane
rows come from local persisted state. AI
allowance uses a separately scheduled quota-axi snapshot, never the fast board
refresh. The optional data/crew-board-cache.json supplies phone observations
such as locks and panels without a cheap local source (builds and Rocketboard
bugs), plus optional overlays for the other panels. The fast projection never
queries a network service; the separately launched allowance sampler may ask
quota-axi for provider data. Its output is embedded in crew-board.json by
fm-crew-board.sh refresh.
"""

import csv
import datetime as dt
import io
import json
import os
from pathlib import Path
import re
import shutil
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
            rows.append(item(line[3:].strip(), status="section"))
            continue
        if line.strip() == "---":
            flush()
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
            value = line.split(":", 1)[1].strip()
            total = re.search(r"of (\d+) total$", value)
            shown = re.match(r"\d+", value)
            if total:
                count = int(total.group(1))
            elif shown:
                count = int(shown.group(0))
            else:
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
        ("In flight", [task for task in in_flight if task["id"] not in held_ids]),
        ("Held for the captain", captain_held),
        ("Held (other)", other_held),
        ("Queued", [task for task in queued if task["id"] not in held_ids]),
    ]
    rows = []
    for heading, tasks in groups:
        rows.append(item(heading, status="section"))
        for task in tasks:
            title = f"{task['title']} [{task['repo']}]" if task["repo"] not in ("", "-") else task["title"]
            if heading == "Held for the captain" and task["reason"]:
                title += f" - {task['reason']}"
            elif heading == "Held (other)":
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


def homebrew_binary(name):
    prefix = os.environ.get("HOMEBREW_PREFIX")
    roots = [prefix] if prefix else ["/home/linuxbrew/.linuxbrew", "/var/home/linuxbrew/.linuxbrew"]
    for root in roots:
        candidate = Path(root) / "bin" / name
        if candidate.is_file():
            return str(candidate)
    return None


def adb_binary():
    found = shutil.which("adb")
    if found:
        return found
    for root in (os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
                 str(Path.home() / "Android" / "Sdk")):
        if not root:
            continue
        candidate = Path(root) / "platform-tools" / "adb"
        if candidate.is_file():
            return str(candidate)
    return homebrew_binary("adb")


def quota_binary():
    found = shutil.which("quota-axi")
    if found:
        return found
    return homebrew_binary("quota-axi")


def local_phones():
    binary = adb_binary()
    if binary is None:
        return None, ("adb was not found on PATH, under ANDROID_HOME or ANDROID_SDK_ROOT, "
                      "in ~/Android/Sdk, or in Linuxbrew")
    try:
        run = subprocess.run([binary, "devices", "-l"], capture_output=True,
                             text=True, timeout=2, check=False)
    except subprocess.TimeoutExpired:
        return None, f"{binary} devices -l did not answer within 2s"
    except OSError as error:
        return None, f"{binary} devices -l could not run: {error}"
    if run.returncode:
        return None, f"{binary} devices -l exited {run.returncode}"
    rows = []
    listed = False
    for line in run.stdout.splitlines():
        if line.startswith("List of devices"):
            listed = True
            continue
        fields = line.split()
        if not listed or len(fields) < 2 or line.startswith("*"):
            continue
        serial = fields[0]
        state = " ".join(fields[1:3]) if fields[1:3] == ["no", "permissions"] else fields[1]
        model = next((friendly_phone(field.removeprefix("model:"))
                      for field in fields[2:] if field.startswith("model:")), serial)
        row = item(model, serial, "connected" if state == "device" else state,
                   alert=state != "device", item_id=serial)
        row["adb"] = state
        rows.append(row)
    if not listed:
        return None, f"{binary} devices -l printed no device list"
    return rows, ""


FRIENDLY_PHONES = {"SM_S901E": "Galaxy S22", "SM_M315F": "Galaxy M31"}


def friendly_phone(model):
    """Name a known adb model the way people say it, else keep the model."""
    key = re.sub(r"[\s-]+", "_", model.strip()).upper()
    return FRIENDLY_PHONES.get(key, model.replace("_", " "))


def normalized_phone_title(value):
    return re.sub(r"[\s_-]+", "", value).casefold()


def phone_entry_match(entry, row, by_serial):
    if by_serial:
        return entry["id"] == row["id"]
    return normalized_phone_title(entry["title"]) == normalized_phone_title(row["title"])


def phone_entries(cache):
    rows, failure = local_phones()
    if failure:
        row = item("Phone check", failure, "unavailable", alert=True)
        row["adb"] = "unavailable"
        return [row]
    cached = entries(cache, "phones")
    matched = [False] * len(rows)
    for by_serial in (True, False):
        for index, row in enumerate(rows):
            if matched[index]:
                continue
            match = next((position for position, entry in enumerate(cached)
                          if phone_entry_match(entry, row, by_serial)), None)
            if match is None:
                continue
            entry = cached.pop(match)
            matched[index] = True
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


def phone_queue_root():
    return Path(os.environ.get("FM_CREW_BOARD_PHONE_QUEUE_ROOT", "/tmp"))


def suite_lock_paths():
    return (Path(os.environ.get("FROGPILE_SUITE_LOCK", "/tmp/frogpile-suite.lock")),
            Path(os.environ.get("FROGPILE_SUITE_LOCK_HOLDER",
                                Path.home() / ".frogpile-suite.lock.holder")))


def start_ticks(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rpartition(")")[2].split()[19]
    except (OSError, IndexError):
        return None


def pid_alive(pid, ticks=None):
    try:
        os.kill(int(pid), 0)
    except PermissionError:
        pass
    except (OSError, ValueError, TypeError, OverflowError):
        return False
    return ticks is None or start_ticks(pid) in (None, str(ticks))


def duration(seconds):
    seconds = max(0, int(seconds))
    if seconds < 60:
        return "<1m"
    if seconds < 3600:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h{seconds % 3600 // 60}m"


def task_worktrees(snapshot):
    trees = []
    for task in snapshot.get("tasks", []):
        if not isinstance(task, dict):
            continue
        tree = ((task.get("paths") or {}).get("worktree") or {}).get("path")
        if isinstance(tree, str) and tree:
            trees.append((os.path.realpath(tree), str(task.get("id", ""))))
    return sorted(trees, key=lambda pair: len(pair[0]), reverse=True)


def process_owner(pid, trees, cwd=""):
    """Name the task whose worktree a process runs in, and what it runs."""
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except (OSError, ValueError, TypeError):
        pass
    kind = ""
    try:
        argv = [arg for arg in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if arg]
        names = [os.path.basename(arg.decode(errors="replace")) for arg in argv]
        kind = next((name for name in names[1:] if name.endswith((".py", ".sh", ".gd"))), names[0] if names else "")
    except (OSError, IndexError):
        pass
    real = os.path.realpath(cwd) if cwd else ""
    for tree, task in trees:
        if real == tree or real.startswith(tree + os.sep):
            return task, kind, cwd
    return (os.path.basename(cwd.rstrip(os.sep)) if cwd else f"pid {pid}"), kind, cwd


def tail_lines(path, limit=65536):
    try:
        with open(path, "rb") as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - limit))
            data = stream.read()
    except OSError:
        return []
    lines = data.decode(errors="replace").splitlines()
    return lines[1:] if size > limit else lines


def epoch(value):
    try:
        return dt.datetime.fromisoformat(str(value)).timestamp()
    except ValueError:
        return None


def phone_queue(serial, trees, now):
    """Read one phone's FIFO: the live holder and live waiters in ticket order."""
    queue = phone_queue_root() / f"frogpile-phone-{serial}.queue"
    acquired = {}
    for line in tail_lines(queue / "events.jsonl"):
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        ticket = str(event.get("ticket", ""))
        if event.get("event") == "acquire":
            acquired[ticket] = epoch(event.get("time"))
        elif event.get("event") in ("release", "crash_cleanup"):
            acquired.pop(ticket, None)
    holder = None
    waiting = []
    try:
        tickets = sorted((queue / "tickets").glob("*.json"))
    except OSError:
        tickets = []
    for path in tickets:
        try:
            owner = json.loads(path.read_text(encoding="utf-8"))
            pid = int(owner["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if not pid_alive(pid, owner.get("start_ticks")):
            continue
        task, kind, _ = process_owner(pid, trees)
        entry = {"task": task, "kind": kind, "pid": pid}
        if path.stem in acquired and holder is None:
            since = acquired[path.stem]
            entry["for"] = duration(now - since) if since else "unknown time"
            holder = entry
        else:
            waiting.append(entry)
    return holder, waiting


def phone_activity(phones, trees, now, titles):
    for phone in phones:
        if phone.get("adb") in (None, "unavailable"):
            continue
        holder, waiting = phone_queue(phone["id"], trees, now)
        behind = f"; {len(waiting)} waiting" if waiting else ""
        if holder:
            phone["detail"] = (f"Testing: {titles.get(holder['task'], holder['task'])} ({holder['kind'] or 'test'}) for "
                               f"{holder['for']}{behind}\n{phone['detail']}")
            if phone["status"] == "connected":
                phone["status"] = "testing"
        elif phone["status"] == "connected":
            phone["status"] = "idle"
            if waiting:
                phone["detail"] = f"{len(waiting)} waiting\n{phone['detail']}"


def suite_waiters(lock):
    try:
        info = lock.stat()
    except OSError:
        return []
    device = f"{os.major(info.st_dev):02x}:{os.minor(info.st_dev):02x}:{info.st_ino}"
    pids = []
    try:
        lines = Path("/proc/locks").read_text().splitlines()
    except OSError:
        return []
    for line in lines:
        fields = line.split()
        if len(fields) >= 7 and fields[1] == "->" and fields[2] == "FLOCK" and fields[6] == device:
            pids.append(int(fields[5]))
    return pids


def task_titles(snapshot):
    return {str(task.get("id")): str((task.get("backlog") or {}).get("title") or task.get("id"))
            for task in snapshot.get("tasks", []) if isinstance(task, dict) and task.get("id")}


def resource_tag(tags, task, priority, text):
    """Keep the strongest resource tag per task: holding beats waiting."""
    if task and (task not in tags or priority < tags[task][0]):
        tags[task] = (priority, text)


def resource_word(kind):
    return "BENCHMARK" if re.search(r"bench|perf", kind or "", re.IGNORECASE) else "TEST"


def test_queue(snapshot, phones, now, tags=None):
    """Return TEST QUEUE rows grouped per shared resource and record each
    worker's held or awaited resource in tags."""
    tags = {} if tags is None else tags
    trees = task_worktrees(snapshot)
    task_ids = {task for _, task in trees}
    titles = task_titles(snapshot)
    rows = []

    def group(heading, holder, waiting, key):
        if not holder and not waiting:
            return
        rows.append(item(heading, status="section", item_id=f"{key}-heading"))
        if holder:
            rows.append(item(f"RUNNING: {titles.get(holder['task'], holder['task'])}",
                             f"Task: {holder['task']} for {holder['for']}\n{holder['detail']}", f"running {holder['for']}",
                             item_id=f"{key}-running"))
        for position, entry in enumerate(waiting, 1):
            label = "NEXT" if position == 1 else f"#{position}"
            rows.append(item(f"{label}: {titles.get(entry['task'], entry['task'])}",
                             f"Task: {entry['task']}\n{entry['detail']}", "next" if position == 1 else "waiting",
                             item_id=f"{key}-wait-{entry['pid']}"))

    lock, holder_path = suite_lock_paths()
    holder = {}
    try:
        for line in holder_path.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            holder[key] = value
    except OSError:
        pass
    try:
        fresh = now - int(holder.get("heartbeat", "")) <= 30
    except ValueError:
        fresh = False
    running = None
    if fresh:
        task, _, cwd = process_owner(holder.get("pid", ""), trees, holder.get("cwd", ""))
        try:
            ran = duration(now - int(holder.get("started", "")))
        except ValueError:
            ran = "unknown time"
        running = {"task": task, "for": ran, "detail": f"pid {holder.get('pid', '?')} in {cwd}"}
        if task in task_ids:
            resource_tag(tags, task, 0, f"FULL SUITE {ran}")
    suite_queue = []
    for position, pid in enumerate(suite_waiters(lock), 1):
        task, _, cwd = process_owner(pid, trees)
        suite_queue.append({"task": task, "pid": pid, "detail": f"pid {pid} in {cwd}"})
        if task in task_ids:
            resource_tag(tags, task, 1, f"WAITING FOR FULL SUITE #{position}")
    group("FULL TEST SUITE", running, suite_queue, "suite")
    serials = sorted(path.name[len("frogpile-phone-"):-len(".queue")]
                     for path in phone_queue_root().glob("frogpile-phone-*.queue"))
    names = {phone["id"]: phone["title"] for phone in phones if phone.get("id")}
    for serial in serials:
        active, waiting = phone_queue(serial, trees, now)
        name = names.get(serial, serial)
        short = re.sub(r"^Galaxy\s+", "", name).upper()
        if active:
            active["detail"] = f"{active['kind'] or 'test'} holding {serial}"
            if active["task"] in task_ids:
                resource_tag(tags, active["task"], 0, f"{short} {resource_word(active['kind'])} {active['for']}")
        for position, entry in enumerate(waiting, 1):
            entry["detail"] = f"{entry['kind'] or 'test'} waiting for {serial}"
            if entry["task"] in task_ids:
                resource_tag(tags, entry["task"], 1, f"WAITING FOR {short} #{position}")
        group(name, active, waiting, f"phone-{serial}")
    return rows


STEP_NAMES = {"test": "TESTS", "document": "DOCS", "ci": "CI"}
LIVE_RUN_STATUSES = ("pending", "running", "fixing", "ci", "awaiting_approval", "fix_review")
GATE_STATUSES = ("awaiting_approval", "fix_review")


def step_table(lines, table):
    """One dict per row of the first `table[N]{column,...}` report block."""
    header, start = [], 0
    for index, line in enumerate(lines):
        match = re.match(r"^\s*" + table + r"\[\d+\]\{(.*?)\}\s*:?\s*$", line)
        if match:
            header, start = match.group(1).split(","), index
            break
    if "step" not in header:
        return []
    rows = []
    for line in lines[start + 1:]:
        if not line.startswith("    "):
            break
        rows.append(dict(zip(header, next(csv.reader([line.strip()])))))
    return rows


def pipeline_step(worktree, deadline):
    """Name a live no-mistakes run's active step, read locally through axi status."""
    budget = deadline - time.monotonic()
    if budget <= 0.05 or not Path(worktree).is_dir():
        return ""
    try:
        run = subprocess.run(["no-mistakes", "axi", "status"], cwd=worktree, capture_output=True,
                             text=True, timeout=min(1.0, budget), check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if run.returncode:
        return ""
    lines = run.stdout.splitlines()
    run_status = ""
    for line in lines[:8]:
        match = re.match(r'^\s*status:\s*"?(.+?)"?\s*$', line)
        if match and match.group(1) in LIVE_RUN_STATUSES:
            run_status = match.group(1)
            break
    if not run_status:
        return ""
    active = step_table(lines, "active_steps")
    step = active[0] if active else next(
        (row for row in step_table(lines, "steps") if row.get("status") in GATE_STATUSES), {})
    statuses = {run_status, str(step.get("status") or "")}
    name = STEP_NAMES.get(step.get("step", ""), step.get("step", "").upper())
    if statuses & set(GATE_STATUSES):
        return f"{name} GATE" if name else "GATE"
    if not active and not name:
        return ""
    if "fixing" in statuses:
        return f"FIXING {name}"
    round_number = step.get("round", "")
    if round_number.isdigit() and int(round_number) > 1:
        return f"{name} ROUND {round_number}"
    return name


def short_note(note, limit=24):
    clause = re.split(r"\s*(?:;|\s-\s|:|,|\()\s*", note.strip(), maxsplit=1)[0]
    words = clause.upper().split()
    text = ""
    for word in words[:4]:
        if len(text) + len(word) + (1 if text else 0) > limit:
            break
        text = f"{text} {word}".strip()
    return text


def worker_tags(snapshot, resources):
    """Pick each worker's tag: a test resource, then its live run step, then its phase note."""
    tags = {}
    deadline = time.monotonic() + 2.0
    for task in snapshot.get("tasks", []):
        if not isinstance(task, dict) or not task.get("id"):
            continue
        task_id = str(task["id"])
        if task_id in resources:
            tags[task_id] = resources[task_id][1]
            continue
        tag = ""
        tree = ((task.get("paths") or {}).get("worktree") or {}).get("path")
        if task.get("mode") == "no-mistakes" and isinstance(tree, str) and tree:
            tag = pipeline_step(tree, deadline)
        tag = tag or short_note(str((task.get("phase") or {}).get("note") or ""))
        if tag:
            tags[task_id] = tag
    return tags


def daily_routines(now):
    rows = []
    today = dt.datetime.fromtimestamp(now).date()
    for script in sorted(STATE.glob("*-daily.check.sh")):
        name = script.name[:-len(".check.sh")]
        try:
            text = script.read_text(encoding="utf-8")
        except OSError:
            continue
        hour = re.search(r'\[\s*"\$hour"\s*-lt\s*(\d+)\s*\]', text)
        hour = int(hour.group(1)) if hour else 0
        marker = STATE / f".{name}-last"
        try:
            last = marker.read_text(encoding="utf-8").strip()
            last_at = dt.datetime.fromtimestamp(marker.stat().st_mtime)
        except OSError:
            last, last_at = "", None
        ran_today = last == today.isoformat()
        due = dt.datetime.combine(today + dt.timedelta(days=1 if ran_today else 0), dt.time(hour))
        if ran_today:
            status = "done today"
        elif dt.datetime.fromtimestamp(now) >= due:
            status = "due now"
        else:
            status = "not yet today"
        last_text = last_at.strftime("%Y-%m-%d %H:%M") if last_at else "never"
        rows.append(item(name, f"Last run: {last_text}\nNext due: {due.strftime('%Y-%m-%d %H:%M')}\n"
                         f"Runs once a day after {hour:02d}:00",
                         status, item_id=name))
    return rows


def ready_entries(snapshot):
    rows = []
    for task in snapshot.get("tasks", []):
        if not isinstance(task, dict):
            continue
        task_id = str(task.get("id", ""))
        title = str((task.get("backlog") or {}).get("title") or task_id)
        current = task.get("current_state") or {}
        hints = task.get("hints") or {}
        pr = str((task.get("pr") or {}).get("url") or "")
        done = current.get("state") == "done"
        green = "checks green" in f"{current.get('detail', '')} {hints.get('last_event_text', '')}"
        if pr and done and (green or current.get("source") == "run-step"):
            rows.append(item(title, f"Checks are green; review and merge the PR\n{pr}", "merge?", pr, item_id=task_id))
        elif task.get("mode") == "local-only" and done:
            rows.append(item(title, "The local branch is finished; approve landing it", "land?", item_id=task_id))
        elif task.get("kind") == "scout" and hints.get("scout_report_present"):
            report = str(((task.get("paths") or {}).get("report") or {}).get("path") or "")
            rows.append(item(title, f"Investigation finished; read the report\n{report}".strip(), "read",
                             report, item_id=task_id))
    for record in snapshot.get("backlog", {}).get("records", []):
        if not isinstance(record, dict) or record.get("state") == "done":
            continue
        reason = str(record.get("hold_reason") or "")
        if record.get("hold_kind") == "captain" and "preview" in reason.casefold():
            rows.append(item(str(record.get("title") or record.get("id")),
                             f"Preview it and give your word: {reason}", "preview",
                             item_id=str(record.get("id", ""))))
    return rows


def alert_entries(snapshot, cache, phones, allowance):
    alerts = entries(cache, "alerts")
    warning = watcher_alert()
    if warning:
        alerts.append(warning)
    for task in snapshot.get("tasks", []):
        if not isinstance(task, dict):
            continue
        task_id = str(task.get("id", "worker"))
        phase = task.get("phase") or {}
        name = phase.get("name", "")
        note = str(phase.get("note", ""))
        held = ((task.get("backlog") or {}).get("hold_kind")) == "captain"
        if name in ("blocked", "failed"):
            alerts.append(item(f"{task_id}: {name}", note or f"The worker reported {name}",
                               name, alert=True, item_id=task_id))
        elif (name == "needs-decision" or (task.get("hints") or {}).get("open_decisions")) and not held:
            alerts.append(item(f"{task_id}: decision not yet raised with you",
                               note or "The worker is waiting on a decision firstmate has not escalated",
                               "needs-decision", alert=True, item_id=task_id))
    for phone in phones:
        adb = phone.get("adb")
        if adb == "unavailable":
            alerts.append(item(phone["title"], phone["detail"], phone["status"], alert=True))
            continue
        if adb in ("unauthorized", "offline"):
            alerts.append(item(f"Phone {phone['title']} {adb}",
                               f"adb reports {adb}, so the phone cannot take tests",
                               adb, alert=True))
        if phone["status"] in ("locked", "unavailable"):
            alerts.append(item(f"Phone {phone['title']} {phone['status']}",
                               phone["detail"], phone["status"], alert=True))
    for row in allowance:
        if row.get("quota") == "unavailable":
            alerts.append(item(row["title"], row["detail"], row["status"], alert=True))
    return alerts


def board_pid_state(started):
    """`live`, `gone`, or `unknown` for this session's board pid record."""
    record = STATE / ".crew-board-tui.pid"
    try:
        if record.stat().st_mtime < started:
            return "unknown"
    except OSError:
        return "unknown"
    try:
        pid = int(record.read_text(encoding="utf-8").strip())
    except FileNotFoundError:
        return "gone"
    except (OSError, ValueError):
        return "unknown"
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return "gone"
    except OSError:
        return "unknown"
    return "live"


def refresh_allowance():
    temp = None
    try:
        binary = quota_binary()
        if binary is None:
            raise ValueError("quota-axi was not found on PATH or in Linuxbrew")
        run = subprocess.run([binary, "--json", "--no-credential-refresh"],
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
        scoped = 0
        for scope in scopes:
            if not isinstance(scope, dict):
                continue
            runway_info = scope.get("runway")
            runway = runway_info.get("status") if isinstance(runway_info, dict) else "unknown"
            runway = runway or "unknown"
            title = name if scope.get("scope") == "all_models" else f"{name} / {scope.get('scope')}"
            percent = scope.get("effectivePercentRemaining")
            if not isinstance(percent, (int, float)):
                if runway == "exhausted_now":
                    rows.append(item(title, f"limit: unknown; reset: unknown; runway: {runway}; observed: {age_label}",
                                     "exhausted now", alert=True))
                    scoped += 1
                continue
            window_ids = scope.get("limitingWindowIds")
            limits = [windows.get(key, {}) for key in window_ids] if isinstance(window_ids, list) else []
            limit = ", ".join(str(window.get("label") or window.get("id") or "unknown") for window in limits) or "unknown"
            reset = ", ".join(str(window.get("resetsAt") or window.get("resetText") or "unknown")
                              for window in limits) or "unknown"
            detail = f"limit: {limit}; reset: {reset}; runway: {runway}; observed: {age_label}"
            rows.append(item(title, detail, f"{percent:g}% left · {age_label}",
                             alert=runway in ("projected_exhaustion", "exhausted_now")))
            scoped += 1
        if scopes:
            if not scoped:
                rows.append(item(name, f"limit: unknown; reset: unknown; runway: unknown; observed: {age_label}",
                                 "headroom unknown"))
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
        noun = "provider" if len(unavailable) == 1 else "providers"
        rows.append(item(f"{len(unavailable)} {noun} unavailable",
                         "\n".join(unavailable) + f"\nobserved: {age_label}", "unavailable"))
    return rows


def allowance_failure():
    try:
        age = max(0, int(time.time() - QUOTA_ERROR.stat().st_mtime))
    except OSError:
        return ""
    unrecorded = "no quota snapshot is recorded; " if not QUOTA.is_file() else ""
    return f"{unrecorded}the last quota-axi attempt failed {age // 60}m ago"


def allowance_entries(cache):
    rows = quota_entries()
    if not rows:
        failure = allowance_failure()
        if failure:
            row = item("Allowance check", failure, "unavailable", alert=True)
            row["quota"] = "unavailable"
            return [row]
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
    now = time.time()
    phones = phone_entries(cache)
    phone_activity(phones, task_worktrees(snapshot), now, task_titles(snapshot))
    allowance = allowance_entries(cache)
    resources = {}
    tests = test_queue(snapshot, phones, now, resources) + entries(cache, "test_queue")
    queued = tasks_axi_list("queued")
    in_flight = tasks_axi_list("in_flight")
    backlog = {
        "queued": queued["count"] if queued else None,
        "in_flight": in_flight["count"] if in_flight else None,
        "next": queued["items"] if queued else [],
        "source": "fm-tasks-axi.sh" if queued and in_flight else "unavailable",
    }
    return {
        "alerts": alert_entries(snapshot, cache, phones, allowance),
        "questions": questions(DATA / "captain-questions.md"),
        "full_questions": question_entries(DATA / "captain-questions.md"),
        "full_backlog": full_backlog(),
        "ready": ready_entries(snapshot) + entries(cache, "ready"),
        "phones": phones,
        "playbot_workers": playbot_workers(),
        "test_queue": tests,
        "worker_tags": worker_tags(snapshot, resources),
        "landings": landed_today(snapshot) + entries(cache, "landings"),
        "builds": entries(cache, "builds"),
        "routines": daily_routines(now) + entries(cache, "routines"),
        "bugs": entries(cache, "bugs"),
        "backlog": backlog,
        "allowance": allowance,
        "cached_at": str(cache.get("observed_at", "")),
    }


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--refresh-allowance":
        refresh_allowance()
        return
    if len(sys.argv) == 2 and sys.argv[1] == "--allowance-loop":
        started, parent = time.time(), os.getppid()
        while True:
            refresh_allowance()
            state = board_pid_state(started)
            if state == "gone" or (os.getppid() != parent and state != "live"):
                return
            time.sleep(300)
    if len(sys.argv) != 2:
        raise SystemExit("usage: fm-crew-board-panels.py <fleet-snapshot.json>")
    snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    if snapshot.get("schema") != "fm-fleet-snapshot.v1":
        raise SystemExit("unsupported fleet snapshot")
    print(json.dumps(project(snapshot), separators=(",", ":")))


if __name__ == "__main__":
    main()
