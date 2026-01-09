#!/bin/bash
# Package ArcBox kernel and initramfs for release
#
# Usage:
#   ./package-release.sh v0.1.0

set -e

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

# Strip 'v' prefix for directory naming
VERSION_NUM="${VERSION#v}"

echo "========================================"
echo "  ArcBox Kernel Release Packaging"
echo "========================================"
echo ""
echo "  Version: $VERSION"
echo ""

# Create release directory
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Package each architecture
for ARCH in arm64 x86_64; do
    KERNEL="$OUTPUT_DIR/kernel-$ARCH"
    INITRAMFS="$OUTPUT_DIR/initramfs-$ARCH.cpio.gz"

    if [ ! -f "$KERNEL" ]; then
        echo "Warning: kernel-$ARCH not found, skipping"
        continue
    fi

    if [ ! -f "$INITRAMFS" ]; then
        echo "Warning: initramfs-$ARCH.cpio.gz not found, skipping"
        continue
    fi

    echo "Packaging $ARCH..."

    BUNDLE_NAME="arcbox-kernel-$ARCH-$VERSION_NUM"
    BUNDLE_DIR="$RELEASE_DIR/$BUNDLE_NAME"

    mkdir -p "$BUNDLE_DIR"
    cp "$KERNEL" "$BUNDLE_DIR/kernel"
    cp "$INITRAMFS" "$BUNDLE_DIR/initramfs.cpio.gz"

    # Create VERSION file
    echo "$VERSION" > "$BUNDLE_DIR/VERSION"

    # Create tar.gz
    cd "$RELEASE_DIR"
    tar -czvf "$BUNDLE_NAME.tar.gz" "$BUNDLE_NAME"

    # Create checksum
    sha256sum "$BUNDLE_NAME.tar.gz" > "$BUNDLE_NAME.tar.gz.sha256"

    # Cleanup
    rm -rf "$BUNDLE_DIR"

    echo "  Created: $BUNDLE_NAME.tar.gz"
done

echo ""
echo "========================================"
echo "  Packaging Complete!"
echo "========================================"
echo ""
echo "Release files:"
ls -lh "$RELEASE_DIR"/*.tar.gz 2>/dev/null || echo "  (none)"
echo ""
echo "Checksums:"
cat "$RELEASE_DIR"/*.sha256 2>/dev/null || echo "  (none)"
