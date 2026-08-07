# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`arcbox-kernel` provides optimized Linux kernel and initramfs builds for ArcBox VMs, targeting Apple Virtualization.framework (primary) and KVM (secondary).

Two kernel **flavors** build from the same source — do not conflate them:

- `system` (default): the System VM guest kernel (`configs/arcbox-{arch}.config`,
  artifact `kernel-{arch}`). Full container stack: netfilter, cgroups
  controllers, dm, overlayfs, NFS, HZ=1000/voluntary (ABX-498 tuning).
- `microvm`: the Firecracker sandbox guest kernel
  (`configs/arcbox-microvm-{arch}.config`, artifact `microvm-kernel-{arch}`).
  Optimized for kernel entry → PID 1 in the 200–300 ms class; virtio-mmio
  only, no PCI/EFI/netfilter/BPF, HZ=100/PREEMPT_NONE. The arches differ
  deliberately: arm64 runs NESTED inside the macOS System VM (DT
  discovery, PL031 RTC, no ACPI; consumed by boot-assets `upstream.toml`
  as the `vmlinux` binary, `install_dir = "kernel"`); x86_64 runs on
  bare-metal Linux KVM (ACPI boot + discovery, kvmclock, ELF vmlinux
  artifact, zstd initramfs + xz squashfs for the platform PaaS fleet;
  KVM boot-smoked in CI). Keep the per-arch assertion sets in
  build-kernel.sh in lockstep with any config edit.

A flavor's load-bearing symbols are asserted post-`olddefconfig` in
`scripts/build-kernel.sh` — extend the flavor's assertion list when adding a
symbol whose silent loss would only surface at guest runtime.

## Build Commands

```bash
# Build kernel (ARM64, requires Docker)
./scripts/build-kernel.sh

# Build kernel for x86_64
ARCH=x86_64 ./scripts/build-kernel.sh

# Build the Firecracker sandbox microVM kernel (arm64-only)
FLAVOR=microvm ./scripts/build-kernel.sh

# Build kernel with specific version
KERNEL_VERSION=6.18.0 ./scripts/build-kernel.sh

# Build initramfs (requires arcbox-agent binary)
./scripts/build-initramfs.sh

# Build initramfs with kernel modules (for standard kernels)
KERNEL_MODULES_DIR=/path/to/lib/modules ./scripts/build-initramfs.sh

# Package release
./scripts/package-release.sh v0.1.0
```

## Prerequisites

- Docker (for kernel cross-compilation)
- `arcbox-agent` binary at `../arcbox/target/aarch64-unknown-linux-musl/release/arcbox-agent`

Build arcbox-agent:
```bash
cd ../arcbox
cargo build -p arcbox-agent --target aarch64-unknown-linux-musl --release
```

## Architecture

```
arcbox-kernel/
├── configs/
│   ├── arcbox-arm64.config           # ARM64 System VM config (Apple Silicon)
│   ├── arcbox-x86_64.config          # x86_64 System VM config
│   └── arcbox-microvm-arm64.config   # ARM64 Firecracker sandbox config
├── scripts/
│   ├── build-kernel.sh         # Kernel build (Docker-based)
│   ├── build-initramfs.sh      # Initramfs build (Alpine + agent)
│   └── package-release.sh      # Release tarball packaging
├── output/                     # Build artifacts (gitignored)
│   ├── kernel-arm64
│   └── initramfs-arm64.cpio.gz
└── release/                    # Packaged releases (gitignored)
```

## Kernel Configuration

Key configs for macOS VM backends (VZ = Virtualization.framework, HV = Hypervisor.framework):

```
# Required for VirtioFS on macOS
CONFIG_VIRTIO_IOMMU=y

# Serial console: PL011 (VZ backend) + 8250/16550 (HV backend)
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y

# GPIO support (Virtualization.framework)
CONFIG_GPIOLIB=y
CONFIG_GPIO_PL061=y
CONFIG_GPIO_VIRTIO=y

# VirtIO devices
CONFIG_VIRTIO_FS=y
CONFIG_VIRTIO_VSOCKETS=y
CONFIG_FUSE_FS=y

# All drivers built-in (no modules)
CONFIG_MODULES=n
```

## Initramfs Contents

- Alpine Linux minirootfs (BusyBox)
- `arcbox-agent` - host-guest communication daemon
- Init script that mounts VirtioFS and starts agent on vsock port 1024

## Integration with ArcBox

Boot assets are downloaded to `~/.arcbox/boot/<version>/`:
```bash
# Check boot asset status
arcbox boot status

# Use custom kernel/initramfs
arcbox daemon --kernel /path/to/kernel --initramfs /path/to/initramfs.cpio.gz
```

## Performance Targets

| Metric | Target |
|--------|--------|
| Kernel size | < 10MB |
| Initramfs size | < 10MB |
| Boot time | < 1s |
