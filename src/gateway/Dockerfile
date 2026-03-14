FROM python:3.12.9-alpine3.21

# Non-root user
RUN addgroup -g 1000 tidegate && \
    adduser -u 1000 -G tidegate -s /bin/sh -D tidegate

WORKDIR /app

# Install uv for dependency management
COPY --from=ghcr.io/astral-sh/uv:0.6.14 /uv /usr/local/bin/uv

# Copy project files
COPY pyproject.toml uv.lock ./
COPY src/gateway/ src/gateway/

# Install dependencies
RUN uv sync --frozen --no-dev && \
    chown -R tidegate:tidegate /app

USER tidegate

EXPOSE 4100

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q --spider http://localhost:4100/health || exit 1

ENTRYPOINT ["uv", "run", "python", "-m", "src.gateway.main"]
