# CLAUDE.md — Tidegate

## What this is

Tidegate is a schema-aware MCP gateway that enforces field-level security policy on AI agent tool calls. It is an architecture layer — not just a gateway binary — comprising a network topology, a policy engine, a leak scanner, field classification mappings, and compose templates.

The agent connects to Tidegate as a normal MCP server over Streamable HTTP. Tidegate validates every tool call with full semantic context — tool names, parameter names, field classifications — before forwarding to the real MCP server. Credentials live in MCP server containers, never in the agent or gateway.

The topology is the security model: agent → Tidegate → MCP servers, no bypass. Without network isolation, the gateway is advisory.

See `README.md` for full architecture and comparisons, `THREAT_MODEL.md` for adversary profiles and sensitive data taxonomy, `UNKNOWNS.md` for open questions.

## Project status

**Phase: Implementation.** Core gateway working, Docker packaging in progress.

### What's done
- Architecture finalized — TypeScript gateway + Python scanner, Streamable HTTP transport, separate container model, 6 gateway modules defined
- Market gap validated — no existing MCP gateway does field-level semantic policy with shaped deny responses
- Leak detection research — resolved. 3-layer detection architecture. See `research/leak-detection/`
- Threat model — complete. See `THREAT_MODEL.md`
- Unknowns #1–#4 resolved — MCP SDK dual-role, credential injection, network topology, egress proxy selection
- **Gateway core implemented** — all 6 modules compile and work end-to-end
  - Policy engine: field validation, regex/enum constraints, unknown field rejection, required field checks
  - L1 leak scanning: credential patterns (AWS, Slack, GitHub, Stripe, 1Password), private keys, sensitive JSON keys
  - Shaped denies: `isError: false` with plain-text explanation
  - Audit logging: NDJSON to stdout
  - Downstream MCP client: Streamable HTTP + stdio transports
- **End-to-end tested** — mock echo server validates the full enforcement pipeline

### What's in progress
- Docker packaging (gateway Dockerfile, egress-proxy, compose templates)
- See `UNKNOWNS.md` for remaining open questions (#5–#7)

### What's next
- Python scanner subprocess (L2/L3 leak detection)
- Real MCP server mappings (Slack, GitHub, etc.)
- Integration testing with real agent frameworks

## Directory structure

```
tidegate/
├── CLAUDE.md                  # This file — project instructions for Claude
├── README.md                  # Full architecture, design philosophy, comparisons
├── THREAT_MODEL.md            # Sensitive data taxonomy, adversary profiles, residual risks
├── UNKNOWNS.md                # Open questions (mark resolved as implementation answers them)
├── .gitignore
├── docker-compose.yaml        # Reference compose template (3-network topology)
│
├── gateway/                   # TypeScript MCP-to-MCP proxy with policy engine
│   ├── Dockerfile
│   ├── package.json
│   ├── tsconfig.json
│   ├── tidegate.yaml          # Dev config (points to localhost, used with `npm run dev`)
│   ├── test-echo-server.ts    # Mock MCP server for dev/testing (not shipped)
│   └── src/
│       ├── index.ts           # Entry point: load config → connect downstream → start host
│       ├── host.ts            # MCP server over Streamable HTTP (agent-facing)
│       ├── router.ts          # Request lifecycle: validate → scan → forward → return
│       ├── policy.ts          # YAML config, field validation, tool filtering
│       ├── scanner.ts         # Leak detection interface (L1 in-process, L2/L3 subprocess)
│       ├── servers.ts         # MCP client connections to downstream servers
│       └── audit.ts           # Structured NDJSON logging
│
├── egress-proxy/              # Squid-based CONNECT-only forward proxy
│   ├── Dockerfile
│   ├── squid.conf             # Hardened config (CONNECT-only, no cache, no MITM)
│   ├── allowlist.txt          # LLM API domains, one per line
│   └── entrypoint.sh          # Squid startup with non-root user
│
├── scanner/                   # Python leak detection subprocess (L2/L3) — NOT YET CREATED
│   ├── Dockerfile
│   ├── requirements.txt       # python-stdnum
│   └── scanner.py             # Stateless: receives {field, value, class}, returns {allow/deny}
│
├── mappings/                  # YAML field classifications per MCP server
│   └── echo.yaml              # Example mapping for test echo server
│
├── test/                      # Integration test fixtures
│   └── echo-server/           # Mock MCP server as Docker service for compose testing
│       └── Dockerfile
│
└── research/                  # Ongoing research (may produce new unknowns)
    ├── README.md
    └── leak-detection/        # Leak detection tool evaluations (resolved, still valid)
```

### Build contexts

Each Dockerfile uses only its own directory as build context:
- `docker build -f gateway/Dockerfile gateway/` — copies `gateway/` only
- `docker build -f egress-proxy/Dockerfile egress-proxy/` — copies `egress-proxy/` only
- `docker build -f test/echo-server/Dockerfile gateway/` — reuses gateway source for test echo server

The compose file maps `tidegate.yaml` (the runtime policy config) and `mappings/` into the gateway container via bind mounts. This keeps policy config editable without rebuilding.

## Architecture

### Component model

Every component is pluggable except the network topology:

- **Agent**: Any MCP client. OpenClaw, NanoClaw, PicoClaw, Claude Code, etc. Tidegate sees an MCP client over Streamable HTTP.
- **Gateway**: Custom TypeScript build. Swappable if market catches up on field-level policy + shaped denies.
- **Scanner**: Python subprocess pool. Stateless, replaceable via clean interface contract.
- **MCP Servers**: Any standard MCP server. Separate containers on isolated network (preferred) or stdio child processes inside Tidegate (fallback for legacy servers).
- **Mappings**: YAML field classifications per MCP server. PR-reviewable, community-contributable.
- **Network Topology**: NOT pluggable. Agent → Tidegate → MCP servers, no bypass. This is the enforced opinion.

### Detailed architecture

```
Agent container (any framework)
  │  egress: Tidegate + LLM API (via egress-proxy) only
  │  HTTPS_PROXY=http://egress-proxy:3128
  │
  │ MCP (Streamable HTTP)
  ▼
Tidegate container (single Node.js process)
  │  ├── MCP server (upstream) + MCP client (downstream)
  │  ├── Exposes only mapped tools/fields to agent
  │  ├── Schema-aware per-field validation
  │  ├── Leak detection on user_content fields only
  │  ├── Response field stripping + scanning
  │  ├── Shaped denies (valid MCP tool results with explanation)
  │  ├── Structured audit log (future anomaly detection input)
  │  ├── Killswitch
  │  │
  │  │ JSON over stdio
  │  ├── Python scanner subprocess (L2/L3 leak detection, stateless)
  │  │
  │  │ stdio (fallback for servers that only speak stdio)
  │  ├── Legacy MCP servers as child processes inside container
  │
  │ MCP (Streamable HTTP)
  ▼
MCP Server containers (on isolated network only Tidegate can reach)
  │  ├── Standard community MCP servers, unmodified
  │  ├── Credentials via env vars (op run / Docker Compose)
  │  ├── HTTP clients live here, not in Tidegate
  ▼
Internet

Egress proxy container
  │  ├── CONNECT-only forward proxy (Squid or custom)
  │  ├── Domain allowlist: LLM API hosts only
  │  ├── No MITM — CONNECT tunnel is end-to-end TLS
  │  ├── Hot-reloadable allowlist (SIGHUP or file watch)
  │  ├── On agent-net (receives requests) + proxy-net (reaches internet)
```

### Network topology (the security model)

Three Docker networks enforce the trust boundary:

- **agent-net** (`internal: true`, `enable_ipv6: false`): Agent + Tidegate + egress-proxy. No direct internet access.
- **proxy-net** (`enable_ipv6: false`): Egress-proxy only. Internet access for LLM API calls.
- **mcp-net** (`internal: true`, `enable_ipv6: false`): Tidegate + MCP server containers. No internet access.

How it works:
- Agent reaches Tidegate directly on `agent-net` (MCP tool calls).
- Agent reaches LLM APIs via `HTTPS_PROXY` → egress-proxy → `proxy-net` → internet. The proxy allowlists only LLM API domains using HTTPS CONNECT inspection (no MITM, no certificate injection — the proxy sees the domain in the CONNECT request, then tunnels TLS end-to-end).
- Tidegate bridges `agent-net` and `mcp-net`. Only path between agent and MCP servers.
- Egress-proxy bridges `agent-net` and `proxy-net`. Only path between agent and internet.
- MCP servers on `mcp-net` can reach the internet directly (they are the HTTP clients that call external APIs).
- **Credentials**: Live in MCP server containers, not in Tidegate, not in agent.
- **Docker >= 25.0.5 required**: Fixes CVE-2024-29018 (DNS exfiltration on internal networks).

### Tech stack

- **Gateway core**: TypeScript. MCP SDK is TS-native, type system enforces schema mappings, natural JSON-RPC handling.
- **Scanner**: Python as stateless subprocess (or pool). Receives `{field, value, class}`, returns `{allow/deny, reason}`. Uses `python-stdnum` (~1MB) for checksum validation.
- **L1 scanning** (key-name heuristics like `ssn`, `api_key`, `password`) stays in TypeScript — no subprocess round-trip.
- **Scanner interface is replaceable**: gateway speaks a clean protocol to an opaque scanning process. Python now, could be Rust/Go/external API later. Scanner must be stateless — no tool context, no session state.

### Gateway modules (6)

| Module | Role |
|---|---|
| `host.ts` | MCP server over Streamable HTTP. Per-request `Server` instances in stateless mode. |
| `router.ts` | Request lifecycle: validate → scan → forward → scan response → return. Denial at any step short-circuits. |
| `policy.ts` | Loads `tidegate.yaml`. Field validation (steps 1-4). Tool filtering. Response field stripping. Hot-reload on YAML change. Pure functions, no I/O except YAML loading. Most testable module. |
| `scanner.ts` | Leak detection. L1 in-process (credential patterns, sensitive JSON keys), L2/L3 via Python subprocess (TODO). |
| `servers.ts` | MCP client connections to downstream servers. Pluggable: Streamable HTTP client or child process stdio. No security logic — pure forwarding. |
| `audit.ts` | Structured NDJSON logging. Every allow/deny/error with tool, field, reason, layer, duration. |

Module design note: `servers.ts` has no knowledge of policy, scanning, or sessions. `router.ts` only calls `servers.forward()` on the pass path. This clean boundary means the forwarding logic can be split into a separate process later if downstream crash isolation proves necessary — but for MVP, a single process with try/catch around downstream calls achieves the same error handling with less complexity.

## Key architectural decisions

| Decision | Rationale |
|---|---|
| Tidegate = topology + gateway + mappings | Gateway alone is advisory without network enforcement |
| TypeScript gateway + Python scanner | TS for MCP SDK; Python for stdnum/entropy analysis |
| Single process, splittable modules | MCP SDK server + client coexist in one Node.js process. `servers.ts` has zero knowledge of policy/scanning — clean boundary allows future process split if needed. Avoids IPC complexity for MVP. |
| MCP Streamable HTTP upstream | Standard protocol, any MCP client connects, no custom API |
| MCP servers as separate containers (preferred) | Network isolation, credential separation; stdio as fallback only |
| Three networks with egress proxy | `internal: true` blocks all internet; proxy allowlists LLM API domains via HTTPS CONNECT (no MITM). Docker Sandboxes uses the same architecture. |
| Shaped denies as `isError: false` | Agent reads and adjusts, not retries blindly |
| Field-level policy, not blob scanning | At 50+ tools, blob scanning FP rate on `system_param` values is paralyzing |
| Build custom gateway | No existing gateway supports shaped denies + field-level policy |
| Per-request MCP Server instances | SDK's `Server.connect()` is one-shot. Creating a fresh `Server` per HTTP request avoids transport lifecycle issues in stateless mode. Handler registration is cheap (two handlers). |

### Credential model
- MCP servers are the HTTP clients. They hold credentials.
- `op run --env-file .env` wraps `docker compose up` on the host, resolving `op://` references and passing real values to containers via Compose `environment:` directives
- 1Password Service Account token (`OP_SERVICE_ACCOUNT_TOKEN`) lives in the operator's shell or CI environment, never in any container or compose file
- One SA token can access multiple vaults (permissions set at creation, immutable)
- For development: plain `.env` file (gitignored) with real values, no `op run` in the chain
- No runtime credential injection, no UDS, no monkey-patching
- The agent and gateway never see API keys, tokens, or passwords

### Leak detection scope
- **Applied to**: `user_content` fields only (free-text tool call parameters)
- **What we detect**: Credentials (vendor-prefix regex), financial instruments (Luhn, mod-97), government IDs (SSN with required context keywords), JSON keys indicating sensitive fields
- **What we don't detect** (and why): Names (NER FP on code), phone numbers (not actionable), emails (ubiquitous), addresses (no reliable pattern), proprietary code/conversations/documents (no structural signature)
- See `THREAT_MODEL.md` for the full sensitive data taxonomy

### Security posture
- Deny-by-default: unmapped tools invisible, unmapped fields blocked
- Fail-closed on all error paths
- No root in any container (`user: "1000:1000"`, `cap_drop: ALL`, `no-new-privileges: true`)
- Credentials never in agent process, gateway process, env vars, compose files, or container filesystem
- Audit log: every tool call recorded before forwarding

## Schema mapping format

```yaml
# tidegate.yaml
version: "1"
defaults:
  scan_timeout_ms: 500
  scan_failure_mode: deny
  unknown_field_policy: deny

servers:
  slack:
    transport: http
    url: http://slack-mcp:3000
    tools:
      post_message:
        params:
          channel:
            class: system_param
            type: string
            validation: "regex:^C[A-Z0-9]{8,}$"
            required: true
          text:
            class: user_content
            type: string
            scan: [L1, L2, L3]
            required: true
        response:
          ok:
            class: system_param
          ts:
            class: system_param

  some-legacy-server:
    transport: stdio
    command: npx
    args: ["-y", "@some/old-mcp-server"]
    env:
      API_KEY: "op://vault/some-key"
    tools: # ...
```

### Field classes

| Class | What it is | Validation | Leak scan |
|---|---|---|---|
| `system_param` | Constrained values (IDs, enums, paths) | Regex, enum, type check | No |
| `user_content` | Free-form text from agent | None (free text) | Full 3-layer scan |
| `opaque_credential` | Injected by MCP server, never from agent | Must not appear in agent request | N/A |
| `structured_data` | Code, JSON, structured payloads | Format validation | Pattern scanning |

### Shaped deny wire format

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": {
    "content": [{
      "type": "text",
      "text": "Policy violation: field 'text' in tool 'post_message' failed L2 scan -- value contains a pattern matching a Slack bot token (xoxb- prefix). Message not sent. Remove the credential and retry."
    }],
    "isError": false
  }
}
```

`isError: false` is deliberate — the agent reads the explanation and adjusts, rather than treating it as a system error and retrying blindly.

## Conventions

### Code style
- TypeScript: gateway implementation. Strict mode, no `any`.
- Python: scanner subprocess. Stateless, no framework dependencies. `python-stdnum` for checksums.
- YAML: schema mappings and Docker Compose files. Explicit long-form, not clever anchors.
- Shell: POSIX sh for scripts, not bash. Must work in Alpine containers.

### File organization
- Gateway code in `gateway/src/` with its own Dockerfile at `gateway/Dockerfile`
- Scanner code in `scanner/` with its own Dockerfile (not yet created)
- Egress proxy in `egress-proxy/` with Dockerfile, squid.conf, allowlist.txt
- Schema mappings in `mappings/`, one YAML per MCP server
- Reference compose template at repo root: `docker-compose.yaml`
- Test fixtures in `test/` (echo server Dockerfile, test configs)
- Research docs in `research/<topic>/`
- Dev-only files (`test-echo-server.ts`, `tidegate.yaml` in gateway/) stay in `gateway/` but aren't copied into Docker images
- Do not create new top-level directories without discussion

### MCP SDK patterns
- **Stateless HTTP transport**: each POST request gets a new `Server` + `StreamableHTTPServerTransport` pair. The SDK's `Server.connect()` is one-shot — calling it on a connected server throws. Creating a fresh `Server` per request is cheap (just handler registrations) and avoids transport lifecycle issues.
- **Low-level `Server` class** (from `@modelcontextprotocol/sdk/server/index.js`): used for the gateway's upstream (agent-facing) MCP server. Gives full control over request schemas. Not `McpServer` (the high-level convenience class).
- **`Client` class** (from `@modelcontextprotocol/sdk/client/index.js`): used for downstream connections to real MCP servers. Persistent connections, reused across requests.
- **`StreamableHTTPClientTransport`**: for connecting to remote MCP servers over HTTP. `StdioClientTransport`: for legacy servers as child processes.

### Security rules
- Never commit secrets, certs, or keys (enforced by `.gitignore`)
- Never use `privileged: true` or `network_mode: host`
- Every shaped deny must be a valid MCP tool result with plain-text explanation — never a protocol error or connection reset
- Audit log writes must be append-only and synchronous (write before forwarding response)
- Schema mappings must be reviewed before first run — no auto-generated mappings without human approval

### Docker
- Base images: pin exact digest or version tag (not `:latest`)
- All containers: `read_only: true`, `tmpfs: ["/tmp"]`, resource limits set
- All containers: `cap_drop: [ALL]`, `security_opt: ["no-new-privileges:true"]`, `user: "1000:1000"` (or service-specific UID like `3128` for squid)
- Define three networks: `agent-net` (`internal: true`), `proxy-net`, `mcp-net` (`internal: true`). All with `enable_ipv6: false`.
- Docker >= 25.0.5 required (CVE-2024-29018 DNS exfiltration fix)
- Dev: `docker compose up --build` from repo root with `.env` file
- Prod: `op run --env-file .env -- docker compose up --build` from repo root

### Testing
- **Dev mode**: `cd gateway && npm run dev` + `npx tsx test-echo-server.ts` — runs gateway and echo server locally without Docker
- **Docker compose**: `docker compose up --build` — full 3-network topology with echo server
- **Manual curl tests**: use JSON-RPC over HTTP with proper headers:
  ```sh
  # Initialize
  curl -X POST http://localhost:4100/mcp \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}'

  # Call tool (after initialize)
  curl -X POST http://localhost:4100/mcp \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "Mcp-Protocol-Version: 2025-03-26" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"test"}}}'
  ```

## Working with this codebase

### Before making changes
- Read `UNKNOWNS.md` — open questions may affect your approach
- Read `README.md` for architectural context
- Read `THREAT_MODEL.md` if working on security-related code
- Check `research/leak-detection/` if working on detection logic

### When writing gateway code
- Single Node.js process acts as both MCP server (upstream) and MCP client (downstream)
- Six modules with clean boundaries: `host.ts`, `router.ts`, `policy.ts`, `scanner.ts`, `servers.ts`, `audit.ts`
- `servers.ts` has zero knowledge of policy, scanning, or sessions — it only forwards validated requests. This is a deliberate boundary: if process separation proves necessary later, `servers.ts` is the split point.
- Enforcement pipeline: tool mapped? → fields mapped? → no extra fields? → system_param validates? → user_content scans clean? → forward via `servers.ts` → response fields mapped? → response clean? → return
- On deny at any step, return shaped deny directly — `servers.ts` is never called
- Wrap downstream calls in try/catch — downstream failures return shaped denies, never crash the gateway

### When writing scanner code
- Scanner is stateless — receives `{field, value, class}`, returns `{allow/deny, reason}`
- No tool context, no session state
- L1 stays in TypeScript (key-name heuristics, no subprocess round-trip)
- L2/L3 go to Python subprocess

### When writing schema mappings
- One YAML file per MCP server in `mappings/`
- Every parameter must be classified: `system_param`, `user_content`, `opaque_credential`, or `structured_data`
- `system_param` must have regex, enum, or type validation
- `user_content` gets full 3-layer leak scan
- `opaque_credential` must never appear in agent requests — if it does, block immediately

### When writing Docker Compose
- Define three networks: `agent-net` (`internal: true`), `proxy-net`, `mcp-net` (`internal: true`). All with `enable_ipv6: false`.
- Agent container on `agent-net` only, with `HTTPS_PROXY=http://egress-proxy:3128`
- Tidegate container on both `agent-net` and `mcp-net`
- Egress-proxy container on both `agent-net` and `proxy-net`, with domain allowlist for LLM APIs
- MCP server containers on `mcp-net` only
- `op run --env-file .env` wraps `docker compose up` on the host
- Docker >= 25.0.5 required (CVE-2024-29018 DNS exfiltration fix)

### When writing Dockerfiles
- Multi-stage builds: `build` stage for compilation, `runtime` stage for slim final image
- Gateway: Node.js Alpine, compile TypeScript to `dist/`, copy only `dist/` + `node_modules/` (production deps) to runtime stage
- Egress proxy: Alpine + `apk add squid`, copy config files
- Non-root user in all images
- `HEALTHCHECK` instruction in every Dockerfile
- Pin base image versions (e.g., `node:22-alpine3.21`, not `node:alpine`)

### Updating project docs
- `UNKNOWNS.md`: mark items resolved when implementation answers them; add new items at the bottom
- `THREAT_MODEL.md`: update if new attack vectors or mitigations are discovered
- `README.md`: update when implementation changes the design
- `CLAUDE.md`: update when project structure, conventions, or status changes

## Explicitly deferred

- Dashboard/web UI for logs, killswitch, server management
- Mapping editor UI
- LLM-assisted mapping generation (`tidegate discover <server>`)
- Community mapping registry
- Multi-agent policy / RBAC
- Approval workflows for sensitive tool calls
- Behavioral anomaly detection (audit log is infrastructure-ready, detection logic is future)
