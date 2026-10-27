#!/bin/zsh
# Builds VoiceNotes.app.
#
#   ./build.sh             build build/VoiceNotes.app (ad-hoc signed)
#   ./build.sh --install   also copy to ~/Applications and launch
#   ./build.sh --dist      also produce a universal build/VoiceNotes-<version>.zip
#
# Most people should run ./setup.sh instead, which also installs Ollama and the models.
#
# For a public release, sign with your Developer ID and notarize:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=voicenotes ./build.sh --dist
# (create the profile once with: xcrun notarytool store-credentials voicenotes)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="${BUNDLE_ID:-local.projectq.voicenotes}"
APP="build/VoiceNotes.app"

# Release zips are universal (Apple Silicon + Intel); local builds target this Mac only,
# which also works with just the Command Line Tools installed.
ARCH_FLAGS=()
[[ "${1:-}" == "--dist" || -n "${UNIVERSAL:-}" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/VoiceNotes"

[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift Resources/AppIcon.icns

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoiceNotes"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VoiceNotes</string>
    <key>CFBundleDisplayName</key><string>Voice Notes</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>VoiceNotes</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© $(date +%Y)</string>
    <key>NSMicrophoneUsageDescription</key><string>Voice Notes listens while you dictate a note.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Voice Notes turns your speech into text on this Mac.</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --timestamp=none \
    --entitlements Resources/VoiceNotes.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (version $VERSION, build $BUILD_NUMBER)"

case "${1:-}" in
--install)
    pkill -x VoiceNotes || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/VoiceNotes.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/VoiceNotes.app
    echo "Installed and launched ~/Applications/VoiceNotes.app"
    ;;
--dist)
    ZIP="build/VoiceNotes-${VERSION}.zip"
    rm -f "$ZIP"
    if [[ "$SIGN_IDENTITY" != "-" ]]; then
        # Re-sign with a secure timestamp, which notarization requires.
        codesign --force --options runtime --timestamp \
            --entitlements Resources/VoiceNotes.entitlements \
            --sign "$SIGN_IDENTITY" "$APP"
    fi
    ditto -c -k --keepParent "$APP" "$ZIP"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        echo "Notarized and stapled."
    elif [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "Note: ad-hoc signed. Other Macs will block it unless signed with a Developer ID and notarized."
    fi
    echo "Created $ZIP"
    ;;
esac
