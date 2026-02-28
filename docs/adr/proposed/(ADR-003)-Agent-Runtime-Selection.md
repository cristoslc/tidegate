---
title: "ADR-003: Agent Runtime Selection — NanoClaw over OpenClaw"
status: Proposed
author: cristos
created: 2026-02-24
last_updated: 2026-02-24
affected_artifacts:
  - VISION-001
---

# ADR-003: Agent Runtime Selection — NanoClaw over OpenClaw

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Proposed | 2026-02-24 | cfcc86a | From agent-selection research spike comparing NanoClaw and OpenClaw |

## Context

Tidegate needs an agent runtime to wrap. The security framework (egress proxy, MCP gateway scanner, taint tracking) is only useful when there's an agent container to enforce constraints on. Two candidates were evaluated: NanoClaw (private, ~5K LOC TypeScript orchestrator) and OpenClaw (open-source, monorepo agent platform).

### Tidegate's wrapping contract

Tidegate's model is: **give us a container image, we'll run it with enforced constraints.** Specifically:

- Read-only source mounts, scoped read-write for IPC only
- All egress through egress-proxy (domain allowlisting, payload scanning)
- All MCP tool calls through tg-gateway (L1/L2/L3 scanning)
- Credential isolation: API keys in MCP server containers on `mcp-net`, never in the agent container
- Runtime taint tracking: eBPF `openat` observation + seccomp-notify `connect()` enforcement (ADR-002)

The runtime must have a **process boundary between the agent and the control plane** for Tidegate to wrap.

### NanoClaw architecture

Single Node.js host process (WhatsApp/WebChat comms bridge, SQLite, IPC watcher) spawns ephemeral Docker containers for each agent session. Agent containers run `agent-runner/index.ts` which calls the Claude Agent SDK.

- **Host↔agent communication:** Entirely filesystem IPC. JSON files in shared volumes (`ipc/input/`, `ipc/messages/`, `ipc/tasks/`). Host polls every 500ms. No network, no stdin/stdout in the proposed detached model.
- **Host network needs:** WhatsApp (baileys WebSocket), WireGuard (WebChat). No connections to agents or MCP servers.
- **Skills:** Code transformations via `git merge-file`. Modify the host source tree at build time. Add new channels, dependencies, docker-compose services, post-apply scripts.
- **Existing isolation:** Per-group filesystem/session/IPC isolation, non-root user, mount allowlist. Key gaps (unrestricted egress, API keys in env, no seccomp) are exactly what Tidegate addresses.

### OpenClaw architecture

Monolithic Node.js Gateway process containing the agent runtime (embedded pi-mono), all messaging surfaces (WhatsApp, Telegram, Slack, Discord, Signal, iMessage), model provider calls, credential storage, and plugin execution in a single process.

- **No agent container.** The agent runs in-process with the Gateway. Docker sandboxing exists but only for tool execution (bash, file ops), not the agent itself. Sandbox is off by default.
- **Host network needs:** Model provider APIs (Anthropic, OpenAI), all messaging surfaces, node WebSocket connections — all from the same process that runs the agent.
- **Skills:** Markdown documents (SKILL.md) injected into the system prompt at runtime. No code transformation, no source modification.
- **Plugins:** TypeScript modules loaded in-process via `jiti`. Full Gateway privileges, no isolation. This is how new channels are added.
- **MCP:** External bridge via mcporter, deliberately decoupled from core.
- **Security model:** Single-user, single-trust-boundary. Operator trusts the whole Gateway process.

## Decision

**Use NanoClaw as the first supported agent runtime.** Support for OpenClaw (and other runtimes) can be added later via network-level wrapping.

### Why NanoClaw fits

NanoClaw already has the process boundary Tidegate needs. Agent containers are separate processes on separate networks. The host is a dumb comms bridge that shares volumes, not a network, with agents. This gives Tidegate:

1. **Per-tool-call scanning.** Agent → tg-gateway → MCP servers. Every tool call argument and response passes through L1/L2/L3 scanning. Denials are shaped MCP results the agent reads and adjusts to.

2. **Credential isolation.** API keys live in MCP server containers on `mcp-net`. The agent container on `agent-net` never sees them. No key to exfiltrate.

3. **Network-level enforcement.** Agent container's only egress path is through egress-proxy. Combined with taint tracking (ADR-002), even encrypted exfiltration attempts are caught.

4. **Read-only source enforcement.** tg-pipeline validates compose specs: source mounts must be `:ro`, only IPC directories are `:rw`. Skills are a build-time concern that produce an image; Tidegate enforces runtime constraints on whatever image shows up.

5. **No dual-homing.** The host sits on `wg-net` (comms ingress) only. Agents sit on `agent-net` only. They share volumes, not networks. No container spans both, so no application-layer bridge can bypass egress controls.

### Why OpenClaw doesn't fit (as a wrapped agent container)

OpenClaw's agent runs in the same process as the Gateway. There is no container boundary to wrap.

- **No per-tool-call scanning seam.** Native tool calls (bash, file ops) are function calls within the process. Only mcporter-bridged MCP tools could be routed through tg-gateway, leaving native tools unscanned.
- **No credential isolation.** The Gateway holds model provider keys and messaging tokens in-process. The agent *is* the Gateway; it has direct access.
- **Single trust boundary.** OpenClaw's security model assumes the operator trusts the whole process. Tidegate assumes agent code is untrusted. These are opposite assumptions.

### OpenClaw can still be wrapped — at the network level

Treating the entire OpenClaw Gateway as an untrusted container provides:

- **Egress control.** All outbound traffic (model calls, messaging, mcporter) goes through egress-proxy. L1/L2/L3 scanning at the proxy catches credential patterns in any outbound payload.
- **Taint tracking.** eBPF `openat` + seccomp-notify `connect()` still works. If the Gateway reads sensitive files, its outbound connections get scrutinized.
- **Domain allowlisting.** Restricts which external services the Gateway can reach.

This is coarser-grained than the NanoClaw integration (network-level vs. tool-call-level) but still covers the primary threat: sensitive data leaving the perimeter. The scanning layers (L1 patterns, L2 checksums, L3 entropy) operate on outbound payloads regardless of whether the payload originated from a tool call or a Telegram message.

The credential isolation gap (Gateway holds its own keys) is partially mitigated: L1/L2/L3 scanning catches known credential patterns in outbound traffic, and the tainted file register flags processes that have accessed sensitive files. Monitoring-based enforcement rather than isolation-based, but effective against all but sophisticated encoding evasion.

### What this ADR does NOT decide

- **tg-pipeline design.** The filesystem job queue and compose spec validation from the design spike are good, but tg-pipeline is not yet built. This ADR recommends NanoClaw as the runtime; the pipeline architecture is a separate concern.
- **Image registry trust model.** For the homelab deployment, the operator controls the registry. Multi-tenant image trust (signing, allowlists) is a future problem.
- **OpenClaw exclusion.** Network-level wrapping is viable and can be offered as a second integration tier. This ADR recommends NanoClaw as the primary/first integration because it enables the full enforcement stack.

## Consequences

- NanoClaw integration work starts with the design spike's decisions (#1–#5, #7, plus #8 build/runtime separation).
- Network topology is four networks: `wg-net` (host comms), `agent-net` (agents + egress-proxy + tg-gateway), `mcp-net` (tg-gateway + MCP servers), `proxy-net` (egress-proxy + internet). No `control-net`.
- The host (NanoClaw) is never on `agent-net`. Filesystem IPC only.
- tg-pipeline enforces read-only source mounts. Skill application is a build step.
- OpenClaw support can be added later as a "network-wrapped" tier with coarser-grained scanning.

## References

- Design spike: `docs/research/completed/agent-selection/nanoclaw-tidegate-design-spike.md`
- ADR-002 (taint tracking): `docs/adr/proposed/002-taint-and-verify-data-flow-model.md`
- NanoClaw source analysis: `docs/research/completed/agent-selection/nanoclaw-main/`
- OpenClaw source analysis: `docs/research/completed/agent-selection/openclaw-main/`
