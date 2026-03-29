#!/bin/bash
# Build chronixd-capture and bundle it as a macOS .app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="chronixd-capture"
BUNDLE_ID="com.finnvoor.chronixd-capture"
APP_DIR="$PROJECT_DIR/.build/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Build release binary
swift build --disable-sandbox -c release --package-path "$PROJECT_DIR"

BINARY="$PROJECT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "error: binary not found at $BINARY"
    exit 1
fi

# Create .app bundle structure
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY" "$MACOS_DIR/$APP_NAME"

# Write Info.plist (LSUIElement hides from Dock)
cat > "$CONTENTS_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>chronixd-capture</string>
    <key>CFBundleIdentifier</key>
    <string>com.finnvoor.chronixd-capture</string>
    <key>CFBundleName</key>
    <string>chronixd-capture</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>chronixd-capture needs microphone access to transcribe speech.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>chronixd-capture needs speech recognition to transcribe audio.</string>
    <key>NSCameraUsageDescription</key>
    <string>chronixd-capture can optionally capture camera frames for context.</string>
</dict>
</plist>
PLIST

# Write entitlements and re-sign
ENTITLEMENTS="/tmp/chronixd-capture-entitlements.plist"
cat > "$ENTITLEMENTS" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.camera</key>
    <true/>
</dict>
</plist>
ENT

codesign --force --sign - --entitlements "$ENTITLEMENTS" "$MACOS_DIR/$APP_NAME"
rm "$ENTITLEMENTS"

echo "Built: $APP_DIR"
echo "Run:   open $APP_DIR"
