#!/bin/zsh
# Builds Edit The Future as a Mac app bundle at .build/EditTheFuture.app.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

config=${1:-release}
swift build -c "$config" --product EditTheFutureMac
bin_path=$(swift build -c "$config" --show-bin-path)

app=.build/EditTheFuture.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/EditTheFutureMac" "$app/Contents/MacOS/EditTheFuture"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Edit The Future</string>
    <key>CFBundleDisplayName</key>
    <string>Edit The Future</string>
    <key>CFBundleIdentifier</key>
    <string>com.editthefuture.mac</string>
    <key>CFBundleExecutable</key>
    <string>EditTheFuture</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.editthefuture.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>etf</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null
echo "Built $app"
