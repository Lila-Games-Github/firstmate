#!/usr/bin/env bash
# Read a remote secondmate home's live child metadata and current state.
# Usage: fm-on.sh <mate> fm-remote-child-inventory.sh
# The bounded JSON response is read-only. An unreadable child is unknown, never
# absent or dead. The parent owns classification and notice deduplication.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FM_HOME=${FM_HOME:?FM_HOME is required}
exec python3 - "$FM_HOME" "$SCRIPT_DIR/fm-crew-state.sh" <<'PY'
import json
import os
import re
import subprocess
import sys
import time

home, crew_state = sys.argv[1:]
state_dir = os.path.join(home, 'state')
now = int(time.time())
pending = None
try:
    log = os.path.join(state_dir, 'parent-replies.status')
    ack = os.path.join(state_dir, 'parent-replies.ack')
    if not os.path.islink(log) and os.path.isfile(log):
        delivered = int(open(ack).read().strip()) if os.path.isfile(ack) and not os.path.islink(ack) else 0
        pending = max(0, os.stat(log).st_size - delivered)
except (OSError, ValueError):
    pass
rows = []
try:
    names = sorted(name for name in os.listdir(state_dir) if name.endswith('.meta'))
except OSError as exc:
    print(json.dumps({'schema': 'fm-remote-child-inventory.v1', 'status': 'unknown', 'reason': str(exc), 'children': []}))
    sys.exit(0)
if len(names) > 64:
    print(json.dumps({'schema': 'fm-remote-child-inventory.v1', 'status': 'unknown', 'reason': 'more than 64 child records', 'children': []}))
    sys.exit(0)
for name in names:
    child = name[:-5]
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', child):
        continue
    meta_path = os.path.join(state_dir, name)
    try:
        if os.path.islink(meta_path) or os.stat(meta_path).st_size > 16384:
            raise ValueError('unsafe metadata')
        with open(meta_path, encoding='utf-8', errors='replace') as source:
            fields = dict(line.rstrip('\n').split('=', 1) for line in source if '=' in line)
        if fields.get('kind') == 'secondmate':
            continue
        status_path = os.path.join(state_dir, child + '.status')
        progress = int(os.stat(status_path).st_mtime) if os.path.isfile(status_path) and not os.path.islink(status_path) else int(os.stat(meta_path).st_mtime)
        env = dict(os.environ, FM_HOME=home, FM_STATE_OVERRIDE=state_dir, FM_CREW_STATE_NO_FORGE='1')
        result = subprocess.run([crew_state, child], env=env, capture_output=True, text=True, timeout=4)
        current = result.stdout.strip().splitlines()[0] if result.returncode == 0 and result.stdout.strip() else 'state: unknown · source: none · current-state read failed'
        match = re.match(r'state: ([a-z-]+) · source: ([a-z-]+) · (.*)', current)
        verdict, source, detail = match.groups() if match else ('unknown', 'none', current)
        rows.append({'id': child, 'state': verdict, 'source': source, 'detail': detail[:500], 'pr': fields.get('pr', '')[:500], 'progress_epoch': progress, 'age_seconds': max(0, now - progress)})
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        rows.append({'id': child, 'state': 'unknown', 'source': 'none', 'detail': str(exc)[:500], 'pr': '', 'progress_epoch': 0, 'age_seconds': 0})
print(json.dumps({'schema': 'fm-remote-child-inventory.v1', 'status': 'ok', 'observed_epoch': now, 'parent_channel_unacked_bytes': pending, 'children': rows}, separators=(',', ':')))
PY
