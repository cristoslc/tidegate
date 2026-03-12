# System Architecture

## Purpose

Tidegate is a security enforcement layer for AI agents that access external tools and services. It interposes between an agentic runtime (Claude Code, Codex CLI, Goose, Aider) and the outside world, scanning all data flows for sensitive content before they leave the operator's control.

The operator picks their runtime. Tidegate provides the topology that makes enforcement possible.

## Design principles

1. **Seams first.** Every container boundary, network segment, and mount point exists to enable a security enforcement layer. The topology is designed around the enforcement boundaries, not the other way around.
2. **Runtime-agnostic.** Any CLI-based AI coding tool that can run in a container works. The runtime runs unmodified — seams are structural, not contractual.
3. **No cooperation required.** The runtime doesn't need plugins, patches, or special flags (beyond headless mode). It sees MCP servers at expected URLs. It reaches the internet through a proxy it doesn't know about. Its file access is observed without its knowledge.
4. **MCP-first, network-fallback.** For runtimes with MCP support, scan at the MCP protocol level (highest fidelity). For runtimes without MCP, scan at the HTTP proxy level (lower fidelity but universal).
5. **Defense in depth.** Multiple seams fire independently. MCP scanning, network scanning, taint tracking, and skill vetting all run simultaneously when available.
6. **Fail-closed.** Scanner unavailable = deny. Proxy down = no egress. Container crash = session over.

## Components

### Tideclaw orchestrator

The host-side CLI that reads `tideclaw.yaml`, generates a Docker Compose spec, starts the container topology, and manages the session lifecycle. It is the entry point — the operator runs Tideclaw, and Tideclaw runs everything else.

### Agent container

Runs the operator's chosen agentic runtime (Claude Code, Codex CLI, Goose, Aider). Sits on `agent-net` only. Has no credentials for external services. Its MCP config points to `tg-gateway`, its `HTTPS_PROXY` points to the egress proxy, and its workspace is mounted read-write.

The runtime's own sandboxing (bubblewrap, Landlock, Seatbelt) is additive — Tidegate's topology provides the outer boundary regardless of what the runtime enforces internally.

### tg-gateway (L2)

MCP interposition proxy. Connects to downstream MCP servers on `mcp-net`, discovers their tools via `listTools()`, and mirrors them to the agent on `agent-net`. Every tool call passes through a five-step pipeline:

1. Is the tool allowed? (per-server allowlist)
2. Scan all string values in the arguments (recursive walk)
3. Forward to the downstream MCP server
4. Scan all string values in the response
5. Return result or shaped deny

The gateway has zero knowledge of credentials. It sees tool names, argument names, and string values — enough for structured scanning. Shaped denies use `isError: false` so the agent adjusts its behavior rather than retrying.

### MCP server containers

Each downstream MCP server (Gmail, Slack, GitHub, etc.) runs in its own container on `mcp-net`. Each holds only its own credentials via environment variables. The agent container cannot reach `mcp-net` — only the gateway bridges the two networks.

Adding a server: add its URL to config, add the container to compose, provide credentials. The gateway discovers its tools automatically.

### Egress proxy (L3)

Controls all HTTP/HTTPS traffic leaving the agent container. Three modes per domain:

- **LLM API domains** — CONNECT passthrough (end-to-end TLS, no inspection)
- **Allowed domains** — MITM: terminate TLS, scan request/response bodies, inject credentials, re-encrypt. Skills never hold API keys.
- **Everything else** — blocked

At MVP this is a Squid CONNECT-only proxy (passthrough + block, no MITM). Post-MVP it becomes a full agent-proxy with MITM scanning and credential injection.

### tg-scanner (L1)

Journal-based taint tracker. Runs on `agent-net` with a read-only mount of the agent's workspace. Three sub-components:

- **eBPF loader** — Attaches to `openat` in the agent container's kernel namespace. Logs `{pid, file_path, sequence_number}` to a ring buffer. Non-blocking, nanosecond overhead. Pure observation.
- **Scanner daemon** — Reads file-open events from the ring buffer. Reads file contents from the shared workspace volume. Runs the same L1/L2/L3 scanner pipeline. Updates a taint table: if a file contains sensitive data, the PID that opened it is tainted.
- **Connect enforcer** — Receives seccomp-notify events when any process in the agent container calls `connect()`. Waits for the scanner daemon to catch up with pending events for that PID. Checks taint table. Tainted = `EPERM`. Clean = allow.

The `connect()` interception is installed at container creation by `tidegate-runtime`, a thin OCI runtime wrapper that injects the `SCMP_ACT_NOTIFY` seccomp filter. The kernel pauses the calling thread on `connect()`, providing a natural synchronization barrier — no race between async scanning and enforcement.

## Network topology

```
┌──────────────────────────────────────────────────────────────┐
│                       Tideclaw host                          │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │               Docker / Podman                          │  │
│  │                                                        │  │
│  │  ┌─────────────────────┐                               │  │
│  │  │  AGENT CONTAINER    │      agent-net (internal)     │  │
│  │  │                     │                               │  │
│  │  │  any agentic        │      ┌──────────────────┐     │  │
│  │  │  runtime             │─MCP─►│    tg-gateway     │     │  │
│  │  │                     │      │    (L2 scan)      │     │  │
│  │  │  /workspace (rw)    │      └────────┬─────────┘     │  │
│  │  │  ~/.claude (ro)     │               │               │  │
│  │  │  no credentials     │        mcp-net (internal)     │  │
│  │  │                     │               │               │  │
│  │  │                     │      ┌────────▼─────────┐     │  │
│  │  │                     │      │   MCP servers     │     │  │
│  │  │                     │      │   (credentials    │     │  │
│  │  │                     │      │    live here)     │     │  │
│  │  │                     │      └──────────────────┘     │  │
│  │  │                     │                               │  │
│  │  │                     │      ┌──────────────────┐     │  │
│  │  │                     │─HTTP─►│   egress-proxy   │─────┼──► Internet
│  │  │                     │      │   (L3 scan)      │     │  │
│  │  │                     │      └──────────────────┘     │  │
│  │  │                     │      proxy-net                │  │
│  │  │                     │                               │  │
│  │  │                     │      ┌──────────────────┐     │  │
│  │  │                     │      │   tg-scanner      │     │  │
│  │  │                     │      │   (L1 taint)      │     │  │
│  │  │                     │      │   /workspace (ro) │     │  │
│  │  └─────────────────────┘      └──────────────────┘     │  │
│  │                                                        │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

Three networks enforce separation:

| Network | Connects | Purpose |
|---------|----------|---------|
| `agent-net` (internal) | agent, tg-gateway, egress-proxy, tg-scanner | Agent's only reachable network. No direct internet. |
| `mcp-net` (internal) | tg-gateway, MCP servers | Credentials live here. Agent cannot reach this network. |
| `proxy-net` | egress-proxy | Sole path to the internet from the agent topology. |

## Enforcement seams

Five boundaries where data flow is inspected or controlled. Each seam operates independently — compromise of one does not disable the others.

| Seam | Where | What it enforces | Bypass condition |
|------|-------|-----------------|------------------|
| **MCP interposition** (L2) | tg-gateway, between agent and MCP servers | Scans all tool call parameters and responses for sensitive data patterns | Agent reaches MCP servers without going through the gateway (network misconfiguration) |
| **Egress mediation** (L3) | egress-proxy, between agent and internet | Domain allowlisting; HTTP body scanning and credential injection (post-MITM) | Agent reaches the internet without going through the proxy (network misconfiguration) |
| **Credential isolation** | Container mount boundaries | API keys and tokens exist only in the containers that need them | Credentials mounted into the wrong container (compose misconfiguration) |
| **Kernel observation** (L1) | tg-scanner + tidegate-runtime, via eBPF and seccomp-notify | Tracks file access, blocks tainted processes from network connections | eBPF/seccomp-notify unavailable (degrades to L2/L3 only) |
| **IPC scanning** | Orchestrator, between agent IPC and external channels | Scans all IPC payloads before the orchestrator forwards to messaging/task systems | Orchestrator forwards IPC without scanning (code bug) |

## Three-layer scanning

Each layer has a distinct detection basis. They are not redundant — each is primary for different data flow segments.

| Layer | Location | Detection basis | Catches | Misses |
|-------|----------|----------------|---------|--------|
| **L1** (taint) | tg-scanner | Runtime file access observation — which PIDs opened which files | Encode-before-exfiltrate (PID tainted by file open, encoding irrelevant) | Semantic propagation through LLM context; agent framework process (PID 1) |
| **L2** (gateway) | tg-gateway | Pattern matching on MCP tool call string values | Credentials, financial instruments, government IDs in cleartext tool calls | Encoded/encrypted data; data that never touches MCP |
| **L3** (proxy) | egress-proxy | Pattern matching on HTTP request/response bodies | Same as L2, but for non-MCP HTTP traffic; also credential injection | Encoded/encrypted data; CONNECT-passthrough traffic (LLM API) |

### Input-output coverage

| Data path | Primary layer | What catches it |
|-----------|--------------|-----------------|
| Workspace file → MCP tool call | L1 + L2 | L1 taints PID on file open; L2 scans tool parameters |
| Workspace file → shell → HTTP | L1 + L3 | L1 taints PID, blocks connect(); L3 scans HTTP body |
| Workspace file → encrypt → exfiltrate | **L1 only** | L2/L3 blind to encrypted data; L1 blocks connect() for tainted PID |
| MCP response → MCP tool call | L2 | Gateway scans both directions |
| Agent context → MCP tool call (semantic) | **None** | LLM rephrases data; no pattern survives; fundamental limit |

## Integration modes

The topology adapts based on what the runtime supports.

### Mode 1: MCP Gateway

For runtimes with MCP support (Claude Code, Codex CLI, Goose).

```
Agent ──MCP──► tg-gateway (scan) ──MCP──► downstream MCP servers
Agent ──HTTP──► egress-proxy ──────────► LLM API (passthrough)
```

Highest scanning fidelity. Every string value in every tool call is scanned with full structural context (tool name, argument name, value).

### Mode 2: Network Proxy

For runtimes without MCP (Aider, any HTTP-only tool).

```
Agent ──HTTP──► egress-proxy (scan) ──► external APIs
```

Medium fidelity. HTTP bodies are scanned but without MCP structural framing. The proxy sees raw payloads, not tool names and argument schemas.

### Mode 3: Hybrid

For runtimes that use both MCP and direct HTTP (Claude Code, Codex CLI).

```
Agent ──MCP──► tg-gateway (high-fidelity scan)
Agent ──HTTP──► egress-proxy (medium-fidelity scan)
```

This is the default. MCP traffic gets gateway-level scanning. Non-MCP HTTP traffic (shell commands making HTTP requests, skill HTTP calls) gets proxy-level scanning. Both pipelines run independently.

## Trust boundaries

```
UNTRUSTED                          TRUSTED
─────────────────────────────────────────────────────
agent runtime          │           tg-gateway
community skills       │           tg-scanner
downloaded MCP servers │           egress-proxy
workspace files        │           tidegate-runtime
                       │           operator's MCP servers
                       │           tideclaw CLI
```

Everything inside the agent container is untrusted. All enforcement infrastructure runs outside the agent container in separate trust domains. No security-critical code runs inside the agent.

The one exception: the orchestrator's IPC scanning (seam 5) runs in the orchestrator process, which is trusted infrastructure. If the orchestrator is compromised, IPC scanning is bypassed — but the orchestrator is operator-controlled code, not agent-reachable.

## Credential flow

```
Host machine
  └── claude login → ~/.claude/ (OAuth tokens)

tideclaw.yaml
  ├── mcp_servers.*.credentials → compose env vars → MCP server containers
  ├── egress.allowed.*.credentials → proxy config → egress-proxy
  └── agent.auth.mount → ~/.claude:/home/agent/.claude:ro

Agent container: ZERO external service credentials
  └── Claude Code auth only (read-only mount)

MCP server containers: OWN credentials only
  └── gmail-mcp gets GMAIL_*, slack-mcp gets SLACK_BOT_TOKEN, etc.

Egress proxy: credential injection config only
  └── Adds Authorization headers to outbound requests
```

## Configuration

```yaml
# tideclaw.yaml — single config file for the entire topology
version: "1"

agent:
  tool: claude-code         # claude-code | codex | aider | goose | custom
  headless: true

mcp_servers:
  slack:
    transport: http
    url: http://slack-mcp:3000/mcp
    credentials:
      SLACK_BOT_TOKEN: ${SLACK_BOT_TOKEN}
    allow_tools: [post_message, list_channels]    # optional allowlist

egress:
  passthrough: [api.anthropic.com, api.openai.com]
  allowed:
    - api.slack.com:
        credentials:
          Authorization: "Bearer ${SLACK_BOT_TOKEN}"

scanning:
  timeout_ms: 500
  failure_mode: deny        # deny | allow
  layers: [L1, L2, L3]
```

Adding a new MCP server: add its entry to `mcp_servers`, provide credentials. The gateway discovers tools automatically.

## Key decisions

| Decision | ADR | Summary |
|----------|-----|---------|
| Taint-and-verify data flow model | [ADR-002](../../../adr/Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) | eBPF + scanner daemon + seccomp-notify. Runtime taint, not static analysis. |
| Agent runtime selection | [ADR-003](../../../adr/Superseded/(ADR-003)-Agent-Runtime-Selection.md) | Runtime-agnostic orchestration; NanoClaw process boundary as initial integration target. |
| IPC as enforcement seam | [ADR-004](../../../adr/Accepted/(ADR-004)-IPC-Orchestrator-Scanning-as-Enforcement-Seam.md) | Orchestrator IPC must be scanned before external forwarding. Fifth seam. |
| Composable VM isolation | [ADR-005](../../../adr/Accepted/(ADR-005)-Composable-VM-Isolation.md) | Tidegate stays Docker-native; agent container interface is transport-based to compose with external VM isolation. |

## Accepted limitations

1. **Semantic exfiltration** — LLM rephrases sensitive data as prose. No pattern scanner catches this. Fundamental limit of all scanning approaches.
2. **LLM API as exfiltration channel** — Agent's LLM API key must exist in the agent container. A sophisticated attacker could encode data in API requests.
3. **Agent framework process (PID 1)** — Reads files and makes network connections. Tainting PID 1 blocks all agent functionality. L1 taint primarily targets child processes spawned to run scripts.
4. **Taint explosion** — If many workspace files are sensitive, most child processes become tainted. Calibration needed: taint on high-confidence findings only (L2 patterns).
5. **Container escape** — Docker shares the host kernel. Hardened config reduces surface. VM isolation (ADR-005, EPIC-001) is the post-MVP upgrade path.

## Related

- [VISION-001](./(VISION-001)-Secure-AI-Agent-Deployment.md) — Product vision and success metrics
- [Target state](./target-state.md) — The `./setup.sh` end goal
- [SPIKE-013](../../../research/Complete/(SPIKE-013)-Tideclaw-Architecture/(SPIKE-013)-Tideclaw-Architecture.md) — Tideclaw design spike (runtime landscape, prior art, detailed architecture)

[Threat model](../../../threat-model/) — Attack scenarios, defenses, scorecard
