#!/usr/bin/env python3
"""Extract read-only review evidence and validate a reusable review playbook.

Usage: fm-review-lessons.py extract --database PATH --candidates DIR
       [--bug-cards PATH] [--since YYYY-MM-DD] [--output PATH]
       fm-review-lessons.py validate PLAYBOOK.json

Extract emits JSON Lines: one summary, then every run, review invocation,
review finding, and escaped-defect candidate. The database is opened read-only.
Cost is null because the no-mistakes ledger records tokens but no price ledger.
BUG cards are accepted as a JSON Lines export with a landed change reference.
"""

import argparse
import collections
import difflib
import json
import re
import sqlite3
import sys
from pathlib import Path


def parsed(value):
    try:
        return json.loads(value) if value else {}
    except (ValueError, TypeError):
        return {}


def emit(stream, record):
    stream.write(json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n")


def extract(database, candidates, stream, bug_cards=None, since=None):
    connection = sqlite3.connect(f"file:{Path(database).resolve()}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    runs = connection.execute("SELECT id, repo_id, branch, status, pr_url, created_at FROM runs ORDER BY created_at, id").fetchall()
    if since:
        import datetime
        threshold = int(datetime.datetime.fromisoformat(since).replace(tzinfo=datetime.timezone.utc).timestamp())
        runs = [row for row in runs if row["created_at"] >= threshold]
    run_ids = {row["id"] for row in runs}
    invocations = connection.execute("""SELECT id, run_id, round, purpose, agent, model, session_mode,
        input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
        fresh_input_tokens, duration_ms, finding_count FROM agent_invocations
        WHERE step_name='review' ORDER BY run_id, round, started_at, id""").fetchall()
    invocations = [row for row in invocations if row["run_id"] in run_ids]
    rounds = connection.execute("""SELECT s.run_id, r.round, r.findings_json,
        r.selected_finding_ids, r.selection_source, r.user_findings_json,
        r.fix_summary, r.reviewed_head_sha, r.starting_head_sha
        FROM step_rounds r JOIN step_results s ON s.id=r.step_result_id
        WHERE s.step_name='review' ORDER BY s.run_id, r.round, r.created_at, r.id""").fetchall()
    rounds = [row for row in rounds if row["run_id"] in run_ids]
    escaped = []
    for path in sorted(Path(candidates).glob("*.json")):
        try:
            candidate = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        incident = candidate.get("incident") or {}
        if incident.get("signal_type") == "escaped-defect" and (not since or candidate.get("captured_at", "")[:10] >= since):
            escaped.append((candidate, incident))
    cards = []
    if bug_cards:
        for line in Path(bug_cards).read_text().splitlines():
            card = json.loads(line)
            if card.get("type", card.get("card_type")) != "BUG":
                continue
            if not (card.get("pr_url") or card.get("landed_change")):
                continue
            cards.append(card)
    findings = []
    by_run = collections.defaultdict(list)
    for row in rounds:
        by_run[row["run_id"]].append(row)
    for run_id, records in by_run.items():
        seen = []
        for row in records:
            selected = parsed(row["selected_finding_ids"])
            selected = selected if isinstance(selected, list) else []
            payload = parsed(row["findings_json"])
            items = payload.get("findings", []) if isinstance(payload, dict) else []
            if not isinstance(items, list):
                continue
            for finding in items:
                if not isinstance(finding, dict):
                    continue
                description = finding.get("description") or ""
                repeated = any(previous["round"] != row["round"] and (
                    (finding.get("id") == previous["id"] and not re.fullmatch(r"(?:review|r)-?\d+", str(finding.get("id")), re.I))
                    or (finding.get("file") == previous["file"] and
                        difflib.SequenceMatcher(None, description[:600], previous["description"][:600]).ratio() >= 0.68)
                ) for previous in seen)
                seen.append({"round": row["round"], "id": finding.get("id"),
                             "file": finding.get("file"), "description": description})
                findings.append({"type": "finding", "run_id": run_id, "round": row["round"],
                                 "id": finding.get("id"), "severity": finding.get("severity"),
                                 "file": finding.get("file"), "line": finding.get("line"),
                                 "description": finding.get("description"),
                                 "action": finding.get("action"),
                                 "selected_for_fix": finding.get("id") in selected,
                                 "re_raised_same_issue": repeated,
                                 "reviewed_head_sha": row["reviewed_head_sha"]})
    emit(stream, {"type": "summary", "runs": len(runs), "review_invocations": len(invocations),
                  "review_rounds": len(rounds), "findings": len(findings),
                  "escaped_defects": len(escaped), "landed_bug_cards": len(cards), "cost_usd": None,
                  "cost_note": "No price ledger in state.sqlite; use model-specific external pricing before estimating cost."})
    for row in runs:
        emit(stream, {"type": "run", **dict(row)})
    for row in invocations:
        emit(stream, {"type": "review_invocation", **dict(row)})
    for row in rounds:
        emit(stream, {"type": "review_round", "run_id": row["run_id"],
                      "round": row["round"], "selected_finding_ids": parsed(row["selected_finding_ids"]),
                      "selection_source": row["selection_source"],
                      "user_findings": parsed(row["user_findings_json"]),
                      "fix_summary": row["fix_summary"],
                      "reviewed_head_sha": row["reviewed_head_sha"],
                      "starting_head_sha": row["starting_head_sha"]})
    for record in findings:
        emit(stream, record)
    for candidate, incident in escaped:
        emit(stream, {"type": "escaped_defect", "id": candidate.get("id"),
                      "lifecycle_state": candidate.get("lifecycle_state"),
                      "captured_at": candidate.get("captured_at"), **incident})
    for card in cards:
        emit(stream, {"type": "landed_bug_card", "card": card})
    connection.close()


INSTANCE = re.compile(r"(?:\b(?:PR|BUG|ET)[- #]*\d+\b|\b[a-f0-9]{7,40}\b|(?:^|\s)[\w.-]+/[\w./-]+|\b\w+\.(?:py|sh|js|ts|gd|md)\b)", re.I)
OWNERS = {"reviewer-guidance", "firstmate-brief", "project-agents", "no-mistakes-follow-up"}


def validate(path):
    document = json.loads(Path(path).read_text())
    patterns = document.get("patterns")
    if not isinstance(patterns, list) or not patterns:
        raise ValueError("playbook needs at least one pattern")
    for index, pattern in enumerate(patterns, 1):
        if pattern.get("kind") not in {"waste", "miss"}:
            raise ValueError(f"pattern {index}: kind must be waste or miss")
        if pattern.get("owner") not in OWNERS:
            raise ValueError(f"pattern {index}: unknown prevention owner")
        for field in ("pattern", "prevention"):
            value = pattern.get(field)
            if not isinstance(value, str) or len(value.strip()) < 20 or INSTANCE.search(value):
                raise ValueError(f"pattern {index}: {field} is absent or instance-specific")
        evidence = pattern.get("evidence")
        if not isinstance(evidence, list) or len(set(evidence)) < 2:
            raise ValueError(f"pattern {index}: recurring evidence needs two distinct source records")
    print(f"valid playbook: {len(patterns)} patterns")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    collect = sub.add_parser("extract")
    collect.add_argument("--database", required=True)
    collect.add_argument("--candidates", required=True)
    collect.add_argument("--output")
    collect.add_argument("--bug-cards")
    collect.add_argument("--since")
    check = sub.add_parser("validate")
    check.add_argument("playbook")
    args = parser.parse_args()
    try:
        if args.command == "extract":
            if args.since:
                import datetime
                datetime.date.fromisoformat(args.since)
            if args.output:
                with open(args.output, "w") as stream:
                    extract(args.database, args.candidates, stream, args.bug_cards, args.since)
            else:
                extract(args.database, args.candidates, sys.stdout, args.bug_cards, args.since)
        else:
            validate(args.playbook)
    except (OSError, sqlite3.Error, ValueError, KeyError) as error:
        parser.exit(1, f"fm-review-lessons: {error}\n")


if __name__ == "__main__":
    main()
