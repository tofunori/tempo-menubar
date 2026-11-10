#!/bin/bash
# Compile Tempo, l'installe dans /Applications et la relance.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh >/dev/null

pkill -x Tempo 2>/dev/null || true
sleep 1
rm -rf /Applications/Tempo.app
cp -R build/Tempo.app /Applications/Tempo.app
open /Applications/Tempo.app

echo "Tempo installée dans /Applications et relancée."
