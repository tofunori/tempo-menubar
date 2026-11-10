#!/bin/bash
# Prépare une version téléchargeable : Tempo.app universelle (Apple silicon et Intel), zippée dans dist/.
# Usage : ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

swift test
swift build -c release --arch arm64 --arch x86_64
# L'emplacement du binaire universel change d'une version de SwiftPM à l'autre : on le demande.
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tempo"

APP="dist/Tempo.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tempo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

ZIP="dist/Tempo-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Architectures : $(lipo -archs "$APP/Contents/MacOS/Tempo")"
echo "$ZIP"
