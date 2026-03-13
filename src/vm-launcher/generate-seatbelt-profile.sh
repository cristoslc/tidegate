#!/bin/sh
# Generate a gvproxy Seatbelt profile with custom gateway/proxy ports.
#
# Usage: generate-seatbelt-profile.sh <gateway-port> <proxy-port> [output-path]
#
# Reads port numbers and produces a .sb profile that restricts
# gvproxy outbound to exactly those two localhost ports.

set -e

GATEWAY_PORT="${1:?Usage: $0 <gateway-port> <proxy-port> [output-path]}"
PROXY_PORT="${2:?Usage: $0 <gateway-port> <proxy-port> [output-path]}"
OUTPUT="${3:-/dev/stdout}"

# Validate ports are numeric
case "$GATEWAY_PORT" in
    ''|*[!0-9]*) echo "Error: gateway port must be numeric" >&2; exit 1 ;;
esac
case "$PROXY_PORT" in
    ''|*[!0-9]*) echo "Error: proxy port must be numeric" >&2; exit 1 ;;
esac

cat > "$OUTPUT" <<EOF
;; Auto-generated Seatbelt profile for gvproxy egress enforcement.
;; Gateway: localhost:${GATEWAY_PORT}  Proxy: localhost:${PROXY_PORT}

(version 1)
(deny default)

;; Process lifecycle
(allow process-exec)
(allow process-fork)
(allow sysctl-read)

;; Filesystem: read anything, write to /tmp only
(allow file-read*)
(allow file-write* (subpath "/tmp"))

;; Network: allow only gateway and proxy on localhost
(allow network-outbound (remote tcp "localhost:${GATEWAY_PORT}"))
(allow network-outbound (remote tcp "localhost:${PROXY_PORT}"))

;; Unix sockets for gvproxy internal communication
(allow network-outbound (local unix-socket))
(allow network-bind (local unix-socket))

;; Inbound from VM (gvproxy listens on unix socket)
(allow network-inbound (local unix-socket))
EOF
