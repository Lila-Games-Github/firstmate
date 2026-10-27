#!/usr/bin/env python3
"""Append task routing evidence and summarize it. See docs/configuration.md."""

import argparse
from contextlib import closing
import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
import statistics

if os.name == "nt":
    import msvcrt
else:
    import fcntl


ROOT = Path(__file__).resolve().parent.parent
PRICES = ROOT / "bin" / "fm-routing-prices.json"
ROUTING_KEYS = ("routing_rule", "routing_provider", "routing_harness", "routing_model",
                "routing_effort", "routing_started_at", "routing_instance_id")
SIGNALS = {"captain-correction": "captain_corrected", "review-rejection": "captain_rejected"}


def fields(path):
    result = {}
    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


def iso(value):
    return dt.datetime.fromtimestamp(float(value), dt.timezone.utc).isoformat()


def lock_ledger(stream):
    stream.seek(0)
    if os.name == "nt":
        msvcrt.locking(stream.fileno(), msvcrt.LK_LOCK, 1)
    else:
        fcntl.flock(stream, fcntl.LOCK_EX)


def unlock_ledger(stream):
    if os.name == "nt":
        stream.seek(0)
        msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
    else:
        fcntl.flock(stream, fcntl.LOCK_UN)


def event_counts(path):
    lines = path.read_text(errors="replace").splitlines() if path.is_file() else []
    return {
        "needs_decision_count": sum(x.startswith("needs-decision") for x in lines),
        "blocked_count": sum(x.startswith("blocked:") for x in lines),
        "stale_wake_count": sum("stale wake" in x.lower() for x in lines),
    }


def timestamp(value):
    if isinstance(value, (int, float)):
        return float(value)
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return (parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)).timestamp()


def learning_candidates(state):
    """Map each origin task to its captured candidates with signal and capture time."""
    directory = Path(state) / "learning-candidates"
    tasks = {}
    unreadable = 0
    if not directory.is_dir():
        return tasks, "learning-candidate store absent"
    for path in directory.glob("*.json"):
        try:
            item = json.loads(path.read_text())
        except (OSError, ValueError):
            unreadable += 1
            continue
        if not isinstance(item, dict):
            unreadable += 1
            continue
        incident = item.get("incident") if isinstance(item.get("incident"), dict) else {}
        task = incident.get("origin_task") or item.get("origin_task")
        if not isinstance(task, str):
            unreadable += 1
            continue
        tasks.setdefault(task, {})[item.get("id", path.name.split(".", 1)[0])] = {
            "signal": incident.get("signal_type"), "captured_at": timestamp(item.get("captured_at"))}
    return tasks, ("%d learning-candidate record(s) unreadable" % unreadable if unreadable else None)


def incarnation_candidates(entries, started, until=None):
    """Select candidates captured during one task incarnation: [started, until)."""
    if started is None:
        return {}, "start time absent; learning candidates cannot be bound to this task incarnation"
    selected = {}
    untimed = 0
    for ident, candidate in (entries or {}).items():
        at = candidate["captured_at"]
        if at is None:
            untimed += 1
        elif at >= started and (until is None or at < until):
            selected[ident] = candidate
    return selected, ("%d learning candidate(s) for task lack a readable capture time" % untimed if untimed else None)


def signal_outcome(selected, store_reason):
    signals = {candidate["signal"] for candidate in selected.values()}
    result = {}
    for signal, key in SIGNALS.items():
        if signal in signals:
            result[key] = True
        else:
            result[key] = None
            result[key + "_reason"] = store_reason or ("no %s learning candidate captured for this task incarnation" % signal)
    return result


def pipeline_rounds(meta, task_id, started):
    """Count review/fix rounds and failed steps from no-mistakes run records."""
    unknown = lambda reason: {"validation_runs": None, "validation_rounds": None, "failed_rounds": None,
                              "pipeline": {"run_ids": [], "reason": reason}}
    if started is None:
        return unknown("start time absent from legacy metadata")
    project = meta.get("project")
    if not project:
        return unknown("project absent from task metadata")
    root = Path(os.environ.get("NM_HOME") or Path.home() / ".no-mistakes")
    database = root / "state.sqlite"
    if not database.is_file():
        return unknown("no-mistakes run records absent")
    try:
        with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
            repos = [row[0] for row in db.execute("SELECT id, working_path FROM repos")
                     if os.path.realpath(row[1]) == os.path.realpath(project)]
            if not repos:
                return unknown("project has no no-mistakes repository record")
            marks = ",".join("?" * len(repos))
            runs = [row[0] for row in db.execute(
                "SELECT id FROM runs WHERE repo_id IN (%s) AND branch = ? AND created_at >= ? "
                "ORDER BY created_at, id" % marks, (*repos, "fm/" + task_id, int(started)))]
            if not runs:
                return unknown("no no-mistakes run recorded for the task branch")
            marks = ",".join("?" * len(runs))
            fixes = db.execute(
                "SELECT COUNT(*) FROM step_rounds r JOIN step_results s ON s.id = r.step_result_id "
                "WHERE s.run_id IN (%s) AND r.trigger_type = 'auto_fix'" % marks, runs).fetchone()[0]
            failed = db.execute(
                "SELECT COUNT(*) FROM step_results WHERE run_id IN (%s) AND status = 'failed'" % marks,
                runs).fetchone()[0]
    except sqlite3.Error as error:
        return unknown("no-mistakes run records unreadable: %s" % error)
    return {"validation_runs": len(runs), "validation_rounds": fixes, "failed_rounds": failed,
            "pipeline": {"run_ids": runs, "reason": None}}


def session_paths(meta, started, harness):
    explicit = meta.get("usage_session_paths", "")
    if explicit:
        return [Path(p) for p in explicit.split(os.pathsep) if p]
    home = Path.home()
    if harness in ("pi", "pi-signed"):
        roots = [Path(os.environ.get("PI_CODING_AGENT_DIR", home / ".pi" / "agent")) / "sessions"]
    elif harness == "codex":
        roots = [Path(os.environ.get("CODEX_HOME", home / ".codex")) / "sessions"]
    elif harness == "claude":
        roots = [Path(os.environ.get("CLAUDE_CONFIG_DIR", home / ".claude")) / "projects"]
    else:
        return []
    found = []
    for root in roots:
        if not root.is_dir():
            continue
        for directory, _, names in os.walk(root):
            for name in names:
                if not name.endswith(".jsonl"):
                    continue
                path = Path(directory) / name
                try:
                    if path.stat().st_mtime >= started:
                        found.append(path)
                except OSError:
                    pass
    return found


def read_jsonl(path):
    with path.open(errors="replace") as stream:
        for line in stream:
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                yield item


def parse_usage(path, harness, worktree):
    # Bind a discovered session to the task's exact worktree. Explicit fixture
    # paths still need this check, preventing a different task's usage crossing in.
    cwd = None
    for index, row in enumerate(read_jsonl(path)):
        payload = row.get("payload")
        value = row.get("cwd") or (payload.get("cwd") if isinstance(payload, dict) else None)
        if isinstance(value, str):
            cwd = value
            break
        if index >= 31:
            break
    if cwd != worktree:
        return None
    totals = {}
    models = set()
    if harness in ("pi", "pi-signed"):
        seen = set()
        for index, row in enumerate(read_jsonl(path)):
            if row.get("type") != "message":
                continue
            msg = row.get("message")
            if not isinstance(msg, dict):
                continue
            ident = row.get("id", index)
            if msg.get("role") != "assistant" or ident in seen:
                continue
            usage = msg.get("usage")
            if not isinstance(usage, dict):
                continue
            seen.add(ident)
            cost_field = usage.get("cost")
            cost = cost_field.get("total") if isinstance(cost_field, dict) else None
            if isinstance(cost, (float, int)):
                totals["dollars"] = totals.get("dollars", 0) + cost
            for source, target in (("input", "input_tokens"), ("output", "output_tokens"),
                                   ("cacheRead", "cached_input_tokens"), ("cacheWrite", "cache_write_tokens")):
                if isinstance(usage.get(source), int):
                    totals[target] = totals.get(target, 0) + usage[source]
            if msg.get("model"):
                models.add(msg["model"])
    elif harness == "codex":
        # token_count totals are cumulative within one Codex session.
        latest = None
        for row in read_jsonl(path):
            payload = row.get("payload")
            if not isinstance(payload, dict):
                continue
            if row.get("type") == "event_msg" and payload.get("type") == "token_count":
                info = payload.get("info")
                if isinstance(info, dict) and isinstance(info.get("total_token_usage"), dict):
                    latest = info["total_token_usage"]
            if row.get("type") == "turn_context" and payload.get("model"):
                models.add(payload["model"])
        if latest:
            for source, target in (("input_tokens", "input_tokens"), ("output_tokens", "output_tokens"),
                                   ("cached_input_tokens", "cached_input_tokens")):
                if isinstance(latest.get(source), int):
                    totals[target] = latest[source]
    elif harness == "claude":
        messages = {}
        for index, row in enumerate(read_jsonl(path)):
            msg = row.get("message") or {}
            if row.get("type") != "assistant" or not isinstance(msg, dict):
                continue
            ident = msg.get("id") or row.get("uuid") or index
            usage = msg.get("usage")
            if not isinstance(usage, dict):
                continue
            # Claude can write several snapshots for one assistant message.
            # Keep its final usage rather than charging every snapshot.
            messages[ident] = msg
        for msg in messages.values():
            usage = msg["usage"]
            for source, target in (("input_tokens", "input_tokens"), ("output_tokens", "output_tokens"),
                                   ("cache_read_input_tokens", "cached_input_tokens"),
                                   ("cache_creation_input_tokens", "cache_write_tokens")):
                if isinstance(usage.get(source), int):
                    totals[target] = totals.get(target, 0) + usage[source]
            cache_creation = usage.get("cache_creation")
            if isinstance(cache_creation, dict):
                one_hour = cache_creation.get("ephemeral_1h_input_tokens")
                if isinstance(one_hour, int):
                    totals["cache_write_1h_tokens"] = totals.get("cache_write_1h_tokens", 0) + one_hour
            if msg.get("model"):
                models.add(msg["model"])
    return {"source": str(path), "harness": harness, "models": sorted(models), "raw": totals} if totals else None


def cost(meta, started):
    harnesses = set(meta.get("routing_harness_history", meta.get("harness", "")).split(","))
    sessions = []
    seen = set()
    for harness in harnesses:
        for path in session_paths(meta, started, harness):
            if path in seen:
                continue
            try:
                parsed = parse_usage(path, harness, meta.get("worktree", ""))
            except OSError:
                parsed = None
            if parsed:
                seen.add(path)
                sessions.append(parsed)
    if not sessions:
        return {"sessions": [], "usd_estimate": None, "reason": "no matching readable session usage"}
    expected = int(meta.get("routing_relaunches", "0")) + 1
    prices = json.loads(PRICES.read_text())
    estimates = []
    for session in sessions:
        raw = session["raw"]
        if "dollars" in raw:
            session["usd_estimate"] = raw["dollars"]
            session["price_source"] = "runtime-reported"
        elif len(session["models"]) == 1 and session["models"][0] in prices["models"]:
            model = session["models"][0]
            rate = prices["models"][model]
            uncached = raw.get("input_tokens", 0)
            if session["harness"] == "codex":
                uncached = max(0, uncached - raw.get("cached_input_tokens", 0))
            session["usd_estimate"] = round((
                uncached * rate["input"] + raw.get("cached_input_tokens", 0) * rate["cached_input"]
                + max(0, raw.get("cache_write_tokens", 0) - raw.get("cache_write_1h_tokens", 0))
                * rate.get("cache_write", rate["input"])
                + raw.get("cache_write_1h_tokens", 0) * rate.get("cache_write_1h", rate["input"] * 2)
                + raw.get("output_tokens", 0) * rate["output"]) / 1_000_000, 8)
            session["price_source"] = str(PRICES.relative_to(ROOT)) + "#" + model
            session["price_per_million"] = rate
        else:
            session["usd_estimate"] = None
            session["reason"] = "model absent or missing from price table"
        estimates.append(session["usd_estimate"])
    complete = all(x is not None for x in estimates) and len(sessions) >= expected
    return {
        "sessions": sessions,
        "usd_estimate": round(sum(estimates), 8) if complete else None,
        "reason": None if complete else
        ("fewer readable sessions than launches" if len(sessions) < expected else "one or more sessions lack a price"),
    }


def routing_missing(meta):
    missing = [key for key in ROUTING_KEYS if key not in meta]
    if "routing_rule" in meta and not meta["routing_rule"]:
        missing.append("routing_rule")
    if "routing_started_at" in meta and not meta["routing_started_at"].isdigit():
        missing.append("routing_started_at")
    return sorted(missing, key=ROUTING_KEYS.index)


def record(args):
    meta = fields(Path(args.meta))
    missing = routing_missing(meta)
    start = None if "routing_started_at" in missing else float(meta["routing_started_at"])
    end = dt.datetime.now(dt.timezone.utc).timestamp()
    state = Path(args.state)
    data = Path(args.data)
    status = event_counts(state / (args.id + ".status"))
    candidates, store_reason = learning_candidates(state)
    selected, bind_reason = incarnation_candidates(candidates.get(args.id), start)
    row = {
        "schema": 1, "task_id": args.id, "instance_id": meta.get("routing_instance_id", meta.get("spawn_gen")),
        "project": meta.get("project"),
        "kind": meta.get("kind"), "delivery_mode": meta.get("mode"),
        "routing": {"rule": meta.get("routing_rule") or "unrecorded", "override_reason": meta.get("routing_reason"),
                    "provider": meta.get("routing_provider"), "harness": meta.get("routing_harness", meta.get("harness")),
                    "model": meta.get("routing_model", meta.get("model")), "effort": meta.get("routing_effort", meta.get("effort")),
                    "quota_snapshot": json.loads(meta["routing_quota"]) if meta.get("routing_quota") else None,
                    "quota_reason": meta.get("routing_quota_reason"),
                    "missing_reason": "routing record incomplete in task metadata: missing " + ", ".join(missing)
                    if missing else None},
        "started_at": iso(start) if start is not None else None,
        "ended_at": iso(end), "wall_seconds": round(end - start, 3) if start is not None else None,
        "outcome": {"landed": args.outcome == "landed", "method": args.method,
                    **signal_outcome(selected, store_reason or bind_reason)},
        **status, **pipeline_rounds(meta, args.id, start), "relaunches": int(meta.get("routing_relaunches", "0")),
        "learning_candidates": sorted(selected),
        "cost": cost(meta, start) if start is not None else
        {"sessions": [], "usd_estimate": None, "reason": "start time absent from legacy metadata"},
    }
    data.mkdir(parents=True, exist_ok=True)
    ledger = data / "routing-ledger.jsonl"
    with ledger.open("a+") as stream:
        lock_ledger(stream)
        try:
            if any(existing.get("task_id") == args.id and
                   (existing.get("instance_id") == row["instance_id"] if row["instance_id"] else
                    existing.get("started_at") == row["started_at"])
                   for line in stream if line.strip() for existing in [json.loads(line)]):
                return
            stream.seek(0, os.SEEK_END)
            stream.write(json.dumps(row, separators=(",", ":"), sort_keys=True) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        finally:
            unlock_ledger(stream)


def summary(args):
    ledger = Path(args.data) / "routing-ledger.jsonl"
    candidates, _ = learning_candidates(args.state) if args.state else ({}, None)
    rows = [json.loads(line) for line in ledger.read_text().splitlines()] if ledger.is_file() else []
    starts = {}
    for row in rows:
        start = timestamp(row.get("started_at"))
        if start is not None:
            starts.setdefault(row["task_id"], set()).add(start)
    if args.state:
        for task in starts:
            meta = Path(args.state) / (task + ".meta")
            if "/" in task or os.sep in task or not meta.is_file():
                continue
            try:
                live = float(fields(meta).get("routing_started_at", ""))
            except (OSError, ValueError):
                continue
            starts[task].add(live)
    groups = {}
    for row in rows:
        if args.from_date <= row["ended_at"][:10] <= args.to_date:
            groups.setdefault(row["routing"]["rule"], []).append(row)
    print("rule\ttasks\tlanded_share\tmedian_rounds\trejected_or_corrected\tcost_coverage\tmedian_cost_usd\tcost_per_landing_usd")
    for rule, rows in sorted(groups.items()):
        landed = sum(x["outcome"]["landed"] for x in rows)
        costs = [x["cost"]["usd_estimate"] for x in rows]
        known = [x for x in costs if x is not None]
        rounds = [x.get("validation_rounds") for x in rows if isinstance(x.get("validation_rounds"), int)]
        flagged = 0
        for x in rows:
            start = timestamp(x.get("started_at"))
            until = min((y for y in starts.get(x["task_id"], ()) if start is not None and y > start), default=None)
            later = signal_outcome(incarnation_candidates(candidates.get(x["task_id"]), start, until)[0], None)
            flagged += any(x["outcome"].get(key) is True or later[key] is True for key in SIGNALS.values())
        median = lambda values: format(statistics.median(values), "g") if values else "null"
        per_landing = str(round(sum(known) / landed, 8)) if landed and len(known) == len(rows) else "null"
        print(f"{rule}\t{len(rows)}\t{landed / len(rows):.3f}\t{median(rounds)}\t{flagged}\t{len(known)}/{len(rows)}\t{median(known)}\t{per_landing}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    write = sub.add_parser("record")
    for flag in ("meta", "state", "data", "id"):
        write.add_argument("--" + flag, required=True)
    write.add_argument("--outcome", choices=("landed", "not-landed"), required=True)
    write.add_argument("--method", choices=("pr-merge", "local-landing", "scout-report", "secondmate-retired", "discarded", "unknown"), required=True)
    view = sub.add_parser("summary")
    view.add_argument("--data", required=True)
    view.add_argument("--state")
    view.add_argument("--from", dest="from_date", required=True)
    view.add_argument("--to", dest="to_date", required=True)
    args = parser.parse_args()
    (record if args.command == "record" else summary)(args)


if __name__ == "__main__":
    main()
