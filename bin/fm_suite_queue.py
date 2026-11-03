"""FIFO admission to a bounded number of full-suite slots.

The shell opens every lock descriptor. This helper flocks the selected slot,
worktree, old queue and legacy locks on those inherited file descriptions;
they remain held by the shell after this process exits. Tickets, events and
slot files use the compatible restart-safe queue format owned by Firstmate.
"""

from __future__ import annotations

import argparse
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import fm_queue_tickets as queue_tickets

NOTICE_S = 15
STALE_AFTER_S = 30


def say(message: str) -> None:
    print(f"[run_suite] {message}", flush=True)


def describe_holders(directory: Path) -> None:
    now = int(time.time())
    for path in sorted(directory.glob("slot-*.holder")):
        try:
            fields = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
        except OSError:
            continue
        started, beat = fields.get("started", ""), fields.get("heartbeat", "")
        elapsed = now - int(started) if started.isdigit() else "?"
        alive = "yes" if beat.isdigit() and now - int(beat) <= STALE_AFTER_S else "stale"
        say(f"  holder {path.stem}: pid={fields.get('pid') or '?'} alive={alive} "
            f"elapsed={elapsed}s cwd={fields.get('cwd') or '?'}")


def try_lock(fd: int, mode: int) -> bool:
    try:
        fcntl.flock(fd, mode | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def lock_while_alive(fd: int, mode: int, owner: dict, poll_s: float) -> bool:
    """Keep kernel FIFO against old exclusive flock callers, watching the owner.

    The small child blocks in flock on the inherited open file description.
    Its exit leaves the lock with the caller; abandonment kills/reaps the child
    and unlocks even if it acquired just as its owner disappeared.
    """
    child = subprocess.Popen([sys.executable, "-c",
                              "import fcntl,sys; fcntl.flock(int(sys.argv[1]),int(sys.argv[2]))",
                              str(fd), str(mode)], pass_fds=(fd,))
    acquired = False
    try:
        while queue_tickets.alive(owner):
            status = child.poll()
            if status is not None:
                acquired = status == 0
                return acquired
            time.sleep(poll_s)
        return False
    finally:
        if child.poll() is None:
            child.terminate()
        child.wait()
        if not acquired:
            fcntl.flock(fd, fcntl.LOCK_UN)


def wait(queue: Path, owner_pid: int, holder: Path, capacity: int,
         selection_out: Path, worktree_fd: int, queue_fd: int, legacy_fd: int,
         slot_fds: list[int], poll_s: float = 1.0) -> int:
    tickets = queue / "tickets"
    tickets.mkdir(parents=True, exist_ok=True)
    log = queue / "events.jsonl"
    owner = queue_tickets.identity(owner_pid)
    record = {**owner, "cwd": os.getcwd(), "requested_unix": int(time.time())}
    mutex = (queue / "queue.lock").open("a+")
    capacity_path = queue / "capacity"
    ticket_path = None
    requested = time.monotonic()
    slot_index = None
    admitted = False
    try:
        fcntl.flock(mutex, fcntl.LOCK_EX)
        try:
            if capacity_path.exists():
                configured = capacity_path.read_text().strip()
                if configured != str(capacity):
                    say(f"FAIL: queue capacity is {configured}, requested {capacity}; all callers must agree")
                    return 2
            else:
                capacity_path.write_text(f"{capacity}\n")
            ticket = queue_tickets.next_name(queue)
            ticket_path = tickets / f"{ticket}.json"
            queue_tickets.write(ticket_path, record)
            queue_tickets.event(log, "request", ticket, owner_pid=owner_pid, cwd=record["cwd"])
        finally:
            fcntl.flock(mutex, fcntl.LOCK_UN)
        announced = False
        last_notice = time.monotonic()
        while True:
            fcntl.flock(mutex, fcntl.LOCK_EX)
            try:
                if not queue_tickets.alive(owner):
                    queue_tickets.event(log, "abandon", ticket, owner_pid=owner_pid)
                    return 1
                live = queue_tickets.live(tickets, lambda name, dead: queue_tickets.event(
                    log, "crash_cleanup", name, owner_pid=dead.get("pid")))
                position = [name for name, _record in live].index(ticket) + 1
                # Only the oldest waiter can claim the next free slot. The
                # worktree flock prevents two full suites in one checkout.
                if position == 1 and try_lock(worktree_fd, fcntl.LOCK_EX):
                    for index, fd in enumerate(slot_fds):
                        if try_lock(fd, fcntl.LOCK_EX):
                            slot_index = index
                            break
                    if slot_index is None:
                        fcntl.flock(worktree_fd, fcntl.LOCK_UN)
            finally:
                fcntl.flock(mutex, fcntl.LOCK_UN)
            if slot_index is not None:
                # SH permits other new runners; older wrappers take EX and
                # therefore never overlap any newly admitted suite.
                for fd in (queue_fd, legacy_fd):
                    if not try_lock(fd, fcntl.LOCK_SH):
                        say(f"first in queue (ticket {ticket}); waiting for an older exclusive suite")
                        describe_holders(holder)
                        if not lock_while_alive(fd, fcntl.LOCK_SH, owner, poll_s):
                            queue_tickets.event(log, "abandon", ticket, owner_pid=owner_pid)
                            return 1
                fcntl.flock(mutex, fcntl.LOCK_EX)
                try:
                    selection_out.write_text(f"{slot_index}\n")
                    waited = round(time.monotonic() - requested, 3)
                    queue_tickets.event(log, "acquire", ticket, owner_pid=owner_pid,
                                        slot=slot_index, wait_seconds=waited)
                    ticket_path.unlink(missing_ok=True)
                    ticket_path = None
                finally:
                    fcntl.flock(mutex, fcntl.LOCK_UN)
                admitted = True
                return 0
            if not announced:
                say(f"waiting for a suite slot: ticket {ticket}, position {position} of {len(live)}")
                describe_holders(holder)
                announced = True
            elif time.monotonic() - last_notice >= NOTICE_S:
                say(f"still waiting after {int(time.monotonic() - requested)}s, "
                    f"position {position} of {len(live)}")
                describe_holders(holder)
                last_notice = time.monotonic()
            time.sleep(poll_s)
    finally:
        if ticket_path is not None:
            ticket_path.unlink(missing_ok=True)
        if not admitted:
            for fd in (worktree_fd, queue_fd, legacy_fd, *slot_fds):
                fcntl.flock(fd, fcntl.LOCK_UN)
        mutex.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--queue", type=Path, required=True)
    parser.add_argument("--owner-pid", type=int, required=True)
    parser.add_argument("--holder", type=Path, required=True)
    parser.add_argument("--capacity", type=int, required=True)
    parser.add_argument("--selection-out", type=Path, required=True)
    parser.add_argument("--worktree-fd", type=int, required=True)
    parser.add_argument("--queue-fd", type=int, required=True)
    parser.add_argument("--legacy-fd", type=int, required=True)
    parser.add_argument("--slot-fd", type=int, action="append", required=True)
    args = parser.parse_args(argv)
    if not 1 <= args.capacity <= 24:
        parser.error("capacity must be from 1 to 24")
    if args.capacity != len(args.slot_fd):
        parser.error("capacity and slot fd count differ")

    descriptors = [args.worktree_fd, args.queue_fd, args.legacy_fd, *args.slot_fd]
    identities = [(os.fstat(fd).st_dev, os.fstat(fd).st_ino) for fd in descriptors]
    if len(set(identities)) != len(identities):
        parser.error("lock descriptors must name distinct files")

    def interrupted(signum, _frame):
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, signal.SIG_IGN)
        raise KeyboardInterrupt(f"signal {signum}")

    for handled in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(handled, interrupted)
    try:
        return wait(args.queue, args.owner_pid, args.holder, args.capacity,
                    args.selection_out, args.worktree_fd, args.queue_fd,
                    args.legacy_fd, args.slot_fd)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
