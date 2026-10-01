#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="$DIR/Mac Screen.app"

echo "🔨 Mac Screen.app derleniyor..."
(cd "$DIR/mac" && swift build -c release)

rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"

cp "$DIR/mac/.build/release/MacScreenApp" "$APP_NAME/Contents/MacOS/MacScreenApp"

cat << 'EOF' > "$APP_NAME/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacScreenApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.antigravity.macscreen</string>
    <key>CFBundleName</key>
    <string>Mac Screen</string>
    <key>CFBundleDisplayName</key>
    <string>Mac Screen</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.3</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

chmod +x "$APP_NAME/Contents/MacOS/MacScreenApp"
echo "✅ Mac Screen.app başarıyla hazırlandı: $APP_NAME"
