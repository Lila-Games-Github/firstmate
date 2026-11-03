"""Arrival-ordered tickets shared by Firstmate phone and suite queues.

Every ticket is a JSON file named by a counter the queue increments under its
own mutex, so a directory listing sorts in arrival order regardless of the wall
clock. A ticket records its waiter's pid, kernel start time and boot id: a
ticket whose process has exited, or which was written before the host last
booted, is dead and is pruned instead of blocking the line.

The caller supplies the queue root; fm_test_queues owns path discovery.
"""

from __future__ import annotations

import datetime as dt
import json
import os
from pathlib import Path
import time
import uuid

# A ticket that cannot be parsed is treated as mid-write for this long.
UNREADABLE_GRACE_S = 30


def boot_id() -> str:
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    except OSError:
        return ""


def start_ticks(pid: int) -> str | None:
    """The process's kernel start time, or None once it has exited.

    An exited process its parent has not reaped yet (a zombie) counts as
    exited, so a killed waiter leaves the line at once.
    """
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rpartition(")")[2].split()
    except OSError:
        return None
    if len(fields) < 20 or fields[0] in ("Z", "X"):
        return None
    return fields[19]


def identity(pid: int | None = None) -> dict:
    pid = os.getpid() if pid is None else pid
    return {"pid": pid, "start_ticks": start_ticks(pid), "boot_id": boot_id()}


def alive(owner: dict) -> bool:
    """True while the recorded process is the same live process on this boot."""
    if not isinstance(owner, dict):
        return False
    pid, ticks = owner.get("pid"), owner.get("start_ticks")
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0 or not isinstance(ticks, str):
        return False
    recorded_boot = owner.get("boot_id")
    if recorded_boot and recorded_boot != boot_id():
        return False
    return start_ticks(pid) == ticks


def next_name(queue: Path) -> str:
    """Return the next arrival-ordered ticket name. Call under the queue mutex."""
    counter = queue / "sequence"
    try:
        value = int(counter.read_text().strip() or 0) + 1
    except (OSError, ValueError):
        value = 1
    # A lost/corrupt counter must never put a new caller ahead of live tickets.
    highest = max((int(p.stem.split("-", 1)[0]) for p in (queue / "tickets").glob("*.json")
                   if p.stem.split("-", 1)[0].isdigit()), default=0)
    value = max(value, highest + 1)
    temporary = counter.with_suffix(f".{os.getpid()}.tmp")
    temporary.write_text(str(value))
    temporary.replace(counter)
    return f"{value:012d}-{uuid.uuid4().hex[:12]}"


def write(path: Path, record: dict) -> None:
    temporary = path.with_suffix(f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(record, sort_keys=True))
    temporary.replace(path)


def live(tickets: Path, on_dead=None) -> list[tuple[str, dict]]:
    """Prune dead tickets and return the live ones in arrival order."""
    result = []
    for path in sorted(tickets.glob("*.json")):
        record: dict = {}
        try:
            record = json.loads(path.read_text())
            if not isinstance(record, dict) or not all(k in record for k in ("pid", "start_ticks")):
                raise ValueError("malformed ticket")
            living = alive(record)
        except FileNotFoundError:
            continue
        except (OSError, ValueError, KeyError, TypeError):
            if not isinstance(record, dict):
                record = {}
            try:
                living = time.time() - path.stat().st_mtime < UNREADABLE_GRACE_S
            except FileNotFoundError:
                continue
        if living:
            result.append((path.stem, record))
            continue
        path.unlink(missing_ok=True)
        if on_dead is not None:
            on_dead(path.stem, record if isinstance(record, dict) else {})
    return result


def event(log: Path, kind: str, ticket: str, **details) -> None:
    row = {"time": dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds"),
           "event": kind, "ticket": ticket, "pid": os.getpid(), **details}
    with log.open("a") as stream:
        stream.write(json.dumps(row, sort_keys=True) + "\n")
