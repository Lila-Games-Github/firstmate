#!/usr/bin/env python3
"""Append task routing evidence and summarize it. See docs/configuration.md."""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import statistics

if os.name == "nt":
    import msvcrt
else:
    import fcntl


ROOT = Path(__file__).resolve().parent.parent
PRICES = ROOT / "bin" / "fm-routing-prices.json"


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
        "validation_rounds": sum("validation" in x.lower() and "round" in x.lower() for x in lines),
        "failed_rounds": sum("failed" in x.lower() and ("test" in x.lower() or "validation" in x.lower()) for x in lines),
        "needs_decision_count": sum(x.startswith("needs-decision") for x in lines),
        "blocked_count": sum(x.startswith("blocked:") for x in lines),
        "stale_wake_count": sum("stale wake" in x.lower() for x in lines),
        "captain_rejection_count": sum("captain rejected" in x.lower() for x in lines),
        "captain_correction_count": sum("captain correction" in x.lower() for x in lines),
    }


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


def record(args):
    meta = fields(Path(args.meta))
    start_value = meta.get("routing_started_at")
    start = float(start_value) if start_value else None
    end = dt.datetime.now(dt.timezone.utc).timestamp()
    state = Path(args.state)
    data = Path(args.data)
    status = event_counts(state / (args.id + ".status"))
    candidate_dir = state / "learning-candidates"
    candidates = []
    if candidate_dir.is_dir():
        for path in candidate_dir.glob("*.json"):
            try:
                item = json.loads(path.read_text())
                if item.get("origin_task") == args.id or (item.get("incident") or {}).get("origin_task") == args.id:
                    candidates.append(item.get("id", path.stem))
            except (OSError, ValueError):
                pass
    row = {
        "schema": 1, "task_id": args.id, "instance_id": meta.get("routing_instance_id", meta.get("spawn_gen")),
        "project": meta.get("project"),
        "kind": meta.get("kind"), "delivery_mode": meta.get("mode"),
        "routing": {"rule": meta.get("routing_rule", "manual"), "override_reason": meta.get("routing_reason"),
                    "provider": meta.get("routing_provider"), "harness": meta.get("routing_harness", meta.get("harness")),
                    "model": meta.get("routing_model", meta.get("model")), "effort": meta.get("routing_effort", meta.get("effort")),
                    "quota_snapshot": json.loads(meta["routing_quota"]) if meta.get("routing_quota") else None,
                    "quota_reason": meta.get("routing_quota_reason")},
        "started_at": iso(start) if start is not None else None,
        "ended_at": iso(end), "wall_seconds": round(end - start, 3) if start is not None else None,
        "outcome": {"landed": args.outcome == "landed", "method": args.method,
                    "captain_rejected": status.pop("captain_rejection_count") > 0,
                    "captain_corrected": status.pop("captain_correction_count") > 0},
        **status, "relaunches": int(meta.get("routing_relaunches", "0")),
        "learning_candidates": sorted(candidates),
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
    groups = {}
    if ledger.is_file():
        for line in ledger.read_text().splitlines():
            row = json.loads(line)
            if args.from_date <= row["ended_at"][:10] <= args.to_date:
                groups.setdefault(row["routing"]["rule"], []).append(row)
    print("rule\ttasks\tlanded_share\tmedian_rounds\tcost_coverage\tmedian_cost_usd\tcost_per_landing_usd")
    for rule, rows in sorted(groups.items()):
        landed = sum(x["outcome"]["landed"] for x in rows)
        costs = [x["cost"]["usd_estimate"] for x in rows]
        known = [x for x in costs if x is not None]
        median = lambda values: format(statistics.median(values), "g") if values else "null"
        per_landing = str(round(sum(known) / landed, 8)) if landed and len(known) == len(rows) else "null"
        print(f"{rule}\t{len(rows)}\t{landed / len(rows):.3f}\t{median([x['validation_rounds'] for x in rows])}\t{len(known)}/{len(rows)}\t{median(known)}\t{per_landing}")


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
    view.add_argument("--from", dest="from_date", required=True)
    view.add_argument("--to", dest="to_date", required=True)
    args = parser.parse_args()
    (record if args.command == "record" else summary)(args)


if __name__ == "__main__":
    main()
