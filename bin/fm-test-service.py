#!/usr/bin/env python3
"""Firstmate test service: durable CLI and user-service worker.

Usage: fm-test-service.py submit PROJECT WORKTREE SHA [--suite] [--device-gate SERIAL|any]
       [--scenario NAME]... [--harness PATH]... [--receipt PATH] [--retest-on-move]
       fm-test-service.py serve | status [--json] | wait ID | cancel ID
       fm-test-service.py install-unit
Configuration: FM_HOME/config/test-service/PROJECT.json (see docs/test-service.md).
State: FM_TEST_SERVICE_STATE or ~/.local/state/firstmate-test-service.
"""
import argparse
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import uuid

CODE = Path(__file__).resolve()
HOME = Path(os.environ.get("FM_HOME", CODE.parent.parent)).resolve()
ROOT = Path(os.environ.get("FM_TEST_SERVICE_STATE", Path.home() / ".local/state/firstmate-test-service")).resolve()
DB = ROOT / "requests.sqlite3"
STATUS = ROOT / "status.json"
TERMINAL = {"passed", "failed", "cancelled", "conflict"}
STOP = False


def run(argv, **kw):
    return subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)


def config(project):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", project):
        raise ValueError("invalid project name")
    path = HOME / "config/test-service" / (project + ".json")
    data = json.loads(path.read_text())
    if not isinstance(data.get("suite"), list) or not isinstance(data.get("device"), list):
        raise ValueError("configuration needs suite and device argv arrays")
    if not isinstance(data.get("phones", []), list) or not isinstance(data.get("landing_branch"), str):
        raise ValueError("configuration needs phones and landing_branch")
    if "any_device" in data and (not isinstance(data["any_device"], list) or not isinstance(data.get("any_phones"), list)):
        raise ValueError("any_device requires any_phones and argv arrays")
    if "landing_repo" in data:
        data["landing_repo"] = data["landing_repo"].replace("{fm_home}", str(HOME))
    for name in ("suite", "device", "any_device"):
        if name in data and (not data[name] or Path(data[name][0]).is_absolute() or ".." in Path(data[name][0]).parts):
            raise ValueError(name + " executable must be relative to the tested checkout")
    return data


def connection():
    ROOT.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(DB, timeout=30, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=30000")
    db.execute("""CREATE TABLE IF NOT EXISTS requests (
        id TEXT PRIMARY KEY, seq INTEGER UNIQUE NOT NULL, project TEXT NOT NULL,
        source TEXT NOT NULL, original_sha TEXT NOT NULL, sha TEXT NOT NULL,
        options TEXT NOT NULL, state TEXT NOT NULL, submitted REAL NOT NULL, queued_at REAL,
        started REAL, finished REAL, generation INTEGER NOT NULL DEFAULT 0,
        branch_tip TEXT, error TEXT, cancel_requested INTEGER NOT NULL DEFAULT 0
    )""")
    if "queued_at" not in {row[1] for row in db.execute("PRAGMA table_info(requests)")}:
        db.execute("ALTER TABLE requests ADD COLUMN queued_at REAL")
    db.execute("UPDATE requests SET queued_at=submitted WHERE queued_at IS NULL")
    db.execute("""CREATE TABLE IF NOT EXISTS steps (
        request_id TEXT NOT NULL, generation INTEGER NOT NULL, name TEXT NOT NULL,
        state TEXT NOT NULL, started REAL, finished REAL, exit_code INTEGER,
        PRIMARY KEY (request_id, generation, name)
    )""")
    return db


def atomic_write(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    try:
        tmp.write_text(content)
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def snapshot(db):
    with (ROOT / "status.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = [dict(r) for r in db.execute("SELECT * FROM requests ORDER BY queued_at,seq")]
        now = time.time()
        for r in rows:
            r["options"] = json.loads(r["options"])
            r["wait_seconds"] = max(0, (r["started"] or now) - r["queued_at"])
            r["run_seconds"] = max(0, (r["finished"] or now) - r["started"]) if r["started"] else 0
            r["steps"] = [dict(step) for step in db.execute("SELECT name,state,started,finished,exit_code FROM steps WHERE request_id=? AND generation=? ORDER BY started,name", (r["id"], r["generation"]))]
        data = {"schema": "fm-test-service.v1", "updated": now,
                "queue": [r["id"] for r in rows if r["state"] in ("preparing", "queued")],
                "running": next((r["id"] for r in rows if r["state"] == "running"), None),
                "requests": rows}
        atomic_write(STATUS, json.dumps(data, indent=2) + "\n")
        return data


def step_state(db, rid, generation, name, state, exit_code=None):
    now = time.time()
    if state == "running":
        db.execute("INSERT INTO steps (request_id,generation,name,state,started) VALUES (?,?,?,?,?) ON CONFLICT(request_id,generation,name) DO UPDATE SET state=excluded.state,started=excluded.started,finished=NULL,exit_code=NULL", (rid, generation, name, state, now))
    else:
        db.execute("UPDATE steps SET state=?,finished=?,exit_code=? WHERE request_id=? AND generation=? AND name=?", (state, now, exit_code, rid, generation, name))
    snapshot(db)


def submit(args):
    cfg = config(args.project)
    if not (args.suite or args.device_gate or args.harness):
        raise ValueError("request has no suite, phone, or harness step")
    if args.receipt and not args.suite:
        raise ValueError("a full-suite receipt requires --suite")
    if args.scenario and not args.device_gate:
        raise ValueError("scenarios require --device-gate")
    source = Path(args.worktree).resolve()
    top = run(["git", "-C", str(source), "rev-parse", "--show-toplevel"])
    if top.returncode or Path(top.stdout.strip()).resolve() != source:
        raise ValueError("worktree must be a git top-level directory")
    if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", args.sha):
        raise ValueError("sha must be a full commit SHA")
    check = run(["git", "-C", str(source), "rev-parse", "--verify", args.sha + "^{commit}"])
    if check.returncode or check.stdout.strip().lower() != args.sha.lower():
        raise ValueError("sha is not an available exact commit")
    if args.device_gate and args.device_gate != "any" and args.device_gate not in cfg["phones"]:
        raise ValueError("phone is not configured for this project")
    for name in args.scenario:
        if name not in cfg.get("scenarios", {}):
            raise ValueError("unknown scenario: " + name)
    for path in args.harness:
        if Path(path).is_absolute() or ".." in Path(path).parts:
            raise ValueError("harness must be a relative path in the tested commit")
        if not run(["git", "-C", str(source), "cat-file", "-e", args.sha + ":" + path]).returncode == 0:
            raise ValueError("harness is not committed in the tested SHA: " + path)
    common = run(["git", "-C", str(source), "rev-parse", "--git-common-dir"])
    if common.returncode:
        raise ValueError("cannot locate project Git storage for landing retests")
    branch_source = str((source / common.stdout.strip()).resolve())
    opts = {"suite": args.suite, "device_gate": args.device_gate, "scenarios": args.scenario,
            "harnesses": args.harness, "receipt": str(Path(args.receipt).resolve()) if args.receipt else None,
            "retest_on_move": args.retest_on_move, "branch_source": branch_source}
    db = connection()
    rid = uuid.uuid4().hex[:16]
    repo = ROOT / "repos" / rid
    db.execute("BEGIN IMMEDIATE")
    seq = db.execute("SELECT COALESCE(MAX(seq),0)+1 FROM requests").fetchone()[0]
    tip = run(["git", "-C", cfg.get("landing_repo", branch_source), "rev-parse", "--verify", "refs/heads/" + cfg["landing_branch"] + "^{commit}"])
    branch_tip = tip.stdout.strip() if tip.returncode == 0 else None
    submitted = time.time()
    db.execute("INSERT INTO requests (id,seq,project,source,original_sha,sha,options,state,submitted,queued_at,branch_tip) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
               (rid, seq, args.project, str(source), args.sha.lower(), args.sha.lower(), json.dumps(opts), "preparing", submitted, submitted, branch_tip))
    db.execute("COMMIT")
    snapshot(db)
    try:
        repo.parent.mkdir(parents=True, exist_ok=True)
        clone = run(["git", "clone", "--no-local", "--quiet", str(source), str(repo)])
        if clone.returncode:
            raise RuntimeError("snapshot clone failed: " + clone.stderr.strip())
        fetched = run(["git", "-C", str(repo), "fetch", "--quiet", str(source), args.sha])
        if fetched.returncode:
            raise RuntimeError("cannot preserve requested commit: " + fetched.stderr.strip())
        run(["git", "-C", str(repo), "update-ref", "refs/heads/test-service-original", args.sha])
        if run(["git", "-C", str(repo), "checkout", "--detach", "--quiet", args.sha]).returncode:
            raise RuntimeError("snapshot lacks requested commit")
        db.execute("UPDATE requests SET state='queued' WHERE id=? AND state='preparing'", (rid,))
    except Exception as exc:
        db.execute("UPDATE requests SET state='failed',error=?,finished=? WHERE id=?", (str(exc), time.time(), rid))
        shutil.rmtree(repo, ignore_errors=True)
        snapshot(db)
        raise
    snapshot(db)
    print(rid)


def expand(argv, serial=None):
    return [str(part).replace("{serial}", serial or "") for part in argv]


def first_error(log, code, step):
    for line in log.splitlines():
        if re.search(r"(?i)(FAIL|ERROR|Assertion|Exception|not ok)", line):
            return step + ": " + line[:500]
    return step + ": exit " + str(code) + (": " + log.strip().splitlines()[-1][:500] if log.strip() else "")


def prepare_phone(serial):
    """Wake and unlock a configured phone without exposing the PIN in argv or logs."""
    adb = ["adb", "-s", serial, "shell"]
    wake = run(adb + ["input", "keyevent", "KEYCODE_WAKEUP"])
    if wake.returncode:
        raise RuntimeError("phone wake failed for " + serial)
    stay = run(adb + ["settings", "get", "global", "stay_on_while_plugged_in"])
    if stay.returncode:
        raise RuntimeError("phone power setting could not be read for " + serial)
    if stay.stdout.strip() != "2":
        update = run(adb + ["settings", "put", "global", "stay_on_while_plugged_in", "2"])
        if update.returncode:
            raise RuntimeError("phone power setting could not be set for " + serial)
    def locked():
        result = run(adb + ["dumpsys", "window"])
        if result.returncode:
            raise RuntimeError("phone lock state could not be read for " + serial)
        if "isKeyguardShowing=true" in result.stdout:
            return True
        if "isKeyguardShowing=false" in result.stdout:
            return False
        raise RuntimeError("phone lock state is unknown for " + serial)
    if not locked():
        return
    pins = Path.home() / ".config/firstmate/test-device-pins"
    if not pins.exists():
        raise RuntimeError("phone-locked: add " + serial + " to " + str(pins))
    stat = pins.lstat()
    if not pins.is_file() or pins.is_symlink() or stat.st_mode & 0o077:
        raise RuntimeError("phone PIN file must be a regular mode-600 private file")
    entries = {}
    for line in pins.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, sep, pin = line.partition("=")
        if not sep or key == "*" or not re.fullmatch(r"[0-9]+", pin):
            raise RuntimeError("invalid phone PIN file entry")
        entries[key] = pin
    pin = entries.get(serial)
    if pin is None:
        raise RuntimeError("phone-locked: add " + serial + " to " + str(pins))
    # Feed shell commands over stdin: the secret never appears in a process argv.
    unlock = subprocess.run(adb, input="input text " + pin + "\ninput keyevent KEYCODE_ENTER\nexit\n",
                            text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if unlock.returncode or locked():
        raise RuntimeError("phone-locked: could not unlock " + serial)


def execute(db, row):
    rid = row["id"]
    opts = json.loads(row["options"])
    cfg = config(row["project"])
    repo = ROOT / "repos" / rid
    work = ROOT / "runs" / rid
    if work.exists():
        shutil.rmtree(work)
    work.parent.mkdir(parents=True, exist_ok=True)
    clone = run(["git", "clone", "--no-local", "--quiet", str(repo), str(work)])
    if clone.returncode:
        return "failed", "cannot make clean detached test copy", None
    run(["git", "-C", str(work), "fetch", "--quiet", str(repo), row["sha"]])
    if run(["git", "-C", str(work), "checkout", "--detach", "--quiet", row["sha"]]).returncode:
        return "failed", "cannot make clean detached test copy", None
    if run(["git", "-C", str(work), "status", "--porcelain"]).stdout.strip():
        return "failed", "test copy is not clean", None
    serial = opts["device_gate"]
    any_serials = cfg.get("any_phones", cfg["phones"][:1])
    if serial == "any" and "any_device" not in cfg:
        serial = any_serials[0] if any_serials else None
    if opts["device_gate"] and not serial:
        return "failed", "no configured phone", None
    if serial:
        step_state(db, rid, row["generation"], "phone-prep", "running")
        try:
            for target in any_serials if serial == "any" else [serial]:
                prepare_phone(target)
        except (RuntimeError, OSError) as exc:
            step_state(db, rid, row["generation"], "phone-prep", "failed", 1)
            return "failed", str(exc), work
        step_state(db, rid, row["generation"], "phone-prep", "passed", 0)
    steps = []
    if opts["suite"]:
        steps.append(("suite", expand(cfg["suite"])))
    if opts["device_gate"]:
        command = expand(cfg["any_device"] if serial == "any" else cfg["device"], serial)
        for scenario in opts["scenarios"]:
            command += cfg.get("scenarios", {})[scenario]
        steps.append(("device", command))
    processes = []
    def step(name, argv):
        watch_db = connection()
        step_state(watch_db, rid, row["generation"], name, "running")
        target = Path(argv[0])
        if not target.is_absolute():
            argv[0] = str(work / target)
        target = Path(argv[0])
        inside = os.path.commonpath((str(work), str(target.resolve()))) == str(work)
        if not inside or not target.is_file() or not os.access(target, os.X_OK):
            step_state(watch_db, rid, row["generation"], name, "failed", 127)
            watch_db.close()
            return name, 127, "command missing or not executable: " + argv[0]
        log_path = ROOT / "logs" / (rid + "-" + str(row["generation"]) + "-" + re.sub(r"[^A-Za-z0-9_-]", "_", name) + ".log")
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("wb") as log:
            proc = subprocess.Popen(argv, cwd=work, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            processes.append(proc)
            while proc.poll() is None:
                cancelled = watch_db.execute("SELECT cancel_requested FROM requests WHERE id=?", (rid,)).fetchone()[0]
                if cancelled or STOP:
                    try:
                        os.killpg(proc.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        proc.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(proc.pid, signal.SIGKILL)
                time.sleep(.1)
        step_state(watch_db, rid, row["generation"], name, "passed" if proc.returncode == 0 else "failed", proc.returncode)
        watch_db.close()
        return name, proc.returncode, log_path.read_text(errors="replace")
    try:
        # Each request's suite and device commands enter their project-owned shared queues concurrently.
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(steps))) as pool:
            futures = [pool.submit(step, name, argv) for name, argv in steps]
            results = [future.result() for future in futures]
        if not any(code for _name, code, _log in results):
            for path in opts["harnesses"]:
                result = step("harness:" + path, [str(work / path)])
                results.append(result)
                if result[1]:
                    break
    finally:
        for proc in processes:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
    if db.execute("SELECT cancel_requested FROM requests WHERE id=?", (rid,)).fetchone()[0]:
        return "cancelled", "cancelled", work
    if STOP:
        return "interrupted", "service stopping", work
    for name, code, log in results:
        if code:
            return "failed", first_error(log, code, name), work
    return "passed", None, work


def complete(db, row, state, error):
    rid = row["id"]
    sha = row["sha"]
    result_dir = ROOT / "results" / rid
    result_dir.mkdir(parents=True, exist_ok=True)
    if state == "passed" and json.loads(row["options"])["suite"]:
        receipt = "schema=fm-full-suite.v1\nsha=" + sha + "\nfailures=0\n"
        atomic_write(result_dir / (sha + ".receipt"), receipt)
        path = json.loads(row["options"]).get("receipt")
        if path:
            atomic_write(path, receipt)
    elif state == "failed":
        atomic_write(result_dir / (sha + ".failure.json"), json.dumps({"sha": sha, "first_failure": error}, indent=2) + "\n")
    db.execute("UPDATE requests SET state=?,error=?,finished=? WHERE id=?", (state, error, time.time(), rid))
    snapshot(db)


def current_tip(repo, source, branch, old_tip):
    result = run(["git", "-C", str(source), "rev-parse", "--verify", "refs/heads/" + branch + "^{commit}"])
    if result.returncode:
        return None
    tip = result.stdout.strip()
    if tip == old_tip:
        return tip
    fetched = run(["git", "-C", str(repo), "fetch", "--quiet", str(source), tip])
    if fetched.returncode:
        return None
    if run(["git", "-C", str(repo), "update-ref", "refs/heads/test-service-landing", tip]).returncode:
        return None
    return tip


def recover_preparing(db):
    for row in db.execute("SELECT * FROM requests WHERE state='preparing' ORDER BY seq").fetchall():
        repo = ROOT / "repos" / row["id"]
        sha = row["original_sha"]
        try:
            if not repo.exists():
                repo.parent.mkdir(parents=True, exist_ok=True)
                cloned = run(["git", "clone", "--no-local", "--quiet", row["source"], str(repo)])
                if cloned.returncode:
                    raise RuntimeError("snapshot clone failed after restart")
            if run(["git", "-C", str(repo), "fetch", "--quiet", row["source"], sha]).returncode:
                raise RuntimeError("requested commit unavailable after restart")
            if run(["git", "-C", str(repo), "update-ref", "refs/heads/test-service-original", sha]).returncode:
                raise RuntimeError("cannot preserve requested commit after restart")
            db.execute("UPDATE requests SET state='queued' WHERE id=? AND state='preparing'", (row["id"],))
        except RuntimeError as exc:
            db.execute("UPDATE requests SET state='failed',error=?,finished=? WHERE id=?", (str(exc), time.time(), row["id"]))
        snapshot(db)


def retest_moved(db):
    for row in db.execute("SELECT * FROM requests WHERE state IN ('passed','failed','conflict') AND cancel_requested=0 ORDER BY seq").fetchall():
        opts = json.loads(row["options"])
        if not opts["retest_on_move"]:
            continue
        try:
            cfg = config(row["project"])
            repo = ROOT / "repos" / row["id"]
            tip = current_tip(repo, cfg.get("landing_repo", opts.get("branch_source", row["source"])), cfg["landing_branch"], row["branch_tip"])
            if not tip or tip == row["branch_tip"]:
                continue
            db.execute("UPDATE requests SET branch_tip=? WHERE id=?", (tip, row["id"]))
            scratch = ROOT / "rebase" / row["id"]
            shutil.rmtree(scratch, ignore_errors=True)
            scratch.parent.mkdir(parents=True, exist_ok=True)
            clone = run(["git", "clone", "--no-local", "--quiet", str(repo), str(scratch)])
            if clone.returncode:
                raise RuntimeError(clone.stderr.strip())
            if run(["git", "-C", str(scratch), "fetch", "--quiet", str(repo), tip]).returncode:
                raise RuntimeError("cannot load new landing tip in scratch copy")
            if run(["git", "-C", str(scratch), "checkout", "--detach", "--quiet", row["original_sha"]]).returncode:
                raise RuntimeError("original commit unavailable")
            base = run(["git", "-C", str(scratch), "merge-base", row["original_sha"], tip])
            if base.returncode:
                raise RuntimeError("cannot find rebase base")
            rebased = run(["git", "-C", str(scratch), "-c", "user.name=Firstmate Test Service", "-c", "user.email=test-service@localhost", "rebase", "--onto", tip, base.stdout.strip(), row["original_sha"]])
            if rebased.returncode:
                db.execute("UPDATE requests SET state='conflict',error=?,finished=? WHERE id=?", (rebased.stderr.strip()[:1000] or "rebase conflict", time.time(), row["id"]))
                snapshot(db)
                continue
            sha = run(["git", "-C", str(scratch), "rev-parse", "HEAD"]).stdout.strip()
            fetched = run(["git", "-C", str(repo), "fetch", "--quiet", str(scratch), sha])
            if fetched.returncode:
                raise RuntimeError("cannot preserve rebased commit")
            run(["git", "-C", str(repo), "update-ref", "refs/heads/test-service-rebased", sha])
            db.execute("UPDATE requests SET state='queued',sha=?,generation=generation+1,queued_at=?,started=NULL,finished=NULL,error=NULL WHERE id=?", (sha, time.time(), row["id"]))
            snapshot(db)
        except Exception as exc:
            db.execute("UPDATE requests SET state='conflict',error=?,finished=? WHERE id=?", (str(exc), time.time(), row["id"]))
            snapshot(db)


def serve():
    global STOP
    def stop(_sig, _frame):
        global STOP
        STOP = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    db = connection()
    # Single writer: a second daemon must not process the same request.
    lock = (ROOT / "service.lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError("test service is already running")
    db.execute("UPDATE requests SET state='queued',queued_at=?,started=NULL WHERE state='running'", (time.time(),))
    db.execute("UPDATE steps SET state='retrying' WHERE state='running'")
    recover_preparing(db)
    snapshot(db)
    def publish_time():
        tick_db = connection()
        while not STOP:
            snapshot(tick_db)
            time.sleep(2)
        tick_db.close()
    threading.Thread(target=publish_time, name="test-service-status", daemon=True).start()
    last_retest = 0
    while not STOP:
        row = db.execute("SELECT * FROM requests WHERE state IN ('preparing','queued') ORDER BY queued_at,seq LIMIT 1").fetchone()
        if row and row["state"] == "queued":
            if row["cancel_requested"]:
                complete(db, row, "cancelled", "cancelled before start")
                continue
            db.execute("UPDATE requests SET state='running',started=? WHERE id=?", (time.time(), row["id"]))
            snapshot(db)
            try:
                state, error, _ = execute(db, row)
            except Exception as exc:
                state, error = "failed", "service error: " + str(exc)
            if STOP:
                snapshot(db)
                break
            complete(db, row, state, error)
            continue
        if time.time() - last_retest > 5:
            retest_moved(db)
            last_retest = time.time()
        time.sleep(.2)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("submit")
    s.add_argument("project"); s.add_argument("worktree"); s.add_argument("sha")
    s.add_argument("--suite", action="store_true")
    s.add_argument("--device-gate")
    s.add_argument("--scenario", action="append", default=[])
    s.add_argument("--harness", action="append", default=[])
    s.add_argument("--receipt")
    s.add_argument("--retest-on-move", action="store_true")
    s = sub.add_parser("status"); s.add_argument("--json", action="store_true")
    s = sub.add_parser("wait"); s.add_argument("id")
    s = sub.add_parser("cancel"); s.add_argument("id")
    sub.add_parser("serve"); sub.add_parser("install-unit")
    args = p.parse_args()
    if args.cmd == "submit":
        submit(args)
    elif args.cmd == "serve":
        serve()
    elif args.cmd == "install-unit":
        unit = Path.home() / ".config/systemd/user/fm-test-service.service"
        unit.parent.mkdir(parents=True, exist_ok=True)
        env = "Environment=" + json.dumps("FM_HOME=" + str(HOME)) + "\n"
        env += "Environment=" + json.dumps("FM_TEST_SERVICE_STATE=" + str(ROOT)) + "\n"
        atomic_write(unit, "[Unit]\nDescription=Firstmate test service\n[Service]\nType=simple\n" + env + "ExecStart=" + json.dumps(str(CODE)) + " serve\nRestart=always\nRestartSec=2\nKillMode=control-group\n[Install]\nWantedBy=default.target\n")
        print(unit)
    else:
        db = connection()
        if args.cmd == "status":
            data = snapshot(db)
            if args.json:
                print(json.dumps(data, indent=2))
            else:
                for row in data["requests"]:
                    print(row["id"], row["state"], row["sha"], row["error"] or "")
        elif args.cmd == "cancel":
            row = db.execute("SELECT state FROM requests WHERE id=?", (args.id,)).fetchone()
            if not row:
                raise ValueError("unknown request")
            if row["state"] in ("preparing", "queued"):
                db.execute("UPDATE requests SET state='cancelled',cancel_requested=1,finished=? WHERE id=?", (time.time(), args.id))
            elif row["state"] == "running":
                db.execute("UPDATE requests SET cancel_requested=1 WHERE id=?", (args.id,))
            elif row["state"] in TERMINAL:
                db.execute("UPDATE requests SET cancel_requested=1 WHERE id=?", (args.id,))
            snapshot(db)
        elif args.cmd == "wait":
            while True:
                row = db.execute("SELECT state,error,sha FROM requests WHERE id=?", (args.id,)).fetchone()
                if not row:
                    raise ValueError("unknown request")
                if row["state"] in TERMINAL:
                    print(row["state"], row["sha"], row["error"] or "")
                    return 0 if row["state"] == "passed" else 1
                time.sleep(.2)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, sqlite3.Error) as exc:
        print("error:", exc, file=sys.stderr)
        sys.exit(2)
