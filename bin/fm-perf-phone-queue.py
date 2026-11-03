#!/usr/bin/env python3
"""Performance queue entry using Firstmate's shared client (no project import).

Usage: fm-perf-phone-queue.py [old-phone_queue.py] --project PROJECT --serial SERIAL -- COMMAND...
The optional old script path is accepted for existing adapter argv compatibility;
it is never imported or executed. FM_TEST_PROJECT supplies --project in service steps.
"""
import sys

import fm_test_queues


def main():
    args = sys.argv[1:]
    if args and not args[0].startswith("-"):
        args = args[1:]
    return fm_test_queues.main(["phone", *args])


if __name__ == "__main__":
    sys.exit(main())
