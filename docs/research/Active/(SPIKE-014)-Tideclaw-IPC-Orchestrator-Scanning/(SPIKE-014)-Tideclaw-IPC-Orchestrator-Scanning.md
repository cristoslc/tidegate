---
title: "SPIKE-014: Tideclaw IPC Orchestrator Scanning"
status: Planned
author: cristos
created: 2026-02-28
last_updated: 2026-02-28
question: "How should Tideclaw scan IPC between agent sub-containers and the orchestrator to prevent data exfiltration through the orchestrator bridge?"
parent: VISION-001
related: [SPIKE-013, SPIKE-011, ADR-003, ADR-002, ADR-004]
gate: Pre-MVP (Tideclaw Phase 1)
risks_addressed:
  - Agent exfiltration via orchestrator IPC bypass
  - Unscanned data reaching external messaging channels
blocks: [ADR-004]
---

# Tideclaw IPC Orchestrator Scanning

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-28 | bb16b22 | Initial creation |

## Purpose

Investigate how to scan the IPC channel between agent sub-containers and the Tideclaw orchestrator as an enforcement seam. The current Tideclaw architecture (SPIKE-013) identifies four enforcement seams — MCP interposition, egress mediation, credential isolation, and kernel observation — but does not address the orchestrator's own IPC channel, which is a data path that bypasses all four seams.

## Context

In NanoClaw's model (SPIKE-011), the agent communicates back to the orchestrator via filesystem IPC:

- **Host→Agent**: JSON files in `data/ipc/{group}/input/`, `_close` sentinel
- **Agent→Host**: JSON files in `data/ipc/{group}/messages/` and `tasks/`, stdout markers
- **Mechanism**: An MCP server (`ipc-mcp-stdio.ts`) runs *inside* the agent container, exposing tools like `send_message` and `schedule_task` that write JSON files to the shared IPC volume

The orchestrator host reads these IPC files and forwards the content to external channels (WhatsApp, Slack, web UI). This creates a data path that is structurally identical to an MCP tool call that sends data externally — but it bypasses the MCP gateway seam entirely because the IPC MCP server runs inside the agent container, not through `tg-gateway`.

If Tideclaw adopts a similar sub-container model — and Phase 4 adds messaging bridges — the orchestrator becomes a bridge between the isolated `agent-net` and external communication channels. Any data the agent writes to IPC reaches the outside world unscanned.

### Why this matters

The current seam model assumes the agent's only outbound data paths are:

1. MCP tool calls → scanned by `tg-gateway` (L2)
2. HTTP egress → scanned by `egress-proxy` (L3)
3. File writes → observed by eBPF taint tracker (L1)

IPC is a fourth outbound data path that reaches external systems without hitting any of these seams. A compromised agent can exfiltrate sensitive data by encoding it in IPC messages that look like legitimate user-facing responses — the orchestrator forwards them without inspection.

## Research Questions

### Q1: What IPC models are viable for Tideclaw?

NanoClaw uses filesystem-based IPC (JSON files in shared volumes). Other options:

| Model | Mechanism | Scanning opportunity |
|-------|-----------|---------------------|
| **Filesystem JSON** (NanoClaw) | Shared volume, atomic `rename()` | Watcher daemon scans files before orchestrator reads |
| **Unix domain sockets** | UDS in shared volume | Proxy/interceptor on UDS path |
| **Named pipes (FIFOs)** | Kernel-mediated byte stream | Must scan inline (no random access) |
| **gRPC over UDS** | Structured RPC over Unix socket | Interceptor proxy with schema awareness |
| **MCP over UDS** | MCP JSON-RPC over Unix socket | Route through `tg-gateway` (reuse existing scanner) |

Evaluate: latency, scanning injection point, structured vs unstructured data, atomicity guarantees, and compatibility with taint tracking (ADR-002).

### Q2: What data flows through orchestrator IPC?

Map all data types flowing agent→orchestrator in NanoClaw's IPC model and project what Tideclaw would need:

- **Messages**: Agent-generated text for delivery to external channels (WhatsApp, Slack, web UI)
- **Tasks**: Scheduled work items for future execution
- **Status updates**: Session state, progress indicators
- **File references**: Paths to workspace artifacts the agent wants to share
- **Agent memory**: Persistent context across sessions
- **Error reports**: Stack traces, failure diagnostics

Which of these can contain exfiltrated sensitive data? (Answer: all of them, but messages and file references are highest risk.)

### Q3: Where can scanning be injected?

Three architectural options:

#### Option A: Inline scanning at orchestrator

The orchestrator scans every IPC payload before forwarding to external channels. Scanning runs in-process (or as a local subprocess) within the orchestrator container.

```
Agent → IPC volume → Orchestrator [scan] → External channel
```

- **Pro**: Simple, no additional containers, orchestrator already reads all IPC
- **Con**: Orchestrator becomes a security-critical component (must trust its scanning logic), scanning code in the orchestrator's trust domain

#### Option B: Sidecar scanner daemon

A dedicated scanner container watches the IPC volume and annotates/blocks payloads before the orchestrator reads them.

```
Agent → IPC volume ← Scanner daemon [scan + annotate]
                   → Orchestrator [check annotation] → External channel
```

- **Pro**: Scanning in separate trust domain, orchestrator only checks pass/fail annotations
- **Con**: Race conditions (orchestrator must wait for scanner), additional container complexity, TOCTOU between scan and read

#### Option C: Route IPC through tg-gateway

Replace the in-container IPC MCP server with a gateway-mediated IPC channel. The agent's IPC tools (`send_message`, `schedule_task`) become MCP tools served by `tg-gateway`, which scans them like any other tool call and forwards results to the orchestrator via a separate channel.

```
Agent → tg-gateway [scan] → Orchestrator → External channel
```

- **Pro**: Reuses existing L1/L2/L3 scanning pipeline, IPC tools are just MCP tools, no new scanner, consistent enforcement model
- **Con**: Requires agent-net connectivity between gateway and orchestrator, adds latency (network hop vs filesystem), changes the IPC architectural model from filesystem to network

### Q4: Performance implications

What is the latency budget for IPC scanning?

- **Interactive messaging** (WhatsApp, Slack): User expects sub-second response delivery. Scanning budget: < 100ms per message.
- **Task scheduling**: Not latency-sensitive. Scanning budget: < 1s per task.
- **Status updates**: May be high-frequency. Scanning budget depends on update rate.

Measure: L1/L2/L3 scan times for typical IPC payloads (short text messages, JSON task specs, file paths).

### Q5: Same scanner pipeline or separate?

Should IPC scanning use the existing L1/L2/L3 pipeline (regex patterns, Luhn checksums, entropy analysis) or a purpose-built scanner?

- **Same pipeline**: Consistent detection, no new code, proven patterns
- **Separate**: Could add IPC-specific checks (e.g., message length anomaly detection, frequency analysis, encoding detection for steganographic exfiltration)
- **Hybrid**: Same L1/L2/L3 baseline + IPC-specific heuristics layered on top

### Q6: Interaction with taint tracking (ADR-002)

ADR-002's taint-and-verify model tracks file reads via eBPF and blocks tainted PIDs at `connect()`. How does IPC interact?

- If the agent reads a sensitive file (`openat` logged), the PID is tainted
- The tainted PID writes to the IPC volume (filesystem write, not `connect()`)
- Current model: `connect()` is the enforcement point. Filesystem writes are not blocked.
- **Gap**: Tainted data escapes via IPC filesystem writes without hitting the `connect()` barrier

Options:
1. **Extend seccomp-notify to IPC writes**: Block `write()`/`rename()` to IPC paths from tainted PIDs. High false-positive risk (agent needs to write IPC for legitimate purposes).
2. **Scanner-at-orchestrator**: Don't block the write. Instead, scan the content when the orchestrator reads it. This is Option A/B/C from Q3, not a kernel-level enforcement.
3. **Taint propagation to IPC**: If a tainted PID writes to IPC, mark the IPC payload as tainted. Orchestrator checks taint annotation before forwarding.

## Go/No-Go Criteria

| Criterion | Threshold | Measurement |
|-----------|-----------|-------------|
| Viable scanning injection point identified | At least one option (A/B/C) is architecturally sound and implementable | Design review |
| Scanning latency within budget | < 100ms for interactive messages, < 1s for tasks | Benchmark with representative IPC payloads |
| Taint tracking integration path exists | ADR-002 model can be extended to cover IPC writes without excessive false positives | Design analysis |

## Pivot if gate fails

If no viable scanning injection point exists without unacceptable latency or architectural complexity: constrain IPC to status/control signals only (no user-generated content), and require all agent→external communication to route through MCP tools via `tg-gateway`. This eliminates the IPC data exfiltration path by removing the data from IPC entirely.

## Expected Outputs

- Recommendation for IPC model (Q1) and scanning injection point (Q3)
- Latency benchmarks for IPC scanning (Q4)
- Design for taint tracking interaction (Q6)
- Input to ADR-004 (decision on IPC as enforcement seam)
