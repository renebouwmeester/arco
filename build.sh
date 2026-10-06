#!/usr/bin/env bash
# Build Arco and run it from build/ (development).
#
#   ./build.sh          generate the project, build Debug, (re)start Arco
#   ./build.sh check    build only (no start)
#   ./build.sh driver   build the audio driver (see below)
set -euo pipefail
cd "$(dirname "$0")"

# ./build.sh driver — the Arco audio driver into build/driver, next to its install script. Installing needs an
# administrator password and restarts coreaudiod: `sudo build/driver/install.sh`.
if [ "${1:-}" = "driver" ]; then
  OUT="build/driver"
  rm -rf "$OUT"; mkdir -p "$OUT/Arco.driver/Contents/MacOS"
  cp Driver/Info.plist "$OUT/Arco.driver/Contents/Info.plist"
  cp Driver/install.sh "$OUT/install.sh"; chmod +x "$OUT/install.sh"
  clang -Wall -Wextra -Wno-unused-parameter -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -bundle \
    -framework CoreFoundation -o "$OUT/Arco.driver/Contents/MacOS/Arco" Driver/ArcoDriver.c
  codesign --force --sign "Apple Development" --timestamp=none "$OUT/Arco.driver"
  echo "Arco.driver is in $OUT — install with: sudo $PWD/$OUT/install.sh"
  exit 0
fi

xcodegen generate --quiet
xcodebuild -project Arco.xcodeproj -scheme Arco -configuration Debug \
           -derivedDataPath build -allowProvisioningUpdates build > build.log 2>&1 \
  || { grep -E "error:" build.log | head -10; echo "BUILD FAILED (see build.log)"; exit 1; }
echo "** BUILD SUCCEEDED **"

[ "${1:-}" = "check" ] && exit 0

APP="build/Build/Products/Debug/Arco.app"
[ -d "$APP" ] || { echo "no $APP"; exit 1; }
pkill -x Arco 2>/dev/null || true
sleep 1
open "$APP"
echo "Arco is running"
