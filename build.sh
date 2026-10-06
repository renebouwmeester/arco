#!/usr/bin/env bash
# Build Arco and run it from build/ (development).
#
#   ./build.sh          generate the project, build Debug, (re)start Arco
#   ./build.sh check    build only (no start)
set -euo pipefail
cd "$(dirname "$0")"

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
