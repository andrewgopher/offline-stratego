#!/usr/bin/env bash
# Builds dist/OfflineBarrage.app (universal: Apple silicon + Intel) and dist/OfflineBarrage.zip.
#
# Requires only the Xcode Command Line Tools (`xcode-select --install`).
# Override the architectures with e.g.:  ARCHS=arm64 ./scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHS="${ARCHS:-arm64 x86_64}"
NATIVE_ARCH="$(uname -m)"
APP="dist/OfflineBarrage.app"

binaries=()
for arch in $ARCHS; do
    echo "==> Building for $arch"
    if swift build -c release --arch "$arch" --product OfflineBarrage; then
        bin_dir="$(swift build -c release --arch "$arch" --show-bin-path)"
        binaries+=("$bin_dir/OfflineBarrage")
    elif [ "$arch" != "$NATIVE_ARCH" ]; then
        echo "warning: building for $arch failed; continuing without it" >&2
    else
        echo "error: build failed" >&2
        exit 1
    fi
done

if [ "${#binaries[@]}" -eq 0 ]; then
    echo "error: nothing was built" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/OfflineBarrage"
cp Support/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad hoc)"
codesign --force --sign - "$APP"

echo "==> Zipping"
rm -f dist/OfflineBarrage.zip
ditto -c -k --keepParent "$APP" dist/OfflineBarrage.zip

echo
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/OfflineBarrage"))"
echo "Run it with:  open $APP"
