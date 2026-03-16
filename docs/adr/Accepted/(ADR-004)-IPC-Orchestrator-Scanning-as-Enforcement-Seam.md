---
artifact: ADR-004
title: "ADR-004: IPC Orchestrator Scanning as Enforcement Seam"
status: Accepted
author: cristos
created: 2026-02-28
last-updated: 2026-03-11
related: [SPIKE-014, SPIKE-013, SPIKE-011, ADR-003, ADR-002]
affects: [SPIKE-013]
affected-artifacts:
  - ADR-002
  - SPIKE-011
  - SPIKE-013
  - SPIKE-014
---
# ADR-004: IPC Orchestrator Scanning as Enforcement Seam

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Draft | 2026-02-28 | bb16b22 | Initial creation; pending SPIKE-014 findings |
| Accepted | 2026-03-11 | — | Accepted as architectural principle: IPC is a first-class enforcement seam; implementation approach (inline vs gateway-mediated) deferred to SPIKE-014 |

## Status

Accepted — the architectural decision that IPC must be scanned is settled. Implementation details (which alternative) remain subject to SPIKE-014 findings.

## Context

Tideclaw's architecture (SPIKE-013) defines four enforcement seams where Tidegate's security layers attach:

1. **MCP interposition** — gateway scans all tool call parameters and responses (L2)
2. **Egress mediation** — proxy scans HTTP traffic and controls domain access (L3)
3. **Credential isolation** — mount boundaries keep credentials in their respective containers
4. **Kernel observation** — eBPF/seccomp track file access and gate network connections (L1)

These seams assume the agent's only outbound data paths are MCP tool calls, HTTP egress, and network connections. There is a fifth path: **IPC to the orchestrator**.

In NanoClaw's model (SPIKE-011), the agent communicates with the orchestrator via filesystem IPC. An MCP server (`ipc-mcp-stdio.ts`) runs *inside* the agent container, exposing tools like `send_message` and `schedule_task` that write JSON files to a shared IPC volume. The orchestrator reads these files and forwards content to external channels — WhatsApp, Slack, web UI, task schedulers.

This IPC channel is structurally identical to an outbound MCP tool call (the agent invokes a tool that sends data externally), but it bypasses the MCP gateway seam entirely because the IPC MCP server runs inside the agent container, not through `tg-gateway`. The orchestrator acts as an unscanned bridge between the agent's isolated network and the outside world.

If Tideclaw adopts sub-container orchestration (Phase 1) and adds messaging bridges (Phase 4), every data type the agent writes to IPC — messages, tasks, file references, status updates — reaches external systems without hitting any scanning layer.

### The exfiltration scenario

1. Agent reads a file containing sensitive data (credit card number, API key, medical record)
2. Agent composes an IPC message: `{"type": "send_message", "text": "Here's the summary: ... 4532-XXXX-XXXX-1234 ..."}`
3. Agent writes the message to `data/ipc/{group}/messages/msg-{ts}.json`
4. Orchestrator reads the file, forwards to WhatsApp/Slack/web UI
5. Sensitive data has left the system without being scanned

The MCP gateway never sees this tool call. The egress proxy never sees this traffic (IPC is filesystem, not network). The taint tracker (ADR-002) observes the `openat` on the sensitive file but enforcement is gated on `connect()` — filesystem writes to IPC don't trigger the barrier.

## Decision

**IPC between agent containers and the Tideclaw orchestrator is a first-class enforcement seam.** All data flowing from agent containers to the orchestrator through IPC must be scanned before the orchestrator forwards it to any external channel.

The orchestrator MUST NOT act as an unscanned bridge between `agent-net` and external services.

Tideclaw's seam model becomes five enforcement seams:

| # | Seam | Layer | What it scans |
|---|------|-------|---------------|
| 1 | MCP interposition | L2 (gateway) | Tool call parameters and responses |
| 2 | Egress mediation | L3 (proxy) | HTTP request/response bodies |
| 3 | Credential isolation | Structural | Mount boundary enforcement |
| 4 | Kernel observation | L1 (taint tracker) | File access → network gating |
| 5 | **IPC scanning** | **L2 or inline** | **All IPC payloads before external forwarding** |

## Alternatives Considered

### Alternative A: No IPC scanning — constrain IPC to control signals only

Remove all user-generated content from IPC. Agent can only send status updates and control signals (ready, done, error). All user-facing communication must route through MCP tools via `tg-gateway`.

- **Pro**: Eliminates the exfiltration path entirely. No new scanning infrastructure.
- **Con**: Severely limits orchestrator capabilities. NanoClaw's `send_message` pattern — which is the primary interaction model for messaging bridge use cases — becomes impossible. Phase 4 (messaging bridges, task scheduling) requires rearchitecting around MCP-only communication. Fundamentally changes the orchestrator's role from "bridge" to "lifecycle manager only."
- **Verdict**: Too restrictive. The IPC data path is a feature, not a bug — it just needs scanning.

### Alternative B: Route IPC through tg-gateway (IPC-as-MCP)

Replace the in-container IPC MCP server with MCP tools served by `tg-gateway`. The agent's `send_message` and `schedule_task` become regular MCP tool calls that the gateway scans and then routes to the orchestrator.

- **Pro**: Reuses existing L1/L2/L3 scanning pipeline. Consistent enforcement model — all tool calls go through the gateway, including IPC tools. No new scanner.
- **Con**: Requires network connectivity between gateway and orchestrator (currently on separate networks). Adds network hop latency to the IPC path. Changes the IPC model from filesystem to network, which affects the orchestrator's design. The gateway becomes the sole bottleneck for all agent communication — both MCP tools and orchestrator IPC.
- **Verdict**: Architecturally clean but may have performance and coupling implications. SPIKE-014 should evaluate latency.

### Alternative C: Scan at the orchestrator (inline)

The orchestrator scans every IPC payload in-process before forwarding to external channels. Reuses the same L1/L2/L3 scanner logic (imported as a library or subprocess).

- **Pro**: Simple, no additional containers, no network topology changes. Orchestrator already reads all IPC — scanning is a filter step in the existing read path.
- **Con**: Orchestrator becomes a security-critical component — its scanning logic must be trusted. Scanner runs in the orchestrator's trust domain, not in a separate container. If the orchestrator is compromised, scanning is bypassed.
- **Verdict**: Pragmatic for MVP. The orchestrator is already trusted to forward IPC correctly — adding scanning doesn't materially change its trust level. For hardening, combine with Option B or a sidecar.

### Alternative D: Sidecar scanner daemon

A dedicated scanner container watches the IPC volume and annotates payloads (pass/fail) before the orchestrator reads them.

- **Pro**: Scanning in a separate trust domain. Orchestrator only checks annotations.
- **Con**: Race conditions between scanner and orchestrator reads. TOCTOU risk (file modified between scan and read). Additional container complexity. Requires coordination protocol (e.g., scanner renames files to a "scanned" directory).
- **Verdict**: Adds complexity for marginal trust improvement over Option C. Consider for Phase 3 hardening.

## Recommendation

**Phase 1 (MVP)**: Option C (inline scanning at orchestrator). The orchestrator scans IPC payloads using the same L1/L2/L3 pipeline before forwarding. This is the simplest path and the orchestrator is already trusted infrastructure.

**Phase 2+**: Evaluate Option B (IPC-as-MCP) based on SPIKE-014 latency findings. If gateway-mediated IPC is viable within the latency budget, migrate to it for a cleaner enforcement model. This eliminates the in-container IPC MCP server entirely — all agent→external communication routes through `tg-gateway`.

## Consequences

### Positive

- Closes the IPC exfiltration gap — all five outbound data paths are now scanned
- Reuses existing scanning infrastructure (L1/L2/L3 pipeline)
- Makes the orchestrator's bridge role explicit and auditable
- Aligns with SPIKE-013's "seams first" design principle — every data boundary is an enforcement point

### Negative

- Adds latency to the agent→messaging path (magnitude depends on SPIKE-014 benchmarks)
- Orchestrator becomes security-critical (scanning logic must be correct)
- IPC protocol design must accommodate scan results (deny responses, shaped errors)

### Neutral

- Taint tracking (ADR-002) gains a new enforcement point: if a tainted PID writes to IPC, the orchestrator's scanner catches the content even though `connect()` wasn't triggered. This is defense in depth — L1 (taint) and the IPC scanner independently detect exfiltration attempts.
- The IPC MCP server pattern (NanoClaw's `ipc-mcp-stdio.ts` inside the container) should be deprecated in favor of gateway-mediated IPC tools (long-term) or orchestrator-scanned filesystem IPC (short-term).
- SPIKE-013's Tideclaw architecture diagram and enforcement layers table should be updated to include IPC scanning as the fifth seam once this ADR moves to Proposed.
