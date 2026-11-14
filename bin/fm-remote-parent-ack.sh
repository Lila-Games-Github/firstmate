#!/usr/bin/env bash
# Record the parent's durable remote-reply cursor in the remote mate home.
# Usage: fm-on.sh <mate> fm-remote-parent-ack.sh <offset> <prefix-sha256>
# The reply log is append-only. Acknowledgement never truncates or removes it.
set -eu
FM_HOME=${FM_HOME:?FM_HOME is required}
[ "$#" -eq 2 ] || exit 2
offset=$1
hash=$2
case "$offset" in ''|*[!0-9]*) exit 2 ;; esac
case "$hash" in ''|*[!a-fA-F0-9]*) exit 2 ;; esac
[ "${#hash}" -eq 64 ] || exit 2
state="$FM_HOME/state"
log="$state/parent-replies.status"
ack="$state/parent-replies.ack"
[ -d "$state" ] && [ ! -L "$state" ] || exit 1
[ -f "$log" ] && [ ! -L "$log" ] || exit 1
[ ! -L "$ack" ] || exit 1
size=$(wc -c < "$log" | tr -d ' ')
[ "$offset" -le "$size" ] || exit 1
if command -v shasum >/dev/null 2>&1; then
  actual=$(head -c "$offset" "$log" | shasum -a 256 | awk '{print $1}')
else
  actual=$(head -c "$offset" "$log" | sha256sum | awk '{print $1}')
fi
[ "$actual" = "$hash" ] || exit 1
old=$(cat "$ack" 2>/dev/null || true)
case "$old" in ''|*[!0-9]*) old=0 ;; esac
[ "$offset" -gt "$old" ] || exit 0
tmp=$(mktemp "$state/.parent-replies-ack.XXXXXX") || exit 1
printf '%s\n' "$offset" > "$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$ack"
