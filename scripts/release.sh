#!/bin/zsh
# release.sh: tag the current commit splashgui/v<version>, push main + the tag to origin,
# and create the GitHub release with the notarized DMG as its asset.
# Precondition: scripts/bundle-app.sh --release (builds, notarizes and staples the DMG).
# Auth: the `gh` CLI (run `gh auth login` once).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
TAG="splashgui/v${VERSION}"
DMG="build/SplashGUI-${VERSION}.dmg"

[[ -f "$DMG" ]] || { echo "error: $DMG not found; run scripts/bundle-app.sh --release first" >&2; exit 1; }
xcrun stapler validate -q "$DMG" || { echo "error: $DMG has no stapled notarization ticket" >&2; exit 1; }
git diff-index --quiet HEAD -- . || { echo "error: uncommitted changes; commit before releasing" >&2; exit 1; }
command -v gh >/dev/null || { echo "error: gh CLI not found; install it and run gh auth login" >&2; exit 1; }

if ! git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  git tag -a "$TAG" -m "SplashGUI v${VERSION}"
  echo "==> tagged ${TAG}"
fi
echo "==> pushing main + ${TAG} to origin"
git push origin main
git push origin "$TAG"

# Notes: app commits since the previous SplashGUI tag, plus the DMG checksum.
PREV=$(git describe --tags --abbrev=0 --match 'splashgui/v*' "${TAG}^" 2>/dev/null || true)
if [[ -n "$PREV" ]]; then
  NOTES=$(git log --no-merges --pretty='- %s' "${PREV}..${TAG}" -- .)
else
  NOTES="First Developer ID-signed, notarized release."
fi
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
NOTES="${NOTES}"$'\n\n'"SHA-256 (SplashGUI-${VERSION}.dmg): \`${SHA}\`"

echo "==> creating GitHub release ${TAG}"
gh release create "$TAG" "$DMG" --title "SplashGUI v${VERSION}" --notes "$NOTES"
echo "==> done"
