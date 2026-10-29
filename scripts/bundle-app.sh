#!/bin/zsh
# Usage: bundle-app.sh [--release] [--open]
# Default: ad-hoc signed build/SplashGUI.app for local dev.
# --release: Developer ID + hardened runtime + timestamp, then a notarized, stapled
# build/SplashGUI-<version>.dmg. Requires SIGN_IDENTITY (a "Developer ID Application"
# identity) and NOTARY_PROFILE (a notarytool keychain profile) in the environment.
# The engine is downloaded by the app at runtime, so only the app's own binary is signed.
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP="build/SplashGUI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SplashGUI "$APP/Contents/MacOS/SplashGUI"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ " $* " == *" --release "* ]]; then
  : "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile}"
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
  DMG="build/SplashGUI-$VERSION.dmg"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  staging=$(mktemp -d -t splashgui-dmg)
  ditto "$APP" "$staging/SplashGUI.app"
  ln -s /Applications "$staging/Applications"
  rm -f "$DMG"
  diskutil image create from --format UDZO --volumeName "SplashGUI $VERSION" "$staging" "$DMG"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
  spctl --assess -vv "$APP"
  echo "built $DMG"
else
  codesign --force --sign - "$APP" 2>/dev/null
fi

if [[ " $* " == *" --open "* ]]; then
  open "$APP"
fi

echo "built $APP"
