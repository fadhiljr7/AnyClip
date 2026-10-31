#!/bin/zsh
# Builds a signed, notarized AnyClip.dmg for distribution outside the App Store.
#
# Needs, once:
#   - a "Developer ID Application" certificate for the team in the project (Xcode › Settings › Accounts)
#   - notarization credentials saved with:
#       xcrun notarytool store-credentials AnyClip --apple-id <you> --team-id A5P7HG9FVD
#
# Usage: Scripts/release.sh [output folder, default ./build/release]
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-build/release}"
ARCHIVE="$OUT/AnyClip.xcarchive"
EXPORT="$OUT/export"
OPTIONS="$OUT/ExportOptions.plist"

rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild test -scheme AnyClip -destination 'platform=macOS'
xcodebuild archive -scheme AnyClip -configuration Release -destination 'generic/platform=macOS' -archivePath "$ARCHIVE"

cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OPTIONS"

APP="$EXPORT/AnyClip.app"
DMG="$OUT/AnyClip.dmg"
hdiutil create -volname AnyClip -srcfolder "$APP" -ov -format UDZO "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile AnyClip --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
echo "Ready: $DMG"
