#!/bin/sh
# Sanity-checks the wattusb.app bundle produced by build.sh.
#
#   scripts/verify-app.sh [expected-version]
set -eu
cd "$(dirname "$0")/.."

app=wattusb.app
plist=$app/Contents/Info.plist
bin=$app/Contents/MacOS/wattusb

plutil -lint "$plist"

archs=$(lipo -archs "$bin")
for arch in arm64 x86_64; do
  case " $archs " in
    *" $arch "*) ;;
    *) echo "Binary is missing $arch (has: $archs)" >&2; exit 1 ;;
  esac
done
echo "Architectures: $archs"

codesign --verify --strict --verbose=2 "$app"

if [ -n "${1:-}" ]; then
  actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
  if [ "$actual" != "$1" ]; then
    echo "Bundle version is $actual, expected $1" >&2
    exit 1
  fi
  echo "Version: $actual"
fi

# Launch smoke test: the app should start and keep running.
"$bin" &
pid=$!
sleep 5
if ! kill -0 "$pid" 2>/dev/null; then
  wait "$pid" || status=$?
  echo "wattusb exited during launch (status ${status:-0})" >&2
  exit 1
fi
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
echo "Launch smoke test passed"
