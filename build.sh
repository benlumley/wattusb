#!/bin/sh
set -e
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64

rm -rf wattusb.app
mkdir -p wattusb.app/Contents/MacOS
cp .build/apple/Products/Release/wattusb wattusb.app/Contents/MacOS/
cp Sources/wattusb/Info.plist wattusb.app/Contents/

# Release builds stamp the version; local builds keep Info.plist as committed.
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" wattusb.app/Contents/Info.plist
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" wattusb.app/Contents/Info.plist
fi

codesign --force --sign - wattusb.app >/dev/null 2>&1 || true

echo "Built wattusb.app"
echo "Run:   open wattusb.app"
echo "Install: mv wattusb.app /Applications/"
