#!/usr/bin/env bash
# Portable regression for recovery when screenshot acknowledgement fails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-browser-preflight.XXXXXX") || fail 'cannot create lab'
trap 'rm -rf "$lab"' EXIT
mkdir "$lab/bin"
python3 - "$lab/fixture.png" <<'PY'
import pathlib
import struct
import sys
import zlib

def chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))

pixels = b'\x00' + b'\x22\x33\x44' * 2
data = b'\x89PNG\r\n\x1a\n'
data += chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 3, 8, 2, 0, 0, 0))
data += chunk(b'IDAT', zlib.compress(pixels * 3))
data += chunk(b'IEND', b'')
pathlib.Path(sys.argv[1]).write_bytes(data)
PY
cat >"$lab/bin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
case "$1" in
  snapshot) echo 'uid=g1:1_0 RootWebArea' ;;
  eval) echo 'result: 1' ;;
  screenshot) cp "$FM_TEST_PNG" "$2"; echo 'acknowledgement parser failed' >&2; exit 1 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$lab/bin/chrome-devtools-axi"

FM_TEST_PNG="$lab/fixture.png" PATH="$lab/bin:$PATH" "$ROOT/bin/fm-browser-preflight.sh" 2 3 1 "$lab/recovered.png" >"$lab/ok.stdout" 2>"$lab/ok.stderr" || fail 'valid PNG did not recover from failed acknowledgement'
assert_grep 'acknowledgement failed but the PNG is valid' "$lab/ok.stderr" 'recovery warning missing'
assert_grep 'acknowledgement parser failed' "$lab/recovered.png.preflight/screenshot.stderr" 'raw stderr was not retained'
pass 'valid PNG recovers from a failed screenshot acknowledgement with raw streams retained'

head -c 24 "$lab/fixture.png" >"$lab/truncated.png"
if FM_TEST_PNG="$lab/truncated.png" PATH="$lab/bin:$PATH" "$ROOT/bin/fm-browser-preflight.sh" 2 3 1 "$lab/invalid.png" >"$lab/bad.stdout" 2>"$lab/bad.stderr"; then
  fail 'truncated PNG passed recovery'
fi
assert_grep 'truncated PNG chunk' "$lab/bad.stderr" 'truncated PNG rejection missing'
pass 'truncated PNG is rejected even when screenshot wrote a file'
