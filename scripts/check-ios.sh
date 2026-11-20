#!/usr/bin/env bash
# Checks the iPhone/iPad app without Xcode, using only the Command Line Tools.
#
# The iOS SDK ships with Xcode, but the macOS SDK carries the iOS frameworks that Mac Catalyst
# apps use. Building the app for Mac Catalyst compiles every iOS code path (`#if os(iOS)`)
# against the iOS API surface, so anything unavailable on iOS fails here too.
#
#     ./scripts/check-ios.sh                       # compile only
#     ./scripts/check-ios.sh snapshots DIR         # also render the iOS UI (iPhone size) to DIR
#     ./scripts/check-ios.sh snapshots DIR 820x1180   # ...at another size (e.g. iPad portrait)
#     ./scripts/check-ios.sh app                   # bundle it as .build/catalyst/OfflineBarrage.app
#
# The app built here runs on this Mac with the iOS interface, which is handy for trying the
# iOS layouts and lifecycle; to put the app on an iPhone, use iOS/OfflineBarrage.xcodeproj.
set -euo pipefail
cd "$(dirname "$0")/.."

sdk="$(xcrun --show-sdk-path)"
ios="$sdk/System/iOSSupport"
scratch=".build/catalyst"
arch="$(uname -m)"

echo "==> Building for Mac Catalyst ($arch)"
swift build --scratch-path "$scratch" --triple "$arch-apple-ios16.0-macabi" --product OfflineBarrage \
    -Xswiftc -Fsystem -Xswiftc "$ios/System/Library/Frameworks" \
    -Xswiftc -I -Xswiftc "$ios/usr/lib/swift" \
    -Xlinker -L -Xlinker "$ios/usr/lib/swift" \
    -Xlinker -F -Xlinker "$ios/System/Library/Frameworks"

mode="${1:-}"
[ -z "$mode" ] && { echo "The iOS code compiles."; exit 0; }

binary="$(find "$scratch" -path "*macabi/debug/OfflineBarrage" -type f | head -1)"
app="$scratch/OfflineBarrage.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$binary" "$app/Contents/MacOS/OfflineBarrage"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>OfflineBarrage</string>
	<key>CFBundleIdentifier</key><string>local.offlinebarrage.catalyst-check</string>
	<key>CFBundleName</key><string>Offline Barrage</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>UIDeviceFamily</key><array><integer>2</integer></array>
	<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
	<key>NSLocalNetworkUsageDescription</key><string>Offline Barrage uses peer-to-peer Wi-Fi to find nearby players.</string>
	<key>NSBonjourServices</key><array><string>_offline-barrage._tcp</string><string>_offline-barrage._udp</string></array>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1
echo "Built $app"

if [ "$mode" = "snapshots" ]; then
    out="${2:?usage: check-ios.sh snapshots DIR [WIDTHxHEIGHT]}"
    mkdir -p "$out"
    echo "==> Rendering the iOS interface to $out"
    OFFLINE_BARRAGE_PROFILE=snapshots OFFLINE_BARRAGE_SNAPSHOTS="$out" OFFLINE_BARRAGE_SNAPSHOT_SIZE="${3:-}" \
        "$app/Contents/MacOS/OfflineBarrage" &
    pid=$!
    for _ in $(seq 1 120); do
        sleep 1
        kill -0 "$pid" 2>/dev/null || break
    done
    kill "$pid" 2>/dev/null || true
    ls "$out"
fi
