#!/bin/bash
# Build initramfs for ArcBox
#
# Usage:
#   ./build-initramfs.sh                 # Build for ARM64 (no modules)
#   ARCH=x86_64 ./build-initramfs.sh     # Build for x86_64 (no modules)
#
# With kernel modules (for kernels that need them):
#   KERNEL_MODULES_DIR=/path/to/lib/modules ./build-initramfs.sh
#
# The KERNEL_MODULES_DIR should contain the modules directory structure,
# e.g., /path/to/lib/modules/6.12.51-0-lts/

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ARCBOX_DIR="$(dirname "$PROJECT_DIR")/arcbox"

# Configuration
TARGET_ARCH="${ARCH:-arm64}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/output}"
WORK_DIR="/tmp/arcbox-initramfs-$$"
ALPINE_VERSION="3.21"
KERNEL_MODULES_DIR="${KERNEL_MODULES_DIR:-}"

# Rust target mapping
if [ "$TARGET_ARCH" = "arm64" ]; then
    RUST_TARGET="aarch64-unknown-linux-musl"
    ALPINE_ARCH="aarch64"
elif [ "$TARGET_ARCH" = "x86_64" ]; then
    RUST_TARGET="x86_64-unknown-linux-musl"
    ALPINE_ARCH="x86_64"
else
    echo "Error: Unsupported architecture: $TARGET_ARCH"
    exit 1
fi

# Agent binary location
AGENT_BIN="$ARCBOX_DIR/target/$RUST_TARGET/release/arcbox-agent"

echo "========================================"
echo "  ArcBox Initramfs Build"
echo "========================================"
echo ""
echo "  Target Arch:    $TARGET_ARCH"
echo "  Rust Target:    $RUST_TARGET"
echo "  Agent Binary:   $AGENT_BIN"
echo "  Output Dir:     $OUTPUT_DIR"
if [ -n "$KERNEL_MODULES_DIR" ]; then
    echo "  Modules Dir:    $KERNEL_MODULES_DIR"
else
    echo "  Modules:        (none - using built-in kernel)"
fi
echo ""

# Check agent binary
if [ ! -f "$AGENT_BIN" ]; then
    echo "Error: arcbox-agent not found at $AGENT_BIN"
    echo ""
    echo "Build it with:"
    echo "  cd $ARCBOX_DIR"
    echo "  cargo build -p arcbox-agent --target $RUST_TARGET --release"
    exit 1
fi

# Create directories
mkdir -p "$OUTPUT_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

cd "$WORK_DIR"

echo "Downloading Alpine Linux minirootfs..."
curl -sL "https://dl-cdn.alpinelinux.org/alpine/v$ALPINE_VERSION/releases/$ALPINE_ARCH/alpine-minirootfs-$ALPINE_VERSION.0-$ALPINE_ARCH.tar.gz" | tar -xz

echo "Setting up initramfs structure..."

# Create necessary directories
mkdir -p dev proc sys run tmp var/log var/run

# Create essential device nodes (will be populated by devtmpfs)
mkdir -p dev/pts dev/shm

# Create directories for VirtioFS mount
mkdir -p arcbox

# Copy arcbox-agent
echo "Adding arcbox-agent..."
cp "$AGENT_BIN" sbin/arcbox-agent
chmod 755 sbin/arcbox-agent

# Verify binary
file sbin/arcbox-agent

# Copy kernel modules if provided
if [ -n "$KERNEL_MODULES_DIR" ] && [ -d "$KERNEL_MODULES_DIR" ]; then
    echo "Copying kernel modules..."
    mkdir -p lib/modules
    cp -r "$KERNEL_MODULES_DIR"/* lib/modules/
    # Run depmod to generate modules.dep if possible
    if command -v depmod >/dev/null 2>&1; then
        KERNEL_VER=$(ls lib/modules | head -1)
        depmod -b . "$KERNEL_VER" 2>/dev/null || true
    fi
    ls -la lib/modules/
fi

# Create init script
echo "Creating init script..."
cat > init << 'INIT_SCRIPT'
#!/bin/sh
# ArcBox Guest VM Init Script

# Mount essential filesystems FIRST (before any device access)
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Now redirect stdout/stderr to console (after devtmpfs is mounted)
exec > /dev/console 2>&1

# Create device nodes
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp

# Set hostname
hostname arcbox-vm

# Print boot message
echo "=================================="
echo "  ArcBox Guest VM Starting..."
echo "=================================="
echo ""

# Display kernel info
echo "Kernel: $(uname -r)"
echo "Arch:   $(uname -m)"
echo ""

# Load kernel modules if available
if [ -d /lib/modules ]; then
    KVER=$(uname -r)
    if [ -d "/lib/modules/$KVER" ]; then
        echo "Loading kernel modules..."
        # Load fuse/virtiofs modules (needed for VirtioFS mount)
        modprobe fuse 2>/dev/null && echo "  Loaded: fuse" || true
        modprobe virtiofs 2>/dev/null && echo "  Loaded: virtiofs" || true
        # Load vsock modules in correct order
        modprobe vsock 2>/dev/null && echo "  Loaded: vsock" || true
        modprobe vmw_vsock_virtio_transport_common 2>/dev/null && echo "  Loaded: vmw_vsock_virtio_transport_common" || true
        modprobe vmw_vsock_virtio_transport 2>/dev/null && echo "  Loaded: vmw_vsock_virtio_transport" || true
        sleep 1
        echo ""
    fi
fi

# Mount VirtioFS for host data sharing
echo "Mounting VirtioFS..."
mkdir -p /arcbox
if mount -t virtiofs arcbox /arcbox 2>/dev/null; then
    echo "  VirtioFS mounted at /arcbox"
    ls -la /arcbox 2>/dev/null | head -5
else
    echo "  VirtioFS not available (this is OK if not configured)"
fi
echo ""

# Check vsock device
echo "Checking vsock..."
if [ -e /dev/vsock ]; then
    echo "  /dev/vsock exists"
elif [ -c /dev/vhost-vsock ]; then
    echo "  /dev/vhost-vsock exists"
    # Create vsock device if missing
    mknod /dev/vsock c 10 $(cat /sys/class/misc/vsock/dev | cut -d: -f2) 2>/dev/null || true
fi
echo ""

# Start arcbox-agent
echo "Starting arcbox-agent on vsock port 1024..."
echo "=================================="

# Run agent in foreground with tracing
RUST_LOG=arcbox_agent=info exec /sbin/arcbox-agent
INIT_SCRIPT
chmod 755 init

# Create a simple /etc/passwd and /etc/group
cat > etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/sh
EOF

cat > etc/group << 'EOF'
root:x:0:
EOF

# Create nsswitch.conf
cat > etc/nsswitch.conf << 'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
netgroup: files
EOF

# Pack initramfs
echo ""
echo "Creating initramfs..."
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$OUTPUT_DIR/initramfs-$TARGET_ARCH.cpio.gz"

# Cleanup
rm -rf "$WORK_DIR"

echo ""
echo "========================================"
echo "  Build Complete!"
echo "========================================"
echo ""
echo "  Output: $OUTPUT_DIR/initramfs-$TARGET_ARCH.cpio.gz"
ls -lh "$OUTPUT_DIR/initramfs-$TARGET_ARCH.cpio.gz"
