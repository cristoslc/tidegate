# Minimal VM guest image for Tidegate agent isolation.
#
# Alpine-based rootfs with Node.js, Python, and git.
# Designed for libkrun microVM boot with custom init (no systemd).
#
# Build: docker build -t tidegate-agent -f Dockerfile .
# Export rootfs: docker export $(docker create tidegate-agent) | tar -C rootfs -xf -

FROM alpine:3.21 AS base

# Install runtime dependencies
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
    /usr/lib/python3.*/tkinter

# Create workspace mount point
RUN mkdir -p /workspace

# Copy init script
COPY init.sh /init.sh
RUN chmod +x /init.sh

# Non-root user for agent execution
RUN adduser -D -h /home/agent agent
RUN chown agent:agent /workspace

# Health check
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s \
    CMD [ -f /tmp/healthy ] || exit 1

ENTRYPOINT ["/init.sh"]
