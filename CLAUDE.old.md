# CLAUDE.md — Tidegate

Tidegate is a secure deployment platform for AI agents. It wraps an agent framework inside a Docker topology that scans all MCP tool calls for sensitive data, isolates credentials on separate networks, and blocks unauthorized egress.

For the full vision and future architecture, see `docs/ROADMAP.md`. For threat model and attack scenarios, see `docs/threat-model/`. For testing strategy, see `docs/testing.md`. For current state details, see `docs/current-state.md`.

## What exists today

An MCP gateway that sits between an agent and downstream MCP servers. It mirrors their tool lists, scans all string values in tool call parameters and responses, and returns shaped denies on policy violations. Plus a Squid egress proxy and Docker packaging.

**Not built yet**: agent container, L1 taint tracking (eBPF `openat` + seccomp-notify `connect()` — see ADR-002), agent-proxy (MITM), skill hardening, setup.sh. See `docs/ROADMAP.md` for the plan.

**Superseded**: ADR-001 (`execve` interception + command evaluator) — replaced by ADR-002's journal-based taint architecture. No `execve` interception, no command evaluator, no static analysis of scripts.

## Directory structure

```
tidegate/
├── CLAUDE.md
├── README.md
├── docker-compose.yaml
├── tidegate.yaml              # Runtime config (server URLs, tool allowlists)
│
├── src/
│   ├── gateway/               # TypeScript MCP gateway
│   │   ├── src/
│   │   │   ├── index.ts       # Entry: load config → connect downstream → start host
│   │   │   ├── host.ts        # Streamable HTTP server (agent-facing, port 4100)
│   │   │   ├── router.ts      # Enforcement pipeline + extractStringValues()
│   │   │   ├── policy.ts      # Config loading + tool allowlists
│   │   │   ├── scanner.ts     # L1 in-process + L2/L3 Python subprocess
│   │   │   ├── servers.ts     # Downstream MCP client connections
│   │   │   └── audit.ts       # NDJSON structured logging
│   │   ├── test-echo-server.ts
│   │   ├── tidegate.yaml      # Dev config (localhost URLs)
│   │   ├── package.json
│   │   └── Dockerfile
│   ├── scanner/               # Python L2/L3 subprocess
│   │   ├── scanner.py         # Stateless: {value} → {allow/deny}
│   │   └── requirements.txt
│   ├── egress-proxy/          # Squid CONNECT-only proxy
│   ├── hello-world/           # Demo MCP server
│   └── test/echo-server/      # Docker echo server for compose testing
│
└── docs/
    ├── adr/                   # Architecture Decision Records (proposed/, accepted/, superseded/)
    ├── research/              # active/, completed/, superseded/
    ├── threat-model/          # Broken-up threat model (README, incidents, defenses, etc.)
    ├── personas.md
    ├── testing.md
    ├── ROADMAP.md
    ├── current-state.md
    └── target-state.md
```

## How the gateway works

Single Node.js process: MCP server upstream (agent-facing) + MCP clients downstream (real servers).

**Enforcement pipeline** (`router.ts`):
1. Resolve tool → downstream server (from discovered tools)
2. Check `allow_tools` (if configured for that server)
3. Scan all string values in args via `extractStringValues()` recursive walker
4. Forward to downstream server
5. Scan all text content in response

Denial at any step returns a shaped deny (`isError: false` + explanation). `servers.ts` is never called on the deny path.

**Scanner layers**:
- **L1** (in-process TypeScript, ~0.1ms): 13 credential patterns (AWS `AKIA`, Slack `xoxb-`, GitHub `ghp_`, etc.), 7 sensitive JSON key patterns
- **L2** (Python subprocess, zero false positives): Luhn (credit cards), mod-97 (IBANs), SSN format+area validation
- **L3** (Python subprocess): Shannon entropy, base64/hex detection

Scanner interface: `{value} → {allow, reason, layer}` over NDJSON stdin/stdout. Subprocess auto-respawns with backoff (max 5 attempts). Fail-closed on unavailability or timeout.

**Shaped denies**: Valid MCP `CallToolResult` with `isError: false` so the agent reads the explanation and adjusts, rather than retrying blindly.

## Config format

```yaml
# tidegate.yaml
version: "1"
defaults:
  scan_timeout_ms: 500
  scan_failure_mode: deny
servers:
  echo:
    transport: http
    url: http://echo-server:4200/mcp
    # allow_tools: [echo]  # optional — omit to mirror all tools
```

Adding a server: add its URL here + add the container to `docker-compose.yaml`.

## Running

**Dev mode** (no Docker):
```sh
cd src/gateway
npx tsx test-echo-server.ts &    # starts echo server on :4200
npm run dev                       # starts gateway on :4100
```

**Docker**:
```sh
docker compose up --build
```

**Curl tests**:
```sh
# Initialize
curl -X POST http://localhost:4100/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}'

# Call tool
curl -X POST http://localhost:4100/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Protocol-Version: 2025-03-26" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}}}'

# Trigger L1 deny (AWS key)
curl -X POST http://localhost:4100/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Protocol-Version: 2025-03-26" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"message":"my key is AKIAIOSFODNN7EXAMPLE"}}}'
```

## Conventions

**TypeScript** (gateway): strict mode, no `any`. MCP SDK from `@modelcontextprotocol/sdk`.

**Python** (scanner): stateless, no framework deps. `python-stdnum` for checksums. L2 patterns must have zero mathematical false positives.

**MCP SDK pattern**: per-request `Server` + `StreamableHTTPServerTransport` pair. The SDK's `Server.connect()` is one-shot — fresh `Server` per request avoids transport lifecycle issues.

**Module boundaries**: `servers.ts` has zero knowledge of policy or scanning. `router.ts` only calls `servers.forward()` on the pass path. `scanner.ts` has no knowledge of tool names or field names.

**Docker**: pin base image versions, `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, non-root user, `HEALTHCHECK` in every Dockerfile. Three networks: `agent-net` (`internal: true`), `proxy-net`, `mcp-net` (`internal: true`). Docker >= 25.0.5 required.

**Security rules**: never commit secrets. Every deny is a valid MCP result with explanation. Audit log writes before forwarding. Fail-closed on all error paths. Credentials only in MCP server containers, never in agent/gateway containers.

**Shell**: POSIX sh, not bash. Must work in Alpine.

## Key files for common tasks

| Task | Start here |
|---|---|
| Add a scanning pattern | `src/gateway/src/scanner.ts` (L1) or `src/scanner/scanner.py` (L2/L3) |
| Change enforcement pipeline | `src/gateway/src/router.ts` |
| Change config schema | `src/gateway/src/policy.ts` |
| Add transport support | `src/gateway/src/servers.ts` |
| Modify HTTP handling | `src/gateway/src/host.ts` |
| Change audit format | `src/gateway/src/audit.ts` |
| Docker topology | `docker-compose.yaml` |
