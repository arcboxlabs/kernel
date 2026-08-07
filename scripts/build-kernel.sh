#!/bin/bash
# Build Linux kernel for ArcBox
#
# Usage:
#   ./build-kernel.sh                    # Build System VM kernel for ARM64
#   ARCH=x86_64 ./build-kernel.sh        # Build for x86_64
#   FLAVOR=microvm ./build-kernel.sh     # Build the sandbox microVM kernel
#   KERNEL_VERSION=6.18.0 ./build-kernel.sh  # Use specific version
#
# Flavors:
#   system  (default) — System VM guest kernel (VZ/HV backends),
#                       configs/arcbox-{arch}.config, output kernel-{arch}
#   microvm           — Firecracker sandbox guest kernel (arm64 only),
#                       configs/arcbox-microvm-{arch}.config,
#                       output microvm-kernel-{arch}

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
KERNEL_VERSION="${KERNEL_VERSION:-6.18.38}"
TARGET_ARCH="${ARCH:-arm64}"
FLAVOR="${FLAVOR:-system}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
CONFIG_DIR="$PROJECT_DIR/configs"

# Determine architecture parameters
if [ "$TARGET_ARCH" = "arm64" ]; then
    CROSS_COMPILE="aarch64-linux-gnu-"
    KERNEL_IMAGE="Image"
elif [ "$TARGET_ARCH" = "x86_64" ]; then
    CROSS_COMPILE=""
    KERNEL_IMAGE="bzImage"
else
    echo "Error: Unsupported architecture: $TARGET_ARCH"
    exit 1
fi

# Determine flavor parameters: config file, output name, and the post-
# olddefconfig assertion sets. olddefconfig silently drops unknown or
# unsatisfiable symbols; each flavor asserts its load-bearing ones actually
# resolved (a renamed choice symbol or a new dependency gate in the fragment
# otherwise degrades silently — 6.18 did exactly that to the legacy iptables
# stack via NETFILTER_XTABLES_LEGACY).
if [ "$FLAVOR" = "system" ]; then
    CONFIG_FILE="$CONFIG_DIR/arcbox-$TARGET_ARCH.config"
    OUTPUT_NAME="kernel-$TARGET_ARCH"
    # CONFIG_PREEMPT_VOLUNTARY is load-bearing for container-teardown
    # latency (see the config comment); a future KERNEL_VERSION that drops
    # the voluntary choice must fail loudly here rather than silently fall
    # back to lazy/full.
    ASSERT_Y="CONFIG_SQUASHFS_DECOMP_MULTI_PERCPU CONFIG_IP_NF_NAT
              CONFIG_IP6_NF_NAT CONFIG_HZ_1000 CONFIG_PSI_DEFAULT_DISABLED
              CONFIG_PREEMPT_VOLUNTARY"
    ASSERT_N=""
elif [ "$FLAVOR" = "microvm" ]; then
    if [ "$TARGET_ARCH" != "arm64" ]; then
        echo "Error: microvm flavor is arm64-only (Firecracker x86_64 needs an ELF vmlinux and a separate config)"
        exit 1
    fi
    CONFIG_FILE="$CONFIG_DIR/arcbox-microvm-$TARGET_ARCH.config"
    OUTPUT_NAME="microvm-kernel-$TARGET_ARCH"
    # The Firecracker sandbox contract: virtio-mmio devices, vsock exec/PTY,
    # devtmpfs automount over the empty template /dev, static ip=, PL031 +
    # ptp_kvm clocks, VMGenID RNG reseed. Also assert that the deliberately
    # cut subsystems stayed cut (a fragment typo re-enabling PCI/netfilter
    # would otherwise ship silently).
    ASSERT_Y="CONFIG_VIRTIO_MMIO CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET
              CONFIG_VIRTIO_VSOCKETS CONFIG_DEVTMPFS_MOUNT CONFIG_IP_PNP
              CONFIG_UNIX98_PTYS CONFIG_EXT4_FS CONFIG_SERIAL_8250_CONSOLE
              CONFIG_RTC_DRV_PL031 CONFIG_PTP_1588_CLOCK_KVM CONFIG_VMGENID"
    ASSERT_N="CONFIG_PCI CONFIG_NETFILTER CONFIG_MODULES CONFIG_ACPI CONFIG_EFI"
else
    echo "Error: Unsupported flavor: $FLAVOR (expected 'system' or 'microvm')"
    exit 1
fi

# Collapse the multi-line assertion lists to one line: they are textually
# interpolated into the Docker build script, where an embedded newline would
# terminate the `for ... in` list early.
ASSERT_Y=$(echo $ASSERT_Y)
ASSERT_N=$(echo $ASSERT_N)

echo "========================================"
echo "  ArcBox Kernel Build"
echo "========================================"
echo ""
echo "  Kernel Version: $KERNEL_VERSION"
echo "  Target Arch:    $TARGET_ARCH"
echo "  Flavor:         $FLAVOR"
echo "  Output Dir:     $OUTPUT_DIR"
echo ""

# Check if config exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# ============================================================================
# Common build logic (called from both Docker and native paths)
# ============================================================================
# Expects:
#   - CWD = extracted kernel source root (linux-$KERNEL_VERSION)
#   - $ARCBOX_SRC = path to arcbox-kernel repo
#   - $TARGET_ARCH, $KERNEL_IMAGE, $CROSS_COMPILE set
#   - $CONFIG_FILE, $ASSERT_Y, $ASSERT_N set (flavor-resolved above)
#   - $OUTPUT_PATH = where to copy the final kernel binary
do_build() {
    local ARCBOX_SRC="$1"
    local OUTPUT_PATH="$2"

    # Inject custom drivers and patches.
    sh "$ARCBOX_SRC/scripts/inject-drivers.sh" "$ARCBOX_SRC"

    # Copy config and update for this kernel version.
    cp "$CONFIG_FILE" .config
    make ARCH=$TARGET_ARCH ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} olddefconfig

    for sym in $ASSERT_Y; do
        grep -q "^$sym=y" .config || {
            echo "ERROR: $sym missing after olddefconfig" >&2
            exit 1
        }
    done
    for sym in $ASSERT_N; do
        if grep -q "^$sym=y" .config; then
            echo "ERROR: $sym enabled after olddefconfig (must stay off)" >&2
            exit 1
        fi
    done

    # Build.
    echo "Building kernel..."
    make ARCH=$TARGET_ARCH ${CROSS_COMPILE:+CROSS_COMPILE=$CROSS_COMPILE} -j"$(nproc)" $KERNEL_IMAGE

    # Copy output.
    cp "arch/$TARGET_ARCH/boot/$KERNEL_IMAGE" "$OUTPUT_PATH"
    echo ""
    echo "Build complete!"
    ls -lh "$OUTPUT_PATH"
}

# ============================================================================
# Check if running in Docker or need to use Docker
# ============================================================================
if [ -f /.dockerenv ] || [ "${USE_DOCKER:-}" = "0" ]; then
    echo "Building natively..."
    BUILD_IN_DOCKER=0
else
    echo "Building in Docker..."
    BUILD_IN_DOCKER=1
fi

if [ "$BUILD_IN_DOCKER" = "1" ]; then
    # $ASSERT_Y/$ASSERT_N/$OUTPUT_NAME and the config basename are expanded
    # host-side into the container script, so both paths share one
    # flavor-resolution.
    docker run --rm \
        -v "$PROJECT_DIR:/workspace" \
        -v "$OUTPUT_DIR:/output" \
        -w /build \
        --platform "linux/$TARGET_ARCH" \
        "${DOCKER_IMAGE:-alpine:latest}" \
        sh -c "
set -e
apk add --no-cache build-base bc bison flex openssl-dev elfutils-dev perl curl xz cpio linux-headers ncurses-dev
echo 'Downloading Linux kernel $KERNEL_VERSION...'
curl -L --retry 8 --retry-all-errors -o linux.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz
tar -xJf linux.tar.xz && rm linux.tar.xz
cd linux-$KERNEL_VERSION
sh /workspace/scripts/inject-drivers.sh /workspace
cp /workspace/configs/$(basename "$CONFIG_FILE") .config
make ARCH=$TARGET_ARCH olddefconfig
for sym in $ASSERT_Y; do
    grep -q \"^\$sym=y\" .config || {
        echo \"ERROR: \$sym missing after olddefconfig\" >&2
        exit 1
    }
done
for sym in $ASSERT_N; do
    if grep -q \"^\$sym=y\" .config; then
        echo \"ERROR: \$sym enabled after olddefconfig (must stay off)\" >&2
        exit 1
    fi
done
echo 'Building kernel...'
make ARCH=$TARGET_ARCH -j\$(nproc) $KERNEL_IMAGE
cp arch/$TARGET_ARCH/boot/$KERNEL_IMAGE /output/$OUTPUT_NAME
echo 'Build complete!'
ls -lh /output/$OUTPUT_NAME
"
else
    BUILD_DIR="/tmp/arcbox-kernel-build-$$"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    echo "Downloading Linux kernel $KERNEL_VERSION..."
    curl -L --retry 8 --retry-all-errors -o "linux.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
    echo "Extracting..."
    tar -xJf "linux.tar.xz"
    rm "linux.tar.xz"
    cd "linux-$KERNEL_VERSION"

    do_build "$PROJECT_DIR" "$OUTPUT_DIR/$OUTPUT_NAME"

    rm -rf "$BUILD_DIR"
fi

echo ""
echo "========================================"
echo "  Build Complete!"
echo "========================================"
echo ""
echo "  Output: $OUTPUT_DIR/$OUTPUT_NAME"
ls -lh "$OUTPUT_DIR/$OUTPUT_NAME"
