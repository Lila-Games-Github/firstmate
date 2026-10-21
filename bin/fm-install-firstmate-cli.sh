#!/usr/bin/env bash
# fm-install-firstmate-cli.sh - install the one-word crew board launcher.
# Usage: fm-install-firstmate-cli.sh [directory=~/.local/bin]
#
# Creates <directory>/firstmate as a symlink to this checkout's bin/firstmate.
# Existing unrelated files are refused, never overwritten. Put the directory
# on PATH (for ~/.local/bin this is normally already configured).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST_DIR=${1:-$HOME/.local/bin}
DEST="$DEST_DIR/firstmate"
SOURCE="$SCRIPT_DIR/firstmate"
mkdir -p -- "$DEST_DIR"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  if [ -L "$DEST" ] && [ "$(readlink "$DEST")" = "$SOURCE" ]; then
    printf 'installed: %s\n' "$DEST"
    exit 0
  fi
  printf 'fm-install-firstmate-cli: refusing to replace %s\n' "$DEST" >&2
  exit 1
fi
ln -s -- "$SOURCE" "$DEST"
printf 'installed: %s\n' "$DEST"
