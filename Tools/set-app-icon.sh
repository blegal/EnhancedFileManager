#!/bin/zsh
# Choisit l'icône de l'app parmi les propositions : Tools/set-app-icon.sh A|B|C|D
set -euo pipefail
cd "${0:A:h}/.."
CHOICE=${1:-A}
WORK=$(mktemp -d)
swiftc -O Tools/make-icons.swift -o "$WORK/make-icons" >/dev/null
"$WORK/make-icons" "$WORK" >/dev/null
SRC=$(ls "$WORK"/icone-"$CHOICE"-*.png)
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$WORK"
echo "Icône $CHOICE installée dans Resources/AppIcon.icns (relancez ./build.sh)"
