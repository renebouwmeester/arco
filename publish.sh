#!/usr/bin/env bash
# Put a built release on GitHub: a release v<version> with the package and the appcast as its assets. Sparkle in every
# installed Arco reads releases/latest/download/appcast.xml — so publishing is what offers the update to everyone.
#
#   ./publish.sh            after ./release.sh; needs the GitHub CLI (gh), signed in
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Arco/Info.plist)
PKG="build/release/Arco-$VERSION.pkg" CAST="build/release/appcast.xml"
[ -f "$PKG" ] && [ -f "$CAST" ] || { echo "no $PKG and $CAST — run ./release.sh first"; exit 1; }
xcrun stapler validate "$PKG" > /dev/null || { echo "$PKG is not notarized"; exit 1; }
grep -q "Arco-$VERSION.pkg" "$CAST" || { echo "$CAST is not for $VERSION"; exit 1; }
NOTES=(--notes "Arco $VERSION")
[ -f "Package/notes/$VERSION.md" ] && NOTES=(--notes-file "Package/notes/$VERSION.md")
gh release create "v$VERSION" "$PKG" "$CAST" --repo renebouwmeester/arco --title "Arco $VERSION" "${NOTES[@]}"
