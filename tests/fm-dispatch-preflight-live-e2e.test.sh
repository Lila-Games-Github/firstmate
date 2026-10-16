#!/usr/bin/env bash
# tests/fm-dispatch-preflight-live-e2e.test.sh - default-on live guard for the
# required-tool MCP probes in bin/fm-dispatch-preflight-lib.sh.
#
# Those verdicts come from vendor CLI output (claude's rendered Status line and
# codex's `mcp list --json` fields), so a stub can only confirm the shape this
# repo already assumed. This guard runs every INSTALLED harness with a verified
# probe against a private configuration holding a real stdio MCP server, a
# server that cannot connect or is disabled, and a name that does not exist,
# and fails naming the harness and version when a verdict drifts.
#
# Listing and health-checking MCP servers submits no prompt, so this consumes no
# model tokens. Each harness reads only a temporary config directory
# (CLAUDE_CONFIG_DIR, CODEX_HOME); the operator's own servers are never read or
# changed. The portable counterpart is tests/fm-dispatch-preflight.test.sh. Run
# this guard after any claude or codex upgrade; docs/verification/runtime-backends.md
# records its dated result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_DISPATCH_PREFLIGHT_LIVE python3 jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-dispatch-preflight-lib.sh
. "$ROOT/bin/fm-dispatch-preflight-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-dispatch-preflight-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/wt" "$LAB/claude" "$LAB/codex"

# A minimal stdio MCP server: answers initialize and tools/list, ignores
# notifications. It is real enough for each CLI's own health check.
cat > "$LAB/server.py" <<'PY'
import json, sys
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    if "id" not in msg:
        continue
    method = msg.get("method")
    if method == "initialize":
        result = {"protocolVersion": msg.get("params", {}).get("protocolVersion", "2024-11-05"),
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "fmprobe", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": []}
    else:
        result = {}
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}) + "\n")
    sys.stdout.flush()
PY

CHECKED=0
MISSING=

expect_verdict() {  # <harness> <version> <server> <callable 0|1> <reason-substring>
  local harness=$1 version=$2 server=$3 want=$4 reason=$5 got=1
  fm_preflight_mcp_callable "$LAB/wt" "$harness" 0 "$server" && got=0
  if [ "$want" = 0 ] && [ "$got" != 0 ]; then
    fail "$harness $version: real server $server was not callable ($FM_PREFLIGHT_REASON)"
  fi
  if [ "$want" = 1 ]; then
    [ "$got" != 0 ] || fail "$harness $version: server $server counted as callable"
    assert_contains "$FM_PREFLIGHT_REASON" "$reason" "$harness $version: unexpected reason for $server"
  fi
}

if command -v claude >/dev/null 2>&1; then
  version=$(claude --version 2>/dev/null | head -1) || version=unknown
  export CLAUDE_CONFIG_DIR="$LAB/claude"
  (cd "$LAB/wt" && claude mcp add -s local fmprobe -- python3 "$LAB/server.py" >/dev/null 2>&1) \
    || fail "claude $version: could not register the private probe server"
  (cd "$LAB/wt" && claude mcp add -s local fmbroken -- false >/dev/null 2>&1) \
    || fail "claude $version: could not register the private broken server"
  expect_verdict claude "$version" fmprobe 0 ''
  expect_verdict claude "$version" fmbroken 1 'claude reports Status:'
  expect_verdict claude "$version" fmnosuch 1 'claude reports no server named fmnosuch'
  unset CLAUDE_CONFIG_DIR
  pass "claude $version: the MCP probe tells a connected server from a broken or unknown one"
  CHECKED=$((CHECKED + 1))
else
  MISSING="$MISSING claude"
  printf '# unverified: claude is not installed on this machine\n'
fi

if command -v codex >/dev/null 2>&1; then
  version=$(codex --version 2>/dev/null | head -1) || version=unknown
  printf '[mcp_servers.fmprobe]\ncommand = "python3"\nargs = ["%s"]\n\n[mcp_servers.fmoff]\ncommand = "python3"\nargs = ["%s"]\nenabled = false\n' \
    "$LAB/server.py" "$LAB/server.py" > "$LAB/codex/config.toml"
  export CODEX_HOME="$LAB/codex"
  expect_verdict codex "$version" fmprobe 0 ''
  expect_verdict codex "$version" fmoff 1 'codex lists no enabled, authenticated server named fmoff'
  expect_verdict codex "$version" fmnosuch 1 'codex lists no enabled, authenticated server named fmnosuch'
  unset CODEX_HOME
  pass "codex $version: the MCP probe tells an enabled server from a disabled or unknown one"
  CHECKED=$((CHECKED + 1))
else
  MISSING="$MISSING codex"
  printf '# unverified: codex is not installed on this machine\n'
fi

[ -z "$MISSING" ] || printf '# harnesses with a verified MCP probe that are absent here:%s\n' "$MISSING"
if [ "$CHECKED" -eq 0 ]; then
  [ "${FM_DISPATCH_PREFLIGHT_LIVE:-}" != 1 ] && [ "${FM_LIVE:-}" != 1 ] \
    || fail "FM_DISPATCH_PREFLIGHT_LIVE=1 checked no harness"
  printf 'skip: live: no harness with a verified MCP probe is installed\n'
  exit 0
fi
printf '# harnesses checked: %s\n' "$CHECKED"
