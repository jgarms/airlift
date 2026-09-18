#!/bin/bash
# Wraps the airlift CLI binary in a minimal .app bundle so TCC (Local Network,
# audio capture) can attribute permissions to a stable bundle identity.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build

APP=build/Airlift.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/debug/airlift "$APP/Contents/MacOS/Airlift"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.garms.airlift</string>
    <key>CFBundleName</key>
    <string>Airlift</string>
    <key>CFBundleExecutable</key>
    <string>Airlift</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Airlift discovers HomePods and AirPlay speakers on your network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_airplay._tcp</string>
        <string>_raop._tcp</string>
    </array>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Airlift captures another app's audio to stream it to your speakers.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP"
