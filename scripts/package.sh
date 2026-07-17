#!/bin/sh
# Build a release .app bundle and .dmg into dist/.
#
# Usage: scripts/package.sh
#   VERSION=x.y.z   override the version (default 0.1.0)
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION="${VERSION:-0.1.0}"
cd "$ROOT"

swift build -c release

APP=dist/AegisMac.app
/bin/rm -rf dist
mkdir -p "$APP/Contents/MacOS"

cp .build/release/AegisMac "$APP/Contents/MacOS/AegisMac"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AegisMac</string>
    <key>CFBundleIdentifier</key>
    <string>dev.myl.aegismac</string>
    <key>CFBundleName</key>
    <string>Aegis</string>
    <key>CFBundleDisplayName</key>
    <string>Aegis</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"

mkdir -p dist/dmg-root
cp -R "$APP" dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications
hdiutil create -volname "Aegis" -srcfolder dist/dmg-root -ov -format UDZO "dist/AegisMac-$VERSION.dmg" >/dev/null
/bin/rm -rf dist/dmg-root

echo "Built: dist/AegisMac-$VERSION.dmg (ad-hoc signed)"
