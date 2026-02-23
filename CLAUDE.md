# CLAUDE.md — Tidegate

## What this is

Tidegate is a secure AI agent deployment platform. You install Tidegate instead of installing an agent framework directly. It includes the agent (OpenClaw, etc.) pre-configured inside a container topology that prevents credential theft, blocks unauthorized network access, and scans all outbound data for sensitive patterns.

Tidegate enforces security at three layers: seccomp-notify command interception via tg-scanner (kernel-level, no code in agent container), an MCP gateway (network-enforced scanning of all tool calls), and an agent-proxy (network-enforced scanning + credential injection for skill HTTP traffic). The network topology is the security model — without it, everything is advisory.

See `README.md` for the user-facing overview, `THREAT_MODEL.md` for adversary profiles and real-world incidents, `UNKNOWNS.md` for open questions.

## Project status

**Phase: Architecture revision.** Core MCP gateway works end-to-end. Architecture expanding to cover skills and agent-proxy.

### What's done
- **MCP gateway core implemented** — TypeScript gateway with 6 modules, all working end-to-end
  - Blob scanning: credential patterns (AWS, Slack, GitHub, Stripe, 1Password), private keys, sensitive JSON keys
  - Shaped denies: `isError: false` with plain-text explanation
  - Audit logging: NDJSON to stdout
  - Downstream MCP client: Streamable HTTP + stdio transports
  - Tool mirroring from downstream servers
- **Python scanner implemented** — L2 (Luhn, IBAN, SSN checksum validation), L3 (entropy detection)
- **Docker packaging** — 3-network topology with echo + hello-world demo servers
- **Egress proxy** — Squid CONNECT-only forward proxy (to be replaced by agent-proxy)
- **Threat model** — revised with real-world incidents (ClawHavoc, Superhuman, EchoLeak)

### What's in progress
- Architecture revision: mirror+scan model replacing per-field YAML mappings
- Skill hardening design (SKILL.md rewriting)
- Agent-proxy design (MITM replacing CONNECT-only egress proxy)
- See `UNKNOWNS.md` for remaining open questions

### What's next
- tg-scanner container: command evaluator + seccomp-notify listener (Go, `libseccomp-golang`)
- tidegate-runtime: OCI runtime wrapper (injects seccomp-notify config into agent container)
- Agent container with agent framework profiles (Claude Code, OpenClaw)
- Skill hardening (SKILL.md rewriting on install)
- Agent-proxy with MITM + credential injection
- Real MCP server configurations (Slack, GitHub, etc.)
- Integration testing with real agent frameworks

## Directory structure

```
tidegate/
├── CLAUDE.md                  # This file — project instructions for Claude
├── README.md                  # User-facing overview, attack scenarios, getting started
├── THREAT_MODEL.md            # Real-world incidents, adversary profiles, honest scorecard
├── UNKNOWNS.md                # Open questions (mark resolved as implementation answers them)
├── .gitignore
├── docker-compose.yaml        # Reference compose template (3-network topology)
├── tidegate.yaml              # Runtime config (server URLs, tool allowlists)
│
├── gateway/                   # TypeScript MCP gateway with scanning
│   ├── Dockerfile
│   ├── package.json
│   ├── tsconfig.json
│   ├── tidegate.yaml          # Dev config (points to localhost, used with `npm run dev`)
│   ├── test-echo-server.ts    # Mock MCP server for dev/testing (not shipped)
│   └── src/
│       ├── index.ts           # Entry point: load config → connect downstream → start host
│       ├── host.ts            # MCP server over Streamable HTTP (agent-facing)
│       ├── router.ts          # Request lifecycle: scan → forward → scan response → return
│       ├── policy.ts          # Config loading, tool allowlists, tool mirroring
│       ├── scanner.ts         # Leak detection (L1 in-process, L2/L3 Python subprocess)
│       ├── servers.ts         # MCP client connections to downstream servers
│       └── audit.ts           # Structured NDJSON logging
│
├── egress-proxy/              # Squid-based CONNECT-only proxy (to be replaced by agent-proxy)
│   ├── Dockerfile
│   ├── squid.conf
│   ├── allowlist.txt
│   └── entrypoint.sh
│
├── scanner/                   # Python leak detection subprocess (L2/L3)
│   ├── Dockerfile
│   ├── requirements.txt       # python-stdnum
│   └── scanner.py             # Stateless: receives {value}, returns {allow/deny}
│
├── mappings/                  # Per-server configuration (URLs, tool allowlists)
│   └── hello-world.yaml       # Example for demo server
│
├── test/                      # Integration test fixtures
│   └── echo-server/           # Mock MCP server as Docker service for compose testing
│       └── Dockerfile
│
└── research/                  # Ongoing research
    ├── README.md
    ├── adr/                   # Architecture Decision Records
    │   └── 001-seccomp-notify-l1-interception.md
    ├── leak-detection/        # Leak detection tool evaluations
    └── shell-wrapper/         # Shell wrapper research (superseded by seccomp-notify)
```

### Build contexts

Each Dockerfile uses only its own directory as build context:
- `docker build -f gateway/Dockerfile gateway/` — copies `gateway/` only
- `docker build -f egress-proxy/Dockerfile egress-proxy/` — copies `egress-proxy/` only
- `docker build -f test/echo-server/Dockerfile gateway/` — reuses gateway source for test echo server

The compose file maps `tidegate.yaml` (runtime config) and `scanner/` into the gateway container via bind mounts.

## Architecture

### Product model

Tidegate is the deployment, not an add-on. The user installs Tidegate and gets:
- An agent framework (OpenClaw, etc.) pre-configured inside the agent container
- MCP servers on an isolated network, reachable only through the scanning gateway
- An agent-proxy that controls all skill HTTP traffic
- One-click MCP server addition via compose config

The user never installs an agent framework directly. They install Tidegate, which includes a safer agent.

### Three enforcement layers

| Layer | Boundary | What it protects | Bypassable? |
|---|---|---|---|
| **seccomp-notify + tg-scanner + skill hardening** | Kernel-level (hard) | Intercepts every `execve` in agent container. tg-scanner reads files from shared volume, analyzes scripts, blocks encoding of sensitive data. No code in agent container. | No (seccomp filter installed by kernel, cannot be removed from userspace) |
| **Tidegate MCP gateway** | Network-enforced (hard) | Scans all MCP tool call parameters and responses | No (separate Docker network) |
| **Agent-proxy** | Network-enforced (hard) | Scans skill HTTP traffic, injects credentials, blocks unauthorized domains | No (only path to internet) |

**All three layers are hard boundaries.** Layer 1 uses kernel-level seccomp-notify — no security code runs in the agent container. Layer 1 is load-bearing: it catches encryption-before-exfiltration that Layers 2/3 are blind to. See [ADR-001](research/adr/001-seccomp-notify-l1-interception.md) for the full decision record.

### Component model

- **Agent container**: Includes agent framework + skills. On `agent-net` only. All egress goes through gateway or proxy. **No security code** — L1 interception is kernel-level via seccomp-notify. Supports multiple agent profiles (Claude Code, OpenClaw, etc.).
- **tg-scanner container**: On `agent-net`. Receives seccomp-notify execve notifications from the agent container. Runs two processes: the **command evaluator** (parses commands, resolves file references, orchestrates scanning, makes allow/deny decisions) and the **scanner** (value → allow/deny, stateless). Mounts workspace as read-only. Makes all L1 trust-critical decisions outside the agent's blast radius.
- **tidegate-runtime**: Custom OCI runtime wrapper (~50 lines). Injects seccomp-notify config into the agent container's OCI bundle before delegating to `runc`. Not a full runtime — just modifies `config.json` and passes through.
- **Scanner**: Stateless process inside tg-scanner. Single interface: receives a value, returns allow/deny. No filesystem access, no network access, no side effects. Used by the command evaluator (L1), gateway (L2), and agent-proxy (L3).
- **Tidegate gateway**: MCP-to-MCP proxy. Mirrors downstream tool lists, scans all values, returns shaped denies. Bridges `agent-net` and `mcp-net`.
- **Agent-proxy**: MITM proxy for skill HTTP traffic. Domain allowlisting, content scanning, credential injection. Bridges `agent-net` and `proxy-net`.
- **MCP server containers**: Standard community servers, unmodified. On `mcp-net` only. Hold API credentials.
- **Network topology**: NOT pluggable. Three Docker networks enforce trust boundaries. This is the security model.

### Detailed architecture

```
agent container (agent-net, HTTPS_PROXY=agent-proxy)
  ├── agent framework (Claude Code / OpenClaw / etc.)
  │     ├── hardened skills (rewritten SKILL.md on install)
  │     ├── Claude Code also gets PreToolUse hooks
  │     ├── NO security code in container
  │     └── seccomp filter: every execve notifies tg-scanner
  │
  ├──────→ tg-scanner (agent-net)                              ← Layer 1 (hard)
  │           ├── receives execve notifications via seccomp fd
  │           ├── reads command args from /proc/<pid>/mem
  │           ├── reads workspace files (shared read-only volume)
  │           ├── command evaluator: parses scripts, resolves globs
  │           ├── scanner: value → allow/deny
  │           └── returns ALLOW or EPERM to kernel
  │
  │ MCP tool calls (Streamable HTTP)
  ├──────→ tidegate gateway ──→ mcp-net ──→ MCP server containers ──→ internet
  │          (mirrors tools, scans all values, shaped denies)   ← Layer 2 (hard)
  │
  │ ALL other HTTPS (skill HTTP + LLM API)
  └──────→ agent-proxy                                         ← Layer 3 (hard)
             ├── LLM domains: CONNECT passthrough (no MITM)
             ├── skill domains: MITM + scan + credential injection
             └── everything else: BLOCKED
                   │
                   ▼ proxy-net → internet

tidegate-runtime (OCI wrapper, runs on host / in VM)
  └── injects seccomp-notify config into agent container's OCI bundle
      before delegating to runc
```

### Network topology (the security model)

Three Docker networks enforce the trust boundary:

- **agent-net** (`internal: true`, `enable_ipv6: false`): Agent + Tidegate + agent-proxy. No direct internet access.
- **proxy-net** (`enable_ipv6: false`): Agent-proxy only. Internet access for LLM API calls and skill-allowed domains.
- **mcp-net** (`internal: true`, `enable_ipv6: false`): Tidegate + MCP server containers. No agent access.

How it works:
- Agent reaches Tidegate directly on `agent-net` (MCP tool calls)
- Agent reaches LLM APIs and skill-allowed domains via `HTTPS_PROXY` → agent-proxy → `proxy-net` → internet
- Tidegate bridges `agent-net` and `mcp-net` — only path between agent and MCP servers
- Agent-proxy bridges `agent-net` and `proxy-net` — only path between agent and internet
- MCP servers on `mcp-net` can reach the internet directly (they are the HTTP clients that call external APIs)
- **Credentials**: API keys live in MCP server containers (for MCP tools) and agent-proxy config (for skill HTTP). Never in the agent container.
- **Docker >= 25.0.5 required**: Fixes CVE-2024-29018 (DNS exfiltration on internal networks)

### Layer 1: seccomp-notify command interception

Every `execve` syscall in the agent container is intercepted by the kernel and forwarded to `tg-scanner` for evaluation. **No security code runs inside the agent container.**

**OCI runtime wrapper** (`tidegate-runtime`): A thin wrapper around `runc` that injects seccomp-notify configuration into the agent container's OCI bundle:
- Adds `SCMP_ACT_NOTIFY` for `execve` and `execveat` syscalls
- Sets `listenerPath` pointing to tg-scanner's Unix socket
- Delegates everything else to `runc`

**tg-scanner** (command evaluator + scanner):

1. Receives the seccomp notification — thread in agent container is paused by kernel
2. Reads command and arguments from `/proc/<pid>/mem` (validates with `SECCOMP_IOCTL_NOTIF_ID_VALID`)
3. Reads the script source from the shared read-only workspace volume
4. Analyzes the script for file discovery patterns (e.g., `glob.glob("**/*.csv")`)
5. Resolves those patterns against the shared volume — same directory tree
6. Reads and scans discovered files via the scanner (value → allow/deny)
7. Analyzes the command/script for encoding and exfiltration patterns
8. Correlates: sensitive files + encoding/exfil intent → DENY (`EPERM`) or ALLOW

The correlation logic lives in the command evaluator, not the scanner. The scanner just answers "is this text sensitive?" The command evaluator determines "is this command dangerous given what it can reach?"

**Why this is load-bearing**: Without Layer 1, a skill reads `bank_statement.csv` (contains credit card numbers), base64-encodes it, and sends the encoded blob through an allowed domain. Layers 2/3 see high-entropy data going to a legitimate API — no patterns to match. Layer 1 catches the credit card numbers in the CSV *before* the encoding command runs.

**Why seccomp-notify, not a shell wrapper**: A shell wrapper replacing `/bin/sh` only intercepts commands that go through the shell. A motivated agent can bypass it via direct `execve()` from Python (`os.execv`), Node.js (`child_process.execFileSync`), alternate shells, binaries on tmpfs, or `memfd_create` + `fexecve`. seccomp-notify intercepts the `execve` *syscall* — every bypass vector still hits the kernel filter. See [ADR-001](research/adr/001-seccomp-notify-l1-interception.md).

**Agent-specific bonuses**: On Claude Code, Tidegate also installs PreToolUse hooks that scan tool arguments before execution (shaped deny back to the LLM). Other agent frameworks get seccomp-notify interception (universal) but not framework-specific hooks.

### Layer 1: skill hardening

When a user installs a skill, Tidegate rewrites the SKILL.md before the agent loads it:

1. Strips `!`command`` preprocessing (executes shell commands at load time, before hooks fire)
2. Constrains `allowed-tools` in frontmatter (minimum privilege)
3. Wraps bundled scripts to route through the shell wrapper

This operates on the cross-platform SKILL.md file format (supported by Claude Code, Codex CLI, OpenClaw, Cursor, and 20+ other platforms). No framework-specific API needed.

### Agent-proxy

Replaces the simple CONNECT-only egress proxy. Skills need HTTP access for their APIs, so blocking all internet breaks legitimate functionality. The agent-proxy provides selective behavior:

- **LLM API domains**: CONNECT passthrough. End-to-end TLS, no inspection. The proxy sees only the domain from the CONNECT request.
- **Skill-allowed domains**: MITM. The proxy terminates TLS, scans request/response bodies for sensitive patterns, injects authentication headers (credential injection), then re-encrypts to the upstream server.
- **Everything else**: Connection refused.

Credential injection means skills never hold API keys. The proxy configuration maps domains to credentials. A skill calls `fetch("https://api.slack.com/...")` and the proxy adds the `Authorization` header. The credential exists only in the proxy's config (injected via `op run`), not in the agent container.

### Scanning model: mirror + scan

The gateway mirrors downstream MCP servers' tool definitions and scans all outbound parameter values. No per-field YAML mappings needed.

**Why not field-level classification?** We evaluated field-level scanning (classifying each parameter as `system_param` vs `user_content` and only scanning free-text fields) and concluded it doesn't justify the complexity. L2 patterns (Luhn for credit cards, mod-97 for IBANs, SSN format validation) are checksum-based with zero mathematical false positives. Running them on channel IDs, commit SHAs, and enum values produces no spurious alerts. The entire market (25+ competing tools) validates blob scanning as sufficient.

**Configuration model**:
```yaml
# tidegate.yaml — mirror + scan
version: "1"
defaults:
  scan_timeout_ms: 500
  scan_failure_mode: deny

servers:
  slack:
    transport: http
    url: http://slack-mcp:3000
    # tools: omit to mirror all, or specify allowlist:
    # allow_tools: [post_message, list_channels]

  github:
    transport: http
    url: http://github-mcp:3000
```

Compare to the old per-field model which required 20+ lines per tool with field classes, validation rules, and scan directives.

### Scanner interface

The scanner has one interface, used by all callers:

```
Input:  { "value": "..." }
Output: { "allow": true } | { "allow": false, "reason": "..." }
```

The scanner does not know what it's scanning — a Slack message body, a CSV file, a Python script, an HTTP request body. It receives text, returns a verdict. No filesystem access, no network access, no side effects. Trivially testable: feed it JSON, assert on the verdict.

All callers (MCP gateway, agent-proxy, shell wrapper) do their own extraction and send values to the scanner. Correlation logic ("sensitive input + encoding operation = deny") lives in the callers, not the scanner. The scanner just answers "is this text sensitive?"

### Tech stack

- **Gateway core**: TypeScript. MCP SDK is TS-native, natural JSON-RPC handling.
- **Scanner**: Python as stateless subprocess. Uses `python-stdnum` for checksum validation. Single interface shared by all callers.
- **L1 scanning** (vendor-prefix credential patterns) stays in TypeScript in the gateway — no subprocess round-trip for MCP tool calls.
- **L2/L3** (Luhn, IBAN, SSN, entropy) goes to Python subprocess.
- **tg-scanner**: Contains the command evaluator (understands commands, resolves file references, orchestrates scanning) and the scanner (stateless value → allow/deny). Language TBD for command evaluator (Go recommended for seccomp-notify integration via `libseccomp-golang`).
- **tidegate-runtime**: OCI runtime wrapper. Thin shell/binary that modifies OCI config.json and delegates to runc.
- **Scanner interface is replaceable**: all callers speak the same protocol to an opaque scanning process. Python now, could be anything later.

### Gateway modules (6)

| Module | Role |
|---|---|
| `host.ts` | MCP server over Streamable HTTP. Per-request `Server` instances in stateless mode. |
| `router.ts` | Request lifecycle: scan all values → forward → scan response → return. Denial at any step short-circuits. |
| `policy.ts` | Loads `tidegate.yaml`. Tool allowlists. Tool mirroring from downstream servers. |
| `scanner.ts` | Leak detection. L1 in-process (credential patterns), L2/L3 via Python subprocess. |
| `servers.ts` | MCP client connections to downstream servers. No security logic — pure forwarding. |
| `audit.ts` | Structured NDJSON logging. Every allow/deny/error with tool, field, reason, layer, duration. |

Module design note: `servers.ts` has no knowledge of policy, scanning, or sessions. `router.ts` only calls `servers.forward()` on the pass path. Clean boundary allows future process split if needed.

## Key architectural decisions

| Decision | Rationale |
|---|---|
| Tidegate = deployment (includes agent) | Not an add-on to an existing agent install. User installs Tidegate, gets a safer agent. Supports multiple agent profiles. |
| Layer 1 is load-bearing AND hard | seccomp-notify catches encryption-before-exfiltration that Layers 2/3 are blind to. Kernel-level, not bypassable from userspace. All three layers are now hard boundaries. |
| seccomp-notify, not shell wrapper | Shell wrapper (replacing `/bin/sh`) is bypassable via direct `execve()` from scripting runtimes. seccomp-notify intercepts the syscall itself — no userspace bypass. See [ADR-001](research/adr/001-seccomp-notify-l1-interception.md). |
| tg-scanner outside blast radius | All trust-critical decisions (command analysis, file scanning, correlation) happen in tg-scanner container, not in the agent container. Shared read-only volume lets tg-scanner read files independently. |
| Scanner has one interface | All callers send values, get verdicts. Scanner has no filesystem/network access. Correlation logic lives in callers (command evaluator, gateway, proxy). |
| Mirror + scan, not field-level classification | Blob scanning with checksum-validated patterns has near-zero FPs. Market validated this. Eliminates per-tool YAML mapping burden. |
| MITM agent-proxy replaces CONNECT-only egress | Skills need HTTP access. MITM enables content scanning + credential injection for skill traffic. |
| Credential injection through proxy | Skills never hold API keys. Proxy adds auth headers. Extends MCP credential isolation to skills. |
| Skill hardening via SKILL.md rewriting | Framework-agnostic — operates on the cross-platform SKILL.md file format, not on framework APIs. |
| Shaped denies as `isError: false` | Agent reads explanation and adjusts, not retries blindly |
| Build custom gateway | No existing gateway supports shaped denies + blob scanning + tool mirroring in a network-enforced topology |
| Per-request MCP Server instances | SDK's `Server.connect()` is one-shot. Fresh `Server` per request avoids transport lifecycle issues. |

### Credential model
- **MCP servers** hold credentials for their APIs (Slack token, GitHub PAT, etc.)
- **Agent-proxy** holds credentials for skill-allowed domains (injected into HTTP requests)
- `op run --env-file .env` wraps `docker compose up` on the host, resolving `op://` references
- For development: plain `.env` file (gitignored) with real values
- The agent container never sees API keys, tokens, or passwords
- **One exception**: the LLM API key must exist in the agent container (hard architectural limit)

### Leak detection scope
- **Applied to**: all outbound parameter values (MCP tool calls), all outbound HTTP request bodies (skill traffic), and all file contents referenced by commands (shell wrapper)
- **L1**: Vendor-prefix credential patterns (AWS `AKIA`, Slack `xoxb-`, GitHub `ghp_`, etc.), private keys, sensitive JSON keys. In-process TypeScript in gateway; scanner subprocess for shell wrapper and agent-proxy.
- **L2**: Financial instruments (Luhn for credit cards, mod-97 for IBANs), government IDs (SSN with context keywords). Python subprocess. Zero false positives by design.
- **L3**: Shannon entropy detection, base64/hex detection. Python subprocess. Higher false positive rate — use judiciously.
- **Not detected**: Semantic rephrasing of sensitive data as natural language. Fundamental limit of pattern-based detection.
- See `THREAT_MODEL.md` for the full sensitive data taxonomy and honest scorecard

### Security posture
- Deny-by-default: unauthorized domains blocked, unauthorized tools optionally hidden
- Fail-closed on all error paths
- No root in any container (`cap_drop: ALL`, `no-new-privileges: true`)
- Credentials never in agent container (except LLM API key)
- Audit log: every tool call and HTTP request recorded before forwarding

## Shaped deny wire format

```json
{
  "jsonrpc": "2.0",
  "id": 42,
  "result": {
    "content": [{
      "type": "text",
      "text": "Policy violation: tool 'post_message' parameter 'text' contains a pattern matching a Slack bot token (xoxb- prefix). Message not sent. Remove the credential and retry."
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
- YAML: configuration and Docker Compose files. Explicit long-form, not clever anchors.
- Shell: POSIX sh for scripts, not bash. Must work in Alpine containers.

### File organization
- Gateway code in `gateway/src/` with its own Dockerfile at `gateway/Dockerfile`
- Scanner code in `scanner/` with its own Dockerfile
- Agent-proxy in `agent-proxy/` (replacing `egress-proxy/`)
- Per-server configuration in `mappings/` (server URLs, tool allowlists)
- Reference compose template at repo root: `docker-compose.yaml`
- Test fixtures in `test/`
- Research docs in `research/<topic>/`
- Do not create new top-level directories without discussion

### MCP SDK patterns
- **Stateless HTTP transport**: each POST request gets a new `Server` + `StreamableHTTPServerTransport` pair. The SDK's `Server.connect()` is one-shot — calling it on a connected server throws. Creating a fresh `Server` per request is cheap (just handler registrations) and avoids transport lifecycle issues.
- **Low-level `Server` class** (from `@modelcontextprotocol/sdk/server/index.js`): used for the gateway's upstream (agent-facing) MCP server.
- **`Client` class** (from `@modelcontextprotocol/sdk/client/index.js`): used for downstream connections to real MCP servers. Persistent connections, reused across requests.
- **`StreamableHTTPClientTransport`**: for connecting to remote MCP servers over HTTP. `StdioClientTransport`: for legacy servers as child processes.

### Security rules
- Never commit secrets, certs, or keys (enforced by `.gitignore`)
- Never use `privileged: true` or `network_mode: host`
- Every shaped deny must be a valid MCP tool result with plain-text explanation — never a protocol error
- Audit log writes must be append-only and synchronous (write before forwarding response)
- Credentials only in MCP server containers and agent-proxy config, never in agent container

### Docker
- Base images: pin exact digest or version tag (not `:latest`)
- All containers: `read_only: true`, `tmpfs: ["/tmp"]`, resource limits set
- All containers: `cap_drop: [ALL]`, `security_opt: ["no-new-privileges:true"]`
- Three networks: `agent-net` (`internal: true`), `proxy-net`, `mcp-net` (`internal: true`). All `enable_ipv6: false`.
- Docker >= 25.0.5 required (CVE-2024-29018 DNS exfiltration fix)
- Dev: `docker compose up --build` from repo root with `.env` file
- Prod: `op run --env-file .env -- docker compose up --build` from repo root

### Testing
- **Dev mode**: `cd gateway && npm run dev` + `npx tsx test-echo-server.ts` — runs gateway and echo server locally without Docker
- **Docker compose**: `docker compose up --build` — full 3-network topology with echo + hello-world servers
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
- Read `README.md` for product context
- Read `THREAT_MODEL.md` if working on security-related code
- Check `research/leak-detection/` if working on detection logic

### When writing gateway code
- Single Node.js process acts as both MCP server (upstream) and MCP client (downstream)
- Six modules with clean boundaries: `host.ts`, `router.ts`, `policy.ts`, `scanner.ts`, `servers.ts`, `audit.ts`
- `servers.ts` has zero knowledge of policy or scanning — it only forwards validated requests
- Enforcement pipeline: tool allowed? → scan all parameter values → forward → scan response → return
- On deny at any step, return shaped deny directly — `servers.ts` is never called
- Wrap downstream calls in try/catch — downstream failures return shaped denies, never crash the gateway

### When writing scanner code
- Scanner is stateless — receives `{value}`, returns `{allow/deny, reason}`
- Single interface used by all callers (MCP gateway, agent-proxy, shell wrapper)
- Scanner has no filesystem access, no network access, no side effects
- Scanner does not know what it's scanning — callers extract content and send values
- Correlation logic ("sensitive input + dangerous operation") lives in callers, not scanner
- L1 stays in TypeScript in the gateway (vendor-prefix patterns, no subprocess round-trip)
- L2/L3 go to Python subprocess
- L2 patterns (Luhn, mod-97, SSN) must have zero false positives — use mathematical validation

### When writing tg-scanner / command evaluator code
- Command evaluator runs in `tg-scanner` container, receives seccomp-notify execve notifications
- Reads command args from `/proc/<pid>/mem`, validates notification with `SECCOMP_IOCTL_NOTIF_ID_VALID`
- Reads script sources and referenced files from the shared read-only workspace volume
- Resolves file discovery patterns (globs) against the shared volume
- Sends file contents to the scanner as values
- Analyzes commands/scripts for encoding + exfiltration patterns
- Correlates: sensitive content (scanner said deny) + encoding/exfil pattern → block (EPERM)
- Scanner stays simple: `{value} → {allow/deny, reason}` — command evaluator does all orchestration

### When writing tidegate-runtime code
- OCI runtime wrapper — thin, delegates to runc
- Injects `listenerPath` and `SCMP_ACT_NOTIFY` for execve/execveat into the OCI bundle's config.json
- Must not break non-agent containers — only inject for containers with a specific label or annotation
- Test with `runc spec` to generate a reference config.json

### When writing Docker Compose
- Three networks: `agent-net` (`internal: true`), `proxy-net`, `mcp-net` (`internal: true`). All `enable_ipv6: false`.
- Agent container on `agent-net` only, with `HTTPS_PROXY=http://agent-proxy:3128`
- Tidegate container on both `agent-net` and `mcp-net`
- Agent-proxy on both `agent-net` and `proxy-net`, with domain allowlists and credential config
- MCP server containers on `mcp-net` only
- Docker >= 25.0.5 required

### When writing Dockerfiles
- Multi-stage builds: `build` stage for compilation, `runtime` stage for slim image
- Non-root user in all images
- `HEALTHCHECK` instruction in every Dockerfile
- Pin base image versions (e.g., `node:22-alpine3.21`, not `node:alpine`)

### Updating project docs
- `UNKNOWNS.md`: mark items resolved; add new items at the bottom
- `THREAT_MODEL.md`: update if new attack vectors or mitigations are discovered
- `README.md`: update when the product changes
- `CLAUDE.md`: update when project structure, conventions, or status changes

## Explicitly deferred

- Dashboard/web UI for logs, killswitch, server management
- LLM-assisted skill scanning (`tidegate discover <skill>`)
- Community skill/server registry
- Multi-agent policy / RBAC
- Approval workflows for sensitive tool calls
- Behavioral anomaly detection (audit log is infrastructure-ready, detection logic is future)
