#!/usr/bin/env python3
"""Extract read-only review evidence and validate a reusable review playbook.

Usage: fm-review-lessons.py extract --database PATH --candidates DIR
       [--bug-cards PATH] [--since YYYY-MM-DD] [--output PATH]
       fm-review-lessons.py validate PLAYBOOK_OR_CLASSES.json [--candidates DIR]
       fm-review-lessons.py recurrence --candidates DIR --backlog PATH
           --archive PATH --classes PATH --ledger PATH --since YYYY-MM-DD
           [--output PATH]

Extract emits JSON Lines: one summary, then every run, review invocation,
review finding, and escaped-defect candidate. The database is opened read-only.
Cost is null because the no-mistakes ledger records tokens but no price ledger.
BUG cards are accepted as a JSON Lines export with a landed change reference.
"""

import argparse
import collections
import difflib
import io
import json
import math
import re
import sqlite3
import sys
from datetime import date, timedelta
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
        if incident.get("signal_type") == "escaped-defect" and (not since or (candidate.get("captured_at") or "")[:10] >= since):
            escaped.append((candidate, incident))
    cards = []
    if bug_cards:
        for number, line in enumerate(Path(bug_cards).read_text().splitlines(), 1):
            if not line.strip():
                continue
            try:
                card = json.loads(line)
            except ValueError as error:
                raise ValueError(f"{bug_cards}:{number}: malformed BUG card JSON: {error}") from error
            if not isinstance(card, dict):
                continue
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
                    (finding.get("id") == previous["id"] and not re.fullmatch(r"[A-Za-z]{1,8}-?\d+", str(finding.get("id"))))
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


INSTANCE = re.compile(r"(?:\b(?:PR|BUG|ET)[- #]*\d+\b|\b(?=[a-f0-9]*\d)[a-f0-9]{7,40}\b|(?:^|\s)[\w.-]+/[\w.-]+/[\w./-]+|\b\w+\.(?:py|sh|js|ts|gd|md)\b)", re.I)
OWNERS = {"reviewer-guidance", "firstmate-brief", "project-agents", "no-mistakes-follow-up"}


def validate_playbook(document):
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


LESSON = re.compile(r"^- \[([ x])\] (lesson-[a-z]+[0-9]+[a-z]?) - ")
DONE = re.compile(r"\((?:merged|done|reported) (\d{4}-\d{2}-\d{2})\)")
LESSON_REF = re.compile(r"lesson-[a-z]+[0-9]+[a-z]?")
STOP = set("""a an and are as at be been before but by can could did do does for from had has have
if in into is it its no nor not of on only or other so such than that the their then there these
this those to was were when where which while who whose will with without would never after
any all also both each every more most own same some too very one two three first second new
old still yet during over under again against between through about above below out up down
existing missing check checks test tests assert asserted asserts assertion assertions did
actual real used using use ran run runs covered cover exercised exercise""".split())
CLASS_INSTANCE = re.compile(r"\b(?:lesson-[a-z]+\d+|(?:fm|nm|frogpile)-[a-z0-9-]+|[A-Za-z_][\w.-]*\.(?:py|sh|js|ts|gd|md|json))\b", re.I)


def candidates_from(path):
    records = {}
    for file in sorted(Path(path).glob("lc-*.json")):
        record = json.loads(file.read_text())
        identifier = record["id"]
        if identifier in records:
            raise ValueError(f"duplicate candidate {identifier}")
        records[identifier] = record
    return records


def validate_classes(document, candidates):
    classes = document.get("classes")
    if not isinstance(classes, list):
        raise ValueError("class file needs a classes list")
    loop_raised = document.get("loop_raised", [])
    if not isinstance(loop_raised, list) or any(not isinstance(day, str) for day in loop_raised):
        raise ValueError("loop_raised must be a list of dates")
    for day in loop_raised:
        date.fromisoformat(day)
    slugs, members = set(), set()
    for index, item in enumerate(classes, 1):
        if not isinstance(item, dict):
            raise ValueError(f"class {index}: invalid entry")
        slug, statement = item.get("slug"), item.get("statement")
        if not isinstance(slug, str) or not re.fullmatch(r"[a-z][a-z0-9-]*", slug) or slug in slugs:
            raise ValueError(f"class {index}: invalid or duplicate slug")
        slugs.add(slug)
        if not isinstance(statement, str) or len(statement.strip()) < 20 or CLASS_INSTANCE.search(statement) or INSTANCE.search(statement):
            raise ValueError(f"class {slug}: statement is absent or instance-specific")
        group = item.get("members")
        if not isinstance(group, list) or any(not isinstance(member, str) for member in group) or len(group) != len(set(group)):
            raise ValueError(f"class {slug}: members must be unique ids")
        for identifier in group:
            if identifier not in candidates:
                raise ValueError(f"class {slug}: unknown member {identifier}")
            if identifier in members:
                raise ValueError(f"candidate {identifier} belongs to multiple classes")
            members.add(identifier)
        raised = item.get("raised")
        if not isinstance(raised, list) or any(not isinstance(r, dict) or not isinstance(r.get("count"), int)
                or r["count"] < 1 or not isinstance(r.get("date"), str) for r in raised):
            raise ValueError(f"class {slug}: invalid raised history")
        for r in raised:
            date.fromisoformat(r["date"])
    return classes


def validate(path, candidates=None):
    document = json.loads(Path(path).read_text())
    if "classes" in document:
        records = candidates_from(candidates or "state/learning-candidates")
        classes = validate_classes(document, records)
        print(f"valid classes: {len(classes)} classes, {sum(len(c['members']) for c in classes)} members")
    else:
        validate_playbook(document)


def lesson_dates(backlog, archive):
    landed, open_lessons = {}, set()
    for path in (archive, backlog):
        for line in Path(path).read_text().splitlines():
            match = LESSON.match(line)
            if match:
                done = DONE.search(line)
                if match[1] == "x" and done:
                    landed[match[2]] = done[1]
                else:
                    open_lessons.add(match[2])
    return landed, open_lessons - landed.keys()


def tokens(value):
    words = []
    for word in re.findall(r"[a-z][a-z0-9_]{2,}", value.lower()):
        if word in STOP:
            continue
        for suffix in ("ing", "ed", "es", "s"):
            if len(word) > len(suffix) + 3 and word.endswith(suffix):
                word = word[:-len(suffix)]
                break
        words.append(word)
    return words


def recurrence(candidates, backlog, archive, classes_path, ledger_path, since, stream):
    records = candidates_from(candidates)
    class_document = json.loads(Path(classes_path).read_text())
    classes = validate_classes(class_document, records)
    landed, open_lessons = lesson_dates(backlog, archive)
    claims = {}

    def claim(identifier, seen=None):
        if identifier in claims:
            return claims[identifier]
        if seen is None:
            seen = set()
        if identifier in seen:
            raise ValueError(f"duplicate cycle at {identifier}")
        seen.add(identifier)
        record = records[identifier]
        disposition = record.get("disposition") or {}
        outcome, at, ref = (disposition.get(k) or "" for k in ("outcome", "at", "reference"))
        result = None
        if outcome in ("dismissed", "documented", "promoted") and at:
            result = (at[:10], outcome, ref, identifier)
        elif outcome == "follow-up":
            match = LESSON_REF.search(ref)
            if match and match.group() in landed:
                result = (landed[match.group()], "lesson landed", match.group(), identifier)
        elif outcome == "duplicate" and ref in records:
            result = claim(ref, seen)
        claims[identifier] = result
        return result

    def captured(identifier):
        return records[identifier].get("captured_at", "")[:10]

    def task(identifier):
        return (records[identifier].get("incident") or {}).get("origin_task")

    def eligible(earlier, later):
        assertion = claim(earlier)
        return (earlier != later and assertion and assertion[0] <= captured(later)
                and records[earlier].get("captured_at", "") < records[later].get("captured_at", "")
                and task(earlier) != task(later))

    counts = {identifier: collections.Counter(tokens(" ".join(str((record.get("incident") or {}).get(key) or "")
              for key in ("root_cause", "missing_check")))) for identifier, record in records.items()}
    df = collections.Counter()
    for count in counts.values():
        df.update(count.keys())
    n = len(records)
    vectors = {identifier: {word: (1 + math.log(frequency)) * math.log(n / df[word])
               for word, frequency in count.items()} for identifier, count in counts.items()}
    norms = {identifier: math.sqrt(sum(value * value for value in vector.values())) or 1.0
             for identifier, vector in vectors.items()}

    def cosine(left, right):
        a, b = vectors[left], vectors[right]
        if len(a) > len(b):
            a, b = b, a
        return sum(value * b.get(word, 0) for word, value in a.items()) / (norms[left] * norms[right])

    batch = sorted((identifier for identifier in records if captured(identifier) >= since), key=lambda i: (captured(i), i))
    shortlist = {}
    for identifier in batch:
        ranked = [(cosine(identifier, prior), prior) for prior in records if eligible(prior, identifier)]
        ranked.sort(key=lambda row: (-row[0], row[1]))
        shortlist[identifier] = [(score, prior) for score, prior in ranked[:5] if score >= 0.10]

    member_class = {identifier: item for item in classes for identifier in item["members"]}
    recurrences = []
    for identifier in batch:
        item = member_class.get(identifier)
        if not item:
            continue
        earlier = sorted((prior for prior in item["members"] if eligible(prior, identifier)),
                         key=lambda prior: (claim(prior)[0], captured(prior), prior))
        if earlier:
            recurrences.append((identifier, item, earlier[0]))

    ledger = Path(ledger_path)
    existing = set()
    if ledger.exists():
        for line in ledger.read_text().splitlines():
            if line.strip():
                row = json.loads(line)
                existing.add((row["candidate"], row["class"]))
    new_rows = []
    for identifier, item, earlier in recurrences:
        key = (identifier, item["slug"])
        if key not in existing:
            new_rows.append({"date": captured(identifier), "candidate": identifier, "class": item["slug"],
                             "earlier_claim": claim(earlier)[3], "kind_of_claim": claim(earlier)[1]})
            existing.add(key)
    if new_rows:
        ledger.parent.mkdir(parents=True, exist_ok=True)
        with ledger.open("a") as handle:
            for row in new_rows:
                emit(handle, row)

    today = date.today()
    window_start = (today - timedelta(days=6)).isoformat()
    window = [i for i in records if captured(i) >= window_start and captured(i) <= today.isoformat()]
    window_repeats = [i for i, _, _ in recurrences if i in window]
    # Include prior ledger entries for the seven-day rate across incremental batches.
    if ledger.exists():
        window_repeats = {json.loads(line)["candidate"] for line in ledger.read_text().splitlines() if line.strip()
                          and window_start <= json.loads(line)["date"] <= today.isoformat()}
    share = len(window_repeats) / len(window) if window else 0
    kinds = collections.Counter(claim(earlier)[1] for _, _, earlier in recurrences)
    stream.write("## Recurrence check\n\n")
    stream.write(f"Batch: {len(batch)} incidents; {len(recurrences)} recurrences (lesson landed {kinds['lesson landed']}, "
                 f"dismissed {kinds['dismissed']}, documented {kinds['documented']}, promoted {kinds['promoted']}); "
                 f"seven-day share {len(window_repeats)}/{len(window)} ({share:.1%}).\n\n")
    stream.write("| Class statement | Earlier claims (id, outcome, date, reference) | Today's incidents | Days since first claim | Total repeats since first claim |\n")
    stream.write("| --- | --- | --- | ---: | ---: |\n")
    for item in classes:
        touched = [i for i in batch if member_class.get(i) is item]
        if not touched:
            continue
        earlier = sorted((i for i in item["members"] if claim(i) and captured(i) < max(map(captured, touched))),
                         key=lambda i: (claim(i)[0], i))
        first = min((claim(i)[0] for i in earlier), default="")
        repeats = sum(bool([j for j in item["members"] if eligible(j, i)]) for i in item["members"])
        labels = "; ".join(f"{i} {claim(i)[1]} {claim(i)[0]} {claim(i)[2]}" for i in earlier)
        stream.write(f"| {item['statement'].replace('|', '/')} | {labels.replace('|', '/')} | {', '.join(touched)} | "
                     f"{(today - date.fromisoformat(first)).days if first else '-'} | {repeats} |\n")
    stream.write("\n### Lessons that did not hold\n\n")
    failed_lessons = sorted({(claim(earlier)[2], claim(earlier)[0]) for _, _, earlier in recurrences
                             if claim(earlier)[1] == "lesson landed"})
    stream.write("\n".join(f"- {lesson}, landed {at}." for lesson, at in failed_lessons) or "None.")
    stream.write("\n\n### Repeats while a fix is open\n\n")
    open_repeats = []
    for identifier in batch:
        item = member_class.get(identifier)
        if not item:
            continue
        for prior in item["members"]:
            if prior == identifier or task(prior) == task(identifier) or not records[prior].get("captured_at", "") < records[identifier].get("captured_at", ""):
                continue
            disposition = records[prior].get("disposition") or {}
            match = LESSON_REF.search(disposition.get("reference") or "")
            if disposition.get("outcome") == "follow-up" and match and match.group() in open_lessons:
                open_repeats.append((identifier, prior, match.group()))
    stream.write("\n".join(f"- {later} repeats {earlier} while {lesson} is open." for later, earlier, lesson in open_repeats) or "None.")
    stream.write("\n\n### Raise to the product owner\n\n")
    raised = []
    raised_mutated = False
    for item in classes:
        repeats = sorted((i for i in item["members"] if any(eligible(p, i) for p in item["members"])), key=captured)
        previous = {entry["count"] for entry in item["raised"]}
        for count in range(3, len(repeats) + 1, 3):
            if count not in previous and repeats[count - 1] in batch:
                raised.append(f"T1 {item['slug']}: {count} recurrences. Proposed fix: strengthen the class-level check: {item['statement']}")
                item["raised"].append({"count": count, "date": today.isoformat()})
                raised_mutated = True
        lessons = collections.defaultdict(list)
        for i in repeats:
            for p in item["members"]:
                if eligible(p, i) and claim(p)[1] == "lesson landed":
                    landing = claim(p)[0]
                    if 0 <= (date.fromisoformat(captured(i)) - date.fromisoformat(landing)).days <= 14:
                        lessons[(claim(p)[2], landing)].append(i)
        for (lesson, landing), incidents in lessons.items():
            ordered = sorted(set(incidents), key=lambda i: (captured(i), i))
            if len(ordered) >= 2 and ordered[1] in batch:
                raised.append(f"T2 {lesson}: {len(set(incidents))} recurrences within 14 days of {landing}. Proposed fix: strengthen {item['slug']} coverage.")
    loop_raised = class_document.setdefault("loop_raised", [])
    if not isinstance(loop_raised, list):
        raise ValueError("loop_raised must be a list of dates")
    if len(window) >= 20 and share >= 0.25 and not any(
            0 <= (today - date.fromisoformat(day)).days < 7 for day in loop_raised):
        raised.append(f"T3 loop health: {len(window_repeats)}/{len(window)} ({share:.1%}) in seven days. Proposed fix: review the highest-volume failure classes.")
        loop_raised.append(today.isoformat())
        raised_mutated = True
    stream.write(("- " + " ".join(raised)) if raised else "None.")
    if raised_mutated:
        Path(classes_path).write_text(json.dumps(class_document, indent=2, ensure_ascii=False) + "\n")
    stream.write("\n\n### Judgement queue\n\n")
    stream.write("For each batch incident, judge it against every class statement; the candidate class assignments above require curator review.\n\n")
    for identifier in batch:
        must = [(prior, score) for score, prior in shortlist[identifier] if score >= 0.20]
        if must:
            stream.write(f"- Must judge {identifier}: " + ", ".join(f"{prior} ({score:.3f})" for prior, score in must) + ".\n")
    stream.write(f"\nSource counts: {len(records)} candidates, {len(classes)} classes, {len(batch)} batch incidents, "
                 f"{sum(bool(shortlist[i]) for i in batch)} with shortlist, "
                 f"{sum(any(score >= 0.20 for score, _ in shortlist[i]) for i in batch)} must-judge incidents, "
                 f"{len(new_rows)} new ledger rows.\n")


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
    check.add_argument("--candidates")
    repeat = sub.add_parser("recurrence")
    for flag in ("candidates", "backlog", "archive", "classes", "ledger", "since"):
        repeat.add_argument("--" + flag, required=True)
    repeat.add_argument("--output")
    args = parser.parse_args()
    try:
        if args.command == "extract":
            if args.since:
                import datetime
                datetime.date.fromisoformat(args.since)
            buffer = io.StringIO()
            extract(args.database, args.candidates, buffer, args.bug_cards, args.since)
            if args.output:
                Path(args.output).write_text(buffer.getvalue())
            else:
                sys.stdout.write(buffer.getvalue())
        elif args.command == "validate":
            validate(args.playbook, args.candidates)
        else:
            date.fromisoformat(args.since)
            buffer = io.StringIO()
            recurrence(args.candidates, args.backlog, args.archive, args.classes, args.ledger, args.since, buffer)
            if args.output:
                Path(args.output).write_text(buffer.getvalue())
            else:
                sys.stdout.write(buffer.getvalue())
    except (OSError, sqlite3.Error, ValueError, KeyError) as error:
        parser.exit(1, f"fm-review-lessons: {error}\n")


if __name__ == "__main__":
    main()
