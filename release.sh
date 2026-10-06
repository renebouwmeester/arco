#!/usr/bin/env bash
# Build a release of Arco: a universal app and audio driver, signed, in one installer package — notarized and stapled
# when the notary profile exists.
#
#   ./release.sh            build/release/Arco-<version>.pkg
#
# Needs (from the Apple Developer account holder, once):
#   - certificates "Developer ID Application" and "Developer ID Installer" in this Mac's keychain
#   - a notary profile: xcrun notarytool store-credentials arco-notary --apple-id … --team-id XX742N7ZNY
# Without the certificates it builds a test package signed for development: it installs on this Mac only.
set -euo pipefail
cd "$(dirname "$0")"

# Run it from Terminal. A process started from an app outside macOS itself (an editor, an assistant) tags everything it
# writes with com.apple.provenance, which can't be removed, and pkgbuild packs it into the payload as ._ files.
probe=$(mktemp)
if xattr -p com.apple.provenance "$probe" > /dev/null 2>&1; then
  echo "!! files written here carry com.apple.provenance (ends up as ._ files in the payload) — run this from Terminal"
fi
rm -f "$probe"

# A release is built with the released Xcode, not whatever xcode-select points to (often a beta).
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -d "$DEVELOPER_DIR" ] || { echo "no Xcode at $DEVELOPER_DIR"; exit 1; }

TEAM=XX742N7ZNY
OUT=build/release
ROOT="$OUT/root"

APP_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*('"$TEAM"')\)"/\1/p' | head -1)
PKG_ID=$(security find-identity -v | sed -n 's/.*"\(Developer ID Installer: .*('"$TEAM"')\)"/\1/p' | head -1)
if [ -z "$APP_ID" ]; then
  APP_ID="Apple Development"
  echo "!! no Developer ID Application certificate — a test package for this Mac only"
fi

xcodegen generate --quiet
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Arco/Info.plist)
rm -rf "$OUT"; mkdir -p "$ROOT/Applications" "$ROOT/Library/Audio/Plug-Ins/HAL"

# The app: Release, universal, hardened runtime, timestamped signature.
xcodebuild -project Arco.xcodeproj -scheme Arco -configuration Release -derivedDataPath build/rel \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$APP_ID" DEVELOPMENT_TEAM=$TEAM \
  OTHER_CODE_SIGN_FLAGS="--timestamp" build > "$OUT/build.log" 2>&1 \
  || { grep -E "error:" "$OUT/build.log" | head -10; echo "BUILD FAILED (see $OUT/build.log)"; exit 1; }
APP="build/rel/Build/Products/Release/Arco.app"
[ -d "$APP" ] && [ -f "$APP/Contents/MacOS/Arco" ] || { echo "no $APP"; exit 1; }
ditto --norsrc --noextattr "$APP" "$ROOT/Applications/Arco.app"
echo "app: $(lipo -archs "$ROOT/Applications/Arco.app/Contents/MacOS/Arco")"

# The driver: universal, hardened runtime, timestamped.
DRV="$ROOT/Library/Audio/Plug-Ins/HAL/Arco.driver"
mkdir -p "$DRV/Contents/MacOS"
cp Driver/Info.plist "$DRV/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$DRV/Contents/Info.plist"
clang -Wall -Wextra -Wno-unused-parameter -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -bundle \
  -framework CoreFoundation -o "$DRV/Contents/MacOS/Arco" Driver/ArcoDriver.c
codesign --force --options runtime --timestamp --sign "$APP_ID" "$DRV"
echo "driver: $(lipo -archs "$DRV/Contents/MacOS/Arco")"


# The package: the app stays in /Applications (not "relocated" to another copy the installer happens to find).
pkgbuild --analyze --root "$ROOT" "$OUT/components.plist" > /dev/null
N=$(plutil -p "$OUT/components.plist" | grep -c "RootRelativeBundlePath")
for ((i = 0; i < N; i++)); do
  /usr/libexec/PlistBuddy -c "Delete :$i:BundleIsRelocatable" "$OUT/components.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$i:BundleIsRelocatable bool false" "$OUT/components.plist"
done
pkgbuild --root "$ROOT" --component-plist "$OUT/components.plist" --identifier nl.renebouwmeester.arco.pkg \
  --version "$VERSION" --scripts Package/scripts --install-location / "$OUT/arco.pkg" > /dev/null
mkdir -p "$OUT/resources"; cp Package/resources/* "$OUT/resources/"; cp LICENSE "$OUT/resources/LICENSE.txt"
sed "s/version=\"0\"/version=\"$VERSION\"/" Package/Distribution.xml > "$OUT/Distribution.xml"
PKG="$OUT/Arco-$VERSION.pkg"
if [ -n "$PKG_ID" ]; then
  productbuild --distribution "$OUT/Distribution.xml" --resources "$OUT/resources" --package-path "$OUT" --sign "$PKG_ID" "$PKG" > /dev/null
else
  echo "!! no Developer ID Installer certificate — the package is unsigned"
  productbuild --distribution "$OUT/Distribution.xml" --resources "$OUT/resources" --package-path "$OUT" "$PKG" > /dev/null
fi

# Notarize and staple, when this Mac has the profile.
if [ "$APP_ID" != "Apple Development" ] && [ -n "$PKG_ID" ] && xcrun notarytool history --keychain-profile arco-notary > /dev/null 2>&1; then
  xcrun notarytool submit "$PKG" --keychain-profile arco-notary --wait
  xcrun stapler staple "$PKG"
else
  echo "!! not notarized (needs both Developer ID certificates and the notary profile arco-notary)"
fi
echo "$PKG"
