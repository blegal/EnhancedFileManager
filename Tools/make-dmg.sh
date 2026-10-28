#!/bin/zsh
# Empaquette build/EnhancedFileManager.app dans une image disque compressée :
# build/EnhancedFileManager-<version>.dmg
# L'image contient l'application et un raccourci vers /Applications (glisser-déposer pour installer).
set -euo pipefail
cd "${0:A:h}/.."
PRODUCT=EnhancedFileManager
APP=build/$PRODUCT.app
[[ -d "$APP" ]] || { echo "Lancez d'abord ./build.sh (PRODUCT=$PRODUCT)" >&2; exit 1 }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$APP/Contents/Info.plist")
DMG="build/$PRODUCT-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/$NAME.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
# L'image elle-même est signée avec la même identité que l'application.
codesign --force --timestamp=none --sign "${SIGN_IDENTITY:--}" "$DMG"
echo "$DMG"
