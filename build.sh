#!/bin/bash
# Builds Peek.app into ./build (works with Xcode or just the Command Line Tools).
# Usage: ./build.sh   (or: make build). Set PEEK_SIGN_IDENTITY to sign with another certificate.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64

APP="build/Peek.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN/Peek" "$APP/Contents/MacOS/Peek"

# Any-app now-playing bridge (runs inside /usr/bin/perl).
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -mmacosx-version-min=14.0 \
  -framework Foundation -framework AppKit \
  Helpers/PeekMediaRemote.m -o "$APP/Contents/Resources/PeekMediaRemote.dylib"
cp Helpers/peek-mediaremote.pl "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Peek</string>
  <key>CFBundleExecutable</key><string>Peek</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>dev.peek.notch</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Peek</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__VERSION__</string>
  <key>CFBundleVersion</key><string>__BUILD__</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Peek reads the current song from Music or Spotify and controls play, pause, skip and volume from the notch.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Peek shows your upcoming events in the notch and lets you join meeting links. Calendar data stays on this Mac.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Peek shows your upcoming events in the notch.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Peek shows today's reminders in the notch so you can tick them off or add new ones.</string>
  <key>NSRemindersUsageDescription</key>
  <string>Peek shows today's reminders in the notch.</string>
  <key>NSLocationUsageDescription</key>
  <string>Peek uses your approximate location only to show local weather.</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Peek uses your approximate location only to show local weather.</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Peek notices when Bluetooth devices like AirPods, speakers or a mouse connect, to show their battery level.</string>
</dict>
</plist>
PLIST

VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
sed -i '' "s/__VERSION__/$VERSION/; s/__BUILD__/$BUILD/" "$APP/Contents/Info.plist"

# Sign with a fixed local certificate when it exists, so macOS keeps Peek's
# permissions (Calendar, Location, Bluetooth, Automation) across rebuilds.
# Ad-hoc signatures change on every build and make macOS forget them.
IDENTITY="${PEEK_SIGN_IDENTITY:-Peek Local Signing}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  SIGN=(--sign "$IDENTITY" -r="designated => identifier \"dev.peek.notch\" and certificate leaf = H\"$(security find-certificate -c "$IDENTITY" -Z | awk '/SHA-1/{print $NF}')\"")
  echo "Signing with \"$IDENTITY\""
else
  SIGN=(--sign -)
  echo "No \"$IDENTITY\" certificate — ad-hoc signing (permissions reset on each build)"
fi
codesign --force "${SIGN[0]}" "${SIGN[1]}" "$APP/Contents/Resources/PeekMediaRemote.dylib"
codesign --force "${SIGN[@]}" "$APP"
echo "Built $APP"
