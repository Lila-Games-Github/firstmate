#!/usr/bin/env bash
# Verify the selected chrome-devtools-axi page before a long visual observation.
# Usage: bin/fm-browser-preflight.sh WIDTH HEIGHT DENSITY PNG_PATH
# The caller opens the target page and applies the requested emulated viewport first.
# A failed screenshot acknowledgement may still leave a valid PNG; raw tool streams
# are retained in PNG_PATH.preflight/ whenever verification fails.
set -euo pipefail

if [ "$#" -ne 4 ] || ! [[ "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^[1-9][0-9]*$ && "$3" =~ ^[1-9][0-9]*$ ]]; then
  echo 'usage: fm-browser-preflight.sh WIDTH HEIGHT DENSITY PNG_PATH' >&2
  exit 2
fi

width=$1 height=$2 density=$3 png=$4
if [ -e "$png" ] || [ -L "$png" ]; then
  echo "error: output already exists: $png" >&2
  exit 2
fi
log_dir="${png}.preflight"
if [ -e "$log_dir" ]; then
  echo "error: evidence directory already exists: $log_dir" >&2
  exit 2
fi
mkdir "$log_dir"
fail() { echo "error: $1; raw stdout/stderr: $log_dir" >&2; exit 1; }

chrome-devtools-axi snapshot >"$log_dir/snapshot.stdout" 2>"$log_dir/snapshot.stderr" || fail 'snapshot failed'
grep -q 'uid=' "$log_dir/snapshot.stdout" || fail 'snapshot has no references'
chrome-devtools-axi eval "() => { if (devicePixelRatio !== $density) throw new Error('device density mismatch: observed ' + devicePixelRatio + ', expected $density'); return devicePixelRatio }" >"$log_dir/density.stdout" 2>"$log_dir/density.stderr" || fail 'device density check failed'
chrome-devtools-axi screenshot "$png" >"$log_dir/screenshot.stdout" 2>"$log_dir/screenshot.stderr" || screenshot_rc=$?

python3 - "$png" "$width" "$height" "$density" <<'PY' || fail 'screenshot is absent, invalid, or has wrong physical dimensions'
import pathlib
import struct
import sys
import zlib

path = pathlib.Path(sys.argv[1])
expected = (int(sys.argv[2]) * int(sys.argv[4]), int(sys.argv[3]) * int(sys.argv[4]))
data = path.read_bytes()
if data[:8] != b'\x89PNG\r\n\x1a\n':
    raise SystemExit('invalid PNG signature')
offset = 8
observed = None
image_data = bytearray()
ended = False
while offset + 12 <= len(data):
    size = struct.unpack('>I', data[offset:offset + 4])[0]
    kind = data[offset + 4:offset + 8]
    end = offset + 12 + size
    if end > len(data):
        raise SystemExit('truncated PNG chunk')
    payload = data[offset + 8:offset + 8 + size]
    crc = struct.unpack('>I', data[offset + 8 + size:end])[0]
    if zlib.crc32(kind + payload) != crc:
        raise SystemExit('PNG checksum mismatch')
    if kind == b'IHDR':
        observed = struct.unpack('>II', payload[:8])
    elif kind == b'IDAT':
        image_data.extend(payload)
    elif kind == b'IEND':
        ended = True
        break
    offset = end
if not ended or observed is None or not image_data:
    raise SystemExit('incomplete PNG')
try:
    zlib.decompress(image_data)
except zlib.error as exc:
    raise SystemExit(f'bad PNG image data: {exc}')
if observed != expected:
    raise SystemExit(f'PNG dimensions {observed} != {expected}')
print(f'PNG dimensions: {observed[0]}x{observed[1]}')
PY

if [ "${screenshot_rc:-0}" -ne 0 ]; then
  echo "warning: screenshot acknowledgement failed but the PNG is valid; raw stdout/stderr: $log_dir" >&2
else
  rm -rf "$log_dir"
fi
echo "browser preflight passed: density=$density png=$png"
