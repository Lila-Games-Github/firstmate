#!/usr/bin/env python3
"""Firstmate's test service is testfarm (Lila-Games-Github/lila-test-farm).

Firstmate copies this file over its bin/fm-test-service.py (docs/MIGRATION.md in
lila-test-farm), so every existing command line keeps working unchanged. It finds
the farm through TESTFARM_CHECKOUT or the installed testfarm command.
"""
import os
import shutil
import sys

here = os.path.dirname(os.path.abspath(__file__))
farm = os.environ.get("TESTFARM_CHECKOUT")
if not farm:
    command = shutil.which("testfarm")
    if not command:
        sys.exit("error: testfarm is not installed; run install.sh from a lila-test-farm checkout")
    farm = os.path.dirname(os.path.dirname(os.path.realpath(command)))
os.environ.setdefault("FM_HOME", os.path.dirname(here))
os.environ.setdefault("FIRSTMATE_BIN", here)
os.execv(sys.executable, [sys.executable, os.path.join(farm, "compat", "fm-test-service.py"), *sys.argv[1:]])
