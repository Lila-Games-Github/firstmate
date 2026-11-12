#!/usr/bin/env python3
"""fm-farm-results.py - deliver finished test-farm results to their tasks, and
record which tasks are waiting on an open farm request.

Usage: fm-farm-results.py sweep [--force]

bin/fm-watch.sh runs `sweep` from its poll once the stamp below is due; the
sweep does real work at most once per FM_FARM_RESULTS_SECS (default 30, valid
5..600) per home, tracked by the epoch in state/.last-farm-results-sweep, and
--force skips that cadence. One sweep
reads `testfarm status --json --no-probe` once (FM_TESTFARM_BIN, default
testfarm; bounded by FM_TESTFARM_TIMEOUT, default 10 seconds, valid 1..60), the
same request store bin/fm-landing-queue.sh resolve reads, and only requests
whose task label names a state/<task>.meta in this home count. A request whose
options name a different submitting home is never touched.

Open requests. Every request still preparing, queued, or running is written to
state/.farm-open-requests, replaced atomically on each successful read: a
`fm-farm-open.v1` line, then one `<task> <request-id> <state>` line per open
request. The watcher's stale check (bin/fm-watch.sh) and the Playbot lane
monitor (bin/fm-playbot-lanes.mjs supervision-poll) treat an idle task listed
there as waiting by design and stay quiet until its request finishes. They
trust the file only while its mtime is at most FM_FARM_OPEN_MAX_AGE seconds old
(default 300), so a farm that stops answering, or a watcher that stops
sweeping, returns every task to the ordinary alarms.

Finished results. Every passed, failed, or cancelled request is delivered to
its task unless the task already has it, whatever delivery hook the request
carried. The body is byte-identical to the farm's own completion message
(compat/firstmate-notify via testfarm's queue_notification) and goes through
bin/fm-send.sh with FM_SEND_IDEMPOTENT=1, so a hook delivery and a sweep
delivery of the same result collapse into one record: the inbox plane and
bin/fm-lane-send.sh both drop an exact repeat. A task already has a result when
any record in state/<task>.inbox/ (pending or handled/) or state/<task>.lane-sent/
names `request=<id> `, or when this sweep's own ledger of settled requests
(state/.farm-results-delivered) lists it, so a body that differs from the
hook's - a receipt moved after completion - is still never sent twice.
A result the task has moved past is settled without being sent: when the task
already holds the result of a request submitted after this one finished, the
worker acted on later work, so a late copy would only mislead it. Requests
running side by side are both delivered, because neither was submitted after
the other finished.
A request that carried a hook is left to that hook for FM_FARM_RESULTS_GRACE
seconds after it finished (default 120); one without a hook is delivered on the
first sweep that sees it. Only results finished after this home's first sweep
(state/.farm-results-baseline) and within FM_FARM_RESULTS_MAX_AGE seconds
(default 86400) are delivered, so enabling the sweep never replays history.
A failed send is retried on every later sweep; its first failure prints one
`farm-result undelivered task=<id> request=<id>: <reason>` line, recorded in
state/.farm-results-failed, and the watcher turns any output into one
`check: farm-results` wake. Prints nothing otherwise.

Environment: FM_HOME (required), FM_STATE_OVERRIDE, FM_TEST_SERVICE_STATE
(the farm's state directory, default ~/.local/state/firstmate-test-service,
read only to name a passed request's receipt exactly as the farm does), and
FM_SEND_BIN to replace bin/fm-send.sh (tests only). Exits nonzero with one
error line only when the sweep itself cannot run; an unreadable farm is
silent and leaves the previous open-request file to age out.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

TASK_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
RID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
OPEN = ("preparing", "queued", "running")
FINISHED = ("passed", "failed", "cancelled")


def bounded(name, default, low, high):
    raw = os.environ.get(name, "")
    if not raw.isdigit():
        return default
    value = int(raw)
    return value if low <= value <= high else default


def atomic_write(path, text):
    fd, tmp = tempfile.mkstemp(prefix="." + path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_lines(path):
    try:
        return [line for line in path.read_text().splitlines() if line]
    except OSError:
        return []


def farm_requests():
    """The farm's request rows, or None when the farm cannot be read."""
    # An invalid bound counts as an unreadable farm, as it does for the landing sweep.
    raw = os.environ.get("FM_TESTFARM_TIMEOUT", "10")
    if not raw.isdigit() or not 1 <= int(raw) <= 60:
        return None
    timeout = int(raw)
    try:
        done = subprocess.run([os.environ.get("FM_TESTFARM_BIN", "testfarm"), "status", "--json", "--no-probe"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode:
        return None
    try:
        rows = json.loads(done.stdout).get("requests")
    except (ValueError, AttributeError):
        return None
    return rows if isinstance(rows, list) else None


def submitted_at(row):
    value = row.get("submitted")
    return value if isinstance(value, (int, float)) else 0


def completion_message(row, farm_state):
    """The farm's frozen completion body for one finished request (testfarm queue_notification)."""
    opts = row.get("options") or {}
    receipt = farm_state / "results" / row["id"] / (row["sha"] + ".receipt")
    if not (row["state"] == "passed" and receipt.is_file()):
        receipt = "-"
    elif opts.get("receipt") and row["sha"] == row.get("original_sha"):
        receipt = opts["receipt"]
    failure = ((row.get("error") or "-").splitlines() or [""])[0]
    return (f"Test service completion: request={row['id']} state={row['state']} "
            f"sha={row['sha']} receipt={receipt}\nfirst_failure={failure}\n"
            "Resume this request's work using this result; do not resubmit or poll it.")


def task_holds(state, task, rid):
    """True when the task's inbox or lane chat record already carries this request's result."""
    needle = f"request={rid} ".encode()
    folders = [state / f"{task}.inbox", state / f"{task}.inbox" / "handled", state / f"{task}.lane-sent"]
    for folder in folders:
        try:
            entries = list(folder.iterdir())
        except OSError:
            continue
        for entry in entries:
            if entry.name.startswith(".") or not entry.is_file() or entry.is_symlink():
                continue
            if folder.name != f"{task}.lane-sent" and not entry.name.endswith(".msg"):
                continue
            try:
                if needle in entry.read_bytes():
                    return True
            except OSError:
                continue
    return False


def sweep(force):
    home = os.environ.get("FM_HOME")
    if not home:
        sys.exit("error: FM_HOME must explicitly select the owning home")
    state = Path(os.environ.get("FM_STATE_OVERRIDE") or os.path.join(home, "state"))
    if not state.is_dir() or state.is_symlink():
        return 0
    now = time.time()
    stamp = state / ".last-farm-results-sweep"
    if not force and stamp.is_file() and not stamp.is_symlink():
        lines = read_lines(stamp)
        last = int(lines[0]) if lines and lines[0].isdigit() else 0
        if last <= now and now - last < bounded("FM_FARM_RESULTS_SECS", 30, 5, 600):
            return 0
    try:
        atomic_write(stamp, f"{int(now)}\n")
    except OSError:
        sys.exit(f"error: cannot record the sweep stamp {stamp}")

    rows = farm_requests()
    if rows is None:
        return 0
    home_real = os.path.realpath(home)
    mine = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        opts = row.get("options") if isinstance(row.get("options"), dict) else {}
        task = opts.get("task") or ""
        rid = row.get("id") or ""
        if not (isinstance(task, str) and TASK_RE.fullmatch(task) and isinstance(rid, str) and RID_RE.fullmatch(rid)):
            continue
        if opts.get("home") and os.path.realpath(str(opts["home"])) != home_real:
            continue
        if not (state / f"{task}.meta").is_file():
            continue
        mine.append((task, rid, row, opts))

    atomic_write(state / ".farm-open-requests", "fm-farm-open.v1\n" + "".join(
        f"{task} {rid} {row.get('state')}\n" for task, rid, row, _ in mine if row.get("state") in OPEN))

    baseline_file = state / ".farm-results-baseline"
    lines = read_lines(baseline_file)
    if lines and lines[0].isdigit():
        baseline = int(lines[0])
    else:
        baseline = int(now)
        atomic_write(baseline_file, f"{baseline}\n")
    grace = bounded("FM_FARM_RESULTS_GRACE", 120, 0, 3600)
    max_age = bounded("FM_FARM_RESULTS_MAX_AGE", 86400, 600, 30 * 86400)
    farm_state = Path(os.environ.get("FM_TEST_SERVICE_STATE")
                      or Path.home() / ".local/state/firstmate-test-service")
    ledger_file = state / ".farm-results-delivered"
    failed_file = state / ".farm-results-failed"
    delivered = set(read_lines(ledger_file))
    failed = set(read_lines(failed_file))
    send = os.environ.get("FM_SEND_BIN") or str(Path(__file__).resolve().parent / "fm-send.sh")
    out = []
    # First settle what each task already holds, so a result the task has moved
    # past is never delivered late (see the header's superseded rule).
    held, pending = {}, []
    for task, rid, row, opts in mine:
        finished = row.get("finished")
        if row.get("state") not in FINISHED or not isinstance(finished, (int, float)) or not isinstance(row.get("sha"), str):
            continue
        submitted = submitted_at(row)
        if rid in delivered:
            held.setdefault(task, []).append(submitted)
        elif finished >= baseline and now - finished <= max_age:
            if task_holds(state, task, rid):
                delivered.add(rid)
                held.setdefault(task, []).append(submitted)
            else:
                pending.append((task, rid, row, opts, finished))
    # Newest first, so a result delivered now settles any older one it supersedes.
    pending.sort(key=lambda item: submitted_at(item[2]), reverse=True)
    for task, rid, row, opts, finished in pending:
        if (opts.get("notify") or opts.get("home")) and now - finished < grace:
            continue
        if any(submitted > finished for submitted in held.get(task, [])):
            delivered.add(rid)
            continue
        env = dict(os.environ, FM_HOME=home, FM_STATE_OVERRIDE=str(state), FM_SEND_IDEMPOTENT="1")
        try:
            sent = subprocess.run([send, task, completion_message(row, farm_state)], env=env,
                                  stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                  text=True, timeout=60, check=False)
            reason = (sent.stderr.strip().splitlines() or [f"fm-send exited {sent.returncode}"])[-1] if sent.returncode else ""
        except (OSError, subprocess.TimeoutExpired) as exc:
            reason = str(exc) or type(exc).__name__
        if not reason:
            delivered.add(rid)
            failed.discard(rid)
            held.setdefault(task, []).append(submitted_at(row))
        elif rid not in failed:
            failed.add(rid)
            out.append(f"farm-result undelivered task={task} request={rid}: {reason}")

    # Forget ids the farm no longer lists, so both ledgers stay bounded by its retention.
    listed = {row.get("id") for row in rows if isinstance(row, dict)}
    atomic_write(ledger_file, "".join(f"{rid}\n" for rid in sorted(delivered & listed)))
    atomic_write(failed_file, "".join(f"{rid}\n" for rid in sorted(failed & listed)))
    for line in out:
        print(line)
    return 0


def main(argv):
    if argv[:1] in (["-h"], ["--help"]):
        print(__doc__.strip())
        return 0
    if not argv or argv[0] != "sweep" or argv[1:] not in ([], ["--force"]):
        print("usage: fm-farm-results.py sweep [--force]", file=sys.stderr)
        return 2
    return sweep(argv[1:] == ["--force"])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
