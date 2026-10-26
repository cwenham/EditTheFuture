#!/bin/zsh
# Fetches the embeddable CPython that the app bundles, into Vendor/Python (not in git).
#
# It comes from BeeWare's Python-Apple-support, which packages CPython for embedding in Mac
# and iOS apps. Checksums are pinned; a mismatch stops the script. The Mac and iOS frameworks
# are merged into Vendor/Python/Python.xcframework, which Package.swift links when it exists.
# pip, ensurepip, venv, idlelib and the test suite are removed (docs/DESIGN.md, 6.4).
#
# Usage: scripts/fetch-python.sh
set -euo pipefail
cd "$(dirname "$0")/.."

version=3.14
build=b13
base="https://github.com/beeware/Python-Apple-support/releases/download/${version}-${build}"
typeset -A sums
sums[macOS]=01e889972d76b22683cb49fd5b3c0e2b1f398cb10e812adb4c7a70a9ce975f9b
sums[iOS]=ce1c68affa1cbd9c5611a0f4a013e412f14a760cf22c6bb58cfb4d893073bd45

vendor=Vendor/Python
stamp="$version-$build"
if [[ -f $vendor/.fetched && $(cat $vendor/.fetched) == "$stamp" && -d $vendor/Python.xcframework ]]; then
    echo "Python $stamp is already in $vendor"
    exit 0
fi

rm -rf "$vendor"
mkdir -p "$vendor"
for platform in macOS iOS; do
    file="Python-${version}-${platform}-support.${build}.tar.gz"
    tmp=$(mktemp -d)
    echo "Downloading $file"
    curl -sSfL -o "$tmp/$file" "$base/$file"
    echo "${sums[$platform]}  $tmp/$file" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch for $file" >&2; exit 1; }
    mkdir -p "$vendor/$platform"
    tar -xzf "$tmp/$file" -C "$vendor/$platform"
    rm -rf "$tmp"
done

mac=$vendor/macOS/Python.xcframework/macos-arm64_x86_64/Python.framework
ios=$vendor/iOS/Python.xcframework

# What the app never ships: package installers, the IDE, the test suite and the interpreter binary.
strip_stdlib() {
    local lib=$1
    rm -rf "$lib"/{ensurepip,venv,idlelib,test,turtledemo,tkinter,turtle.py}
}
strip_stdlib "$mac/Versions/$version/lib/python$version"
rm -rf "$mac/Versions/$version/bin"
strip_stdlib "$ios/lib/python$version"
for slice in "$ios"/ios-*/lib-*/python$version; do strip_stdlib "$slice"; done
rm -rf "$vendor/iOS/testbed"

echo "Merging the Mac and iOS frameworks"
xcodebuild -create-xcframework \
    -framework "$mac" \
    -framework "$ios/ios-arm64/Python.framework" \
    -framework "$ios/ios-arm64_x86_64-simulator/Python.framework" \
    -output "$vendor/Python.xcframework" >/dev/null
# The merged copy holds the Mac framework; the separate one isn't needed.
rm -rf "$vendor/macOS"

echo "$stamp" > "$vendor/.fetched"
echo "Python $stamp is in $vendor"
