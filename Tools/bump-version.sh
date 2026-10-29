#!/bin/zsh
# Incrémente la version d'iExplorer avant chaque commit :
# dernier chiffre de CFBundleShortVersionString (0.2.1 → 0.2.2) et numéro de build.
#   Tools/bump-version.sh          → version corrective
#   Tools/bump-version.sh minor    → 0.2.5 → 0.3.0
#   Tools/bump-version.sh major    → 0.3.2 → 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."
PLIST=Resources/Info.plist
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
IFS=. read -r major minor patch <<< "$version"
if [[ "${1:-}" == major ]]; then major=$((major + 1)); minor=0; patch=0
elif [[ "${1:-}" == minor ]]; then minor=$((minor + 1)); patch=0; else patch=$((${patch:-0} + 1)); fi
# sed plutôt que PlistBuddy, qui reformaterait tout le fichier.
sed -i '' -e "s|<key>CFBundleShortVersionString</key><string>$version</string>|<key>CFBundleShortVersionString</key><string>$major.$minor.$patch</string>|" \
          -e "s|<key>CFBundleVersion</key><string>$build</string>|<key>CFBundleVersion</key><string>$((build + 1))</string>|" "$PLIST"
echo "$major.$minor.$patch ($((build + 1)))"
