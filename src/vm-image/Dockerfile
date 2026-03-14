# Minimal VM guest image for Tidegate agent isolation.
#
# Alpine-based rootfs with Node.js, Python, and git.
# Designed for libkrun microVM boot with custom init (no systemd).
#
# Build:   docker build -t tidegate-agent -f Dockerfile .
# Export:  docker export $(docker create tidegate-agent) | tar -C rootfs -xf -
#
# See SPEC-006 for full requirements.

# ---------------------------------------------------------------------------
# Stage 1: Build — install packages, strip unnecessary files
# ---------------------------------------------------------------------------
FROM alpine:3.21 AS builder

# Install runtime dependencies in a single layer
RUN apk add --no-cache \
    nodejs \
    npm \
    python3 \
    py3-pip \
    git \
    curl \
    ca-certificates \
    && rm -rf /var/cache/apk/*

# Remove unnecessary files to minimize image size
RUN rm -rf \
    /usr/share/man \
    /usr/share/doc \
    /usr/share/info \
    /usr/lib/python3.*/test \
    /usr/lib/python3.*/unittest \
    /usr/lib/python3.*/pydoc* \
    /usr/lib/python3.*/idle* \
    /usr/lib/python3.*/tkinter \
    /usr/lib/python3.*/ensurepip

# ---------------------------------------------------------------------------
# Stage 2: Runtime — minimal image with non-root user
# ---------------------------------------------------------------------------
FROM alpine:3.21

LABEL org.opencontainers.image.title="tidegate-agent" \
      org.opencontainers.image.description="Minimal VM guest for Tidegate agent isolation" \
      org.opencontainers.image.source="https://github.com/cristos/tidegate"

# Copy installed packages from builder
COPY --from=builder /usr/ /usr/
COPY --from=builder /etc/ssl/ /etc/ssl/
COPY --from=builder /etc/ca-certificates/ /etc/ca-certificates/

# Reinstall shared libraries needed at runtime
RUN apk add --no-cache \
    musl \
    libstdc++ \
    libgcc \
    busybox \
    && rm -rf /var/cache/apk/*

# Create workspace mount point (virtiofs target)
RUN mkdir -p /workspace

# Copy init script
COPY init.sh /init.sh
RUN chmod +x /init.sh

# Non-root user for agent execution
RUN adduser -D -h /home/agent agent
RUN chown agent:agent /workspace

# Health check (convention: every Dockerfile must have HEALTHCHECK)
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s \
    CMD [ -f /tmp/healthy ] || exit 1

ENTRYPOINT ["/init.sh"]
