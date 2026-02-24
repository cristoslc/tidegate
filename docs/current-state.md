# Tidegate — Current State

Last updated: 2026-02-23

## Summary

The MCP gateway works end-to-end with demo servers using the mirror+scan model. The gateway scans all string values in tool call parameters and responses without per-field YAML mappings — adding a new MCP server requires only a URL in `tidegate.yaml`. Scanning (L1/L2/L3), shaped denies, and audit logging are functional. The Docker 3-network topology is defined. There is no agent container, no setup script, and no real MCP server integration.

## What's built and working

### MCP gateway (6 modules, ~1200 LOC TypeScript)

All modules compile clean. The gateway acts as both an MCP server (agent-facing on port 4100) and MCP client (connecting to downstream servers).

| Module | LOC | Status | What it does |
|--------|-----|--------|-------------|
| `host.ts` | 146 | Working | Streamable HTTP server. Per-request `Server` + `Transport` pair (stateless mode). Health check at `/health`. |
| `router.ts` | ~120 | Working | 5-step pipeline: resolve tool server → check allowed → scan all string values → forward → scan response. Short-circuits with shaped deny on any failure. Uses `extractStringValues()` recursive walker. |
| `policy.ts` | ~65 | Working | Loads `tidegate.yaml`. `ServerConfig` with optional `allow_tools`. `isToolAllowed()` check. No per-field mappings. |
| `scanner.ts` | 330 | Working | L1 in-process (vendor-prefix credential patterns, sensitive JSON keys). L2/L3 via Python subprocess (NDJSON protocol). Auto-respawn with backoff (max 5 attempts). Fail-closed on subprocess unavailability or timeout. |
| `servers.ts` | 157 | Working | Persistent MCP client connections. Streamable HTTP and stdio transports. Tool discovery via `listTools()`. Pure forwarding — zero policy knowledge. |
| `audit.ts` | 40 | Working | NDJSON structured logging. Every allow/deny/error with tool, server, verdict, layer, reason, duration. |

### Python scanner (L2/L3, ~330 LOC)

Stateless subprocess. NDJSON protocol: `{value} → {allowed, reason, layer}`.

- **L2** (zero false positives): Credit cards (Luhn), IBANs (mod-97), US SSNs (format + area validation)
- **L3** (tuned FP rate): SSN with context keywords, base64 detection (entropy > 4.5), hex strings (entropy > 3.5), high-entropy sliding window (entropy > 5.0)
- Dependency: `python-stdnum` with built-in fallback
- This module is solid and does not need changes for the mirror+scan refactor

### L1 in-process scanning (in `scanner.ts`)

Runs synchronously in the gateway process, ~0.1ms per check:

- **Credential patterns** (13 patterns): AWS `AKIA`, Slack `xoxb-`/`xoxp-`, GitHub `ghp_`/`github_pat_`, Stripe `sk_live_`/`pk_live_`, generic API keys, Bearer tokens, private key blocks, 1Password `ops_`
- **Sensitive JSON key patterns** (7 patterns): SSN, password, API key, credit card, private key, auth token, bank account
- These run on values, not field names — catches credentials embedded in free-text

### Docker infrastructure

**`docker-compose.yaml`** — Complete 3-network topology:
- `agent-net` (`internal: true`): tidegate + egress-proxy. No agent container defined.
- `proxy-net`: egress-proxy only.
- `mcp-net` (`internal: true`): tidegate + demo servers.
- All networks: `enable_ipv6: false`.
- All containers: `read_only: true`, `cap_drop: ALL`, `no-new-privileges`, resource limits.

**Dockerfiles** (4):
- `gateway/Dockerfile` — Multi-stage Node.js 22 Alpine. Installs Python for scanner subprocess. Non-root user. Health check.
- `egress-proxy/Dockerfile` — Squid 6.12 on Alpine 3.21. CONNECT-only, hardened config. Non-root.
- `test/echo-server/Dockerfile` — Reuses gateway build context. Exposes `echo` and `echo_system` tools.
- `hello-world/Dockerfile` — In-memory notes server. `save_note`, `list_notes`, `get_note` tools.

### Egress proxy (Squid CONNECT-only)

Working Squid 6.12 proxy. Allowlists LLM API domains (`api.anthropic.com`, etc.) via file-based allowlist. Hot-reload via `HUP` signal. No MITM, no content scanning, no credential injection — this is a placeholder for the future agent-proxy.

### Configuration

**`tidegate.yaml`** — Mirror+scan config:
```yaml
version: "1"
defaults:
  scan_timeout_ms: 500
  scan_failure_mode: deny
servers:
  echo:
    transport: http
    url: http://echo-server:4200/mcp
  hello-world:
    transport: http
    url: http://hello-world:4300/mcp
```

Adding a new MCP server requires only its URL. The gateway discovers tools via `listTools()` and scans all string values automatically.

### Research

- **ADR-001** (`adr/superseded/001-seccomp-notify-l1-interception.md`): Accepted. Full decision record for seccomp-notify over shell wrapper. Covers alternatives (eBPF, Tetragon, fanotify), residual risks, requirements.
- **Leak detection research** (`research/completed/leak-detection/`): Evaluated 25+ tools. Validated 3-layer architecture. Selected `python-stdnum`.
- **Shell wrapper research** (`research/superseded/shell-wrapper/`): Superseded by ADR-001.

### Documentation

- `../CLAUDE.md` — Project instructions for Claude (current codebase, not aspirational)
- `../README.md` — User-facing overview with attack scenarios
- `threat-model/` — Real-world incidents (ClawHavoc, Superhuman, EchoLeak), adversary profiles, honest scorecard
- `research/planning/` — open questions (e.g., protocol abuse resistance)

## What's not built

| Component | Status | Notes |
|-----------|--------|-------|
| **Agent container** | Nothing | No Dockerfile. No Claude Code headless setup. No OpenClaw integration. |
| **Mirror+scan gateway refactor** | **DONE** | Gateway scans all string values. No per-field YAML. `policy.ts` simplified, `router.ts` rewritten. |
| **`setup.sh`** | Nothing | No bootstrap script. |
| **Real MCP server configs** | Nothing | Only demo servers (echo, hello-world). No Gmail, Slack, GitHub. |
| **Credential passthrough** | Nothing | No Claude Code auth mounting. No `.env.example`. |
| **MCP routing from agent** | Nothing | No Claude Code MCP config pointing to gateway. |
| **Agent-proxy (MITM)** | Nothing | Squid CONNECT-only placeholder exists. No content scanning, no credential injection. |
| **tg-scanner container** | Nothing | ADR-001 superseded by ADR-002. No Go code. Architecture: eBPF loader + scanner daemon + connect enforcer. |
| **tidegate-runtime** | Nothing | OCI wrapper injects seccomp-notify for `connect()`. No code. |
| **Skill hardening** | Nothing | SKILL.md rewriting designed. No implementation. |
| **Claude Code hooks** | Nothing | PreToolUse hooks mentioned. No integration. |

## Code-to-documentation drift

The following items are described in docs as if they exist, but are not implemented:

1. **Agent container with agent framework** — README and threat model describe an agent running inside the container topology. No agent container exists.
2. **seccomp-notify interception** — Described as functional in README attack scenarios. Only designed (ADR-001), no code.
3. **Agent-proxy with MITM + credential injection** — Described as a hard boundary. Only a CONNECT-only Squid proxy exists.
4. **Skill hardening** — Described as active. Not implemented.

## Dependencies and versions

| Dependency | Version | Used by |
|-----------|---------|---------|
| Node.js | 22 (Alpine 3.21) | Gateway |
| TypeScript | 5.9.3 | Gateway |
| `@modelcontextprotocol/sdk` | ^1.26.0 | Gateway (Client + Server) |
| `yaml` | ^2.8.2 | Gateway config |
| Python | 3 (Alpine) | Scanner subprocess |
| `python-stdnum` | >=1.20,<2.0 | Scanner (Luhn, IBAN) |
| Squid | 6.12 (Alpine 3.21) | Egress proxy |
| Docker | >= 25.0.5 | Required (CVE-2024-29018) |
