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

# About the ._ files in the payload: everything written on this Mac carries com.apple.provenance (it can't be removed),
# and pkgbuild packs extended attributes as AppleDouble files. The installer merges them back into attributes — the
# installed app and driver have no ._ files and pass codesign --verify --strict (0.1.0, 6 Oct 2026).

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
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$APP_ID" DEVELOPMENT_TEAM=$TEAM CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" build > "$OUT/build.log" 2>&1 \
  || { grep -E "error:" "$OUT/build.log" | head -10; echo "BUILD FAILED (see $OUT/build.log)"; exit 1; }
APP="build/rel/Build/Products/Release/Arco.app"
[ -d "$APP" ] && [ -f "$APP/Contents/MacOS/Arco" ] || { echo "no $APP"; exit 1; }
ditto --norsrc --noextattr "$APP" "$ROOT/Applications/Arco.app"
# Sparkle's helpers (installer, downloader, Autoupdate, Updater.app) come signed by their own project: notarization wants
# every executable under our Developer ID with the hardened runtime — inside out, then the app again.
FW="$ROOT/Applications/Arco.app/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
  sign() { codesign --force --options runtime --timestamp --sign "$APP_ID" "$@"; }
  sign "$FW/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
  sign "$FW/Versions/B/Autoupdate"
  sign "$FW/Versions/B/Updater.app"
  sign "$FW"
  sign --entitlements Arco/Arco.entitlements "$ROOT/Applications/Arco.app"
  codesign --verify --strict --deep "$ROOT/Applications/Arco.app" || { echo "the app's signature doesn't hold"; exit 1; }
fi
# Xcode adds the debugging entitlement get-task-allow by itself; notarization refuses it.
if codesign -d --entitlements - "$ROOT/Applications/Arco.app" 2> /dev/null | grep -q get-task-allow; then
  echo "the app still has com.apple.security.get-task-allow — notarization would refuse it"; exit 1
fi
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
# Top-level components only (Sparkle's helpers appear nested, as ChildBundles, with the same key).
N=0
while /usr/libexec/PlistBuddy -c "Print :$N:RootRelativeBundlePath" "$OUT/components.plist" > /dev/null 2>&1; do N=$((N + 1)); done
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

# The appcast for Sparkle: one item, this package, signed with the EdDSA key in this Mac's keychain (made once with
# Sparkle's generate_keys). It goes up with the package as an asset of the GitHub Release (./publish.sh).
KEY=$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" Arco/Info.plist 2> /dev/null || true)
SIGN_UPDATE=build/rel/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
if [ -n "$KEY" ] && [ -x "$SIGN_UPDATE" ]; then
  BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Arco/Info.plist)
  SIGNATURE=$("$SIGN_UPDATE" "$PKG")   # sparkle:edSignature="…" length="…"
  NOTES=""
  [ -f "Package/notes/$VERSION.html" ] && NOTES="<description><![CDATA[$(cat "Package/notes/$VERSION.html")]]></description>"
  REPO=https://github.com/renebouwmeester/arco
  cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Arco</title>
    <item>
      <title>Arco $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>$REPO/releases/tag/v$VERSION</link>
      $NOTES
      <enclosure url="$REPO/releases/download/v$VERSION/Arco-$VERSION.pkg" sparkle:installationType="package"
                 type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
  echo "$OUT/appcast.xml"
else
  echo "!! no appcast (needs SUPublicEDKey in project.yml and Sparkle's sign_update)"
fi
echo "$PKG"
