# Egress proxy Dockerfile — Squid CONNECT-only forward proxy
# Build context: egress-proxy/
#
# Build:  docker build -t tidegate-egress-proxy egress-proxy/
# Run:    docker run -p 3128:3128 tidegate-egress-proxy

FROM alpine:3.21

RUN apk add --no-cache squid

# Copy config
COPY squid.conf /etc/squid/squid.conf
COPY allowlist.txt /etc/squid/allowlist.txt
COPY entrypoint.sh /entrypoint.sh

# Squid needs writable dirs for PID and Unix domain sockets.
# Cache is disabled so no swap dirs needed.
# /tmp is mounted as tmpfs in compose (read_only: true compatible).
RUN mkdir -p /tmp && \
    chown squid:squid /tmp

EXPOSE 3128

# Alpine squid package creates user squid (UID 31)
USER squid

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD squid -k check -f /etc/squid/squid.conf 2>/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
