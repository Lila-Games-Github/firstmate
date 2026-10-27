#!/usr/bin/env python3
"""Regenerate the crew board phone screenshots from this fixture board.

Usage: python3 tests/fixtures/crew-board-phone/capture.py [output-dir]
Needs Python Playwright with Chromium installed. Defaults to tests/assets.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from urllib.request import Request, urlopen

from playwright.sync_api import sync_playwright

OWNER = "owner@example.com"
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
output = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "tests" / "assets"

with tempfile.TemporaryDirectory() as temporary:
    home = Path(temporary)
    (home / "state").mkdir()
    (home / "config").mkdir()
    (home / "config" / "crew-board-phone-owner").write_text(OWNER + "\n")
    board = json.loads((HERE / "crew-board.json").read_text())
    board["generated_epoch"] = int(time.time())
    (home / "state" / "crew-board.json").write_text(json.dumps(board))
    env = dict(os.environ, FM_HOME=str(home))
    env.pop("FM_STATE_OVERRIDE", None)
    env.pop("FM_CONFIG_OVERRIDE", None)
    server = subprocess.Popen([sys.executable, str(ROOT / "bin" / "fm-crew-board-phone.py"), "--port", "0"],
                              env=env, stdout=subprocess.PIPE, text=True)
    try:
        base = server.stdout.readline().split()[-1]
        urlopen(Request(base + "api/board", headers={"Tailscale-User-Login": OWNER}), timeout=5).read()
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            for theme in ("light", "dark"):
                page = browser.new_page(viewport={"width": 360, "height": 800},
                                        extra_http_headers={"Tailscale-User-Login": OWNER})
                page.goto(f"{base}?theme={theme}")
                page.wait_for_selector("#needs .row")
                page.screenshot(path=str(output / f"crew-board-phone-{theme}.png"))
                page.close()
            browser.close()
    finally:
        server.terminate()
        server.wait(timeout=5)
