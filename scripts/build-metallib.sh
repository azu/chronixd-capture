#!/bin/bash
# Build MLX metallib for SPM CLI builds.
# SPM does not compile .metal files, so we do it manually.
# Run after: swift package clean, or when metallib is missing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
METAL_DIR="$REPO_ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
BUILD_DIR="$REPO_ROOT/.build/arm64-apple-macosx/release"
BUNDLE_DIR="$BUILD_DIR/mlx-swift_Cmlx.bundle"
TMP_DIR="$(mktemp -d)"

if [ ! -d "$METAL_DIR" ]; then
    echo "Error: Metal shader directory not found. Run 'swift build --disable-sandbox -c release' first."
    exit 1
fi

echo "Compiling Metal shaders..."
for f in "$METAL_DIR"/*.metal; do
    base=$(basename "$f" .metal)
    xcrun metal -c -I "$METAL_DIR" -I "$METAL_DIR/steel" "$f" -o "$TMP_DIR/$base.air"
done

echo "Linking metallib..."
xcrun metallib "$TMP_DIR"/*.air -o "$TMP_DIR/default.metallib"

echo "Installing to $BUNDLE_DIR..."
mkdir -p "$BUNDLE_DIR"
cp "$TMP_DIR/default.metallib" "$BUNDLE_DIR/default.metallib"

rm -rf "$TMP_DIR"
echo "Done. metallib installed at $BUNDLE_DIR/default.metallib"
