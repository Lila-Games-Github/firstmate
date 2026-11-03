"""Public client API and CLI for the test service's host-wide admission queues.

Usage: fm-test-service.py queue phone --project PROJECT [--serial SERIAL|any]
         [--prepare] -- COMMAND...
       fm-test-service.py queue suite [--capacity N] [--worktree-lock PATH] -- COMMAND...
       fm-test-service.py queue suite-acquire <inherited-descriptor arguments>
       fm-test-service.py queue paths [--project PROJECT]
       fm-test-service.py queue client-path

Phone commands replace {serial} in each argument with the admitted serial and
export FM_TEST_PHONE_QUEUE_HELD (also the legacy FROGPILE_PHONE_QUEUE_HELD).
--prepare wakes/unlocks the admitted phone using the service's normal policy.
Python callers import this module and use reservation(serial, project=PROJECT)
at their existing acquisition boundary, after building/exporting their app.
No running daemon is required: the client owns every hold and waiting ticket.

Path precedence: FM_TEST_QUEUE_ROOT, isolated FM_TEST_SERVICE_STATE/queues,
FROGPILE_QUEUE_ROOT, ~/.frogpile-queues (the compatible host-wide default).
FM_TEST_QUEUE_LEGACY_ROOT overrides the legacy flock directory; it defaults to
the isolated queue's legacy/ when FM_TEST_SERVICE_STATE is set, else /tmp.
FROGPILE_SUITE_QUEUE and FROGPILE_SUITE_LOCK retain their old meanings outside
isolated instances. Explicit queue/legacy roots work for isolated migration tests.
The normal installed service state path retains the host-wide default queue.
FM_TEST_SUITE_CAPACITY selects the global capacity (default 4, range 1..24).
All suite callers must agree; an existing capacity file is never resized.
The project queue_mode is client by default for compatibility with existing
wrappers, or service for commands which do not already acquire a reservation.
queue_lease_dir optionally selects a project's existing device-test lease pool.
"""
from contextlib import contextmanager
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading

import fm_phone_queue
import fm_queue_tickets
import fm_suite_queue


CODE = Path(__file__).resolve().parent / "fm-test-service.py"


def configuration(project=None):
    project = project or os.environ.get("FM_TEST_PROJECT")
    if not project or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", project):
        raise ValueError("phone queue requires --project or FM_TEST_PROJECT")
    home = Path(os.environ.get("FM_HOME", CODE.parent.parent)).resolve()
    root = Path(os.environ.get("FM_TEST_SERVICE_CONFIG_ROOT", home / "config/test-service"))
    cfg = json.loads((root / (project + ".json")).read_text())
    validate(cfg)
    return project, cfg


def validate(cfg):
    if cfg.get("queue_mode", "client") not in ("client", "service"):
        raise ValueError("queue_mode must be client or service")
    phones = cfg.get("phones")
    if not isinstance(phones, list) or not phones or any(
        not isinstance(p, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]*", p)
        or p == "any" for p in phones
    ) or len(phones) != len(set(phones)):
        raise ValueError("phones must contain distinct safe device serials")
    any_phones = cfg.get("any_phones", phones)
    if not isinstance(any_phones, list) or any(p not in phones for p in any_phones):
        raise ValueError("any_phones must contain configured phones")
    equivalents = cfg.get("equivalent_phones", {})
    if not isinstance(equivalents, dict) or any(
        phone not in phones or not isinstance(peers, list)
        or any(peer not in phones or peer == phone for peer in peers)
        for phone, peers in equivalents.items()
    ):
        raise ValueError("equivalent_phones must map configured phones to configured alternatives")
    lease = cfg.get("queue_lease_dir")
    if lease is not None and (not isinstance(lease, str) or not Path(lease).is_absolute()):
        raise ValueError("queue_lease_dir must be an absolute path")


def paths(cfg=None):
    selected_state = os.environ.get("FM_TEST_SERVICE_STATE")
    default_state = Path.home() / ".local/state/firstmate-test-service"
    isolated = selected_state if selected_state and Path(selected_state).resolve() != default_state.resolve() else None
    root = Path(os.environ.get("FM_TEST_QUEUE_ROOT") or
                (str(Path(isolated) / "queues") if isolated else
                 os.environ.get("FROGPILE_QUEUE_ROOT", str(Path.home() / ".frogpile-queues")))).resolve()
    legacy = Path(os.environ.get("FM_TEST_QUEUE_LEGACY_ROOT") or
                  (str(root / "legacy") if isolated else "/tmp")).resolve()
    suite = root / "suite"
    suite_lock = legacy / "frogpile-suite.lock"
    if not isolated:
        if os.environ.get("FROGPILE_SUITE_LOCK"):
            suite_lock = Path(os.environ["FROGPILE_SUITE_LOCK"]).resolve()
            suite = Path(str(suite_lock) + ".queue")
        if os.environ.get("FROGPILE_SUITE_QUEUE"):
            suite = Path(os.environ["FROGPILE_SUITE_QUEUE"]).resolve()
    # Never follow a production project's configured pool from an isolated instance.
    pool = root / "device-test-locks"
    if cfg and cfg.get("queue_lease_dir") and not isolated:
        pool = Path(cfg["queue_lease_dir"])
    return {"root": root, "phones": root / "phones", "suite": suite,
            "legacy": legacy, "suite_lock": suite_lock, "lease_pool": pool}


def environment(project, cfg):
    locations = paths(cfg)
    return {**os.environ, "FM_TEST_SERVICE": str(CODE), "FM_TEST_PROJECT": project,
            "FM_TEST_QUEUE_ROOT": str(locations["root"]),
            "FM_TEST_QUEUE_LEGACY_ROOT": str(locations["legacy"]),
            "FROGPILE_QUEUE_ROOT": str(locations["root"]),
            "FROGPILE_SUITE_QUEUE": str(locations["suite"]),
            "FROGPILE_SUITE_LOCK": str(locations["suite_lock"])}


def phone_busy(serial, cfg=None):
    locations = paths(cfg)
    files = [locations["phones"] / (serial + ".lock"),
             locations["legacy"] / ("frogpile-phone-" + serial + ".lock")]
    import fcntl
    streams = []
    try:
        for path in files:
            if not path.parent.is_dir():
                continue
            stream = path.open("a+")
            streams.append(stream)
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return (locations["lease_pool"] / serial).exists()
    except BlockingIOError:
        return True
    finally:
        for stream in streams:
            stream.close()


@contextmanager
def reservation(serial=None, *, project=None, equivalents=False, **options):
    """Reserve at the phone-use boundary; caller retains its normal build phase.

    Project configuration supplies the ordered any-phone candidates; the lower
    level fm_phone_queue.reservation API also allows explicit private paths and
    injected transport for behavioral tests.
    """
    _project, cfg = configuration(project)
    if serial not in (None, "", "any", *cfg["phones"]):
        raise ValueError("phone is not configured for this project")
    if equivalents and serial not in (None, "", "any"):
        candidates = [serial, *cfg.get("equivalent_phones", {}).get(serial, [])]
        usable = [p for p, state in fm_phone_queue.phone_states(candidates, refresh=True).items()
                  if state == "usable"]
        if usable:
            serial = next((p for p in usable if not phone_busy(p, cfg)), usable[0])
    locations = paths(cfg)
    defaults = {"root": locations["phones"], "legacy_root": locations["legacy"],
                "device_lock_dir": locations["lease_pool"],
                "phones": cfg.get("any_phones", cfg["phones"])}
    defaults.update(options)
    with fm_phone_queue.reservation(serial, **defaults) as phone:
        yield phone


def command(argv, *, serial=None, keep_fds=()):
    """Run a synchronous child, retaining lock descriptors across exec.

    On cancellation ignore repeated signals in the client, stop descendants,
    escalate after three seconds, then reap before releasing descriptors.
    """
    if serial:
        argv = [part.replace("{serial}", serial) for part in argv]
    child = None
    cancelled = threading.Event()
    forwarded = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)
    previous = {sig: signal.getsignal(sig) for sig in forwarded}
    observed = {}

    def signal_tree(signum):
        if child is None:
            return
        # The child stays in the caller's group, so an external group stop also
        # reaches it if this client is killed. Direct-client cancellation walks
        # descendants instead of signalling the interactive caller's own group.
        parents = {}
        for path in Path("/proc").glob("[0-9]*/stat"):
            try:
                fields = path.read_text().rpartition(")")[2].split()
                parents[int(path.parent.name)] = int(fields[1])
            except (OSError, IndexError, ValueError):
                continue
        descendants = [child.pid]
        for pid in descendants:
            descendants.extend(p for p, parent in parents.items() if parent == pid and p not in descendants)
        for pid in descendants:
            ticks = fm_queue_tickets.start_ticks(pid)
            if ticks is not None:
                observed[pid] = ticks
        for pid, ticks in reversed(list(observed.items())):
            try:
                if fm_queue_tickets.start_ticks(pid) == ticks:
                    os.kill(pid, signum)
            except ProcessLookupError:
                pass

    def stop(signum, _frame):
        for sig in forwarded:
            signal.signal(sig, signal.SIG_IGN)
        cancelled.set()
        signal_tree(signum)

    for sig in forwarded:
        signal.signal(sig, stop)
    try:
        child = subprocess.Popen(argv, pass_fds=tuple(keep_fds))
        if cancelled.is_set():
            signal_tree(signal.SIGTERM)
    except BaseException:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        raise
    try:
        while True:
            try:
                status = child.wait(timeout=.1)
                break
            except subprocess.TimeoutExpired:
                if cancelled.is_set():
                    try:
                        status = child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        signal_tree(signal.SIGKILL)
                        status = child.wait()
                    break
        # A wrapper can exit before descendants. A cancelled group must lose
        # those descendants before the resource becomes available to a waiter.
        if cancelled.is_set():
            try:
                signal_tree(signal.SIGKILL)
            except ProcessLookupError:
                pass
        return 128 - status if status < 0 else status
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


@contextmanager
def suite_reservation(capacity, worktree_lock=None, lock_fds=None):
    locations = paths()
    queue = locations["suite"]
    slots = queue / "slots"
    slots.mkdir(parents=True, exist_ok=True)
    locations["suite_lock"].parent.mkdir(parents=True, exist_ok=True)
    if worktree_lock is None:
        key = hashlib.sha256(str(Path.cwd().resolve()).encode()).hexdigest()
        worktree_lock = queue / "worktrees" / (key + ".lock")
    worktree_lock.parent.mkdir(parents=True, exist_ok=True)
    lock_paths = [worktree_lock, queue / "suite.lock", locations["suite_lock"],
                  *(slots / f"slot-{i}.lock" for i in range(capacity))]
    streams = []
    try:
        for path in lock_paths:
            streams.append(path.open("a+"))
        with tempfile.TemporaryDirectory(prefix="selection-", dir=queue) as temporary:
            selection = Path(temporary) / "slot"
            args = ["--queue", str(queue), "--owner-pid", str(os.getpid()),
                    "--holder", str(queue / "holders"), "--capacity", str(capacity),
                    "--selection-out", str(selection),
                    "--worktree-fd", str(streams[0].fileno()),
                    "--queue-fd", str(streams[1].fileno()),
                    "--legacy-fd", str(streams[2].fileno())]
            for stream in streams[3:]:
                args += ["--slot-fd", str(stream.fileno())]
            status = fm_suite_queue.main(args)
            if status:
                raise RuntimeError("suite admission failed")
            if lock_fds is not None:
                lock_fds.extend(stream.fileno() for stream in streams)
            yield int(selection.read_text().strip())
    finally:
        for stream in streams:
            stream.close()


def main(argv=None, prepare_phone=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["suite-acquire"]:
        return fm_suite_queue.main(argv[1:])
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="kind", required=True)
    phone = sub.add_parser("phone")
    phone.add_argument("--project")
    phone.add_argument("--serial", default="any")
    phone.add_argument("--prepare", action="store_true")
    phone.add_argument("--equivalents", action="store_true", help="allow configured alternatives for named requests")
    phone.add_argument("command", nargs=argparse.REMAINDER)
    suite = sub.add_parser("suite")
    suite.add_argument("--capacity", type=int, default=int(os.environ.get("FM_TEST_SUITE_CAPACITY", "4")))
    suite.add_argument("--worktree-lock", type=Path)
    suite.add_argument("command", nargs=argparse.REMAINDER)
    sub.add_parser("paths").add_argument("--project")
    sub.add_parser("client-path")
    sub.add_parser("suite-acquire", help="admit inherited shell descriptors")
    args = parser.parse_args(argv)
    if args.kind == "client-path":
        print(Path(__file__).resolve())
        return 0
    if args.kind == "paths":
        cfg = configuration(args.project)[1] if args.project else None
        print(json.dumps({key: str(value) for key, value in paths(cfg).items()}, sort_keys=True))
        return 0
    cmd = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not cmd:
        parser.error("a command is required after --")
    if args.kind == "suite" and not 1 <= args.capacity <= 24:
        parser.error("capacity must be from 1 to 24")

    def interrupted(signum, _frame):
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, signal.SIG_IGN)
        raise KeyboardInterrupt(f"signal {signum}")

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, interrupted)
    try:
        lock_fds = []
        if args.kind == "phone":
            with reservation(args.serial, project=args.project, equivalents=args.equivalents, lock_fds=lock_fds) as serial:
                if args.prepare:
                    if prepare_phone is None:
                        raise ValueError("--prepare requires the test-service CLI")
                    prepare_phone(serial)
                return command(cmd, serial=serial, keep_fds=lock_fds)
        with suite_reservation(args.capacity, args.worktree_lock, lock_fds=lock_fds):
            return command(cmd, keep_fds=lock_fds)
    except KeyboardInterrupt:
        return 130
