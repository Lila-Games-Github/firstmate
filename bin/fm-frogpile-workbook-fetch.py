#!/usr/bin/env python3
"""Fetch a raw FrogPile workbook export into a private snapshot.

Usage: FM_HOME=/path/to/home bin/fm-frogpile-workbook-fetch.py [--check]

The private inputs are config/frogpile-workbook.url (HTTPS endpoint, without a
key query parameter) and config/frogpile-workbook.key (one nonempty line with
no newline, owned by this user, readable, regular, non-symlink, with no
group or other permissions).
curl receives --get --data-urlencode key@FILE, so the key never enters argv.
Only HTTPS redirects are allowed. Connect and total timeouts are 10 and 60
seconds. A successful nonempty response is stored as raw bytes under
data/frogpile-workbook/ with mode 0600, beside JSON metadata. Metadata holds
the SHA-256 identity of the unauthenticated URL, UTC retrieval time, byte
count, SHA-256 checksum, classified response type, and unvalidated status.
The response format remains unknown until a real authenticated fetch is
reconciled manually against the pinned export. Failed bodies are discarded.
"""

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit


class InputError(Exception):
    pass


def load_inputs(home):
    config = home / "config"
    url_path = config / "frogpile-workbook.url"
    key_path = config / "frogpile-workbook.key"
    try:
        url_bytes = url_path.read_bytes()
    except OSError:
        raise InputError("URL file is missing or unreadable") from None
    if not url_bytes or len(url_bytes) > 8192 or url_bytes.count(b"\n") > 1:
        raise InputError("URL file must contain one bounded line")
    try:
        url = url_bytes.decode("utf-8").strip()
        parts = urlsplit(url)
        query = parse_qsl(parts.query, keep_blank_values=True)
        if (
            parts.scheme.lower() != "https"
            or not parts.hostname
            or parts.username is not None
            or parts.password is not None
            or parts.fragment
            or any(name.lower() == "key" for name, _ in query)
            or re.search(r"[\x00-\x20\x7f]", url)
        ):
            raise ValueError
    except (UnicodeError, ValueError):
        raise InputError("URL must be HTTPS without credentials, fragment, or key parameter") from None
    try:
        descriptor = os.open(key_path, os.O_RDONLY | os.O_NOFOLLOW)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise InputError("key file must be an owned private regular file")
        key = os.read(descriptor, 4097)
        if not key or len(key) > 4096 or b"\n" in key or b"\r" in key or b"\x00" in key:
            raise InputError("key file must contain one nonempty line without a terminator")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return url, descriptor
    except (OSError, InputError) as exc:
        if "descriptor" in locals():
            os.close(descriptor)
        if isinstance(exc, InputError):
            raise
        raise InputError("key file is missing or unreadable") from None


def response_type(raw):
    mime = raw.split(";", 1)[0].strip().lower()
    known = {"application/json", "text/csv", "text/plain", "text/html", "application/octet-stream", "application/zip"}
    return mime if mime in known else "other"


def fetch(home, url, key_descriptor):
    directory = home / "data" / "frogpile-workbook"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077:
        raise InputError("snapshot directory must be private")
    fd, tmp_name = tempfile.mkstemp(prefix=".download-", dir=directory)
    os.close(fd)
    tmp = Path(tmp_name)
    meta_tmp = None
    try:
        command = [
            "curl", "--silent", "--fail", "--location", "--proto", "=https",
            "--proto-redir", "=https", "--connect-timeout", "10", "--max-time", "60",
            "--max-redirs", "5", "--get", "--data-urlencode", f"key@/dev/fd/{key_descriptor}",
            "--output", str(tmp), "--write-out", "%{content_type}", url,
        ]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False, timeout=65, pass_fds=(key_descriptor,))
        if result.returncode != 0:
            raise InputError("fetch failed; response discarded")
        size = tmp.stat().st_size
        if size == 0:
            raise InputError("empty response discarded")
        digest = hashlib.sha256()
        with tmp.open("rb") as stream:
            for block in iter(lambda: stream.read(65536), b""):
                digest.update(block)
        timestamp = datetime.now(timezone.utc)
        stem = timestamp.strftime("%Y%m%dT%H%M%S.%fZ") + "-" + uuid.uuid4().hex[:8]
        snapshot = directory / f"{stem}.raw"
        metadata = directory / f"{stem}.json"
        record = {
            "source_identity": hashlib.sha256(url.encode("utf-8")).hexdigest(),
            "retrieved_at": timestamp.isoformat(),
            "byte_count": size,
            "sha256": digest.hexdigest(),
            "response_type": response_type(result.stdout.decode("ascii", "ignore")[:128]),
            "validation_status": "unvalidated",
        }
        fd, meta_name = tempfile.mkstemp(prefix=".metadata-", dir=directory)
        meta_tmp = Path(meta_name)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(record, stream, sort_keys=True)
            stream.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, snapshot)
        try:
            os.replace(meta_tmp, metadata)
        except OSError:
            snapshot.unlink(missing_ok=True)
            raise
        print(f"snapshot={snapshot} bytes={size} sha256={digest.hexdigest()}")
    finally:
        tmp.unlink(missing_ok=True)
        if meta_tmp is not None:
            meta_tmp.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check private input readiness without fetching")
    args = parser.parse_args()
    home_value = os.environ.get("FM_HOME")
    if not home_value:
        print("error: FM_HOME is required", file=sys.stderr)
        return 1
    try:
        home = Path(home_value)
        url, key_descriptor = load_inputs(home)
        try:
            if args.check:
                print("ready: private inputs valid; export format unvalidated")
            else:
                fetch(home, url, key_descriptor)
        finally:
            os.close(key_descriptor)
    except (InputError, OSError, subprocess.TimeoutExpired) as exc:
        if isinstance(exc, InputError):
            print(f"error: {exc}", file=sys.stderr)
        else:
            print("error: fetch or snapshot failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
