#!/bin/bash
set -e

# Release script: build, sign, notarize, staple, zip, and publish to GitHub.
#
# One-time setup:
#   1. Enroll in Apple Developer Program ($99/yr)
#   2. Create a "Developer ID Application" certificate in Apple Developer portal
#      and install it in your login keychain
#   3. Create an app-specific password at appleid.apple.com
#   4. Store notarization credentials in the keychain:
#        xcrun notarytool store-credentials ClaudeUsageNotary \
#          --apple-id you@example.com \
#          --team-id YOUR_TEAM_ID \
#          --password YOUR_APP_SPECIFIC_PASSWORD
#   5. Export env vars (or set here):
#        export DEVELOPER_ID="Developer ID Application: Your Name (TEAM_ID)"
#        export NOTARY_PROFILE="ClaudeUsageNotary"
#
# Usage:
#   ./Scripts/release.sh 1.0.0

VERSION="${1:?Usage: $0 <version> (e.g. 1.0.0)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="ClaudeUsage"
APP_BUNDLE="$PROJECT_DIR/build/$APP_NAME.app"
ZIP_PATH="$PROJECT_DIR/build/$APP_NAME-$VERSION.zip"
ENTITLEMENTS="$PROJECT_DIR/Resources/$APP_NAME.entitlements"

: "${DEVELOPER_ID:?Set DEVELOPER_ID env var (e.g. 'Developer ID Application: Name (TEAM_ID)')}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE env var (keychain profile name from notarytool store-credentials)}"

cd "$PROJECT_DIR"

echo "==> Building release binary..."
swift build -c release

echo "==> Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.local.claude-usage</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Claude Usage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Code signing with hardened runtime..."
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID" \
    "$APP_BUNDLE"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "==> Zipping for notarization..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Submitting to notary service (this takes a few minutes)..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

echo "==> Re-zipping stapled app..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')

echo ""
echo "==> Release artifact: $ZIP_PATH"
echo "==> SHA256: $SHA256"
echo ""
echo "Next steps:"
echo "  1. Publish GitHub release:"
echo "       gh release create v$VERSION \"$ZIP_PATH\" --title \"v$VERSION\" --notes-file CHANGELOG.md"
echo "  2. Update homebrew/claude-usage-widget.rb with version $VERSION and sha256 $SHA256"
echo "  3. Commit and push the cask update"
