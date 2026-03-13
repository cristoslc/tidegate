#!/bin/sh
# Minimal init for Tidegate agent VM.
# Replaces systemd — mounts filesystems, configures networking,
# sets environment, and starts the agent process.
#
# This script runs as PID 1 inside the VM guest.

set -e

# Mount essential filesystems (only needed when booting as VM init,
# not when running in Docker)
if [ "$$" -eq 1 ]; then
    mount -t proc proc /proc 2>/dev/null || true
    mount -t sysfs sysfs /sys 2>/dev/null || true
    mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
    mount -t tmpfs tmpfs /tmp 2>/dev/null || true
    mount -t tmpfs tmpfs /run 2>/dev/null || true

    # Mount virtiofs workspace if available
    if grep -q virtiofs /proc/filesystems 2>/dev/null; then
        mount -t virtiofs workspace /workspace 2>/dev/null || true
    fi

    # Configure networking from kernel cmdline or DHCP
    if [ -f /proc/cmdline ]; then
        # Parse ip= from kernel cmdline (format: ip=<addr>::<gw>:<mask>)
        IP_ARG=$(cat /proc/cmdline | tr ' ' '\n' | grep '^ip=' | head -1)
        if [ -n "$IP_ARG" ]; then
            ADDR=$(echo "$IP_ARG" | sed 's/ip=//;s/::.*$//')
            GW=$(echo "$IP_ARG" | sed 's/.*::\([^:]*\):.*/\1/')
            ip addr add "$ADDR/24" dev eth0 2>/dev/null || true
            ip link set eth0 up 2>/dev/null || true
            ip route add default via "$GW" 2>/dev/null || true
        fi
    fi

    # Fall back to DHCP if no static IP
    if ! ip addr show eth0 2>/dev/null | grep -q 'inet '; then
        udhcpc -i eth0 -s /usr/share/udhcpc/default.script -q 2>/dev/null || true
    fi

    # Set hostname
    hostname tidegate-agent 2>/dev/null || true
fi

# Read proxy configuration from environment (set by launcher)
export HTTP_PROXY="${HTTP_PROXY:-}"
export HTTPS_PROXY="${HTTPS_PROXY:-}"
export TIDEGATE_GATEWAY="${TIDEGATE_GATEWAY:-}"

# Signal readiness
touch /tmp/healthy
echo "tidegate-agent ready"

# If no command specified, drop to shell
if [ $# -eq 0 ]; then
    exec sh
else
    exec "$@"
fi
