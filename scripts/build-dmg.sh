#!/usr/bin/env bash
set -euo pipefail

# Build, sign, notarize, and staple a Seasons DMG for distribution.
# Usage: ./scripts/build-dmg.sh
#
# Requires a "Developer ID Application" certificate in the login keychain and a notarytool
# keychain profile (default "TRCNotarize"), created once with:
#   xcrun notarytool store-credentials "<profile>" --apple-id ... --team-id ... --password ...
# Override with SIGN_IDENTITY and NOTARY_PROFILE.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
DERIVED="$BUILD_DIR/DerivedData"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: MDPSync LLC (4DW7P8P2PH)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-TRCNotarize}"

VERSION=$(grep 'MARKETING_VERSION:' "$PROJECT_DIR/project.yml" | head -1 | awk '{print $2}' | tr -d '"')
APP_PATH="$DERIVED/Build/Products/Release/Seasons.app"
DMG_PATH="$BUILD_DIR/Seasons-${VERSION}.dmg"
STAGING_DIR="$BUILD_DIR/dmg-staging"

echo "==> Building Seasons ${VERSION}"
cd "$PROJECT_DIR"
xcodegen generate
xcodebuild -project Seasons.xcodeproj -scheme SeasonsApp -configuration Release \
    -derivedDataPath "$DERIVED" build

echo "==> Signing app with hardened runtime"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

# Notarize and staple the app itself so it passes Gatekeeper offline after it leaves the DMG.
echo "==> Notarizing app"
APP_ZIP="$BUILD_DIR/Seasons-app-notary.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$APP_ZIP"
xcrun stapler staple "$APP_PATH"

echo "==> Creating DMG"
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/Seasons.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "Seasons" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING_DIR"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"

echo "==> Done: $DMG_PATH"
