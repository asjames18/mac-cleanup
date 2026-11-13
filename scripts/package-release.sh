#!/usr/bin/env bash
# Packages an already-built, ad-hoc-signed .app into a .zip and a .dmg (with an
# Applications shortcut) for free, unnotarized distribution.
# Usage: scripts/package-release.sh path/to/App.app <version> [out-dir]
set -euo pipefail
APP="$1"; VERSION="$2"
NAME="$(basename "$APP" .app)"
OUT="${3:-$(cd "$(dirname "$APP")" && pwd)/release}"
mkdir -p "$OUT"
ZIP="$OUT/$NAME-$VERSION-macOS.zip"
DMG="$OUT/$NAME-$VERSION-macOS.dmg"
rm -f "$ZIP" "$DMG"
/usr/bin/codesign --verify --strict --deep "$APP"
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
STAGE="$(mktemp -d)"
/usr/bin/ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
/usr/bin/hdiutil verify -quiet "$DMG"
ls -l "$ZIP" "$DMG"
/usr/bin/shasum -a 256 "$ZIP" "$DMG"
