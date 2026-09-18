#!/usr/bin/env bash
#
# Assembles Cornice.app from the SwiftPM build product.
#
# SwiftPM produces a bare executable, but macOS needs a bundle for several
# things this app depends on: LSUIElement (no Dock icon), the Keychain access
# group implied by a bundle identifier, user notifications, and SMAppService
# for launch-at-login. All of those fail in ways that are confusing to debug
# when the binary is run loose, so the bundle is not optional.

set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Cornice"
BUNDLE_ID="dev.cornice.app"
BUILD_DIR="$ROOT/.build/$CONFIGURATION"
APP_DIR="$ROOT/dist/$APP_NAME.app"

# Version comes from the current tag when there is one, so a release build is
# labelled by the tag rather than by whatever is hardcoded in a plist.
VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.1.0")"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo "1")"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --package-path "$ROOT"

echo "==> Assembling $APP_NAME.app  version $VERSION ($BUILD_NUMBER)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

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
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Accessory app: lives in the menu bar, no Dock icon, no app menu. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT licensed.</string>
    <!-- Required before the app may send Apple events. macOS shows this string
         in the permission prompt, so it has to say what the app actually wants
         and why. Without it the first Apple event is refused outright. -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Cornice reads what Music and Spotify are playing, and sends play, pause, skip, and seek commands when you use the controls in the panel.</string>
    <!-- Required for the Core Audio process tap that drives the visualiser.
         Only requested when you turn the visualiser on in Settings. -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>Cornice reads the audio your Mac is playing so the visualiser follows the music. Audio is analysed in memory for the spectrum display and is never recorded, saved, or sent anywhere.</string>
    <!-- Registered so the Spotify sign-in can hand the browser somewhere to
         come back to. The redirect carries an authorization code that is
         useless without the PKCE verifier held in memory by the process that
         started the sign-in, and its state parameter is checked on arrival. -->
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
    <!-- Cornice talks to accounts.spotify.com and api.spotify.com, and only
         once you connect Spotify in Settings. It requests no camera,
         microphone, location, contacts, or full-disk access. -->
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

# An ad-hoc signature is enough for the app to run locally and for the Keychain
# to treat it as a stable identity across rebuilds. It is NOT notarization and
# will still show Gatekeeper's warning on another machine — see the README.
echo "==> Ad-hoc signing"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null \
    || echo "    (codesign unavailable; the bundle will still run locally)"

echo "==> Built $APP_DIR"
