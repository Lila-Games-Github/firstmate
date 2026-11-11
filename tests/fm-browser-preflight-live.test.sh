#!/usr/bin/env bash
# Live smoke for the browser preflight's density and screenshot recovery path.
# It uses a real selected page and real Chrome output, including a wrong-density
# case that must fail before any long observation run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_BROWSER_PREFLIGHT_LIVE chrome-devtools-axi python3

lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-preflight-live.XXXXXX") || fail 'cannot create browser lab'
export CHROME_DEVTOOLS_AXI_SESSION="fm-browser-preflight-$$"
trap 'chrome-devtools-axi stop >/dev/null 2>&1 || true; rm -rf "$lab"' EXIT

chrome-devtools-axi open 'data:text/html,<html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><h1>Preflight</h1></body></html>' >"$lab/open.stdout" 2>"$lab/open.stderr" || fail 'real browser page did not open'
chrome-devtools-axi emulate --viewport '390x844x3,mobile,touch' >"$lab/emulate.stdout" 2>"$lab/emulate.stderr" || fail 'real browser viewport emulation failed'

"$ROOT/bin/fm-browser-preflight.sh" 390 844 3 "$lab/good.png" >"$lab/good.stdout" 2>"$lab/good.stderr" || fail 'real browser preflight rejected the requested density and PNG'
[ -s "$lab/good.png" ] || fail 'preflight did not save a nonempty PNG'
pass 'real browser accepts the requested density and physical PNG dimensions'

if "$ROOT/bin/fm-browser-preflight.sh" 390 844 2 "$lab/bad.png" >"$lab/bad.stdout" 2>"$lab/bad.stderr"; then
  fail 'preflight accepted a wrong device density'
fi
assert_grep 'device density mismatch' "$lab/bad.png.preflight/density.stdout" 'wrong-density failure lost the real CLI output'
[ ! -e "$lab/bad.png" ] || fail 'wrong-density failure still captured a screenshot'
pass 'real wrong-density case fails before capture and retains raw CLI output'
