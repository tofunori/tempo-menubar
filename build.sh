#!/bin/bash
# Compile Tempo et assemble build/Tempo.app.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Tempo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tempo "$APP/Contents/MacOS/Tempo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "$APP"
