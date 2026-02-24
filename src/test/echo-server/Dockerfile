# Test echo MCP server — for integration testing
# Build context: gateway/ (reuses gateway's dependencies)
#
# This is a test fixture, not a production component.
# It exposes two tools (echo, echo_system) matching the test tidegate.yaml.

FROM node:22-alpine3.21

WORKDIR /app

# Install deps (same as gateway — shares the lockfile)
COPY package.json package-lock.json ./
RUN npm ci

# Copy only the echo server source
COPY test-echo-server.ts ./

ENV PORT=4200

EXPOSE 4200

USER node

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:4200/health || exit 1

# Run directly with tsx (dev tool, acceptable for test fixture)
ENTRYPOINT ["npx", "tsx", "test-echo-server.ts"]
