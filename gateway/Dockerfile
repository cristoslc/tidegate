# Gateway Dockerfile — multi-stage build
# Build context: gateway/
#
# Build:  docker build -t tidegate-gateway gateway/
# Run:    docker run -p 4100:4100 -v ./tidegate.yaml:/app/tidegate.yaml:ro tidegate-gateway
#
# The gateway runs Node.js with a Python subprocess for L2/L3 leak scanning.
# Python + python-stdnum are installed in the runtime stage.

# ── Build stage ──────────────────────────────────────────────
FROM node:22-alpine3.21 AS build

WORKDIR /build

# Install dependencies first (layer caching)
COPY package.json package-lock.json ./
RUN npm ci

# Copy source and compile
COPY tsconfig.json ./
COPY src/ src/
RUN npx tsc

# Prune dev dependencies for runtime
RUN npm prune --production

# ── Runtime stage ────────────────────────────────────────────
FROM node:22-alpine3.21 AS runtime

# node:22-alpine3.21 already has user 'node' (UID 1000)
WORKDIR /app

# Install Python for L2/L3 scanner subprocess
# python-stdnum is pure Python — no C extensions, no build tools needed
RUN apk add --no-cache python3 py3-pip && \
    pip3 install --no-cache-dir --break-system-packages python-stdnum>=1.20,\<2.0

# Copy only what's needed to run
COPY --from=build /build/dist/ dist/
COPY --from=build /build/node_modules/ node_modules/
COPY --from=build /build/package.json package.json

# Scanner is bind-mounted at /app/scanner/ in docker-compose.yaml
# For standalone builds, copy it into the image:
# COPY ../scanner/ scanner/

# Default config path — override with bind mount or env var
ENV TIDEGATE_CONFIG=/app/tidegate.yaml
ENV TIDEGATE_PORT=4100
ENV TIDEGATE_SCANNER_PATH=/app/scanner/scanner.py
ENV NODE_ENV=production

EXPOSE 4100

USER node

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:4100/health || exit 1

ENTRYPOINT ["node", "dist/index.js"]
