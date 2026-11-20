#!/usr/bin/env bash
# Runs the unit tests. With only the Command Line Tools installed (no Xcode), SwiftPM needs
# to be pointed at the Swift Testing framework that ships with them.
set -euo pipefail
cd "$(dirname "$0")/.."

dev_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$dev_dir" == *CommandLineTools* ]]; then
    lib="$dev_dir/Library/Developer"
    exec swift test \
        -Xswiftc -F -Xswiftc "$lib/Frameworks" \
        -Xlinker -F -Xlinker "$lib/Frameworks" \
        -Xlinker -rpath -Xlinker "$lib/Frameworks" \
        -Xlinker -rpath -Xlinker "$lib/usr/lib" \
        "$@" 2> >(grep -v "^ld: warning: building for macOS" >&2)
fi
exec swift test "$@"
