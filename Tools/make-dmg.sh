#!/bin/zsh
# Empaquette build/EnhancedFileManager.app dans une image disque compressée :
#   build/EnhancedFileManager-<version>.dmg
# L'image contient l'application et un raccourci vers /Applications (glisser-déposer pour installer).
set -euo pipefail
cd "${0:A:h}/.."
APP=build/EnhancedFileManager.app
[[ -d "$APP" ]] || { echo "Lancez d'abord ./build.sh" >&2; exit 1 }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/EnhancedFileManager-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/Enhanced File Manager.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Enhanced File Manager" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
# L'image elle-même est signée avec la même identité que l'application.
codesign --force --timestamp=none --sign "${SIGN_IDENTITY:--}" "$DMG"
echo "$DMG"
