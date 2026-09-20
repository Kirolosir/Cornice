#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICON_DIR"
trap 'rm -rf "$(dirname "$ICON_DIR")"' EXIT

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/Resources/AppIcon.png" --out "$ICON_DIR/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$ROOT/Resources/AppIcon.png" --out "$ICON_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICON_DIR" -o "$ROOT/Resources/AppIcon.icns"
