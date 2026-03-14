#!/bin/sh
# Validates that the kernel config fragment contains all required options.
# Tests acceptance criterion 6: BPF, BPF_SYSCALL, BPF_JIT = y
# Also validates virtio, virtiofs, filesystem, and security options.
set -e

CONFIG_FILE="${1:-src/vm-image/kernel-config.fragment}"
PASS=0
FAIL=0

check_option() {
    option="$1"
    value="$2"
    if grep -q "^${option}=${value}$" "$CONFIG_FILE"; then
        PASS=$((PASS + 1))
        printf "  PASS: %s=%s\n" "$option" "$value"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s=%s not found\n" "$option" "$value"
    fi
}

check_disabled() {
    option="$1"
    if grep -q "^# ${option} is not set$" "$CONFIG_FILE"; then
        PASS=$((PASS + 1))
        printf "  PASS: %s is disabled\n" "$option"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s should be disabled\n" "$option"
    fi
}

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

echo "Validating kernel config: $CONFIG_FILE"
echo ""

# eBPF (acceptance criterion 6)
echo "--- eBPF ---"
check_option CONFIG_BPF y
check_option CONFIG_BPF_SYSCALL y
check_option CONFIG_BPF_JIT y
check_option CONFIG_BPF_JIT_ALWAYS_ON y
check_option CONFIG_CGROUP_BPF y

# Virtio (required for libkrun)
echo ""
echo "--- Virtio ---"
check_option CONFIG_VIRTIO y
check_option CONFIG_VIRTIO_PCI y
check_option CONFIG_VIRTIO_MMIO y
check_option CONFIG_VIRTIO_NET y
check_option CONFIG_VIRTIO_BLK y
check_option CONFIG_VIRTIO_CONSOLE y

# Virtiofs (acceptance criterion 5)
echo ""
echo "--- Virtiofs ---"
check_option CONFIG_FUSE_FS y
check_option CONFIG_VIRTIO_FS y

# Filesystems
echo ""
echo "--- Filesystems ---"
check_option CONFIG_EXT4_FS y
check_option CONFIG_TMPFS y
check_option CONFIG_PROC_FS y
check_option CONFIG_SYSFS y
check_option CONFIG_DEVTMPFS y
check_option CONFIG_DEVTMPFS_MOUNT y

# Networking
echo ""
echo "--- Networking ---"
check_option CONFIG_NET y
check_option CONFIG_INET y

# Security
echo ""
echo "--- Security ---"
check_option CONFIG_SECCOMP y
check_option CONFIG_SECCOMP_FILTER y

# Disabled subsystems (minimize attack surface)
echo ""
echo "--- Disabled ---"
check_disabled CONFIG_SOUND
check_disabled CONFIG_DRM
check_disabled CONFIG_USB_SUPPORT
check_disabled CONFIG_BLUETOOTH
check_disabled CONFIG_WIRELESS
check_disabled CONFIG_MODULES

echo ""
echo "--- Results ---"
TOTAL=$((PASS + FAIL))
echo "$PASS passed, $FAIL failed (of $TOTAL total)"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
