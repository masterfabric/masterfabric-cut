#!/bin/bash
# MasterFabric Cut — build a Release .app and wrap it in a DMG.
#
#   scripts/make-dmg.sh [tag]
#
# Signing: macOS privacy permissions (Screen Recording, Accessibility) are tied to the app's code signature.
# The default ad-hoc signature ("-") is identified by its code hash, which changes on every build, so each new
# build looks like a different app and macOS asks for permissions again. Set MFC_SIGN_IDENTITY to a real
# certificate (e.g. "Apple Development: Your Name (TEAMID)" — free with an Apple ID in Xcode › Settings ›
# Accounts — or "Developer ID Application: …") and every future build keeps the same identity, so grants stick.
#   security find-identity -v -p codesigning   # list available identities
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-build}"
TS="$(date +%Y%m%d-%H%M)"

xcodegen generate >/dev/null
xcodebuild -project MasterFabricCut.xcodeproj -scheme MasterFabricCut -configuration Release -derivedDataPath build build \
  | grep -E "error:|BUILD" || true
APP="build/Build/Products/Release/MasterFabric Cut.app"
[ -d "$APP" ] || { echo "Release build missing: $APP" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

if [ -n "${MFC_SIGN_IDENTITY:-}" ]; then
  echo "Signing with: $MFC_SIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp=none \
    --entitlements Sources/App/MasterFabricCut.entitlements \
    --sign "$MFC_SIGN_IDENTITY" "$APP"
else
  echo "warning: MFC_SIGN_IDENTITY not set — ad-hoc signature; macOS will ask for Screen Recording/Accessibility again after this update." >&2
fi
codesign --verify --deep --strict "$APP"
codesign -dr - "$APP" 2>&1 | grep designated || true

STAGE="build/dmg/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MasterFabric Cut.app"
ln -s /Applications "$STAGE/Applications"
DMG="build/dmg/MasterFabric-Cut-${VERSION}-${TAG}-${TS}.dmg"
hdiutil create -volname "MasterFabric Cut" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
rm -rf "$STAGE"
echo "$DMG"
