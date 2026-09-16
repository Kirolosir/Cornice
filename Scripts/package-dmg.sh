#!/usr/bin/env bash
#
# Packages dist/Cornice.app into a DMG with an Applications symlink, so the
# install is the drag-and-drop one people expect.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Cornice.app"
DMG="$ROOT/dist/Cornice.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

if [ ! -d "$APP" ]; then
    echo "dist/Cornice.app not found. Run ./Scripts/bundle.sh first." >&2
    exit 1
fi

VERSION="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")"

echo "==> Staging"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating DMG"
rm -f "$DMG"
hdiutil create \
    -volname "Cornice $VERSION" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

echo "==> Built $DMG"
