#!/usr/bin/env bash
# release.sh — archive, notarize, staple and zip a signed AllskyMLCurator release.
#
# Usage: ./scripts/release.sh [--skip-notarize] [--skip-gh]
#
# What it does, in order:
#   1. Regenerates the Xcode project (xcodegen).
#   2. Runs xcodebuild archive into build/.
#   3. Exports a Developer ID signed .app via ExportOptions.plist.
#   4. Ditto-zips the exported .app.
#   5. xcrun notarytool submit --keychain-profile "$NOTARY_PROFILE" --wait
#      (Profile must be created once via `xcrun notarytool store-credentials`.)
#   6. xcrun stapler staple on the exported .app.
#   7. Re-zips the stapled .app into the final release artifact.
#   8. Creates a GitHub release with `gh`, uploading the zip.
#
# Prerequisites one-time setup:
#   brew install xcodegen
#   xcrun notarytool store-credentials "allskymlcurator-notary" \
#     --apple-id "joergklaas@mac.com" \
#     --team-id "<YOUR_TEAM_ID>" \
#     --password "<app-specific-password>"
#
# Pass --skip-notarize to run an unsigned / unnotarised local build; pass
# --skip-gh to leave the release artefact on disk without pushing it to
# GitHub. Both flags accumulate.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SKIP_NOTARIZE=0
SKIP_GH=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --skip-gh)       SKIP_GH=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

NOTARY_PROFILE="${NOTARY_PROFILE:-allskymlcurator-notary}"
SCHEME="AllskyMLCurator"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

# Read MARKETING_VERSION so the release tag / filename stay in sync.
VERSION="$(grep -E 'MARKETING_VERSION:' project.yml | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [[ -z "$VERSION" ]]; then
  echo "Could not parse MARKETING_VERSION from project.yml" >&2
  exit 1
fi
TAG="v$VERSION"
STAGE_ZIP="$BUILD_DIR/$SCHEME-$VERSION-unsigned.zip"
RELEASE_ZIP="$BUILD_DIR/$SCHEME-$VERSION.zip"

echo "===> Release $TAG from $(git rev-parse --short HEAD)"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree not clean — commit or stash before releasing." >&2
  exit 1
fi

echo "===> Regenerating Xcode project"
xcodegen generate

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "===> Archiving"
xcodebuild \
  -project "$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  | tail -n 20

# Minimal export options for Developer ID distribution. No specific team
# id here — Xcode uses the default signing identity in the user's login
# keychain. Adjust if you maintain multiple Apple Developer teams.
cat > "$EXPORT_OPTIONS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "===> Exporting signed .app"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -exportPath "$EXPORT_DIR" \
  | tail -n 20

APP_PATH="$EXPORT_DIR/$SCHEME.app"

echo "===> ditto-zipping for notarisation"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$STAGE_ZIP"

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  echo "===> Submitting to notarytool (profile: $NOTARY_PROFILE)"
  xcrun notarytool submit "$STAGE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "===> Stapling"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
else
  echo "===> SKIP_NOTARIZE set — leaving the build un-notarised"
fi

echo "===> Producing final zip"
rm -f "$RELEASE_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$RELEASE_ZIP"

if [[ "$SKIP_GH" -eq 0 ]]; then
  echo "===> Creating GitHub release $TAG"
  gh release create "$TAG" "$RELEASE_ZIP" \
    --title "$TAG" \
    --notes "Automated release built from $(git rev-parse --short HEAD). See commit log for details." \
    --latest
else
  echo "===> SKIP_GH set — artefact at $RELEASE_ZIP"
fi

echo "===> Done."
echo "    Artefact: $RELEASE_ZIP"
