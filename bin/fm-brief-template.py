#!/usr/bin/env python3
"""Validate and render private fm-brief task templates.

Format: YAML-like front matter with one-line name, project, when, and
comma-separated placeholders fields, followed by the two task subsections.
This deliberately does not accept general YAML or nested values.
"""

import argparse
from pathlib import Path
import re
import sys


KEYS = {"name", "project", "when", "placeholders"}
IDENT = re.compile(r"[A-Za-z][A-Za-z0-9_]*\Z")
TOKEN = re.compile(r"\{\{([A-Za-z][A-Za-z0-9_]*)\}\}")


def fail(message):
    raise ValueError(message)


def load(path, project):
    if not path.is_file() or path.is_symlink():
        fail(f"template is not a regular file: {path}")
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        fail(f"{path}: missing front matter opening ---")
    try:
        end = next(i for i, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration:
        fail(f"{path}: missing front matter closing ---")
    fields = {}
    for line in lines[1:end]:
        match = re.fullmatch(r"([a-z-]+):[ \t]*(.*)\n?", line.rstrip("\n"))
        if not match or match[1] not in KEYS or match[1] in fields:
            fail(f"{path}: invalid, unknown, or repeated front matter field: {line.strip()}")
        fields[match[1]] = match[2].strip()
    missing = KEYS - fields.keys()
    if missing:
        fail(f"{path}: missing front matter fields: {', '.join(sorted(missing))}")
    if not fields["name"] or not IDENT.fullmatch(fields["name"].replace("-", "_")):
        fail(f"{path}: invalid name")
    if path.stem != fields["name"]:
        fail(f"{path}: name must match filename stem")
    if fields["project"] != project:
        fail(f"{path}: project must match {project}")
    if not fields["when"] or "\r" in fields["when"]:
        fail(f"{path}: when must be nonempty plain text")
    declared = [item.strip() for item in fields["placeholders"].split(",") if item.strip()]
    if len(declared) != len(set(declared)) or any(not IDENT.fullmatch(item) for item in declared):
        fail(f"{path}: invalid or repeated placeholders")
    body = "".join(lines[end + 1:]).strip()
    headings = list(re.finditer(r"^## (Captain's intent|Firstmate spec)[ \t]*$", body, re.M))
    if len(headings) != 2 or [m[1] for m in headings] != ["Captain's intent", "Firstmate spec"]:
        fail(f"{path}: template needs Captain's intent and Firstmate spec sections in order")
    if body[:headings[0].start()].strip():
        fail(f"{path}: unexpected content before Captain's intent")
    for index, match in enumerate(headings):
        tail = headings[index + 1].start() if index + 1 < len(headings) else len(body)
        if not body[match.end():tail].strip():
            fail(f"{path}: empty {match[1]} section")
    used = set(TOKEN.findall(body))
    undeclared = used - set(declared)
    unused = set(declared) - used
    if undeclared or unused or "{{" in TOKEN.sub("", body):
        fail(f"{path}: placeholder declaration mismatch (undeclared: {', '.join(sorted(undeclared)) or 'none'}; unused: {', '.join(sorted(unused)) or 'none'})")
    return fields, body, declared


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("list", "render"))
    parser.add_argument("path", type=Path)
    parser.add_argument("project")
    parser.add_argument("--set", action="append", default=[])
    parser.add_argument("--set-file", action="append", default=[])
    args = parser.parse_args()
    if args.action == "list":
        if not args.path.exists():
            return
        if not args.path.is_dir() or args.path.is_symlink():
            fail(f"template directory is invalid: {args.path}")
        for path in sorted(args.path.glob("*.md")):
            fields, _, _ = load(path, args.project)
            print(f"{fields['name']}: {fields['when']}")
        return
    fields, body, declared = load(args.path, args.project)
    values = {}
    for item in args.set:
        if "=" not in item:
            fail(f"--set needs NAME=value: {item}")
        name, value = item.split("=", 1)
        if name in values:
            fail(f"repeated --set name: {name}")
        values[name] = value
    for item in args.set_file:
        if "=" not in item:
            fail(f"--set-file needs NAME=path: {item}")
        name, path = item.split("=", 1)
        if name in values:
            fail(f"repeated --set name: {name}")
        values[name] = Path(path).read_text(encoding="utf-8")
    unknown = values.keys() - set(declared)
    missing = set(declared) - values.keys()
    if unknown or missing:
        fail(f"{args.path}: unknown --set names: {', '.join(sorted(unknown)) or 'none'}; unfilled placeholders: {', '.join(sorted(missing)) or 'none'}")
    rendered = TOKEN.sub(lambda match: values[match[1]], body)
    if "{{" in rendered:
        fail(f"{args.path}: unfilled placeholder remains after rendering")
    print("# Task\n" + rendered)


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
