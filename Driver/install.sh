#!/bin/bash
# Install the Arco audio driver (development; the release uses a .pkg). Copies Arco.driver next to this script to
# /Library/Audio/Plug-Ins/HAL and restarts coreaudiod — the Mac's sound is gone for a few seconds.
#
#   sudo ./install.sh            install (or replace)
#   sudo ./install.sh --remove   remove
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$DIR/Arco.driver"
TARGET="/Library/Audio/Plug-Ins/HAL/Arco.driver"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
if [ "${1:-}" = "--remove" ]; then
  [ -d "$TARGET" ] && rm -rf "$TARGET"
  echo "Arco driver removed"
else
  # Only copy when the source really is a driver bundle.
  [ -n "$DIR" ] && [ -f "$SOURCE/Contents/MacOS/Arco" ] && [ -f "$SOURCE/Contents/Info.plist" ] || { echo "no Arco.driver next to this script"; exit 1; }
  [ -d "$TARGET" ] && rm -rf "$TARGET"
  cp -R "$SOURCE" /Library/Audio/Plug-Ins/HAL/
  chown -R root:wheel "$TARGET"
  echo "Arco driver installed"
fi
killall coreaudiod 2>/dev/null || true
echo "coreaudiod restarted"
