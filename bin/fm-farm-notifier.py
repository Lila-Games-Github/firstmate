#!/usr/bin/env python3
"""Independent workstation remote-farm notifier (Linux systemd user timer).

Usage: FM_HOME=/absolute/home bin/fm-farm-notifier.py install|status|uninstall|run-once

Install from the stable, landed code root, never from a disposable worker copy.
Install requires an existing FM_HOME/state, an installed testfarm (or absolute
FM_TESTFARM_BIN), systemctl --user, and loginctl's Linger=yes for this user.
If absent, the operator must first run `loginctl enable-linger "$USER"` so the
user manager survives logout and starts at boot. No system service or shell
background process is created. No farm submission syntax changes.

One per-home firstmate-farm-<home-sha256-prefix>.timer enables a oneshot service
30s after manager startup and 30s after each completed attempt. The service
runs this code's run-once using an absolute Python path, explicit FM_HOME,
installed client path (retain its upgradeable symlink), and installation PATH
so node/ssh and the exact-task fm-send path work without a login shell.
It calls fm-farm-results.py sweep --report; that script owns selection, body,
retry, baseline, shared locking, and ledgers. No foreground watcher or chat is
required. Playbot must be running to accept chat messages; refused sends retry.
Service failures are journalled and retried on the next tick. systemd imposes
no invocation timeout; the existing farm and send calls retain their own bounds.

status prints unit identity, lingering, enabled/active status and recent service
result, then the journal command. uninstall disables/stops the timer, removes
only these two owned unit files and reloads the user manager; result ledgers
are preserved. An in-flight service invocation is allowed to finish; uninstall
never kills an uncertain delivery.
Install/uninstall reject a unit with different content ownership rather than
overwriting another program's file. Install is idempotent and starts the timer.
XDG_CONFIG_HOME selects the systemd user unit directory, normally ~/.config.
"""
import argparse
import hashlib
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys

OWNER = "# Managed by firstmate fm-farm-notifier.py\n"


def command(args, check=True):
    done = subprocess.run(args, stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=30)
    if check and done.returncode:
        raise ValueError(f"{' '.join(args)}: {done.stderr.strip() or done.stdout.strip()}")
    return done


def quote(value, exec_arg=False):
    if any(c in value for c in '\n\r\x00'):
        raise ValueError("unit values must contain no newline or NUL")
    value = value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%')
    if exec_arg:
        value = value.replace('$', '$$')
    return '"' + value + '"'


def linger():
    return command(["loginctl", "show-user", str(os.getuid()), "--property=Linger", "--value"]).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("install", "status", "uninstall", "run-once"))
    args = parser.parse_args()
    raw_home = os.environ.get("FM_HOME", "")
    if not os.path.isabs(raw_home):
        raise ValueError("FM_HOME must explicitly select an absolute owning home")
    home = Path(raw_home).resolve()
    state = home / "state"
    if not state.is_dir() or state.is_symlink():
        raise ValueError(f"missing or symlinked state directory: {state}")
    code = Path(__file__).resolve()
    if args.action == "run-once":
        # Ignore accidental inherited state overrides: this service belongs to one home.
        env = dict(os.environ, FM_HOME=str(home), FM_STATE_OVERRIDE=str(state))
        return subprocess.run([sys.executable, str(code.with_name("fm-farm-results.py")), "sweep", "--report"],
                              env=env, stdin=subprocess.DEVNULL, check=False).returncode
    name = "firstmate-farm-" + hashlib.sha256(str(home).encode()).hexdigest()[:16]
    directory = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "systemd/user"
    service, timer = directory / (name + ".service"), directory / (name + ".timer")
    print(f"home={home}\nservice={service.name}\ntimer={timer.name}", flush=True)
    if args.action == "status":
        print(f"linger={linger()}")
        for operation in (["is-enabled", timer.name], ["is-active", timer.name],
                          ["show", service.name, "--property=ActiveState,Result,ExecMainStatus"]):
            done = command(["systemctl", "--user", *operation], check=False)
            print(done.stdout.strip() or done.stderr.strip())
        print(f"journal: journalctl --user -u {service.name}")
        return 0
    for path in (service, timer):
        if path.is_symlink() or (path.exists() and not path.read_text().startswith(OWNER + f"# Home: {home}\n")):
            raise ValueError(f"refusing foreign unit: {path}")
    if args.action == "uninstall":
        command(["systemctl", "--user", "disable", "--now", timer.name])
        for path in (service, timer):
            path.unlink(missing_ok=True)
        command(["systemctl", "--user", "daemon-reload"])
        return 0
    if linger() != "yes":
        user = pwd.getpwuid(os.getuid()).pw_name
        raise ValueError(f'logout/reboot persistence requires: loginctl enable-linger {user}')
    client = shutil.which(os.environ.get("FM_TESTFARM_BIN", "testfarm"))
    if not client:
        raise ValueError("installed testfarm client not found")
    env = {"FM_HOME": str(home), "FM_TESTFARM_BIN": os.path.abspath(client), "PATH": os.environ["PATH"]}
    header = OWNER + f"# Home: {home}\n"
    service_text = header + "[Unit]\nDescription=Firstmate remote farm completion delivery\n\n[Service]\nType=oneshot\n"
    service_text += "Environment=" + " ".join(quote(f"{key}={value}") for key, value in env.items()) + "\n"
    service_text += "ExecStart=" + " ".join(quote(value, True) for value in (sys.executable, str(code), "run-once")) + "\n"
    service_text += "TimeoutStartSec=infinity\nUMask=0077\n"
    timer_text = header + ("[Unit]\nDescription=Poll remote farm completions independently of Firstmate\n\n"
                           f"[Timer]\nOnStartupSec=30s\nOnUnitInactiveSec=30s\nUnit={service.name}\n\n"
                           "[Install]\nWantedBy=timers.target\n")
    # Validate all interpolated strings before creating either file.
    quote(str(home))
    directory.mkdir(parents=True, exist_ok=True)
    for path, content in ((service, service_text), (timer, timer_text)):
        path.write_text(content)
    command(["systemctl", "--user", "daemon-reload"])
    command(["systemctl", "--user", "enable", "--now", timer.name])
    print("installed; use status to inspect delivery and journal output")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        sys.exit(f"error: {exc}")
