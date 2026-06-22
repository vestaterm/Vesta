#!/bin/sh
# Build halo (release) and symlink it onto PATH so `halo` works from anywhere.
# Usage: ./install.sh [DEST_DIR]   (default /usr/local/bin)
set -e
cd "$(dirname "$0")"
swift build -c release
BIN="$(pwd)/.build/release/halo"          # arch-independent SPM symlink
DEST="${1:-/usr/local/bin}/halo"
ln -sf "$BIN" "$DEST"
echo "linked $DEST -> $BIN"
echo "try: halo help"
