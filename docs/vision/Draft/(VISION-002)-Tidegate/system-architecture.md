# System Architecture

## Purpose

Tidegate is a reference architecture for an MCP gateway, egress proxy, and Docker network topology that together enforce data-flow boundaries for AI agents. It interposes between an agentic runtime (Claude Code, Codex CLI, Goose, Aider) and the outside world, scanning all data flows for sensitive content before they leave the operator's control.

The operator picks their runtime. Tidegate provides the boundary.

This document describes how the system would be built. It is a design, not a description of running software.

## Design principles

1. **Seams first.** Every container boundary, network segment, and mount point exists to enable a security enforcement layer. The topology is designed around the enforcement boundaries, not the other way around.
2. **Runtime-agnostic.** Any CLI-based AI agent that can run in a container works. The runtime runs unmodified — seams are structural, not contractual.
3. **No cooperation required.** The runtime doesn't need plugins, patches, or special flags (beyond headless mode). It sees MCP servers at expected URLs. It reaches the internet through a proxy it doesn't know about.
4. **Fail-closed.** Scanner unavailable = deny. Proxy down = no egress. Container crash = session over.

## Components

### tg-gateway

MCP interposition proxy. Connects to downstream MCP servers on `mcp-net`, discovers their tools via `listTools()`, and mirrors them to the agent on `agent-net`. Every tool call passes through a five-step pipeline:

1. Is the tool allowed? (per-server allowlist)
2. Scan all string values in the arguments (recursive walk)
3. Forward to the downstream MCP server
4. Scan all string values in the response
5. Return result or shaped deny

The gateway has zero knowledge of credentials. It sees tool names, argument names, and string values — enough for structured scanning. Shaped denies use `isError: false` so the agent adjusts its behavior rather than retrying.

### Egress proxy

Controls all HTTP/HTTPS traffic leaving the agent container. Two modes per domain:

- **LLM API domains** — CONNECT passthrough (end-to-end TLS, no inspection)
- **Everything else** — blocked

This is a Squid CONNECT-only proxy. It is the sole path to the internet from the agent container. The agent cannot reach the internet without going through it.

### MCP server containers

Each downstream MCP server (Gmail, Slack, GitHub, etc.) runs in its own container on `mcp-net`. Each holds only its own credentials via environment variables. The agent container cannot reach `mcp-net` — only the gateway bridges the two networks.

Adding a server: add its URL to config, add the container to compose, provide credentials. The gateway discovers its tools automatically.

### Agent container

Runs the operator's chosen agentic runtime (Claude Code, Codex CLI, Goose, Aider). Sits on `agent-net` only. Has no credentials for external services. Its MCP config points to `tg-gateway`, its `HTTPS_PROXY` points to the egress proxy, and its workspace is mounted read-write.

The runtime's own sandboxing (bubblewrap, Landlock, Seatbelt) is additive — Tidegate's topology provides the outer boundary regardless of what the runtime enforces internally.

## Network topology

```
┌──────────────────────────────────────────────────────────┐
│                        Docker host                        │
│                                                           │
│  ┌─────────────────────┐                                  │
│  │  AGENT CONTAINER    │      agent-net (internal)        │
│  │                     │                                  │
│  │  any agentic        │      ┌──────────────────┐        │
│  │  runtime            │─MCP─►│    tg-gateway     │        │
│  │                     │      │    (scan)         │        │
│  │  /workspace (rw)    │      └────────┬─────────┘        │
│  │  no credentials     │               │                  │
│  │                     │        mcp-net (internal)        │
│  │                     │               │                  │
│  │                     │      ┌────────▼─────────┐        │
│  │                     │      │   MCP servers     │        │
│  │                     │      │   (credentials    │        │
│  │                     │      │    live here)     │        │
│  │                     │      └──────────────────┘        │
│  │                     │                                  │
│  │                     │      ┌──────────────────┐        │
│  │                     │─HTTP─►│   egress-proxy   │────────► Internet
│  │                     │      │   (allowlist)    │        │
│  └─────────────────────┘      └──────────────────┘        │
│                                proxy-net                  │
│                                                           │
└──────────────────────────────────────────────────────────┘
```

Three networks enforce separation:

| Network | Connects | Purpose |
|---------|----------|---------|
| `agent-net` (internal) | agent, tg-gateway, egress-proxy | Agent's only reachable network. No direct internet. |
| `mcp-net` (internal) | tg-gateway, MCP servers | Credentials live here. Agent cannot reach this network. |
| `proxy-net` | egress-proxy | Sole path to the internet from the agent topology. |

## Enforcement seams

Three boundaries where data flow is inspected or controlled. Each seam operates independently — compromise of one does not disable the others.

| Seam | Where | What it enforces | Bypass condition |
|------|-------|-----------------|------------------|
| **MCP interposition** | tg-gateway, between agent and MCP servers | Scans all tool call parameters and responses for sensitive data patterns | Agent reaches MCP servers without going through the gateway (network misconfiguration) |
| **Egress mediation** | egress-proxy, between agent and internet | Domain allowlisting; blocks all direct internet access | Agent reaches the internet without going through the proxy (network misconfiguration) |
| **Credential isolation** | Container mount boundaries | API keys and tokens exist only in the containers that need them | Credentials mounted into the wrong container (compose misconfiguration) |

## Scanning pipeline

The gateway extracts all string values from tool call arguments and responses via recursive walk. Every string is scanned through a two-tier pipeline:

**In-process (TypeScript):** Fast regex patterns for high-confidence credential formats — AWS access keys (`AKIA...`), GitHub tokens (`ghp_...`, `gho_...`), Slack tokens (`xoxb-...`, `xoxp-...`), private keys, and similar well-structured secrets. These patterns have near-zero false positive rates because the formats are distinctive.

**Subprocess (Python):** Checksum validation and entropy analysis. Luhn algorithm for credit card numbers (zero mathematical false positives — if it passes Luhn, it's structurally valid). `python-stdnum` for government IDs (SSN structure validation). Entropy scoring for high-randomness strings that might be tokens or keys.

The scanner is stateless: it receives a string, returns allow or deny. It has no knowledge of tool names, argument names, or field semantics — it operates on raw string values. This keeps the scanner simple and the boundary clean.

L2 patterns (checksum-validated) must have zero mathematical false positives. This is the design constraint that keeps false positive rates low enough that operators don't disable the scanner.

## Trust boundaries

```
UNTRUSTED                          TRUSTED
─────────────────────────────────────────────────
agent runtime          │           tg-gateway
community skills       │           egress-proxy
downloaded MCP servers │           operator's MCP servers
workspace files        │
```

Everything inside the agent container is untrusted. All enforcement infrastructure runs outside the agent container in separate trust domains. No security-critical code runs inside the agent.

## Configuration

```yaml
# tidegate.yaml
version: "1"
defaults:
  scan_timeout_ms: 500
  scan_failure_mode: deny       # deny | allow

servers:
  gmail:
    transport: http
    url: http://gmail-mcp:3000/mcp

  slack:
    transport: http
    url: http://slack-mcp:3000/mcp
    allow_tools: [post_message, list_channels]    # optional

  github:
    transport: http
    url: http://github-mcp:3000/mcp
```

No per-field scan mappings. The gateway scans every string value in every tool call. Configuration is just: which servers, how to reach them, and optionally which tools to expose.

## Accepted limitations

1. **Semantic exfiltration** — If the LLM rephrases sensitive data as prose ("the user's checking account has twelve thousand dollars"), no pattern scanner catches it. This is a fundamental limit of all scanning approaches. Documented as accepted risk, not claimed as blocked.
2. **LLM API as exfiltration channel** — The agent's LLM API key must exist in the agent container (it's how the agent thinks). A sophisticated attacker could encode data in API requests. This is a hard architectural limit — the agent must be able to talk to its LLM.
3. **CONNECT passthrough** — LLM API traffic uses end-to-end TLS via CONNECT tunneling. The proxy cannot inspect this traffic without MITM, which is out of scope. A compromised agent could encode data in its LLM API requests.
4. **Container escape** — Docker shares the host kernel. Hardened container config (read-only filesystem, dropped capabilities, no-new-privileges) reduces the attack surface. VM isolation is a possible future upgrade path (see [ADR-005](../../../adr/Accepted/(ADR-005)-Composable-VM-Isolation.md)).

## Future directions

Research spikes have explored whether additional enforcement layers could close gaps in the three-seam model:

- **L1 taint tracking** — [SPIKE-013](../../../research/Complete/(SPIKE-013)-Tideclaw-Architecture/(SPIKE-013)-Tideclaw-Architecture.md) investigated whether eBPF-based file access observation combined with seccomp-notify `connect()` enforcement could catch encryption-before-exfiltration attacks (where the agent encodes sensitive data before sending it, defeating pattern scanning). The approach is technically viable but adds significant complexity. Not committed to the architecture.
- **IPC scanning** — [SPIKE-014](../../../research/Complete/(SPIKE-014)-Tideclaw-IPC-Orchestrator-Scanning/(SPIKE-014)-Tideclaw-IPC-Orchestrator-Scanning.md) explored scanning IPC payloads between the agent and an orchestrator as a fifth enforcement seam. Formalized in [ADR-004](../../../adr/Accepted/(ADR-004)-IPC-Orchestrator-Scanning-as-Enforcement-Seam.md) but not part of VISION-002's committed scope.

If structural gaps in the three-seam model are identified that require additional enforcement layers, those decisions enter through the ADR process.

## Key decisions

| Decision | ADR | Status | Relevance to VISION-002 |
|----------|-----|--------|------------------------|
| Taint-and-verify data flow model | [ADR-002](../../../adr/Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) | Accepted | Research context — describes L1 taint approach not committed in VISION-002 |
| IPC as enforcement seam | [ADR-004](../../../adr/Accepted/(ADR-004)-IPC-Orchestrator-Scanning-as-Enforcement-Seam.md) | Accepted | Research context — describes fifth seam not committed in VISION-002 |
| Composable VM isolation | [ADR-005](../../../adr/Accepted/(ADR-005)-Composable-VM-Isolation.md) | Accepted | Directly relevant — Tidegate stays Docker-native; transport-based interface composes with external VM isolation |

## Related

- [VISION-002](./(VISION-002)-Tidegate.md) — Product vision and value proposition
- [Threat model](../../../threat-model/) — Attack scenarios, defenses, scorecard
- [SPIKE-013](../../../research/Complete/(SPIKE-013)-Tideclaw-Architecture/(SPIKE-013)-Tideclaw-Architecture.md) — Tideclaw architecture research (L1 taint, eBPF, seccomp-notify)
