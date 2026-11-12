#!/usr/bin/env python3
"""Check whether a car's changed paths qualify for a documentation gate exemption.

Usage: fm-docs-gate.py <config-root> <repo-name> <checkout> <target> <head>
Exit 0 for a nonempty docs-only diff, 1 for no exemption, and 2 for bad config.
The target and head are commits already validated by fm-landing-queue.sh.
"""

import fnmatch
import json
from pathlib import Path
import subprocess
import sys


def matches(path, pattern):
    # A leading **/ also covers a file in the repository root.
    return fnmatch.fnmatchcase(path, pattern) or (
        pattern.startswith("**/") and fnmatch.fnmatchcase(path, pattern[3:])
    )


def main():
    if len(sys.argv) != 6:
        return 2
    root, repo, checkout, target, head = sys.argv[1:]
    candidates = []
    for config_path in sorted(Path(root).glob("*.json")):
        try:
            config = json.loads(config_path.read_text())
        except (OSError, ValueError) as exc:
            print(f"invalid test-service config {config_path}: {exc}", file=sys.stderr)
            return 2
        if not isinstance(config, dict) or not isinstance(config.get("repos", []), list):
            print(f"invalid test-service config {config_path}: repos must be a list", file=sys.stderr)
            return 2
        if repo != config_path.stem and repo not in config.get("repos", []):
            continue
        candidates.append(config)
    if len(candidates) > 1:
        print(f"multiple test-service projects match {repo}", file=sys.stderr)
        return 2
    if not candidates:
        return 1
    patterns = candidates[0].get("documentation_path_globs", [])
    if not isinstance(patterns, list) or any(
        not isinstance(pattern, str) or not pattern or pattern.startswith("/")
        or ".." in pattern.split("/") or "\\" in pattern
        for pattern in patterns
    ):
        print("documentation_path_globs must list safe relative globs", file=sys.stderr)
        return 2
    if not patterns:
        return 1
    result = subprocess.run(
        ["git", "-C", checkout, "diff", "--name-only", "-z", "--no-renames", target, head, "--"],
        stdout=subprocess.PIPE, check=False,
    )
    if result.returncode:
        return 2
    paths = [part.decode("utf-8", "surrogateescape") for part in result.stdout.split(b"\0") if part]
    return 0 if paths and all(any(matches(path, pattern) for pattern in patterns) for path in paths) else 1


if __name__ == "__main__":
    sys.exit(main())
