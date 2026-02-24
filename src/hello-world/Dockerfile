# Hello World MCP server — demo for Tidegate
# Build context: hello-world/ (has its own package.json)
#
# This is a demo component showing how an MCP server
# integrates with Tidegate's field-level policy.

FROM node:22-alpine3.21

WORKDIR /app

# Install deps
COPY package.json package-lock.json ./
RUN npm ci

# Copy the server source
COPY server.ts ./

ENV PORT=4300

EXPOSE 4300

USER node

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:4300/health || exit 1

# Run directly with tsx (acceptable for demo)
ENTRYPOINT ["npx", "tsx", "server.ts"]
