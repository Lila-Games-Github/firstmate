#!/usr/bin/env python3
"""Firstmate's test service is testfarm (Lila-Games-Github/lila-test-farm).

Firstmate copies this file over its bin/fm-test-service.py (docs/MIGRATION.md in
lila-test-farm), so every existing command line keeps working unchanged. It finds
the farm through TESTFARM_CHECKOUT or the installed testfarm command.

Firstmate-side addition kept when that copy is refreshed: `submit` without a
task label (`--task ID`, matching [A-Za-z0-9][A-Za-z0-9_-]*) is refused before
the farm sees it, because testfarm routes completion to that worker. Before submission the shim
freezes its current identity in FM_FARM_WORKER_BINDING and a local descriptor
owned by bin/fm-farm-deliver.py. Missing or ambiguous worker records are refused.
"""
import importlib.util
import os
import re
import shutil
import sys

if sys.argv[1:2] == ["submit"]:
    labels = [sys.argv[i + 1] for i, arg in enumerate(sys.argv[:-1]) if arg == "--task"]
    labels += [arg[len("--task="):] for arg in sys.argv if arg.startswith("--task=")]
    if not labels or not all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", label) for label in labels):
        sys.exit("error: submit requires --task ID naming the firstmate task, so its result can be delivered")

here = os.path.dirname(os.path.abspath(__file__))
farm = os.environ.get("TESTFARM_CHECKOUT")
if not farm:
    command = shutil.which("testfarm")
    if not command:
        sys.exit("error: testfarm is not installed; run install.sh from a lila-test-farm checkout")
    farm = os.path.dirname(os.path.dirname(os.path.realpath(command)))
os.environ.setdefault("FM_HOME", os.path.dirname(here))
os.environ.setdefault("FIRSTMATE_BIN", here)
if sys.argv[1:2] == ["submit"]:
    # Capture before invoking the client: a request can finish before submit
    # returns. The farm freezes this binding locally before its remote call.
    spec = importlib.util.spec_from_file_location("farm_delivery", os.path.join(here, "fm-farm-deliver.py"))
    delivery = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(delivery)
    home = os.environ["FM_HOME"]
    state = os.environ.get("FM_STATE_OVERRIDE") or os.path.join(home, "state")
    if len(set(labels)) != 1:
        sys.exit("error: submit must name exactly one worker task")
    try:
        os.environ["FM_FARM_WORKER_BINDING"] = delivery.capture(home, state, labels[0])
    except (ValueError, OSError) as error:
        sys.exit("error: cannot bind submitting worker: " + str(error))
    # Older remote clients ignore hooks. Their parser must refuse this flag
    # before any push/submit rather than silently falling back to polling.
    sys.argv.append("--require-notification-delivery")
os.execv(sys.executable, [sys.executable, os.path.join(farm, "compat", "fm-test-service.py"), *sys.argv[1:]])
