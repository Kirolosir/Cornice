#!/usr/bin/env bash
# Build Cornice.app from the SwiftPM executable.
# The bundle is needed for permissions, notifications and launch at login.

set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Cornice"
BUNDLE_ID="dev.cornice.app"
BUILD_ARGS=(-c "$CONFIGURATION" --package-path "$ROOT" "${@:2}")
APP_DIR="$ROOT/dist/$APP_NAME.app"

# Use the latest tag for the version and the commit count for the build number.
VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.1.0")"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo "1")"

echo "==> Building ($CONFIGURATION)"
swift build "${BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

echo "==> Assembling $APP_NAME.app  version $VERSION ($BUILD_NUMBER)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE" ]; then
    echo "Sparkle framework is missing. Run swift package resolve first." >&2
    exit 1
fi
ditto "$SPARKLE" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
UPDATE_PUBLIC_KEY="$(cat "$ROOT/Resources/Updates/public-key.txt")"
cp "$ROOT/Resources/Updates/Sparkle-LICENSE.txt" "$APP_DIR/Contents/Resources/"

cp "$BUILD_DIR/cornice" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/Kirolosir/Cornice/main/Resources/Updates/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>$UPDATE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <key>SURequireSignedFeed</key>
    <true/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Accessory app: lives in the menu bar, no Dock icon, no app menu. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT licensed.</string>
    <!-- Explain why the app needs Music and Spotify automation. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Cornice reads what Music and Spotify are playing, and sends play, pause, skip, and seek commands when you use the controls in the panel.</string>
    <!-- Audio capture is requested when the visualizer is enabled. -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>Cornice reads the audio your Mac is playing so the visualiser follows the music. Audio is analysed in memory for the spectrum display and is never recorded, saved, or sent anywhere.</string>
    <!-- Callback for Spotify PKCE sign-in. The app checks the returned state. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>dev.cornice.app.callback</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>cornice</string>
            </array>
        </dict>
    </array>
    <!-- Spotify requests only happen after the user connects their account. -->
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Sign the nested helpers first, keeping their required entitlements.
echo "==> Signing"
IDENTITY="${CORNICE_SIGN_IDENTITY:--}"
FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
for helper in "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
              "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
              "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app"; do
    codesign --force --sign "$IDENTITY" --options runtime --preserve-metadata=entitlements "$helper"
done
codesign --force --sign "$IDENTITY" --options runtime "$FRAMEWORK"
codesign --force --sign "$IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> Built $APP_DIR"
