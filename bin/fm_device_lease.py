"""Minimal compatible device-test leases, independent of any project package.

The existing directory/label/ts/port format is retained for older callers.
Explicit release requires a matching unique label; stale incomplete claims
can also be reaped. Unknown directory contents are never removed. A missing
timestamp uses directory mtime so an in-flight claim is not expired early.
"""
import os
import random
import socket
import stat
import time

_CLAIM_FILES = frozenset(("ts", "label", "port"))
_DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class Busy(Exception):
    """The device already has a lease."""


def _remove_claim(target, identity):
    descriptor = None
    try:
        descriptor = os.open(target, _DIRECTORY_FLAGS)
        current = os.fstat(descriptor)
        if (current.st_dev, current.st_ino) != identity:
            return False
        with os.scandir(descriptor) as listing:
            entries = list(listing)
        if any(entry.name not in _CLAIM_FILES
               or not stat.S_ISREG(entry.stat(follow_symlinks=False).st_mode)
               for entry in entries):
            return False
        for entry in entries:
            os.unlink(entry.name, dir_fd=descriptor)
        current = target.lstat()
        if (current.st_dev, current.st_ino) != identity:
            return False
        target.rmdir()
        return True
    except OSError:
        return False
    finally:
        if descriptor is not None:
            os.close(descriptor)


def release(serial, *, lock_dir, label):
    target = lock_dir / serial
    try:
        if target.is_symlink() or (target / "label").read_text().strip() != label:
            return False
        entries = list(target.iterdir())
        if any(p.name not in _CLAIM_FILES or p.is_symlink() or not p.is_file()
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
        descriptor = None
        try:
            descriptor = os.open(entry, _DIRECTORY_FLAGS)
            identity = os.fstat(descriptor)
            try:
                stamp_fd = os.open("ts", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=descriptor)
                with os.fdopen(stamp_fd) as stream:
                    stamp = int(stream.read().strip())
            except (OSError, ValueError):
                stamp = identity.st_mtime
            if time.time() - stamp > stale_secs:
                _remove_claim(entry, (identity.st_dev, identity.st_ino))
        except OSError:
            continue
        finally:
            if descriptor is not None:
                os.close(descriptor)


def acquire(online, *, lock_dir, device, label):
    if device not in online:
        raise ValueError("device is not online")
    lock_dir.mkdir(parents=True, exist_ok=True)
    target = lock_dir / device
    try:
        target.mkdir()
    except FileExistsError as exc:
        raise Busy(device) from exc
    identity = None
    descriptor = None
    try:
        descriptor = os.open(target, _DIRECTORY_FLAGS)
        created = os.fstat(descriptor)
        identity = (created.st_dev, created.st_ino)
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
        if identity is not None:
            _remove_claim(target, identity)
        raise
    finally:
        if descriptor is not None:
            os.close(descriptor)
