#!/usr/bin/env python3
"""Execute a project phone-queue module as the performance service lease entry."""
import argparse
from pathlib import Path
import sys


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("queue", type=Path)
    p.add_argument("--serial", required=True)
    p.add_argument("command", nargs=argparse.REMAINDER)
    args = p.parse_args()
    script = args.queue.resolve()
    if not script.is_file() or script.name != "phone_queue.py":
        p.error("queue must name the project's phone_queue.py")
    sys.path.insert(0, str(script.parent))
    import phone_queue  # noqa: E402
    return phone_queue.main(["--serial", args.serial, *args.command])


if __name__ == "__main__":
    sys.exit(main())
