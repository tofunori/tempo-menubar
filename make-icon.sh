#!/bin/bash
# Redessine l'icône de l'app et produit Resources/AppIcon.icns, plus docs/icon.png pour le README.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release >/dev/null
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

.build/release/Tempo --app-icon "$WORK/icon_1024.png" >/dev/null

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$WORK/icon_1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$WORK/icon_1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o Resources/AppIcon.icns
sips -z 256 256 "$WORK/icon_1024.png" --out docs/icon.png >/dev/null
echo "Resources/AppIcon.icns"
