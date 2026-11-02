#!/usr/bin/env python3
"""FrogPile adapter for the Firstmate performance plan service.

This host adapter uses the committed audit scene and runner in the tested
FrogPile commit. The service holds the phone queue lease for every invocation
except build. It never acquires a second lease.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

PACKAGE = "com.lila.prototype.perfaudit20261102"
TARGETS = {
    "pond_idle": ("midgame", "pond_idle"),
    "list_working": ("midgame", "list_working"),
    "crew": ("midgame", "crew"),
    "ftue_missions": ("ftue", "ftue_missions"),
}


def runner(work):
    path = work / "prototype-game/tests/run_60fps_audit.py"
    spec = importlib.util.spec_from_file_location("frogpile_audit_runner", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def adb(serial, *args, check=True):
    return subprocess.run(["adb", "-s", serial, *args], check=check, capture_output=True, text=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=("build", "install", "drive", "capture", "pull", "uninstall"))
    p.add_argument("worktree", type=Path)
    p.add_argument("bundle", type=Path)
    p.add_argument("--device")
    p.add_argument("--state")
    p.add_argument("--repeat", type=int, default=0)
    p.add_argument("--kind")
    p.add_argument("--output", type=Path)
    args = p.parse_args()
    if args.action != "build" and not args.device:
        p.error("device required inside lease")
    apk = args.bundle / "audit.apk"
    if args.action == "build":
        env = dict(os.environ, ANDROID_HOME=os.environ.get("ANDROID_HOME", str(Path.home() / "Android/Sdk")),
                   JAVA_HOME=os.environ.get("JAVA_HOME", str(Path.home() / "Android/jdk-21")),
                   HARVEST_PERF_SCENE="res://tests/perf_audit_device.tscn", HARVEST_PERF_PACKAGE=PACKAGE)
        subprocess.run([str(args.worktree / "prototype-game/tests/export_harvesting_perf.sh"), str(apk)],
                       cwd=args.worktree, env=env, check=True)
    elif args.action == "install":
        adb(args.device, "install", "--no-incremental", "-r", str(apk))
    elif args.action == "drive":
        if args.state not in TARGETS:
            raise ValueError("unknown FrogPile audit target: " + str(args.state))
        kind, phase = TARGETS[args.state]
        request = {"seconds": 5, "bisect": False, "battle_expedition": 10,
                   "highest_cleared": 10, "no_workers": True,
                   "runs": [kind], "phases": [phase]}
        label = args.state + "-" + str(args.repeat)
        runner(args.worktree).run_one(label, request)
        result = args.worktree / "prototype-game/.godot/60fps-audit" / label / "result.json"
        (args.bundle / (label + "-result.json")).write_bytes(result.read_bytes())
    elif args.action == "capture":
        if args.kind != "frame" or args.state not in TARGETS or not args.output:
            raise ValueError("FrogPile audit adapter supports frame metrics for named targets")
        label = args.state + "-" + str(args.repeat)
        result = json.loads((args.bundle / (label + "-result.json")).read_text())
        kind, phase = TARGETS[args.state]
        row = result["runs"][kind][phase]
        steady = row["steady"]
        action = row["interaction"]
        metrics = {"fps": steady["fps"], "p95_ms": steady["i"]["p95"],
                   "interaction_fps": action["fps"], "interaction_p95_ms": action["i"]["p95"],
                   "main_ms": steady["main"]["mean"], "gpu_ms": steady["gpu"]["mean"]}
        args.output.write_text(json.dumps(metrics) + "\n")
    elif args.action == "pull":
        # run_one already pulled the completed device receipt and logcat.
        pass
    elif args.action == "uninstall":
        adb(args.device, "uninstall", PACKAGE, check=False)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        print("error:", exc, file=sys.stderr)
        sys.exit(1)
