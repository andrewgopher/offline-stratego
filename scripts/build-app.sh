#!/usr/bin/env bash
# Builds dist/OfflineBarrage.app (universal: Apple silicon + Intel) and dist/OfflineBarrage.zip.
#
# Requires only the Xcode Command Line Tools (`xcode-select --install`).
# Override the architectures with e.g.:  ARCHS=arm64 ./scripts/build-app.sh
#
# The app is assembled in a temporary folder and only moved into dist/ once it is complete, so a
# failed build never leaves behind a bundle without its executable.
set -euo pipefail

cd "$(dirname "$0")/.."

ARCHS="${ARCHS:-arm64 x86_64}"
NATIVE_ARCH="$(uname -m)"
APP="dist/OfflineBarrage.app"
ZIP="dist/OfflineBarrage.zip"

fail() {
    echo "error: $*" >&2
    exit 1
}

echo "==> Toolchain: $(swift --version 2>&1 | head -n 1)"
echo "==> macOS $(sw_vers -productVersion) on $NATIVE_ARCH"

# Remove the previous result first, so a failed build can't be mistaken for a working one.
rm -rf "$APP" "$ZIP"
mkdir -p dist
STAGE="$(mktemp -d dist/.build-app.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

binaries=()
for arch in $ARCHS; do
    echo "==> Building for $arch"
    bin=""
    if swift build -c release --arch "$arch" --product OfflineBarrage; then
        bin="$(swift build -c release --arch "$arch" --show-bin-path)/OfflineBarrage"
        if [ ! -f "$bin" ]; then
            echo "warning: swift build succeeded, but $bin doesn't exist" >&2
            bin=""
        fi
    fi
    if [ -n "$bin" ]; then
        binaries+=("$bin")
    elif [ "$arch" != "$NATIVE_ARCH" ]; then
        echo "warning: building for $arch failed; continuing without it" >&2
    else
        fail "building for $arch (this Mac) failed; see the output above"
    fi
done

[ "${#binaries[@]}" -gt 0 ] || fail "nothing was built"

echo "==> Assembling $APP"
staged="$STAGE/OfflineBarrage.app"
mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources"
lipo -create "${binaries[@]}" -output "$staged/Contents/MacOS/OfflineBarrage" \
    || fail "lipo couldn't combine: ${binaries[*]}"
[ -x "$staged/Contents/MacOS/OfflineBarrage" ] || fail "the app's executable wasn't created"
cp Support/Info.plist "$staged/Contents/Info.plist"
printf 'APPL????' > "$staged/Contents/PkgInfo"

echo "==> Signing (ad hoc)"
codesign --force --sign - "$staged" || fail "codesign failed"

mv "$staged" "$APP"

echo "==> Zipping"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/OfflineBarrage"))"
echo "Run it with:  open $APP"
