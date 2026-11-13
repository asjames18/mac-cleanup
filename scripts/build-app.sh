#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacSweep"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
CONFIGURATION="${CONFIGURATION:-release}"
cd "$ROOT_DIR"
# Universal (arm64 + x86_64) by default; set UNIVERSAL=0 for a host-only build.
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-1}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c "$CONFIGURATION" --product "$APP_NAME" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIGURATION" "${ARCH_FLAGS[@]}" --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
if [[ ! -f "$ROOT_DIR/Assets/MacSweep.icns" ]]; then
    swift "$ROOT_DIR/scripts/make-icon.swift" "$ROOT_DIR/build/MacSweep.iconset"
    /usr/bin/iconutil -c icns "$ROOT_DIR/build/MacSweep.iconset" -o "$ROOT_DIR/Assets/MacSweep.icns"
fi
cp "$ROOT_DIR/Assets/MacSweep.icns" "$APP_DIR/Contents/Resources/MacSweep.icns"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacSweep</string>
<key>CFBundleIdentifier</key><string>com.local.MacSweep</string>
<key>CFBundleName</key><string>MacSweep</string>
<key>CFBundleDisplayName</key><string>MacSweep</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>MacSweep</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSDocumentsFolderUsageDescription</key><string>MacSweep scans Documents to show files for your review. Nothing is removed during a scan.</string>
<key>NSDownloadsFolderUsageDescription</key><string>MacSweep scans Downloads to show files for your review. Nothing is removed during a scan.</string>
<key>NSDesktopFolderUsageDescription</key><string>MacSweep scans Desktop to show files for your review. Nothing is removed during a scan.</string>
<key>NSHumanReadableCopyright</key><string>MacSweep</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --deep --sign - --timestamp=none "$APP_DIR"
/usr/bin/codesign --verify --strict "$APP_DIR"
/usr/bin/lipo -info "$APP_DIR/Contents/MacOS/$APP_NAME"
echo "$APP_DIR"
