#!/usr/bin/env bash
set -euo pipefail

hamii_bundle=".build/hamii.app"
hamii_macos="$hamii_bundle/Contents/MacOS"
mkdir -p "$hamii_macos"
cp .build/debug/hamii-studio "$hamii_macos/hamii-studio"
cat > "$hamii_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.hamii.studio</string>
  <key>CFBundleName</key><string>hamii</string>
  <key>CFBundleDisplayName</key><string>hamii</string>
  <key>CFBundleExecutable</key><string>hamii-studio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$hamii_bundle/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$hamii_bundle"
echo "Packaged $hamii_bundle"
