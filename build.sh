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
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    # Une compilation par architecture puis lipo : la compilation multi-architecture
    # en une passe (XCBuild) échoue sur le plugin de SwiftTerm.
    # Chaque tranche est copiée aussitôt : selon la version de SwiftPM, le dossier de sortie est commun.
    SLICES=()
    mkdir -p build/slices
    for ARCH in arm64 x86_64; do
        TRIPLE="$ARCH-apple-macosx26.0"
        swift build -c "$CONFIG" --triple "$TRIPLE"
        cp "$(swift build -c "$CONFIG" --triple "$TRIPLE" --show-bin-path)/EnhancedFileManager" "build/slices/$ARCH"
        SLICES+=("build/slices/$ARCH")
    done
    BIN=build/EnhancedFileManager-universal
    lipo -create -output "$BIN" "${SLICES[@]}"
else
    swift build -c "$CONFIG"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/EnhancedFileManager"
fi
APP=build/EnhancedFileManager.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/EnhancedFileManager"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
PLIST="$APP/Contents/Info.plist"
[[ -n "${VERSION:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
[[ -n "${BUILD_NUMBER:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
codesign --force --timestamp=none --sign "${SIGN_IDENTITY:--}" "$APP" >/dev/null
echo "$APP"
