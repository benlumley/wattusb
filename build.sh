#!/bin/sh
set -e
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64

rm -rf wattusb.app
mkdir -p wattusb.app/Contents/MacOS
cp .build/apple/Products/Release/wattusb wattusb.app/Contents/MacOS/
cp Sources/wattusb/Info.plist wattusb.app/Contents/

codesign --force --sign - wattusb.app >/dev/null 2>&1 || true

echo "Built wattusb.app"
echo "Run:   open wattusb.app"
echo "Install: mv wattusb.app /Applications/"
