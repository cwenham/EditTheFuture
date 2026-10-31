#!/bin/zsh
# Builds Edit The Future as a Mac app bundle at .build/EditTheFuture.app.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

config=${1:-release}
swift build -c "$config" --product EditTheFutureMac
swift build -c "$config" --product etf
bin_path=$(swift build -c "$config" --show-bin-path)

app=.build/EditTheFuture.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/EditTheFutureMac" "$app/Contents/MacOS/EditTheFuture"
# The command-line tool (docs/DESIGN.md, 10.2). The app takes commands only from this copy.
cp "$bin_path/etf" "$app/Contents/MacOS/etf"

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
    <!-- A scenario is a folder with the .etf extension (docs/DESIGN.md, 15.1). Finder shows it as one document. -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.editthefuture.scenario</string>
            <key>UTTypeDescription</key>
            <string>Edit The Future scenario</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>com.apple.package</string>
                <string>public.composite-content</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>etf</string>
                </array>
            </dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Edit The Future scenario</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSTypeIsPackage</key>
            <true/>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.editthefuture.scenario</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Python, when it's in this build (scripts/fetch-python.sh): the framework, with its standard
# library inside, goes in Contents/Frameworks (docs/DESIGN.md, 6.4).
if [[ -d "$bin_path/Python.framework" ]]; then
    mkdir -p "$app/Contents/Frameworks"
    ditto "$bin_path/Python.framework" "$app/Contents/Frameworks/Python.framework"
    install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/EditTheFuture"
fi

# Shortcuts, Siri and Spotlight read the app's intents from Contents/Resources/Metadata.appintents,
# which Xcode makes with appintentsmetadataprocessor from the constant values the compiler
# recorded (Package.swift). Without Xcode the app still runs, without its intents.
if processor=$(xcrun --find appintentsmetadataprocessor 2>/dev/null); then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    ls "$PWD"/Sources/EditTheFutureMac/*.swift > "$work/sources.txt"
    find "$bin_path/EditTheFutureMac.build" -name '*.swiftconstvalues' > "$work/constvalues.txt"
    arch=$(uname -m)
    "$processor" \
        --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
        --module-name EditTheFutureMac \
        --sdk-root "$(xcrun --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
        --platform-family macOS \
        --deployment-target 14.0 \
        --bundle-identifier com.editthefuture.mac \
        --target-triple "$arch-apple-macos14.0" \
        --binary-file "$app/Contents/MacOS/EditTheFuture" \
        --source-file-list "$work/sources.txt" \
        --swift-const-vals-list "$work/constvalues.txt" \
        --output "$app/Contents/Resources" \
        --force --no-app-shortcuts-localization --quiet-warnings 2>&1 | grep -v -E "^\S+ \S+ appintentsmetadataprocessor\[" || true
    [[ -f "$app/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] || echo "warning: no App Intents metadata was made" >&2
else
    echo "warning: Xcode isn't selected (xcode-select), so the app's App Intents won't show in Shortcuts" >&2
fi

# The tool is signed first: the app is sealed with it inside, and trusts that exact copy.
codesign --force --sign - --identifier com.editthefuture.etf "$app/Contents/MacOS/etf" >/dev/null
codesign --force --sign - "$app" >/dev/null
echo "Built $app"
