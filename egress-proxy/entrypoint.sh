#!/bin/sh
# Tidegate egress proxy entrypoint
# Runs Squid in foreground with the hardened CONNECT-only config.
# Must work in Alpine (POSIX sh, not bash).

set -e

# Verify allowlist exists
if [ ! -f /etc/squid/allowlist.txt ]; then
  echo "[egress-proxy] ERROR: /etc/squid/allowlist.txt not found" >&2
  exit 1
fi

echo "[egress-proxy] Allowed domains:" >&2
cat /etc/squid/allowlist.txt | grep -v '^#' | grep -v '^$' >&2

echo "[egress-proxy] Starting Squid (CONNECT-only mode)..." >&2

# -N = no daemon (foreground)
# -Y = quick restart on reconfigure
# -C = don't catch fatal signals (let Docker handle restarts)
exec squid -NYC -f /etc/squid/squid.conf
