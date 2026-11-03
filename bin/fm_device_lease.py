"""Minimal compatible device-test leases, independent of any project package.

The existing directory/label/ts/port format is retained for older callers.
Only leases with a matching unique label are released; unknown directory
contents are never removed. A missing timestamp uses directory mtime so an
in-flight mkdir claim is not mistaken for an expired lease.
"""
import random
import socket
import time


class Busy(Exception):
    """The device already has a lease."""


def release(serial, *, lock_dir, label):
    target = lock_dir / serial
    try:
        if target.is_symlink() or (target / "label").read_text().strip() != label:
            return False
        entries = list(target.iterdir())
        if any(p.name not in ("ts", "label", "port") or p.is_symlink() or not p.is_file()
               for p in entries):
            return False
        for entry in entries:
            entry.unlink(missing_ok=True)
        target.rmdir()
        return True
    except FileNotFoundError:
        return not target.exists()


def renew(serial, *, lock_dir, label):
    target = lock_dir / serial
    try:
        if target.is_symlink() or (target / "label").read_text().strip() != label:
            return False
        (target / "ts").write_text(str(int(time.time())))
        return True
    except FileNotFoundError:
        return False


def reap(lock_dir, stale_secs=3600):
    if not lock_dir.is_dir():
        return
    for entry in list(lock_dir.iterdir()):
        if not entry.is_dir() or entry.is_symlink():
            continue
        try:
            try:
                stamp = int((entry / "ts").read_text().strip())
            except (OSError, ValueError):
                stamp = entry.stat().st_mtime
            if time.time() - stamp > stale_secs:
                release(entry.name, lock_dir=lock_dir, label=(entry / "label").read_text().strip())
        except FileNotFoundError:
            continue


def acquire(online, *, lock_dir, device, label):
    if device not in online:
        raise ValueError("device is not online")
    lock_dir.mkdir(parents=True, exist_ok=True)
    target = lock_dir / device
    try:
        target.mkdir()
    except FileExistsError as exc:
        raise Busy(device) from exc
    try:
        (target / "ts").write_text(str(int(time.time())))
        (target / "label").write_text(label)
        # Older device-test users reserve a host bridge port even when the
        # phone test does not use one. Keep it distinct from their leases.
        candidates = list(range(8111, 8131))
        random.shuffle(candidates)
        for port in candidates:
            with socket.socket() as probe:
                probe.settimeout(.05)
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    continue
            (target / "port").write_text(str(port))
            others = set()
            for path in lock_dir.glob("*/port"):
                if path.parent == target:
                    continue
                try:
                    others.add(int(path.read_text().strip()))
                except (FileNotFoundError, ValueError):
                    continue
            if port not in others:
                return
        raise RuntimeError("no compatible device-test bridge port is available")
    except BaseException:
        release(device, lock_dir=lock_dir, label=label)
        raise
