#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ARGS=(--target CorniceKit --package-path "$ROOT" "$@")
swift build "${BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
COMPILER_ARGS=()
for ((i=0; i<${#BUILD_ARGS[@]}; i++)); do
    if [ "${BUILD_ARGS[i]}" = "--sdk" ]; then
        COMPILER_ARGS+=(-sdk "${BUILD_ARGS[i+1]}")
    fi
done
CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "$CHECK_DIR"' EXIT
# SwiftPM can produce either a combined object or separate object files.
if [ -f "$BUILD_DIR/CorniceKit.o" ]; then
    swiftc "${COMPILER_ARGS[@]}" "$ROOT/Scripts/check-features.swift" -I "$BUILD_DIR" \
        "$BUILD_DIR/CorniceKit.o" -o "$CHECK_DIR/check-features"
else
    swiftc "${COMPILER_ARGS[@]}" "$ROOT/Scripts/check-features.swift" -I "$BUILD_DIR/Modules" \
        "$BUILD_DIR/CorniceKit.build/"*.o -o "$CHECK_DIR/check-features"
fi
"$CHECK_DIR/check-features"
