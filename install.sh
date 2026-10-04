#!/usr/bin/env bash
# install.sh — generate project, build, ad-hoc sign, install the .saver locally.
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null && xcodegen generate
xcodebuild -project Seasons.xcodeproj -scheme Seasons -configuration Debug build
DERIVED=$(xcodebuild -project Seasons.xcodeproj -scheme Seasons -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
SAVER="$DERIVED/Seasons.saver"
codesign --force --deep --sign - "$SAVER"
DEST="$HOME/Library/Screen Savers/Seasons.saver"
rm -rf "$DEST"
mkdir -p "$HOME/Library/Screen Savers"
cp -R "$SAVER" "$DEST"
echo "Installed to $DEST"
