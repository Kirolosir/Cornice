#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --package-path "$ROOT"
BUILD_DIR="$(swift build --package-path "$ROOT" --show-bin-path)"
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT

swiftc "$ROOT/Scripts/check-battery.swift" -I "$BUILD_DIR/Modules" \
    "$BUILD_DIR/CorniceKit.build/"*.o -o "$CHECK_DIR/check-battery"
"$CHECK_DIR/check-battery"
