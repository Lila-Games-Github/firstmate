"""Firstmate phone reservations, compatible with FrogPile's ticket and lock format.

Named/VIP FIFO precedes any-phone FIFO, without interrupting current holders.
The client owns its ticket, queue flock, legacy flock and renewable device lease;
restarting the service cannot revoke a live direct client's hold or arrival.
fm_test_queues owns configuration, path discovery and the public service CLI.
"""

from __future__ import annotations

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import re
import subprocess
import threading
import time
import uuid

import fm_device_lease as device_lock
import fm_queue_tickets as queue_tickets

ANY = "any"
HELD_ENV = "FM_TEST_PHONE_QUEUE_HELD"
LEASE_RENEW_S = 600
NESTED_LOCK_TIMEOUT_S = 60.0

_adb_cache: tuple[float, dict[str, str]] = (0.0, {})
PROBE_TIMEOUT_S = 5


def phone_states(phones, *, refresh: bool = False) -> dict[str, str]:
    """Bounded host-side classification of every registered phone.

    A successful listing alone is insufficient: get-state must also succeed for
    this user. The result never contains adb diagnostic text or credentials.
    """
    global _adb_cache
    phones = tuple(phones)
    if not refresh and time.monotonic() - _adb_cache[0] < 5 and all(p in _adb_cache[1] for p in phones):
        return {p: _adb_cache[1][p] for p in phones}
    try:
        listing = subprocess.run(["adb", "devices", "-l"], capture_output=True,
                                 text=True, timeout=PROBE_TIMEOUT_S)
        rows = listing.stdout.splitlines()[1:] if listing.returncode == 0 else []
    except (OSError, subprocess.TimeoutExpired):
        rows = []
    listed = {}
    for row in rows:
        fields = row.split()
        if len(fields) >= 2:
            listed[fields[0]] = row.lower()
    result = {}
    for serial in phones:
        row = listed.get(serial, "")
        if "no permissions" in row or "unauthorized" in row:
            result[serial] = "permission-denied"
            continue
        if not row or row.split()[1] != "device":
            result[serial] = "offline"
            continue
        try:
            probe = subprocess.run(["adb", "-s", serial, "get-state"],
                                   capture_output=True, text=True, timeout=PROBE_TIMEOUT_S)
            output = (probe.stdout + probe.stderr).lower()
            if "no permissions" in output or "unauthorized" in output:
                result[serial] = "permission-denied"
            elif probe.returncode == 0 and probe.stdout.strip() == "device":
                result[serial] = "usable"
            else:
                result[serial] = "offline"
        except (OSError, subprocess.TimeoutExpired):
            result[serial] = "offline"
    _adb_cache = (time.monotonic(), result)
    return result


def _unavailable(states: dict[str, str]) -> RuntimeError:
    summary = ", ".join(f"{serial}={state}" for serial, state in states.items())
    return RuntimeError(
        f"phone unavailable on this host ({summary}); for permission-denied check "
        "loginctl seat/uaccess ACL, plugdev membership and USB debugging authorization; "
        "for offline check the cable and replug the phone")


def classify_phones(states: dict[str, str], busy) -> dict[str, str]:
    """Apply queue occupancy to host states without hiding an unusable device."""
    return {serial: ("busy" if state == "usable" and serial in busy else state)
            for serial, state in states.items()}


@contextmanager
def _locked(mutex):
    fcntl.flock(mutex, fcntl.LOCK_EX)
    try:
        yield
    finally:
        fcntl.flock(mutex, fcntl.LOCK_UN)


def _release_lease(pool: Path, label: str) -> list[str]:
    """Release every device-test lease carrying this reservation's unique label."""
    released = []
    if not label or not pool.is_dir():
        return released
    for entry in pool.iterdir():
        try:
            owner = (entry / "label").read_text().strip()
        except OSError:
            continue
        if owner == label and device_lock.release(entry.name, lock_dir=pool, label=label):
            released.append(entry.name)
    return released


def _ancestor_pids() -> list[int]:
    """This process, then each parent up to init."""
    pids, pid = [], os.getpid()
    while pid > 0 and pid not in pids:
        pids.append(pid)
        try:
            fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
            pid = int(fields[1])
        except (OSError, IndexError, ValueError):
            break
    return pids


def _open_descriptors(pid: int) -> set[str]:
    try:
        names = os.listdir(f"/proc/{pid}/fd")
    except OSError:
        return set()
    paths = set()
    for name in names:
        try:
            paths.add(os.path.realpath(f"/proc/{pid}/fd/{name}"))
        except OSError:
            continue
    return paths


def _command_line(pid: int) -> str:
    try:
        argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
    except OSError:
        return "unknown command"
    return " ".join(part.decode(errors="replace") for part in argv if part) or "unknown command"


class _Queue:
    def __init__(self, queue: Path, legacy_root: Path, pool: Path):
        self.queue = queue
        self.tickets = queue / "tickets"
        self.log = queue / "events.jsonl"
        self.legacy_root = legacy_root
        self.pool = pool

    def phone_locks(self, serial: str):
        return ((self.queue / f"{serial}.lock").open("a+"),
                (self.legacy_root / f"frogpile-phone-{serial}.lock").open("a+"))

    def live(self) -> list[tuple[str, dict]]:
        def cleanup(name: str, record: dict) -> None:
            label = record.get("lease_label")
            pool = record.get("lease_pool")
            pool = Path(pool) if isinstance(pool, str) and Path(pool).is_absolute() else self.pool
            released = _release_lease(pool, label)
            queue_tickets.event(self.log, "crash_cleanup", name,
                                serial=record.get("holding") or record.get("requested"),
                                lease_label=label, released=released)
        live = queue_tickets.live(self.tickets, cleanup)
        for name, record in live:
            if not record:
                continue  # An unreadable ticket retains its place during grace.
            serials = [record.get("requested"), record.get("holding")]
            serials += [p for key in ("phones", "online") for p in (record[key] if isinstance(record.get(key), list) else [])]
            if (any(p is not None and (not isinstance(p, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]*", p))
                    for p in serials)
                    or not isinstance(record.get("requested"), str)
                    or (record.get("holding") is not None and not isinstance(record["holding"], str))
                    or any(not isinstance(record[key], list) or not all(isinstance(p, str) for p in record[key])
                           for key in ("phones", "online") if key in record)):
                raise RuntimeError(f"invalid phone ticket: {name}")
        return live

    def free(self, serial: str, held: set) -> bool:
        """True when nothing old or new holds the phone. Probes, then lets go."""
        if serial in held or (self.pool / serial).exists():
            return False
        files = self.phone_locks(serial)
        try:
            for stream in files:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            return False
        finally:
            for stream in files:
                stream.close()

    def nested_holder(self, serial: str) -> tuple[int, str] | None:
        """This run's own ancestor holding a phone lock, as (pid, command).

        The whole session already waits in this queue, so an outer ``flock``
        around the wrapper can only deadlock: it holds the lock we are queued
        for, and we would wait forever on our own parent. Probe the locks and,
        when one is genuinely held, look for an open descriptor on it in this
        process or an ancestor.
        """
        files = self.phone_locks(serial)
        try:
            for stream in files:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return None  # Nothing holds it; this is not a nested lock.
        except BlockingIOError:
            pass
        finally:
            for stream in files:
                stream.close()
        wanted = {os.path.realpath(str(path)) for path in
                  (self.queue / f"{serial}.lock",
                   self.legacy_root / f"frogpile-phone-{serial}.lock")}
        for pid in _ancestor_pids():
            if wanted & _open_descriptors(pid):
                return pid, _command_line(pid)
        return None

    def take(self, serial: str, label: str):
        """All four marks on the phone, or None if anything holds it."""
        files = self.phone_locks(serial)
        try:
            for stream in files:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            device_lock.acquire([serial], lock_dir=self.pool, device=serial, label=label)
        except (BlockingIOError, device_lock.Busy):
            for stream in files:
                stream.close()
            return None
        except BaseException:
            for stream in files:
                stream.close()
            raise
        return files


def _all_candidates_nested(state: _Queue, phones, online) -> tuple[int, str] | None:
    """The ancestor holder when this run's own outer lock owns every candidate."""
    candidates = [phone for phone in phones if phone in online]
    if not candidates:
        return None
    holders = [state.nested_holder(phone) for phone in candidates]
    return None if any(holder is None for holder in holders) else holders[0]


def choose(ticket: str, requested: str, live: list[tuple[str, dict]], phones,
           online, free) -> str | None:
    """The phone this ticket may take now, or None while it must wait."""
    if any(not record.get("requested") for _name, record in live):
        return None  # A recent unreadable ticket retains its place during the grace period.
    waiting = [(name, record) for name, record in live if not record.get("holding")]
    if requested != ANY:
        earlier = any(name < ticket and record.get("requested") == requested
                      for name, record in waiting)
        return None if earlier or requested not in online or not free(requested) else requested
    vip_wanted = {record.get("requested") for _name, record in waiting}
    reserved = set()
    for name, record in waiting:
        if name >= ticket or record.get("requested") != ANY:
            continue
        # Earlier callers can belong to another project with a different set
        # or preference order. Reserve what that caller can actually use.
        choice = next((phone for phone in record.get("phones", phones)
                       if phone in record.get("online", online)
                       and phone not in vip_wanted and phone not in reserved and free(phone)), None)
        if choice is not None:
            reserved.add(choice)
    return next((phone for phone in phones if phone in online and phone not in vip_wanted
                 and phone not in reserved and free(phone)), None)



@contextmanager
def reservation(serial: str | None = None, *, root: Path | None = None,
                legacy_root: Path, device_lock_dir: Path,
                wait_seconds: float = 1.0, phones=(), connected=None,
                nested_timeout: float = NESTED_LOCK_TIMEOUT_S, lock_fds=None):
    """Hold one ticket, then one phone, for the whole session; yields the phone serial.

    ``serial`` names a phone (a VIP ticket); ``None`` or ``"any"`` requests any phone.
    """
    requested = ANY if serial in (None, "", ANY) else serial
    if not isinstance(requested, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]*", requested):
        raise ValueError("invalid device serial")
    previous = os.environ.get(HELD_ENV) or os.environ.get("FROGPILE_PHONE_QUEUE_HELD")
    if previous:
        raise RuntimeError(f"nested phone reservation for {requested} while holding {previous}")
    if root is None:
        raise ValueError("phone queue root is required")
    state = _Queue(root, legacy_root, device_lock_dir)
    state.tickets.mkdir(parents=True, exist_ok=True)
    legacy_root.mkdir(parents=True, exist_ok=True)
    mutex = (state.queue / "queue.lock").open("a+")
    lease_label = f"firstmate-test-{os.getpid()}-{uuid.uuid4().hex}"
    record = {**queue_tickets.identity(), "requested": requested,
              "requested_unix_ns": time.time_ns(), "lease_label": lease_label,
              "lease_pool": str(state.pool.resolve()), "phones": list(phones)}
    ticket = ticket_path = None
    holding = None
    files = ()
    stop_renew = threading.Event()
    requested_at = time.monotonic()
    acquired_at = 0.0
    old_held = os.environ.get("FROGPILE_PHONE_QUEUE_HELD")
    try:
        candidates = phones if requested == ANY else (requested,)
        states = (phone_states(candidates, refresh=True) if connected is None else
                  {p: "usable" if p in connected() else "offline" for p in candidates})
        if not any(state == "usable" for state in states.values()):
            raise _unavailable(states)
        record["online"] = [p for p, status in states.items() if status == "usable"]
        with _locked(mutex):
            ticket = queue_tickets.next_name(state.queue)
            ticket_path = state.tickets / f"{ticket}.json"
            queue_tickets.write(ticket_path, record)
            queue_tickets.event(state.log, "request", ticket, serial=requested,
                                requested=requested)
        last_notice = 0.0
        nested_since = None
        while holding is None:
            # adb can be slow; ask it before taking the queue mutex.
            states = (phone_states(candidates) if connected is None else
                      {p: "usable" if p in connected() else "offline" for p in candidates})
            online = frozenset(p for p, condition in states.items() if condition == "usable")
            if not online:
                raise _unavailable(states)
            with _locked(mutex):
                record["online"] = sorted(online)
                queue_tickets.write(ticket_path, record)
                live = state.live()
                held = {entry.get("holding") for _name, entry in live}
                device_lock.reap(state.pool)
                conditions = classify_phones(states, {p for p in candidates
                                                    if states[p] == "usable" and
                                                    not state.free(p, held)})
                choice = choose(ticket, requested, live, phones, online,
                                lambda phone: state.free(phone, held))
                if choice is not None and choice not in held:
                    files = state.take(choice, lease_label) or ()
                    if files:
                        holding = choice
                        acquired_at = time.monotonic()
                        record.update(holding=holding, acquired_unix_ns=time.time_ns())
                        queue_tickets.write(ticket_path, record)
                        queue_tickets.event(state.log, "acquire", ticket, serial=holding,
                                            requested=requested,
                                            wait_seconds=round(acquired_at - requested_at, 3))
            if holding is None:
                nested = (state.nested_holder(requested) if requested != ANY
                          else _all_candidates_nested(state, phones, online))
                if nested is None:
                    nested_since = None
                else:
                    pid, where = nested
                    if nested_since is None:
                        nested_since = time.monotonic()
                        print(f"[phone_queue] {requested} is locked by this run's own ancestor "
                              f"pid {pid} ({where}); an outer flock cannot be waited out and "
                              f"is refused after {nested_timeout:g}s", flush=True)
                    elif time.monotonic() - nested_since >= nested_timeout:
                        raise RuntimeError(
                            f"nested phone lock: this run already holds {requested} through "
                            f"ancestor pid {pid} ({where}); an outer flock must not wrap the "
                            f"phone wrapper - run it directly")
                if time.monotonic() - last_notice >= 30:
                    order = [f"{name}:{entry.get('holding') or 'waiting ' + str(entry.get('requested'))}"
                             for name, entry in live]
                    print(f"[phone_queue] waiting for {requested}, ticket {ticket}; "
                          f"phones {conditions}; queue {order}",
                          flush=True)
                    last_notice = time.monotonic()
                time.sleep(wait_seconds)

        # Locks cannot prove transport. Confirm again before handing a phone to
        # the caller, including a ticket that waited through a disconnect.
        states = (phone_states((holding,), refresh=True) if connected is None else
                  {holding: "usable" if holding in connected() else "offline"})
        if states[holding] != "usable":
            raise _unavailable(states)

        def renew() -> None:
            while not stop_renew.wait(LEASE_RENEW_S):
                device_lock.renew(holding, lock_dir=state.pool, label=lease_label)
        threading.Thread(target=renew, daemon=True).start()
        if lock_fds is not None:
            lock_fds.extend(stream.fileno() for stream in files)
        os.environ["FROGPILE_PHONE_QUEUE_HELD"] = holding
        os.environ[HELD_ENV] = holding
        yield holding
    finally:
        stop_renew.set()
        try:
            with _locked(mutex):
                if holding is not None:
                    queue_tickets.event(state.log, "release", ticket, serial=holding,
                                        requested=requested,
                                        held_seconds=round(time.monotonic() - acquired_at, 3))
                # A signal can land between claiming a lease and recording the
                # hold; the unique label finds it either way.
                _release_lease(state.pool, lease_label)
                for stream in files:
                    stream.close()
                if ticket_path is not None:
                    ticket_path.unlink(missing_ok=True)
        finally:
            mutex.close()
            if old_held is None:
                os.environ.pop("FROGPILE_PHONE_QUEUE_HELD", None)
            else:
                os.environ["FROGPILE_PHONE_QUEUE_HELD"] = old_held
            if previous is None:
                os.environ.pop(HELD_ENV, None)
            else:
                os.environ[HELD_ENV] = previous
