#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ARGS=(--target CorniceKit --package-path "$ROOT" "$@")
swift build "${BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
COMPILER=(swiftc)
for ((i=0; i<${#BUILD_ARGS[@]}; i++)); do
    if [ "${BUILD_ARGS[i]}" = "--sdk" ]; then
        COMPILER+=(-sdk "${BUILD_ARGS[i+1]}")
    fi
done
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
# SwiftPM can produce either a combined object or separate object files.
if [ -f "$BUILD_DIR/CorniceKit.o" ]; then
    "${COMPILER[@]}" "$ROOT/Scripts/check-system.swift" -I "$BUILD_DIR" \
        "$BUILD_DIR/CorniceKit.o" -o "$CHECK_DIR/check-system"
else
    "${COMPILER[@]}" "$ROOT/Scripts/check-system.swift" -I "$BUILD_DIR/Modules" \
        "$BUILD_DIR/CorniceKit.build/"*.o -o "$CHECK_DIR/check-system"
fi
"$CHECK_DIR/check-system"
