# VISION-002 Documentation Update — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a README and architecture doc that present Tidegate as a reference architecture for data-flow enforcement in AI agent deployments, and update AGENTS.md framing.

**Architecture:** Three documents — system-architecture.md (under VISION-002) written first since the README links to it, then README.md at project root, then AGENTS.md one-line edit. All docs are prose, no code changes.

**Tech Stack:** Markdown

---

## Chunk 1: Architecture Doc + README + AGENTS.md

### Task 1: Create system-architecture.md

**Files:**
- Create: `docs/vision/Draft/(VISION-002)-Tidegate/system-architecture.md`

- [ ] **Step 1: Write system-architecture.md**

Create `docs/vision/Draft/(VISION-002)-Tidegate/system-architecture.md` with this content:

```markdown
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

- [VISION-002](./\(VISION-002\)-Tidegate.md) — Product vision and value proposition
- [Threat model](../../../threat-model/) — Attack scenarios, defenses, scorecard
- [SPIKE-013](../../../research/Complete/(SPIKE-013)-Tideclaw-Architecture/(SPIKE-013)-Tideclaw-Architecture.md) — Tideclaw architecture research (L1 taint, eBPF, seccomp-notify)
```

- [ ] **Step 2: Verify file renders correctly**

Run: `head -5 docs/vision/Draft/\(VISION-002\)-Tidegate/system-architecture.md`
Expected: First 5 lines of the architecture doc, starting with `# System Architecture`

- [ ] **Step 3: Commit**

```bash
git add "docs/vision/Draft/(VISION-002)-Tidegate/system-architecture.md"
git commit -m "docs: add system architecture for VISION-002

Prescriptive architecture scoped to three enforcement seams:
MCP gateway scanning, egress proxy, credential isolation.
Frames Tidegate as a reference architecture design."
```

---

### Task 2: Create README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md**

Create `README.md` at the project root with this content:

```markdown
# Tidegate

A reference architecture for data-flow enforcement in AI agent deployments. Tidegate maps what it takes to prevent an AI agent from leaking sensitive data — not through best-effort scanning of one channel, but through a topology where every data path from the agent passes through an enforcement boundary. It may get built; it may remain an analytical tool for evaluating how well commercial solutions cover the problem. The value is in the analysis regardless.

## The problem

AI agents read your most sensitive files and call external APIs in the same breath. A community skill can read your bank statements and post them to any endpoint. A prompt injection in a document can instruct the agent to exfiltrate credentials through a tool call.

Agent frameworks sandbox *code execution* (bubblewrap, Landlock, Seatbelt) but not *data flow*. MCP gateways scan *tool call payloads* but can't stop the agent from bypassing MCP entirely — `curl`, cron jobs, IPC, or encoding data in the LLM API request. Each layer covers one exit; nothing covers them all. A determined or compromised agent routes around whichever single layer is present.

## Existing landscape

The landscape for agent security tooling has matured rapidly, but each category covers only part of the problem:

- **Agent frameworks** (Claude Code, Codex CLI, Aider, Goose) provide code-execution sandboxing and permission prompts. None enforce data-flow boundaries — a sandboxed agent can still pipe your SSN through a tool call.
- **MCP gateways with payload scanning** — Docker MCP Gateway (`--block-secrets`), Pipelock (36 DLP patterns), Lasso Security (PII masking via Presidio), Pangea (50+ PII types with format-preserving encryption), Enkrypt AI, Operant AI, MintMCP, and others all scan MCP tool call payloads for credentials and PII. Most are SaaS or enterprise products. Pipelock and Docker MCP Gateway are self-hostable.
- **MCP governance tools** — Snyk agent-scan (formerly Invariant mcp-scan), Promptfoo, MCP Manager, and Trail of Bits mcp-context-protector focus on tool poisoning, prompt injection, and access control. Some include PII detection as a secondary feature.
- **AI gateway DLP** — Cloudflare AI Gateway, Lakera Guard, and Nightfall AI provide DLP for LLM interactions. Not MCP-specific but converging toward agent-aware scanning.
- **Cloud sandboxes** (E2B, Daytona, microsandbox) provide isolated execution environments. They contain blast radius but don't inspect what leaves the sandbox.

The gap is not "nobody scans MCP payloads" — many tools now do. The gap is that scanning alone is insufficient without *structural enforcement*. An MCP gateway that scans tool calls doesn't help when the agent bypasses MCP entirely — shelling out to `curl`, writing to a cron job, encoding data in the LLM API request, or exfiltrating through IPC. No existing tool combines payload scanning with network-level enforcement that makes bypass structurally impossible.

## What comprehensive enforcement requires

Tidegate's architecture addresses the gap by combining three independent enforcement seams:

- **MCP gateway scanning** — An interposition proxy sits between the agent and all downstream MCP servers. It discovers tools automatically, scans every string value in every tool call parameter and response, and returns shaped denies on policy violations. The agent never contacts MCP servers directly.
- **Network egress control** — A CONNECT-only proxy is the agent container's sole path to the internet. LLM API domains get passthrough; everything else is blocked. The agent cannot reach the internet without going through the proxy.
- **Credential isolation** — API keys and tokens live in isolated MCP server containers on a network the agent cannot reach. The agent has zero external service credentials. Credential exposure requires a Docker compose misconfiguration, not a `curl` command.

These seams operate independently — compromise of one does not disable the others. The topology is enforced by Docker networking: the agent container sits on a single internal network and can only reach the gateway and the proxy. Bypass requires a container escape, not a creative shell command.

See the [system architecture](docs/vision/Draft/(VISION-002)-Tidegate/system-architecture.md) for the full design.

## Honest limitations

Tidegate is honest about what it cannot do:

- **Semantic exfiltration** — If the LLM rephrases your bank balance as prose, no pattern scanner catches it. This is a fundamental limit of all scanning approaches. Documented as accepted risk, not claimed as blocked.
- **LLM API as exfiltration channel** — The agent's API key must exist in the agent container (it's how the agent thinks). A sophisticated attacker could encode data in API requests. This is a hard architectural limit.
- **Sabotage prevention** — Tidegate prevents data *leaving*; it doesn't prevent the agent from deleting files or running destructive commands. Containerization and workspace backups handle that.
- **Multi-tenant hosting** — This is a single-operator deployment, not a shared platform.
- **Replacing agent frameworks** — Tidegate wraps your existing agent (Claude Code, Codex, Aider, Goose). It doesn't compete with them. You pick the brain; Tidegate provides the boundary.

See the [threat model](docs/threat-model/) for the full analysis including attack scenarios, defense mapping, and a security scorecard.

## Status

Tidegate is a reference architecture. There is no roadmap.

The repo contains research spikes, a threat model, architecture decision records, and user personas alongside the architecture design. If it gets built, the architecture doc guides implementation. If it doesn't, it serves as a point of comparison for evaluating commercial tools — a way to ask "does this product actually cover the gaps it claims to?"

The repo also contains proof-of-concept code from an earlier iteration. This code validated the MCP scanning approach but will be replaced if implementation proceeds.

## Navigation

| Document | What it covers |
|----------|---------------|
| [System architecture](docs/vision/Draft/(VISION-002)-Tidegate/system-architecture.md) | Components, network topology, enforcement seams, scanning pipeline, trust boundaries |
| [VISION-002](docs/vision/Draft/(VISION-002)-Tidegate/(VISION-002)-Tidegate.md) | Product vision — target audience, value proposition, problem statement, landscape analysis |
| [Threat model](docs/threat-model/) | Attack scenarios, defense mapping, sensitive data catalog, threat personas, security scorecard |
| [Research spikes](docs/research/list-spikes.md) | Investigations — leak detection tools, taint models, architecture options, RL-trained agent risks |
| [Architecture decisions](docs/adr/list-adrs.md) | ADRs — taint-and-verify model, IPC scanning, composable VM isolation |
| [Personas](docs/persona/list-personas.md) | User archetypes — personal assistant operator, small team operator, security-conscious developer, contributor |
```

- [ ] **Step 2: Verify file renders correctly**

Run: `head -3 README.md`
Expected: First 3 lines starting with `# Tidegate`

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README as reference architecture landing page

Substantive landing page covering the problem, landscape analysis,
enforcement approach, honest limitations, and project status.
Positions Tidegate as a reference architecture, not a shipped product."
```

---

### Task 3: Update AGENTS.md framing

**Files:**
- Modify: `AGENTS.md:3` (opening paragraph)

- [ ] **Step 1: Edit AGENTS.md**

Change line 3 from:

```
MCP gateway that sits between an agent and downstream MCP servers. Scans all string values in tool call parameters and responses for sensitive data, returns shaped denies on policy violations. Plus Squid egress proxy and Docker packaging.
```

To:

```
Reference architecture for an MCP gateway that sits between an agent and downstream MCP servers. Scans all string values in tool call parameters and responses for sensitive data, returns shaped denies on policy violations. Plus Squid egress proxy and Docker packaging.
```

- [ ] **Step 2: Verify the edit**

Run: `head -5 AGENTS.md`
Expected: Line 3 starts with "Reference architecture for an MCP gateway"

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs: reframe AGENTS.md as reference architecture"
```
