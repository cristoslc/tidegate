---
title: "SPIKE-013: Tideclaw Architecture"
status: Active
author: cristos
created: 2026-02-25
last_updated: 2026-02-27
question: "What should a security-first orchestrator for AI coding tools look like?"
parent: VISION-001
---

# Tideclaw — Architecture Spike: Security-First Orchestrator for AI Coding Tools

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-02-25 | 0ec6eb8 | Spike started; researched Claude Code, Codex CLI, Gemini, MCP security, E2B, Daytona |
| Active | 2026-02-27 | 0ec6eb8 | Added Aider, Goose, llm CLI deep-dives; added Skills Paradigm section; added non-Claude/Codex base evaluation |

## Purpose

Design **Tideclaw** from scratch: a security-first orchestrator for AI coding tools. Like ClaudeClaw or NanoClaw, Tideclaw is an orchestrator — it manages the lifecycle of an agentic runtime (Claude Code, Codex CLI, Aider, etc.). Unlike those orchestrators, Tideclaw's primary concern is providing the **process separation and enforcement seams** that Tidegate's security layers need to attach to.

The user picks their agentic runtime. Tideclaw orchestrates it with credential isolation, network segmentation, MCP scanning boundaries, egress control, and taint tracking built into the orchestration topology.

### Why a new orchestrator?

The current Tidegate approach (ADR-003) chose NanoClaw as the first agent runtime — a specific orchestrator that already has Docker containers and filesystem IPC. That gave Tidegate an enforcement seam but coupled the security framework to one orchestrator. The problem: NanoClaw's process boundaries weren't designed for security enforcement. They're incidental to its orchestration model, not intentional seams.

Tideclaw asks: **what if the orchestrator IS designed around the seams?**

ClaudeClaw and NanoClaw are orchestrators that happen to use containers. Tideclaw is an orchestrator that exists *because of* containers — because process separation, network isolation, and mount boundaries are the seams that make security enforcement possible.

Tideclaw provides:
- Process separation between agent and MCP servers (the scanning seam)
- Network segmentation between agent, gateway, and servers (the egress control seam)
- Mount isolation for credentials (the credential isolation seam)
- Kernel-level observation points (the taint tracking seam)

The agentic runtime runs inside these seams, unmodified.

---

## The Landscape: Login-Based AI Coding Tools (Feb 2026)

> Full tool profiles in [landscape.md](./landscape.md). Summary table below.

| Tool | Has CLI? | Has sandbox? | Has MCP? | Has Skills? | Integration mode |
|------|----------|-------------|----------|-------------|-------------------|
| **Claude Code** | Yes | bubblewrap + seccomp | Yes (first-class) | Yes (SKILL.md, CLAUDE.md, hooks) | **MCP gateway** — route all MCP calls through scanner |
| **Codex CLI** | Yes | Landlock + seccomp | Yes (client + server) | Yes (Agent Skills standard) | **MCP gateway + proxy** — hybrid mode |
| **Goose** | Yes | bubblewrap / seatbelt (v1.25.0) | Yes (foundational) | Yes (SKILL.md + recipes) | **MCP gateway** — all extensions are MCP servers |
| **Gemini (Jules)** | Yes (new CLI) | Yes (cloud VM) | Migrating to MCP | Yes (Agent Skills standard) | **Not orchestrable locally** (cloud only) |
| **Aider** | Yes | No | No | No (`.aider.conventions` only) | **Container + proxy** — full isolation |
| **llm CLI** | Yes | No | Community plugin | No | **Not a coding agent** — completion tool only |

**Conclusion**: **Claude Code**, **Codex CLI**, and **Goose** all have both MCP and Skills support, meaning Tideclaw can activate the MCP gateway seam for all three. Goose is the strongest open-source alternative — its MCP-native architecture means all extensions route through the gateway seam by design. The Agent Skills standard (agentskills.io, Dec 2025) has been adopted by 40+ agents, making skill security scanning a Tideclaw concern alongside MCP tool scanning (see [security-landscape.md](./security-landscape.md)).

---

## Prior Art: How Others Solve Agent Sandboxing

> Full profiles of 8 sandboxing solutions: [prior-art.md](./prior-art.md)

| Tier | Technology | Isolation Strength | Example |
|------|-----------|-------------------|---------|
| **MicroVMs** | Firecracker, Kata, libkrun | Strongest (dedicated kernel) | E2B, microsandbox |
| **gVisor** | User-space kernel | Strong (syscall interception) | Modal, GKE Agent Sandbox |
| **Hardened containers** | Docker + seccomp/AppArmor | Moderate (shared kernel) | **Tideclaw**, Docker MCP |
| **OS-native** | Landlock + seccomp, bubblewrap | Moderate (process-level) | Codex CLI, Claude Code |

**Key prior art**: Pipelock (closest architectural analog — capability separation, 9-layer scanner, MCP scanning), Docker MCP Gateway (closest commercial analog — interceptor framework, credential injection), Claude Code sandbox-runtime (reusable bubblewrap sandbox). Codex CLI's cloud two-phase model (setup with creds → agent without) is the cleanest credential isolation pattern. If Docker containers aren't enough, Firecracker microVMs (E2B) or self-hosted libkrun (microsandbox) are the upgrade path.

### MCP & Skills Security Landscape

> Full details: [security-landscape.md](./security-landscape.md) — MCP auth evolution, real-world incidents, tool poisoning stats, Skills paradigm, skills security incidents, and Tideclaw implications.

Modern agentic runtimes have **two extension planes** — both are attack surfaces:

| Plane | What it provides | Security surface |
|-------|-----------------|-----------------|
| **MCP (tools)** | Structured tool connectivity (JSON-RPC) | Tool poisoning, RCE, supply chain, elicitation phishing |
| **Skills (knowledge)** | Natural-language procedural expertise (SKILL.md) | Prompt injection, memory poisoning, supply chain |

**MCP key gap**: No built-in security gateway between client and server. The spec's security model is client-side consent, which fails headless. Tideclaw fills this with server-side policy enforcement. Real-world incidents (Postmark supply chain, Smithery exfiltration, mcp-remote RCE, Claude Desktop RCE, GitHub prompt injection) validate each of Tideclaw's enforcement layers.

**Skills key gap**: 96,000+ skills in circulation (Feb 2026), 13.4% contain critical security issues (Snyk ToxicSkills study). Denylist scanners are fundamentally flawed — you cannot block specific words in a system designed to understand concepts. Skills require a **new enforcement seam** (skill vetting before load) that Tideclaw's L1/L2/L3 layers don't directly address. L1 (taint tracking) helps because it's intent-agnostic. Skill vetting is a Phase 3 concern, but the architecture anticipates it now.

### Tool-Call Process Isolation

> Full analysis of all four runtimes: [tool-isolation.md](./tool-isolation.md)

**No runtime provides per-tool-call isolation.** All four sandbox the session or the subprocess, not individual tool invocations. Within a sandbox boundary, all tool calls share the same filesystem view, network policy, and credential set.

| Runtime | Sandbox boundary | What's sandboxed | Key gap |
|---------|-----------------|-----------------|---------|
| **Claude Code** | Per-Bash-command (bubblewrap/Seatbelt) | Bash subprocess only | Read/Write/Edit/Glob/Grep are in-process (Node.js) with app-level permission checks only — no OS sandbox. MCP servers (stdio) are unsandboxed child processes. |
| **Codex CLI** | Per-command (Landlock + seccomp + env clearing) | Every shell command | Network is binary (all/nothing) — no domain-level filtering. Env var stripping catches `KEY`/`SECRET`/`TOKEN` but not content-embedded credentials. |
| **Gemini CLI** | Per-tool-call (Seatbelt or Docker) | All tools when sandbox is enabled | **Sandbox is OFF by default.** Six Seatbelt profiles with proxied option. Docker mode provides full container isolation. |
| **Goose** | Per-session (Seatbelt wraps entire `goosed` process) | All tools + all child processes | **macOS only** — Linux bubblewrap not yet shipped (v1.25.0). Builtin extensions (developer, shell) run in-process with no separate boundary. |

**What Tideclaw adds**: Runtimes sandbox the agent; Tideclaw sandboxes the topology. The runtime prevents the agent from accessing files or network. Tideclaw prevents credentials from existing where they can be stolen (mount isolation), prevents tool calls from containing exfiltrated data (L2 gateway scanning), and prevents network traffic from reaching unauthorized destinations (L3 egress proxy) — regardless of what the agent's own sandbox does or doesn't enforce.

---

## Tideclaw Architecture

### Core Concept

Tideclaw is a **security-first orchestrator** for AI coding tools. It manages the lifecycle of an agentic runtime (Claude Code, Codex CLI, Aider, etc.) inside a topology that provides the enforcement seams Tidegate's security layers attach to:

1. **Process separation** — agent, gateway, MCP servers, and proxy run in separate containers
2. **Network segmentation** — three isolated networks control what can talk to what
3. **MCP interposition** — gateway sits between agent and MCP servers (the scanning seam)
4. **Egress mediation** — proxy sits between agent and internet (the egress control seam)
5. **Credential isolation** — mount boundaries ensure each container sees only its own credentials
6. **Kernel observation** — eBPF/seccomp attach points for taint tracking

The agentic runtime runs unmodified inside this topology. It sees MCP servers at the URLs it expects. It reaches the internet through a proxy it doesn't know about. Its file access is observed without its knowledge.

### Design Principles

1. **Seams first**: The orchestration topology is designed around the enforcement boundaries Tidegate needs. Every container boundary, network segment, and mount point exists to enable a security layer.
2. **Runtime-agnostic**: Works with any CLI-based AI coding tool that can run in a container. The orchestrator provides the seams; the runtime is pluggable.
3. **No cooperation required**: The agentic runtime doesn't need modification, plugins, or special flags (beyond headless mode). Seams are structural, not contractual.
4. **MCP-first scanning**: For runtimes with MCP support, scan at the MCP protocol level (highest fidelity). The gateway seam provides structured tool name + argument + value visibility.
5. **Network-fallback scanning**: For runtimes without MCP, scan at the HTTP proxy level (lower fidelity but universal). The proxy seam provides payload-level visibility.
6. **Skills-aware security**: Modern runtimes extend via two planes: tools (MCP) and knowledge (Skills/SKILL.md). Tideclaw's gateway seam covers the tool plane. The skills plane requires additional enforcement: skill vetting at load time, skill allowlisting, and skill isolation via restricted tool access. MCP is not the only extension mechanism — skills are becoming equally important.
7. **Defense in depth**: MCP scanning, network scanning, skill vetting, and taint tracking run simultaneously when available. Multiple seams firing independently.
8. **Fail-closed**: Scanner unavailable = deny. Proxy down = no egress. Container crash = session over.

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        TIDECLAW HOST                        │
│                                                             │
│  tideclaw CLI                                               │
│    - reads tideclaw.yaml                                    │
│    - generates compose spec                                 │
│    - starts containers                                      │
│    - manages lifecycle                                      │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │               Docker / Podman                       │    │
│  │                                                     │    │
│  │  ┌──────────────────────┐    agent-net (internal)   │    │
│  │  │   AGENT CONTAINER    │◄──────────────────────┐   │    │
│  │  │                      │                       │   │    │
│  │  │  Claude Code / Codex │     ┌──────────────┐  │   │    │
│  │  │  / Aider / any CLI   │────►│  tg-gateway   │  │   │    │
│  │  │                      │     │  (MCP proxy)  │  │   │    │
│  │  │  MCP config points   │     │  port 4100    │  │   │    │
│  │  │  to tg-gateway       │     └──────┬───────┘  │   │    │
│  │  │                      │            │          │   │    │
│  │  │  HTTPS_PROXY points  │     ┌──────▼───────┐  │   │    │
│  │  │  to egress-proxy     │────►│ egress-proxy  │  │   │    │
│  │  │                      │     │  port 3128    │──┼───┼──► Internet
│  │  │  /workspace (rw)     │     └──────────────┘  │   │    │
│  │  │  ~/.claude (ro)      │            │          │   │    │
│  │  └──────────────────────┘     ┌──────▼───────┐  │   │    │
│  │                               │  MCP servers  │  │   │    │
│  │            mcp-net (internal) │  (gmail,slack │  │   │    │
│  │                               │   github,..) │  │   │    │
│  │                               └──────────────┘  │   │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### The Three Integration Modes

Tideclaw's orchestration topology adapts based on the agentic runtime's capabilities — specifically, which seams can be activated:

#### Mode 1: MCP Gateway (Claude Code, Codex CLI, Goose, Continue.dev, any MCP-native runtime)

```
Agent → tg-gateway (scan all values) → downstream MCP servers
Agent → egress-proxy → internet (LLM API only)
```

**Seams activated**: MCP interposition (gateway) + egress mediation (proxy) + credential isolation (mount boundaries)

**How it works**:
- Tideclaw generates MCP config for the runtime, pointing all servers at `http://tg-gateway:4100/mcp`
- The gateway mirrors tools from real downstream servers
- Every tool call parameter and response is scanned (L1/L2/L3)
- Shaped denies on policy violations
- Runtime sees one MCP endpoint; gateway fans out to real servers on `mcp-net`

**Scanning fidelity**: **High**. Every string value in every tool call is scanned. Structured data is preserved. Tool name, argument names, and values are all visible.

**Claude Code specific**:
- Mount `~/.claude/` read-only for OAuth auth
- Generate `~/.claude/settings.json` with MCP servers pointing to gateway
- Optionally install `PreToolUse` hooks for double-checking at the tool level (defense in depth — hooks + gateway both scan)
- `--dangerously-skip-permissions` for headless operation

**Codex CLI specific** (MCP mode):
- Codex supports MCP via `rmcp-client` crate. Configure gateway as MCP server.
- Run with `--sandbox danger-full-access` (Tideclaw's orchestration provides isolation instead)
- `OPENAI_API_KEY` or ChatGPT OAuth auth passed via env/mount
- Codex's shell commands (primary tool) are NOT MCP — they bypass the gateway seam. This is why Codex also needs Mode 2 (proxy) as a backup.

#### Mode 2: Network Proxy (Aider, any runtime without MCP, backup for shell-heavy runtimes)

```
Agent → egress-proxy (scan HTTP bodies) → internet
Agent → egress-proxy (scan HTTP bodies) → external APIs
```

**Seams activated**: Egress mediation (proxy) + credential isolation (mount boundaries). No MCP interposition.

**How it works**:
- Tideclaw runs the runtime in a container on `agent-net` (internal) with proxy env vars
- All HTTP/HTTPS traffic routes through `egress-proxy`
- For LLM API domains: CONNECT passthrough (no inspection — encrypted, high volume)
- For external API domains: MITM, scan request/response bodies, inject credentials
- Domain allowlist controls what's reachable

**Scanning fidelity**: **Medium**. HTTP request/response bodies are scanned, but there's no structured MCP framing. Scanner sees raw JSON/form payloads, not tool names and argument schemas. The proxy seam provides less visibility than the gateway seam.

**Codex CLI backup layer**:
- Codex's primary tool is a unified shell executor — shell commands don't go through MCP
- If a shell command makes HTTP requests (curl, wget, Python requests), those hit the proxy seam
- Codex's env var stripping (`KEY`/`SECRET`/`TOKEN` excluded from subprocesses) provides additional defense
- Tideclaw's proxy seam catches content-embedded credentials that Codex's env var filter misses

#### Mode 3: Hybrid (runtimes with partial MCP + HTTP)

```
Agent → tg-gateway (MCP tools, high-fidelity scan)
Agent → egress-proxy (HTTP tools, medium-fidelity scan)
```

**Seams activated**: All — MCP interposition + egress mediation + credential isolation + kernel observation (when available).

**How it works**: Combine modes 1 and 2. MCP traffic goes through the gateway seam. Non-MCP HTTP traffic goes through the proxy seam. Both scanning pipelines run independently.

This is the default for Claude Code (which uses MCP for tools but HTTPS for the Anthropic API).

### Tideclaw Configuration

```yaml
# tideclaw.yaml
version: "1"

# Which agentic runtime to orchestrate
agent:
  tool: claude-code           # claude-code | codex | aider | custom
  image: tideclaw/claude-code:latest  # pre-built image or custom
  auth:
    mount: ~/.claude:/home/agent/.claude:ro  # tool-specific auth mount
  env:
    HTTPS_PROXY: http://egress-proxy:3128
  headless: true              # --dangerously-skip-permissions / equivalent

# MCP servers (tool-call-level scanning)
mcp_servers:
  gmail:
    transport: http
    url: http://gmail-mcp:3000/mcp
    credentials:
      GMAIL_CLIENT_ID: ${GMAIL_CLIENT_ID}
      GMAIL_CLIENT_SECRET: ${GMAIL_CLIENT_SECRET}
  slack:
    transport: http
    url: http://slack-mcp:3000/mcp
    credentials:
      SLACK_BOT_TOKEN: ${SLACK_BOT_TOKEN}
    allow_tools: [post_message, list_channels]
  github:
    transport: http
    url: http://github-mcp:3000/mcp
    credentials:
      GITHUB_TOKEN: ${GITHUB_TOKEN}

# Egress control
egress:
  # LLM API: passthrough (no inspection)
  passthrough:
    - api.anthropic.com
    - api.openai.com
    - generativelanguage.googleapis.com
  # Allowed with MITM scanning + credential injection
  allowed:
    - api.github.com:
        credentials:
          Authorization: "Bearer ${GITHUB_TOKEN}"
    - api.slack.com:
        credentials:
          Authorization: "Bearer ${SLACK_BOT_TOKEN}"
  # Everything else: blocked

# Scanning policy
scanning:
  timeout_ms: 500
  failure_mode: deny          # deny | allow
  # L1 (in-process): credential patterns, JSON key patterns
  # L2 (subprocess): Luhn, IBAN, SSN
  # L3 (subprocess): entropy, base64/hex detection
  layers: [L1, L2, L3]

# Taint tracking (post-MVP, requires Linux kernel 5.8+)
taint:
  enabled: false              # true when tg-scanner is built
  workspace: /workspace
```

### Container Images: Pre-Built vs Custom

Tideclaw ships **pre-built container images** for supported runtimes:

| Image | Base | Contents |
|-------|------|----------|
| `tideclaw/claude-code` | `node:22-slim` | Claude Code CLI, non-root user, MCP config template, skill directory |
| `tideclaw/codex` | `debian:bookworm-slim` | Codex CLI (Rust binary), non-root user, MCP + proxy config |
| `tideclaw/goose` | `debian:bookworm-slim` | Goose CLI (Rust binary), non-root user, MCP extension config pointing to gateway, proxy config. All extensions route through gateway seam. |
| `tideclaw/aider` | `python:3.12-slim` | Aider, non-root user, proxy config (no MCP) |
| `tideclaw/custom` | `ubuntu:24.04` | Base image with proxy config, user adds their runtime |

Each image:
- Runs as non-root user
- Has `HTTPS_PROXY` pre-configured
- Has MCP config templates (for MCP-capable runtimes)
- Includes health check scripts
- Is pinned to specific runtime versions

For **custom runtimes**, users can extend the base image:

```dockerfile
FROM tideclaw/custom:latest
RUN pip install my-agent-tool
COPY my-config /home/agent/.config/
```

### The tideclaw CLI

```sh
# Initialize (creates tideclaw.yaml from template)
tideclaw init --tool claude-code

# Start (generates compose, builds, starts)
tideclaw up

# Status
tideclaw status

# Attach to agent container
tideclaw attach

# View audit logs
tideclaw logs

# Stop
tideclaw down
```

Under the hood, `tideclaw up`:
1. Reads `tideclaw.yaml`
2. Generates a `docker-compose.yaml` with:
   - Agent container (runtime-specific image)
   - `tg-gateway` container
   - `egress-proxy` container
   - MCP server containers (one per configured server)
   - Network topology / seams (`agent-net`, `mcp-net`, `proxy-net`)
3. Generates MCP config for the agentic runtime (pointing to gateway seam)
4. Generates proxy config (allowlists, credential injection rules)
5. Runs `docker compose up --build`
6. Waits for health checks
7. Prints status

### How MCP Config Injection Works

Each runtime has a different MCP config format. Tideclaw generates the appropriate config:

**Claude Code** (`~/.claude/settings.json`):
```json
{
  "mcpServers": {
    "tideclaw": {
      "type": "streamable-http",
      "url": "http://tg-gateway:4100/mcp"
    }
  }
}
```

Claude Code sees one MCP server ("tideclaw") that exposes all tools from all downstream servers. The gateway handles the fan-out.

**Codex CLI** (`~/.codex/config.toml` + MCP config):
```toml
# config.toml — disable Codex's own sandbox (Tideclaw provides isolation)
[sandbox]
sandbox_mode = "danger-full-access"
```
```json
// MCP server config — point to gateway
{
  "mcpServers": {
    "tideclaw": {
      "type": "streamable-http",
      "url": "http://tg-gateway:4100/mcp"
    }
  }
}
```
Plus `HTTPS_PROXY=http://egress-proxy:3128` for shell commands that make HTTP requests.

**Goose** (`~/.config/goose/config.yaml` — extension config pointing to gateway):
```yaml
extensions:
  tideclaw:
    type: streamable-http
    uri: http://tg-gateway:4100/mcp
    # All downstream MCP servers exposed via single gateway endpoint
    # Goose sees one extension; gateway fans out to real servers on mcp-net
```
Plus `HTTPS_PROXY=http://egress-proxy:3128` for any direct HTTP traffic. Run with `--no-session --quiet --output-format json` for headless container operation. Goose's own sandbox (seatbelt/bubblewrap) should be disabled — Tideclaw's container topology provides the isolation.

**Aider** (proxy-only, no MCP):
```
HTTPS_PROXY=http://egress-proxy:3128
```

### Credential Flow

```
User's machine
  ├── ~/.claude/auth.json        → mounted :ro into agent container (Claude Code auth)
  ├── tideclaw.yaml              → read by tideclaw CLI
  └── .env (or 1Password CLI)    → MCP server credentials

Agent container
  ├── Sees: ~/.claude/auth.json (read-only, for LLM API auth)
  ├── Sees: HTTPS_PROXY env var
  ├── Does NOT see: SLACK_BOT_TOKEN, GITHUB_TOKEN, GMAIL_*, etc.
  └── Does NOT see: any credential except its own LLM API auth

tg-gateway container
  ├── Sees: downstream MCP server URLs
  ├── Does NOT see: MCP server credentials (they're in the MCP server containers)
  └── Does NOT see: agent's LLM API auth

MCP server containers (each isolated)
  ├── gmail-mcp: Sees GMAIL_* only
  ├── slack-mcp: Sees SLACK_BOT_TOKEN only
  └── github-mcp: Sees GITHUB_TOKEN only

egress-proxy container
  ├── Sees: domain allowlist
  ├── Sees: credential injection rules (for MITM mode)
  └── Injects credentials into matching requests (agent never sees the creds)
```

### Network Topology

```
agent-net (internal: true)
  ├── agent container
  ├── tg-gateway
  └── egress-proxy

mcp-net (internal: true)
  ├── tg-gateway
  └── MCP server containers

proxy-net
  ├── egress-proxy
  └── → internet
```

**Key properties**:
- Agent cannot reach MCP servers directly (different networks)
- Agent cannot reach internet directly (internal network, proxy only)
- MCP servers cannot reach agent (different networks)
- MCP servers can reach their external APIs (via `mcp-net` → direct or through own proxy)
- Only `egress-proxy` spans `agent-net` and `proxy-net`
- Only `tg-gateway` spans `agent-net` and `mcp-net`

### Enforcement Layers (Tidegate components attached to Tideclaw seams)

| Layer | What | Where | Fidelity |
|-------|------|-------|----------|
| **L1: Taint tracking** | eBPF `openat` + seccomp-notify `connect()` | Agent container kernel | **File-level** — tracks which files were read, blocks network if tainted |
| **L2: MCP gateway** | Scan all string values in tool call params and responses | tg-gateway | **Field-level** — sees tool name, arg names, values. Highest fidelity. |
| **L3: Egress proxy** | Scan HTTP request/response bodies, domain allowlisting, credential injection | egress-proxy | **Payload-level** — sees raw HTTP bodies. Medium fidelity. |

Defense in depth: a credential in a tool call parameter hits L2 (gateway scan) AND L3 (proxy scan if it reaches egress). A file tainted by a read hits L1 (taint tracker blocks connect). All three layers fire independently.

---

## Tideclaw vs ClaudeClaw vs NanoClaw: Orchestrator Comparison

All three are orchestrators. They differ in what they optimize for:

```
ClaudeClaw (orchestrator — optimizes for web UI + chat bridges)
  - Web dashboard, WhatsApp/Telegram bridge
  - User-facing interaction layer
  - No security seams — trusts the runtime

NanoClaw (orchestrator — optimizes for multi-session management)
  - Container-per-session, skills, scheduling, memory
  - WhatsApp/Telegram bridge
  - Incidental container boundaries (not designed as security seams)

Tideclaw (orchestrator — optimizes for security enforcement)
  - Orchestration topology designed around enforcement seams
  - Process separation, network segmentation, credential isolation
  - Seams that Tidegate's security layers (gateway, proxy, scanner) attach to
  - Runtime-agnostic: any CLI tool runs inside the topology
```

**Key distinction**: NanoClaw and ClaudeClaw use containers for operational reasons (isolation between sessions, deployment convenience). Tideclaw uses containers for security reasons (each container boundary is an enforcement seam). The topology isn't incidental — it's the point.

### Where does Tidegate fit?

Tidegate is NOT an orchestrator. It's the **security framework** — the gateway, scanner, proxy, and taint tracker. Tidegate's components attach to the seams that an orchestrator provides. The problem: most orchestrators don't provide the right seams. Tideclaw is the orchestrator designed to provide them.

```
Tidegate (security framework — the enforcement layers)
  - MCP gateway + scanner (attaches to the MCP interposition seam)
  - Egress proxy (attaches to the network segmentation seam)
  - Taint tracker (attaches to the kernel observation seam)
  - Needs an orchestrator that provides these seams

Tideclaw (orchestrator — provides the seams Tidegate needs)
  - Process separation → gateway can sit between agent and MCP servers
  - Network segmentation → proxy can mediate all egress
  - Mount isolation → credentials stay in their containers
  - Kernel attach points → eBPF/seccomp can observe the agent
```

### What happens to ClaudeClaw and NanoClaw?

They're peer orchestrators with different priorities. A user who wants a web dashboard picks ClaudeClaw. A user who wants WhatsApp integration and multi-session scheduling picks NanoClaw. A user who wants security enforcement picks Tideclaw.

In principle, the features aren't mutually exclusive — a future orchestrator could combine Tideclaw's security seams with ClaudeClaw's web UI. But that's a later concern. For now, Tideclaw focuses on getting the seams right.

```yaml
# tideclaw.yaml — Claude Code as the agentic runtime (most common)
agent:
  tool: claude-code
```

```yaml
# tideclaw.yaml — Codex CLI as the agentic runtime
agent:
  tool: codex
```

```yaml
# tideclaw.yaml — Goose as the agentic runtime (best open-source option)
agent:
  tool: goose
```

---

## Implementation Plan

### Phase 1: Core (MVP)

**Goal**: `tideclaw init --tool claude-code && tideclaw up` produces a working system.

1. **tideclaw CLI** — Go or shell script. `init`, `up`, `down`, `status`, `attach`, `logs`.
2. **Claude Code container image** — `tideclaw/claude-code`. Claude Code CLI + non-root user + MCP config template.
3. **Compose generator** — Reads `tideclaw.yaml`, generates `docker-compose.yaml` with correct topology.
4. **MCP config injector** — Generates Claude Code's `settings.json` pointing to gateway.
5. **Reuse existing tg-gateway** — Tidegate's gateway is Tideclaw's gateway. No changes needed.
6. **Reuse existing egress-proxy** — Squid CONNECT-only proxy. No changes needed.

### Phase 2: Multi-Runtime Support

**Goal**: `tideclaw init --tool codex` and `tideclaw init --tool goose` also work.

1. **Codex CLI container image** — `tideclaw/codex`. Rust binary + non-root user + MCP config pointing to gateway + `danger-full-access` sandbox mode + proxy env vars.
2. **Goose container image** — `tideclaw/goose`. Rust binary + non-root user + MCP extension config pointing to gateway + proxy env vars. Goose's MCP-native architecture means ALL extensions route through the gateway seam (highest coverage among open-source tools). Disable Goose's own seatbelt/bubblewrap sandbox (Tideclaw provides the isolation layer). Run with `--no-session --quiet --output-format json` for headless operation.
3. **Proxy-mode scanning (MITM)** — Upgrade egress-proxy from CONNECT-only to MITM for allowed domains. This catches shell command HTTP traffic that bypasses MCP.
4. **Credential injection** — Proxy injects auth headers on matching domains. Codex's shell commands can make API calls without knowing the credentials.
5. **Aider container image** — `tideclaw/aider`. Python-based, proxy-only mode (no MCP).
6. **Tool description scanning** — Scan `tools/list` responses from downstream MCP servers for poisoned descriptions (hidden instructions, rug-pull detection). Pipelock demonstrates this is feasible.

### Phase 3: Hardening

**Goal**: Full defense-in-depth.

1. **tg-scanner + tidegate-runtime** — L1 taint tracking (eBPF + seccomp-notify).
2. **Skill vetting** — Scan SKILL.md files at load time for malicious patterns (exfiltration instructions, credential harvesting, persistence). Integrate with Snyk agent-scan or equivalent. Skill allowlisting in `tideclaw.yaml`. Enforce `allowed-tools` restrictions from SKILL.md frontmatter.
3. **PreToolUse hooks** — Claude Code framework-specific double-checking.

### Phase 4: Extended Features

**Goal**: Tideclaw offers messaging and scheduling features for users who need them (comparable to ClaudeClaw/NanoClaw convenience features).

1. **Messaging bridge** — Optional container that bridges WhatsApp/Telegram/Slack to the agent.
2. **Task scheduler** — Optional container for cron-style scheduled prompts.
3. **Multi-session support** — Multiple agent containers, each isolated.

---

## Key Design Decisions

### D1: Agentic runtime runs unmodified inside the topology

The AI coding tool is installed as-is. No patches, no plugins, no forks. Tideclaw's seams are structural (process boundaries, network segments, mount points), not contractual (APIs the runtime must implement):
- MCP config injection (point runtime's MCP at gateway seam)
- Environment variables (HTTPS_PROXY → proxy seam)
- Container isolation (network, filesystem → all seams)

**Why**: Maintainability. Runtime updates don't break Tideclaw. Users can upgrade their runtime independently. No vendor-specific code in the security layer. The seams work because of topology, not cooperation.

**Exception**: Some runtimes may need `--headless` or `--dangerously-skip-permissions` flags for unattended operation. These are documented per-runtime, not code modifications.

### D2: MCP gateway is the highest-fidelity seam

For MCP-capable runtimes, the gateway seam provides the highest-fidelity scanning:
- Structured tool name + argument names + values
- Structured response content
- Shaped denies the runtime can understand and adjust to

The proxy seam provides backup scanning for traffic that bypasses MCP (direct HTTP calls, skill execution, etc.).

**Why**: MCP framing lets us scan *semantically*. We know "this string is the `message` parameter of the `post_message` tool." The proxy seam only sees "this string is somewhere in a JSON body sent to api.slack.com." The gateway seam enables better policy decisions.

### D3: Credentials never cross the mount isolation seam

The agent container has exactly ONE credential: its own LLM API auth token (for Claude/OpenAI/Google API calls). All other credentials (Slack, GitHub, Gmail, etc.) live in:
- MCP server containers (on `mcp-net`, unreachable from agent)
- Proxy config (credential injection on matching domains)

**Why**: Mount isolation is an enforcement seam. Each container's credentials are bounded by its mount namespace. If the agent is compromised (prompt injection, malicious skill), it cannot exfiltrate API credentials because they don't exist in its mount namespace. The LLM API token is the residual risk (accepted — see threat model).

### D4: Single MCP endpoint consolidates the gateway seam

The runtime sees one MCP server at `http://tg-gateway:4100/mcp` that exposes all tools from all downstream servers. All MCP traffic passes through a single interposition point.

**Why**: One seam is easier to enforce than many. Simplifies config injection — only one MCP entry in the runtime's settings. The gateway handles tool-to-server routing internally. Also enables cross-server policy (e.g., "don't allow tool X from server A if tool Y from server B was called in this session").

### D5: Compose generation, not static compose file

The `tideclaw.yaml` config generates a Docker Compose spec at `tideclaw up` time. This is better than a hand-maintained `docker-compose.yaml` because:
- Runtime-specific containers and configs are generated dynamically
- MCP server list changes don't require editing compose
- Network topology (the seams) is always correct (no manual network assignment errors)
- Credential injection rules are derived from `tideclaw.yaml`

The generated compose file is written to `.tideclaw/docker-compose.yaml` for inspection.

### D6: Go for the CLI (recommended)

The `tideclaw` CLI should be Go:
- Single static binary, no runtime deps
- Docker SDK available (`github.com/docker/docker/client`)
- YAML parsing (`gopkg.in/yaml.v3`)
- Fast startup (important for CLI tools)
- Consistent with tg-scanner (also Go for eBPF/seccomp)

Alternative: POSIX shell script for Phase 1 (simpler, follows Tidegate's shell conventions), upgrade to Go for Phase 2+.

### D7: Seams are structural, not contractual

Tideclaw's enforcement seams come from the orchestration topology (container boundaries, network segments, mount namespaces), not from APIs or hooks the runtime must implement. This means:
- Any CLI tool works, even ones with no plugin/hook system
- Seams can't be bypassed by the runtime (they're below the application layer)
- Security doesn't degrade when the runtime updates (no API contracts to break)

The exception is MCP config injection — we rely on the runtime reading MCP config from a known location. But even if MCP config fails, the network and mount seams still enforce.

---

## Open Questions

### Q1: Codex CLI's sandbox conflict

Codex CLI on Linux uses Landlock + seccomp-BPF for process-level sandboxing (NOT Docker). In `workspace-write` mode, it blocks all network syscalls (`connect`, `accept`, `bind`). This conflicts with Tideclaw's proxy-based egress control, which requires network access to the proxy.

**Options**:
- **(a) `danger-full-access` mode** — Codex's `--sandbox danger-full-access` or `sandbox_mode = "danger-full-access"` in config.toml disables all sandbox restrictions. Tideclaw's container provides the isolation instead. **This is the recommended approach** — Codex explicitly supports this for "externally hardened environments."
- (b) Custom seccomp profile — Codex's seccomp blocks `connect()`. We'd need to modify the seccomp filter to allow connections to the proxy IP only. Fragile and version-dependent.
- (c) Redundant layering — Run Codex in default mode. Its Landlock allows reads everywhere (good), and its seccomp blocks network (Tideclaw's proxy is unreachable). This breaks proxy-based scanning entirely. **Not viable.**

**Recommendation**: (a). Codex documents `danger-full-access` as appropriate for CI containers and externally secured environments. Tideclaw IS the external security layer. The `--yolo` flag (`--dangerously-bypass-approvals-and-sandbox`) also works as a single flag for fully headless operation.

### Q2: Claude Code session continuity

Claude Code uses `--resume <sessionId>` for session continuity. In a containerized environment:
- Sessions are stored in `~/.claude/` — mounted read-only, so new sessions go to a tmpfs
- Need a writable session directory — either a named volume or a bind mount
- Session IDs need to survive container restarts

**Options**:
- Mount a writable `sessions/` directory as a volume
- Store session IDs in a sidecar DB
- Accept ephemeral sessions (each `tideclaw up` is a fresh start)

### Q3: Multi-tool MCP server compatibility

Different MCP servers have different transport requirements (HTTP, stdio, SSE). The gateway currently supports HTTP and stdio. Some community MCP servers may only support stdio.

**Approach**: Gateway hosts stdio servers as child processes. These run inside the gateway container on `mcp-net` — acceptable isolation since the gateway is already trusted (it sees all tool calls).

### Q4: How does the user interact with the agent?

Tideclaw orchestrates the runtime but needs an interaction surface:
- **Terminal attach**: `tideclaw attach` → `docker exec -it agent-container <tool-cli>`
- **API**: Expose the agent's MCP endpoint (through the gateway) for programmatic use
- **Messaging bridge**: Optional NanoClaw-style WhatsApp/Telegram bridge
- **Web UI**: Optional dashboard (ClaudeClaw-style)

Phase 1: Terminal attach only. Phase 4: Messaging bridge.

### Q5: Should Tideclaw ship as a Claude Code extension/plugin?

One distribution model: Tideclaw as a Claude Code plugin. The plugin:
- Detects local Docker
- Generates compose from embedded config
- Starts containers
- Configures Claude Code's MCP settings to point to the gateway
- Provides `/tideclaw status`, `/tideclaw logs` commands

**Pro**: Zero-friction installation for Claude Code users. Plugin marketplace distribution.
**Con**: Couples to Claude Code. Can't orchestrate Codex or Aider this way. Plugin runs on host (not in container).

**Recommendation**: Ship as standalone CLI first. Plugin as a convenience layer later (Phase 4+).

---

## Comparison: Tideclaw vs Competitors

| Dimension | Tideclaw | Pipelock | Docker MCP Gateway | Goose (native) | E2B | Codex Sandbox |
|-----------|----------|---------|-------------------|----------------|-----|---------------|
| **Isolation** | Docker + network topology | Docker (2 containers) | MicroVM or Docker | bubblewrap/seatbelt (process-level) | Firecracker microVM | Landlock + seccomp |
| **MCP scanning** | L1/L2/L3 (regex, checksums, entropy) | 9-layer DLP + injection detection | `--block-secrets` (regex) | No | No | No |
| **Tool description scanning** | Not yet | Yes (rug-pull detection) | `--verify-signatures` | No | No | No |
| **Skill vetting** | Phase 3 (static analysis + allowlisting) | No | No | No | No | No |
| **Egress control** | Proxy + domain allowlist + credential injection | Domain blocklist + SSRF protection | Container networking | No | IP/CIDR + SNI domain filtering | Binary on/off (seccomp) |
| **Credential isolation** | Creds in MCP servers, never in agent | Agent has secrets + no network (capability separation) | Gateway injects credentials | No (env vars in process) | Env vars in sandbox | Env var stripping (`KEY`/`SECRET`/`TOKEN`) |
| **Taint tracking** | eBPF + seccomp-notify (Phase 3) | No | No | No | No | No |
| **Shaped denies** | Yes (valid MCP result + explanation) | block/strip/warn/ask | No | No | No | No |
| **Runtime-agnostic** | Yes (any CLI tool) | MCP servers only | MCP servers only | N/A (is the runtime) | Yes (any code) | Codex only |
| **Skills support** | Scans/vets skills loaded by runtime | No | No | Yes (Agent Skills standard) | No | Yes (Agent Skills standard) |
| **Self-hosted** | Yes | Yes | Yes | Yes | Cloud or BYOC | Yes |
| **Elicitation scanning** | Planned | No | No | No | No | No |
| **Audit logging** | NDJSON structured logs | Configurable | `--log-calls` | No | Partial | No |
| **Open source** | Yes (planned) | Yes (Apache-2.0) | Yes | Yes (Apache-2.0) | Yes (Apache-2.0) | Yes (Apache-2.0) |

**Tideclaw's differentiation**:
1. **Taint tracking** (eBPF + seccomp-notify) — no competitor has kernel-level data flow tracking
2. **Shaped denies** — agent reads explanation and adjusts behavior, doesn't retry blindly
3. **Runtime-agnostic** — orchestrates any CLI tool, not just MCP servers
4. **Defense-in-depth** — four independent layers (taint, gateway, proxy, skill vetting) vs. single-layer approaches
5. **Credential topology** — credentials in separate containers on isolated network, not env vars in the agent
6. **Skills-aware security** — only security framework that addresses both the MCP tool plane and the Skills knowledge plane as distinct attack surfaces

---

## Threat Model Delta (Tideclaw vs no Tideclaw)

| Attack | Without Tideclaw | With Tideclaw |
|--------|------------------|---------------|
| **Prompt injection → credential exfil via tool call** | Tool sends creds to attacker's Slack channel | L2 gateway scans tool call params, blocks credential patterns |
| **Malicious skill → `fetch()` to attacker server** | Succeeds (tool has full network) | Proxy blocks non-allowlisted domains |
| **Malicious skill → read `~/.ssh/id_rsa`** | Succeeds (tool has full filesystem) | Container isolation — `~/.ssh` not mounted |
| **Malicious skill → read workspace file, base64, exfil** | Succeeds | L1 taint tracking: eBPF sees file open, seccomp blocks connect |
| **Compromised MCP server → inject creds in response** | Tool receives and may forward | L2 gateway scans response, blocks credential patterns |
| **Credential theft from env vars** | All creds in one process | Only LLM API auth in agent. All others isolated. |
| **Malicious skill → instructs agent to craft legitimate-looking exfil** | Succeeds (agent follows skill instructions) | L1 taint tracking catches file-to-network flows regardless of intent. L3 proxy blocks non-allowlisted domains. **Partial mitigation** — skill vetting (Phase 3) adds pre-load static analysis. |
| **Supply chain skill poisoning (registry)** | Succeeds (agent loads poisoned skill) | Skill allowlisting in `tideclaw.yaml` blocks unknown skills. Snyk agent-scan integration for static analysis. **Phase 3.** |
| **Semantic rephrasing ("card ending in 4242")** | Not blocked | **Not blocked** (residual risk — fundamental limit of pattern scanning) |
| **Exfil via LLM API request** | N/A (direct API access) | **Not blocked** (residual risk — LLM API must be reachable) |

---

## Tideclaw Base Evaluation: Best Non-Claude/Codex/Gemini Runtime

If Tideclaw must work with a runtime that is not Claude Code, Codex CLI, or Gemini CLI, which tool makes the best base? Evaluated against Tideclaw's integration requirements:

### Evaluation Criteria

| Criterion | Weight | Why it matters for Tideclaw |
|-----------|--------|----------------------------|
| MCP support | Critical | Gateway seam requires MCP. Without it, only proxy mode (medium fidelity). |
| Headless/API mode | Critical | Container orchestration requires non-interactive execution with structured output. |
| Docker/containerization | High | Tideclaw's topology is container-based. The runtime must run cleanly in containers. |
| Skills support | High | Skills are a major extension paradigm. The runtime should support or be compatible with the Agent Skills standard. |
| Sandboxing (own) | Medium | Can be disabled in favor of Tideclaw's topology. Nice to have as defense-in-depth option. |
| Model agnosticism | Medium | Users should choose their LLM. Lock-in to one provider reduces Tideclaw's value. |
| Community/maintenance | Medium | Single-maintainer projects are riskier for production infrastructure. |
| Code editing quality | High | The runtime must actually be good at writing code — that's the user's goal. |

### Comparison

| | **Goose** | **Aider** | **llm CLI** |
|---|---|---|---|
| MCP support | **Foundational** — all extensions are MCP | None (community workarounds) | Community plugin only |
| Headless mode | **Yes** — `--quiet`, `--output-format json`, `--no-session`, recipes, cron | Minimal — `-m` flag, no structured output | Not applicable (not an agent) |
| Docker | **Official images**, non-root, Compose workflows | Official images, but `/run` limitations | No official images |
| Skills | **Yes** — Agent Skills standard, SKILL.md, recipes | None (`.aider.conventions` only) | None |
| Own sandbox | **Yes** — bubblewrap (Linux), seatbelt (macOS), v1.25.0 | None | None |
| Model agnosticism | **25+ providers** incl. local (Ollama) | Broad (any LLM via API) | Broadest (51+ plugins) |
| Community | **31K stars, 373 contributors**, Linux Foundation AAIF | 41K stars but **single maintainer** | 11K stars, single maintainer |
| Code quality | Full agent (file edit, shell, test, subagents) | **Best editing engine** (tree-sitter + PageRank repo map) | **Not a coding agent** |
| Integration mode | **MCP gateway** (high fidelity) | Container + proxy only (medium fidelity) | Not viable |
| Tideclaw seam coverage | **All seams activate**: MCP gateway, egress proxy, credential isolation, taint tracking | Proxy + credential isolation only. No MCP gateway seam. | — |

### Recommendation: Goose

**Goose is the clear best base for Tideclaw** outside of Claude Code, Codex CLI, and Gemini CLI. The reasoning:

1. **MCP-native = full seam activation.** Every Goose extension is an MCP server. Point all extensions at the gateway → 100% tool call visibility. This is the highest scanning fidelity achievable. Aider, by contrast, has no MCP support — Tideclaw can only scan its HTTP traffic (medium fidelity) and cannot see structured tool calls at all.

2. **Headless-ready for container orchestration.** `goose run --quiet --output-format json --no-session --max-turns N` gives Tideclaw exactly the non-interactive, structured-output interface needed for container lifecycle management. Aider's `-m` flag exists but produces no structured output and has no proper daemon mode.

3. **Skills-aware.** Goose supports the Agent Skills standard, meaning Tideclaw's Phase 3 skill vetting/scanning applies cleanly. Aider has no skill system, which means fewer attack surfaces but also less extensibility for users.

4. **Rust binary.** Like Codex CLI, Goose compiles to a single Rust binary — fast startup, no runtime dependency bloat inside the container. Aider requires a full Python environment.

5. **Community sustainability.** 373+ contributors, Linux Foundation governance (AAIF), Block corporate backing, 100+ releases in one year. Compare to Aider's single-maintainer model.

6. **The gap Tideclaw fills for Goose.** Goose v1.25.0 added sandboxing, but it's process-level (seatbelt/bubblewrap) — no credential isolation across containers, no MCP interposition scanning, no egress proxy with domain allowlists, no taint tracking. These are exactly Tideclaw's additions. Tideclaw + Goose is a natural pairing: Goose provides the agent runtime and MCP-native extensibility; Tideclaw provides the security topology.

**Aider is a viable but distant second.** Its tree-sitter + PageRank code editing engine is genuinely best-in-class, but the lack of MCP, headless mode, and skills support means Tideclaw can only offer medium-fidelity protection. If a user specifically wants aider's editing quality inside Tideclaw's security topology, proxy-only mode works — but they lose the gateway seam.

**llm CLI is not viable.** It is a chat/completion tool, not a coding agent. Tideclaw would need to build the entire agent runtime from scratch, defeating the purpose.

---

## What This Spike Decided

1. **Tideclaw is an orchestrator** — a peer to ClaudeClaw and NanoClaw, not a layer above or below them. It's the orchestrator you choose when security enforcement is the priority.

2. **The orchestrator's job is to provide seams**: process separation, network segmentation, credential isolation, kernel observation points. Tidegate's security layers (gateway, scanner, proxy, taint tracker) attach to these seams.

3. **Three integration modes**: MCP gateway (high fidelity), network proxy (medium fidelity), hybrid (both). Mode selected automatically based on the agentic runtime's capabilities — specifically, which seams can be activated.

4. **Claude Code, Codex CLI, and Goose are the three launch runtimes**. Claude Code via MCP gateway mode. Codex via hybrid mode (MCP + proxy). Goose via MCP gateway mode (all extensions are MCP servers → highest coverage among open-source tools).

5. **Runtime-agnostic design**: The agentic runtime is pluggable. Any CLI tool that can run in a container works inside Tideclaw's topology. Seams are structural (container boundaries, network segments), not contractual (APIs the runtime must implement).

6. **Pre-built container images** for each supported runtime. Custom Dockerfile support for unsupported runtimes.

7. **Compose generation** (not static compose file) from `tideclaw.yaml`. The generated topology encodes the seams.

8. **Two extension planes, not one**: Modern agentic runtimes extend via MCP (tool connectivity) AND Skills (procedural knowledge). Tideclaw's gateway seam covers MCP. Skill security (vetting, allowlisting, isolation) is a Phase 3 concern but the architecture must anticipate it now.

## What This Spike Did NOT Decide

- CLI implementation language (Go recommended, shell acceptable for Phase 1)
- Plugin distribution model (standalone first, plugin later)
- Codex sandbox conflict resolution (needs empirical testing)
- Goose sandbox conflict resolution (disable Goose's seatbelt/bubblewrap when inside Tideclaw's topology? needs empirical testing)
- Session persistence model for containerized Claude Code
- Skill scanning approach (static analysis vs. allowlisting vs. isolation vs. all three)
- Pricing/distribution model (open source? paid? freemium?)
- Whether to keep "Tidegate" as a name for the security framework or fold it into "Tideclaw"
- Whether Tideclaw's seam topology could be composed with other orchestrators' features (e.g., ClaudeClaw's web UI + Tideclaw's seams)

## References

### Internal
- Prior spike: `docs/research/completed/agent-selection/nanoclaw-tidegate-design-spike.md`
- ADR-002 (taint tracking): `docs/adr/proposed/002-taint-and-verify-data-flow-model.md`
- ADR-003 (agent runtime selection): `docs/adr/proposed/003-agent-runtime-selection.md`
- ClaudeClaw comparison: `docs/research/active/claudeclaw-vs-nanoclaw/claudeclaw-vs-nanoclaw.md`

### AI Coding Tools
- Claude Code docs: https://code.claude.com/docs/en/hooks
- Claude Code sandboxing: https://www.anthropic.com/engineering/claude-code-sandboxing
- Claude Code sandbox-runtime: https://github.com/anthropic-experimental/sandbox-runtime
- Claude Code Agent SDK: https://platform.claude.com/docs/en/agent-sdk
- OpenAI Codex CLI: https://github.com/openai/codex
- Codex security docs: https://developers.openai.com/codex/security/
- Codex cloud environments: https://developers.openai.com/codex/cloud/environments/
- Google Jules: https://blog.google/technology/google-labs/jules/
- Goose (Block): https://github.com/block/goose
- Goose architecture: https://block.github.io/goose/docs/goose-architecture/
- Goose v1.25.0 release: https://block.github.io/goose/blog/2026/02/23/goose-v1-25-0/
- Goose in Docker: https://block.github.io/goose/docs/guides/goose-in-docker/
- Goose + Docker (Docker blog): https://www.docker.com/blog/building-ai-agents-with-goose-and-docker/
- Goose red team report: https://www.theregister.com/2026/01/12/block_ai_agent_goose/
- Aider: https://aider.chat/
- Aider GitHub: https://github.com/Aider-AI/aider
- Aider Docker: https://aider.chat/docs/install/docker.html
- Aider MCP request (Issue #4506): https://github.com/aider-ai/aider/issues/4506
- Aider MCP request (Issue #3314): https://github.com/Aider-AI/aider/issues/3314
- llm CLI: https://github.com/simonw/llm
- llm tool calling (v0.26): https://simonwillison.net/2025/May/27/llm-tools/
- llm plugin directory: https://llm.datasette.io/en/stable/plugins/directory.html

### MCP Security
- MCP spec (latest): https://modelcontextprotocol.io/specification/2025-11-25
- MCP authorization spec: https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
- MCP security best practices: https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices
- MCP elicitation: https://modelcontextprotocol.io/specification/draft/client/elicitation
- Timeline of MCP security breaches: https://authzed.com/blog/timeline-mcp-breaches
- MCP tool poisoning: https://www.pillar.security/blog/the-security-risks-of-model-context-protocol-mcp
- Securing MCP (paper): https://arxiv.org/abs/2511.20920
- OWASP Agentic AI: https://www.kaspersky.com/blog/top-agentic-ai-risks-2026/55184/

### Skills Paradigm and Security
- Agent Skills specification: https://agentskills.io/specification
- Claude Code skills docs: https://code.claude.com/docs/en/skills
- Skills explained (Anthropic): https://claude.com/blog/skills-explained
- Extending Claude with skills and MCP: https://claude.com/blog/extending-claude-capabilities-with-skills-mcp-servers
- Claude Skills vs MCP (IntuitionLabs): https://intuitionlabs.ai/articles/claude-skills-vs-mcp
- Vercel skills.sh: https://vercel.com/changelog/introducing-skills-the-open-agent-skills-ecosystem
- Snyk ToxicSkills study: https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/
- Snyk SKILL.md to shell access: https://snyk.io/articles/skill-md-shell-access/
- Snyk agent-scan: https://github.com/snyk/agent-scan
- Snyk + Vercel securing skills: https://snyk.io/blog/snyk-vercel-securing-agent-skill-ecosystem/
- ClawHavoc malicious campaign: https://snyk.io/articles/clawdhub-malicious-campaign-ai-agent-skills/
- OpenClaw security (Cisco): https://blogs.cisco.com/ai/personal-ai-agents-like-openclaw-are-a-security-nightmare
- Federal Register RFI on AI agent security: https://www.federalregister.gov/documents/2026/01/08/2026-00206/request-for-information-regarding-security-considerations-for-artificial-intelligence-agents
- Linux Foundation AAIF: https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation

### Sandboxing and Agent Security
- Pipelock: https://github.com/luckyPipewrench/pipelock
- Docker MCP Gateway: https://github.com/docker/mcp-gateway
- Docker sandboxes for coding agents: https://www.docker.com/blog/docker-sandboxes-run-claude-code-and-other-coding-agents-unsupervised-but-safely/
- E2B: https://e2b.dev
- Daytona: https://www.daytona.io
- microsandbox: https://github.com/zerocore-ai/microsandbox
- Kubernetes Agent Sandbox: https://github.com/kubernetes-sigs/agent-sandbox
- How to sandbox AI agents (Northflank): https://northflank.com/blog/how-to-sandbox-ai-agents
- NVIDIA sandboxing guidance: https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/
- A deep dive on agent sandboxes: https://pierce.dev/notes/a-deep-dive-on-agent-sandboxes
- Awesome MCP gateways: https://github.com/e2b-dev/awesome-mcp-gateways
- UK AISI sandboxing toolkit: https://github.com/UKGovernmentBEIS/aisi-sandboxing
