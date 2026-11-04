#!/usr/bin/env python3
"""Observe worker status events and retain per-project timing at teardown.

Status lines have no embedded timestamp. `observe` records the time a watcher
first saw each line; several lines seen in one poll share one observation time.
The report never treats an unobserved historical phase as a measured duration.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import sys

if os.name == "nt":
    import msvcrt
else:
    import fcntl

PHASES = {"investigating": "planning", "building": "developing",
          "testing": "testing", "validating": "testing", "fixing": "fixing",
          "ready-to-merge": "landing"}
WAIT_CAUSES = ("test_service", "phone_queue", "landing_queue", "review_pipeline",
               "captain", "other")


def fields(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)


def stamp(value):
    if value is None:
        return None
    try:
        if isinstance(value, (float, int)) or str(value).isdigit():
            return float(value)
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, OverflowError):
        return None


def iso(value):
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).isoformat() if value is not None else None


def project_file(data, project):
    canonical = os.path.realpath(project) if project else "unknown"
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", Path(canonical).name) or "unknown"
    return Path(data) / "worker-timing" / (slug + "-" + hashlib.sha256(canonical.encode()).hexdigest()[:12] + ".jsonl")


def json_rows(lines):
    for line in lines:
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict):
            yield item


def locked_append(path, row):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as stream:
        if os.name == "nt":
            stream.seek(0)
            msvcrt.locking(stream.fileno(), msvcrt.LK_LOCK, 1)
        else:
            fcntl.flock(stream, fcntl.LOCK_EX)
        try:
            stream.seek(0)
            contents = stream.read()
            for existing in json_rows(contents.splitlines()):
                if (existing.get("task_id"), existing.get("instance_id"), existing.get("started_at")) == \
                        (row["task_id"], row["instance_id"], row["started_at"]):
                    return False
            stream.seek(0, os.SEEK_END)
            if contents and not contents.endswith("\n"):
                stream.write("\n")
            stream.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
            return True
        finally:
            if os.name == "nt":
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)


def observe(state, task, now=None):
    status = Path(state) / (task + ".status")
    sidecar = Path(state) / (task + ".timing-events.json")
    lock = Path(state) / (task + ".timing-events.lock")
    if not status.is_file():
        return
    with lock.open("a+") as stream:
        if os.name == "nt":
            stream.seek(0)
            msvcrt.locking(stream.fileno(), msvcrt.LK_LOCK, 1)
        else:
            fcntl.flock(stream, fcntl.LOCK_EX)
        try:
            _observe_locked(status, sidecar, now)
        finally:
            if os.name == "nt":
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream, fcntl.LOCK_UN)


def _observe_locked(status, sidecar, now):
    if sidecar.is_symlink():
        raise ValueError("timing sidecar is a symlink")
    if not status.is_file():
        return
    if status.is_symlink():
        raise ValueError("status log is a symlink")
    raw = status.read_bytes()
    lines = raw.splitlines(keepends=True)
    complete = [line.decode("utf-8", "replace").rstrip("\r\n") for line in lines if line.endswith(b"\n")]
    old = json.loads(sidecar.read_text()) if sidecar.is_file() else {"prefix": "", "events": []}
    previous = old.get("events", [])
    n = len(previous)
    prefix = hashlib.sha256(b"".join(lines[:n])).hexdigest() if n else ""
    if n and prefix != old.get("prefix"):
        raise ValueError("status history changed after timing observation")
    if len(complete) <= n:
        return
    at = now if now is not None else dt.datetime.now(dt.timezone.utc).timestamp()
    previous.extend({"line": line, "at": at} for line in complete[n:])
    payload = {"prefix": hashlib.sha256(b"".join(lines[:len(complete)])).hexdigest(), "events": previous}
    tmp = sidecar.with_name(sidecar.name + ".tmp." + str(os.getpid()))
    tmp.write_text(json.dumps(payload, separators=(",", ":")))
    os.replace(tmp, sidecar)


def wait_cause(line):
    lower = line.lower()
    if lower.startswith("needs-decision:") or lower.startswith("needs-decision ") or "captain-held" in lower or "waiting on the captain" in lower:
        return "captain"
    if "test-service" in lower or "test service" in lower or "testfarm" in lower:
        return "test_service"
    if "phone" in lower or "device queue" in lower:
        return "phone_queue"
    if "landing-queue" in lower or "landing queue" in lower:
        return "landing_queue"
    if "no-mistakes" in lower or "review pipeline" in lower or "ci check" in lower:
        return "review_pipeline"
    return "other"


def measured(events, start, end):
    phases = {name: 0.0 for name in set(PHASES.values())}
    waits = {name: 0.0 for name in WAIT_CAUSES}
    if start is None:
        return None, None, "start time absent"
    if not events:
        return None, None, "status event observation absent"
    if len({stamp(event.get("at")) for event in events}) < 2:
        return None, None, "phase transitions not observed in separate polls"
    current_phase = None
    current_wait = None
    cursor = start
    saw_phase = False
    for event in events:
        at = stamp(event.get("at"))
        if at is None or at < start or at > end + 60:
            return None, None, "event observation outside task lifetime"
        at = min(at, end)
        if at < cursor:
            return None, None, "event observation order invalid"
        duration = at - cursor
        if current_wait:
            waits[current_wait] += duration
        elif current_phase:
            phases[current_phase] += duration
        line = event["line"]
        if line.startswith("phase:"):
            match = re.match(r"phase:\s*([a-z-]+)(?:\s|$)", line)
            if match and match.group(1) in PHASES:
                current_phase = PHASES[match.group(1)]
                current_wait = None
                saw_phase = True
        elif line.startswith(("paused:", "blocked:", "needs-decision:", "needs-decision ")):
            if not line.startswith("blocked: phase handoff ready "):
                current_wait = wait_cause(line)
        elif line.startswith(("resolved:", "working:", "done:", "failed:")):
            current_wait = None
        cursor = at
    duration = end - cursor
    if current_wait:
        waits[current_wait] += duration
    elif current_phase:
        phases[current_phase] += duration
    if not saw_phase:
        return None, None, "no recognized phase event"
    return ({key: round(value, 3) for key, value in phases.items()},
            {key: round(value, 3) for key, value in waits.items()}, None)


def row_from_meta(meta, task, end, events, outcome, method, source):
    start = stamp(meta.get("routing_started_at"))
    phases, waits, reason = measured(events, start, end)
    return {"schema": 1, "task_id": task,
            "instance_id": meta.get("routing_instance_id") or meta.get("spawn_gen"),
            "project": meta.get("project"), "kind": meta.get("kind"),
            "delivery_mode": meta.get("mode"), "harness": meta.get("routing_harness") or meta.get("harness"),
            "model": meta.get("routing_model") or meta.get("model"),
            "effort": meta.get("routing_effort") or meta.get("effort"),
            "started_at": iso(start), "ended_at": iso(end),
            "wall_seconds": round(end - start, 3) if start is not None else None,
            "phase_seconds": phases, "waiting_seconds": waits, "timing_unknown_reason": reason,
            "relaunches": int(meta.get("routing_relaunches", 0)),
            "failed_validation_rounds": None, "outcome": outcome, "method": method,
            "source": source, "observed_events": len(events)}


def record(args):
    meta = fields(Path(args.meta))
    state = Path(args.state)
    end = dt.datetime.now(dt.timezone.utc).timestamp()
    routing = Path(args.data) / "routing-ledger.jsonl"
    matched = None
    if routing.is_file():
        for item in json_rows(routing.read_text().splitlines()):
            instance = meta.get("routing_instance_id") or meta.get("spawn_gen")
            if item.get("task_id") == args.id and item.get("instance_id") == instance and \
                    (instance is not None or item.get("started_at") == iso(stamp(meta.get("routing_started_at")))):
                matched = item
                end = stamp(item.get("ended_at")) or end
                break
    # The routing row is written just before this call. Attribute any final
    # lines still unseen by the watcher to that same teardown instant.
    try:
        observe(state, args.id, now=end)
    except (OSError, ValueError) as error:
        print(f"worker timing observation skipped for {args.id}: {error}", file=sys.stderr)
    sidecar = state / (args.id + ".timing-events.json")
    events = []
    if sidecar.is_file() and not sidecar.is_symlink():
        try:
            events = json.loads(sidecar.read_text())["events"]
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"worker timing events skipped for {args.id}: {error}", file=sys.stderr)
    row = row_from_meta(meta, args.id, end, events, args.outcome, args.method, "teardown")
    if matched:
        row["failed_validation_rounds"] = matched.get("failed_rounds")
        row["wall_seconds"] = matched.get("wall_seconds")
    locked_append(project_file(args.data, row["project"]), row)


def backfill(args):
    source = Path(args.data) / "routing-ledger.jsonl"
    rows = [item for item in json_rows(source.read_text().splitlines()) if item.get("task_id")] if source.is_file() else []
    added = 0
    timed = 0
    for item in rows:
        routing = item.get("routing")
        routing = routing if isinstance(routing, dict) else {}
        outcome = item.get("outcome")
        outcome = outcome if isinstance(outcome, dict) else {}
        row = {"schema": 1, "task_id": item["task_id"], "instance_id": item.get("instance_id"),
               "project": item.get("project"), "kind": item.get("kind"),
               "delivery_mode": item.get("delivery_mode"), "harness": routing.get("harness"),
               "model": routing.get("model"), "effort": routing.get("effort"),
               "started_at": item.get("started_at"), "ended_at": item.get("ended_at"),
               "wall_seconds": item.get("wall_seconds"), "phase_seconds": None,
               "waiting_seconds": None, "timing_unknown_reason": "historical status timestamps absent",
               "relaunches": item.get("relaunches"), "failed_validation_rounds": item.get("failed_rounds"),
               "outcome": "landed" if outcome.get("landed") else "not-landed",
               "method": outcome.get("method"), "source": "routing-ledger",
               "observed_events": 0}
        added += locked_append(project_file(args.data, row["project"]), row)
        timed += row["wall_seconds"] is not None
    print(f"routing_source={len(rows)} total_timed={timed} new_records={added} phase_timed=0")


def spread(values):
    if not values:
        return "unknown"
    ordered = sorted(values)
    half = max(1, len(ordered) // 2)
    lower = statistics.median(ordered[:half])
    upper = statistics.median(ordered[-half:])
    return "median=%.1fs p25=%.1fs p75=%.1fs range=%.1f..%.1fs" % (
        statistics.median(ordered), lower, upper, ordered[0], ordered[-1])


def report(args):
    files = sorted((Path(args.data) / "worker-timing").glob("*.jsonl"))
    rows = [item for path in files for item in json_rows(path.read_text().splitlines())]
    projects = sorted({row.get("project") or "unknown" for row in rows})
    if args.project:
        projects = [project for project in projects if project == args.project or Path(project).name == args.project]
    print(f"source_files={len(files)} source_records={len(rows)} total_timed={sum(row.get('wall_seconds') is not None for row in rows)} phase_timed={sum(row.get('phase_seconds') is not None for row in rows)}")
    for project in projects:
        group = [row for row in rows if (row.get("project") or "unknown") == project]
        print(f"project={project} tasks={len(group)} total {spread([row['wall_seconds'] for row in group if row.get('wall_seconds') is not None])}")
        for phase in ("planning", "developing", "testing", "fixing", "landing"):
            print(f"  {phase}: {spread([row['phase_seconds'][phase] for row in group if row.get('phase_seconds') is not None])}")
        causes = {cause: sum((row.get("waiting_seconds") or {}).get(cause, 0) for row in group) for cause in WAIT_CAUSES}
        print("  waits: " + ", ".join(f"{key}={value:.1f}s" for key, value in sorted(causes.items(), key=lambda pair: -pair[1]) if value))
        for row in group:
            peers = [peer["wall_seconds"] for peer in group if peer.get("kind") == row.get("kind") and peer.get("wall_seconds") is not None]
            if len(peers) >= 3 and row.get("wall_seconds") is not None and row["wall_seconds"] > 2 * statistics.median(peers):
                print(f"  far_past_typical: {row['task_id']} kind={row.get('kind')} wall={row['wall_seconds']:.1f}s typical={statistics.median(peers):.1f}s")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    observation = sub.add_parser("observe")
    observation.add_argument("--state", required=True)
    observation.add_argument("--id", required=True)
    recording = sub.add_parser("record")
    for flag in ("meta", "state", "data", "id", "outcome", "method"):
        recording.add_argument("--" + flag, required=True)
    historical = sub.add_parser("backfill")
    historical.add_argument("--data", required=True)
    summary = sub.add_parser("report")
    summary.add_argument("--data", required=True)
    summary.add_argument("--project")
    calculation = sub.add_parser("calculate", help="Calculate durations from a timestamped event fixture")
    calculation.add_argument("--events", required=True)
    calculation.add_argument("--start", required=True)
    calculation.add_argument("--end", required=True)
    calculation.add_argument("--strict", action="store_true", help="Reject a fixture with unknown timing")
    args = parser.parse_args()
    try:
        if args.command == "observe":
            observe(args.state, args.id)
        elif args.command == "record":
            record(args)
        elif args.command == "backfill":
            backfill(args)
        elif args.command == "calculate":
            phases, waits, reason = measured(json.loads(Path(args.events).read_text()), stamp(args.start), stamp(args.end))
            print(json.dumps({"phase_seconds": phases, "waiting_seconds": waits,
                              "timing_unknown_reason": reason}, sort_keys=True))
            if args.strict and reason:
                parser.exit(2, f"invalid timing fixture: {reason}\n")
        else:
            report(args)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
