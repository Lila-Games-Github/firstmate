#!/usr/bin/env python3
"""Drive the shipped Go board in a real PTY and inspect its public effects."""

import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

board, home = sys.argv[1:]
state = Path(home) / "state"
master, slave = pty.openpty()
height = int(os.environ.get("TUI_TEST_HEIGHT", "30"))
width = int(os.environ.get("TUI_TEST_WIDTH", "120"))
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
proc = subprocess.Popen(
    [board, "tui"], stdin=slave, stdout=slave, stderr=slave,
    env={**os.environ, "TERM": "xterm-256color", "FM_HOME": home,
         "FM_STATE_OVERRIDE": str(state)}, start_new_session=True,
)
os.close(slave)
output = bytearray()
try:
    deadline = time.monotonic() + 10
    while b"WORKERS" not in output and time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.2)
        if ready:
            try:
                output += os.read(master, 65536)
            except OSError:
                break
    os.write(master, os.environ.get("TUI_TEST_KEYS", "jiwhy so slow?\\r").encode().replace(b"\\r", b"\r"))
    deadline = time.monotonic() + 10
    notes = []
    while time.monotonic() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                output += os.read(master, 65536)
            except OSError:
                break
        notes = list((state / "inbox").glob("*.note"))
        wake = state / ".wake-queue"
        if notes and wake.exists() and b"check: captain inbox note" in wake.read_bytes():
            break
    stopped = subprocess.run([board, "stop"], capture_output=True, text=True,
                             env={**os.environ, "FM_HOME": home,
                                  "FM_STATE_OVERRIDE": str(state)}, check=False)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=5)
    ansi = re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]", b"", bytes(output))
    rendered = ansi.decode("utf-8", "replace")
    print(json.dumps({
        "exit": proc.returncode,
        "workers": "WORKERS" in rendered,
        "feed": "FEED" in rendered,
        "row": "widget / Make the widget spin" in rendered,
        "phase": "TESTING" in rendered,
        "counts": "TESTING 1" in rendered and "FIXING 1" in rendered,
        "input": "NOTE [" in rendered,
        "note": notes[0].read_text() if notes else "",
        "wake": (state / ".wake-queue").read_text() if (state / ".wake-queue").exists() else "",
        "stop": stopped.stdout.strip(),
        "pid_removed": not (state / ".crew-board-tui.pid").exists(),
    }))
finally:
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=5)
    os.close(master)
