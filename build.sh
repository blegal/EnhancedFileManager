#!/bin/zsh
# Compile l'application et produit build/EnhancedFileManager.app
# Variables facultatives :
#   UNIVERSAL=1        binaire universel (Apple Silicon + Intel)
#   VERSION=1.2.0      numéro de version écrit dans Info.plist
#   BUILD_NUMBER=42    numéro de build écrit dans Info.plist
#   SIGN_IDENTITY=…    identité de signature (par défaut : signature ad hoc « - »)
set -euo pipefail
cd "${0:A:h}"
CONFIG=${1:-release}
ARCH_FLAGS=()
[[ "${UNIVERSAL:-0}" == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/EnhancedFileManager"
APP=build/EnhancedFileManager.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
PLIST="$APP/Contents/Info.plist"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
codesign --force --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP" >/dev/null
echo "$APP"
