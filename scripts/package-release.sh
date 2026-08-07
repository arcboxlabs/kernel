#!/bin/bash
# Package ArcBox kernel binaries for local release.
#
# v6 schema: kernel-only, no initramfs.
#
# Usage:
#   ./package-release.sh v0.1.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
RELEASE_DIR="$PROJECT_DIR/release"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 v0.1.0"
    exit 1
fi

echo "========================================"
echo "  ArcBox Kernel Release Packaging"
echo "========================================"
echo ""
echo "  Version: $VERSION"
echo ""

rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

for NAME in kernel-arm64 kernel-x86_64 microvm-kernel-arm64; do
    KERNEL="$OUTPUT_DIR/$NAME"

    if [ ! -f "$KERNEL" ]; then
        echo "Warning: $NAME not found, skipping"
        continue
    fi

    echo "Packaging $NAME..."
    cp "$KERNEL" "$RELEASE_DIR/$NAME"
    sha256sum "$RELEASE_DIR/$NAME" > "$RELEASE_DIR/$NAME.sha256"
    echo "  Created: $NAME + $NAME.sha256"
done

echo ""
echo "========================================"
echo "  Packaging Complete!"
echo "========================================"
echo ""
echo "Release files:"
ls -lh "$RELEASE_DIR"/*kernel-* 2>/dev/null || echo "  (none)"
