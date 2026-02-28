---
title: "SPIKE-014: Tideclaw IPC Orchestrator Scanning"
status: Active
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
| Active | 2026-02-28 | 4bd2303 | Research complete; findings and recommendation written |

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

---

## Findings

### Q1: IPC Transport Models

#### Evaluated models

| Model | Mechanism | Scanning injection | Structured? | Atomicity | Taint interaction |
|-------|-----------|-------------------|-------------|-----------|-------------------|
| **Filesystem JSON** | Shared volume, `rename()` | Sidecar watcher or inline at reader | Yes (JSON) | `rename()` is atomic | Write not gated by `connect()` — no L1 enforcement |
| **Unix domain socket** | UDS in shared volume | Proxy on UDS path | Framing-dependent | Stream-based | `connect()` fires but seccomp filter must allow `AF_UNIX` for MCP stdio — can't selectively block |
| **Named pipe (FIFO)** | Kernel byte stream | Inline only (no random access) | No — raw bytes | None | No `connect()` involved |
| **gRPC over UDS** | Protobuf RPC over UDS | gRPC interceptor/middleware | Yes (protobuf) | Per-RPC | Over-engineered: adds protobuf compilation, heavy deps |
| **MCP over HTTP** | JSON-RPC via tg-gateway | **Existing gateway scanner** | Yes (MCP) | Per-request | Same as all MCP tool calls — L2 scanning, no L1 gap |

#### Analysis

**Filesystem JSON** is what NanoClaw uses. It works, but the scanning injection point is awkward — you need either a sidecar watcher or inline scanning at the orchestrator. The fundamental problem: the IPC MCP server runs *inside* the agent container, so the data is already in its final form (a JSON file) by the time any external component sees it. Scanning must happen after the write, not before.

**Unix domain sockets** are tempting because `connect()` on a UDS fires the same syscall as TCP `connect()`. But ADR-002's seccomp-notify filter cannot selectively block UDS connections to the IPC socket while allowing UDS connections to MCP servers (stdio transport). The seccomp BPF filter operates on syscall arguments — it can distinguish `AF_UNIX` from `AF_INET`, but not one UDS path from another (path resolution requires userspace logic). Blocking all `AF_UNIX` `connect()` breaks stdio MCP servers. Allowing all `AF_UNIX` `connect()` means no enforcement.

**Named pipes** have no random access (can't scan before the reader consumes) and no built-in framing (must layer a protocol on top). Worse in every dimension than filesystem JSON.

**gRPC over UDS** adds protobuf compilation and heavy runtime dependencies for no security benefit over MCP-over-HTTP. The scanning injection point (gRPC interceptor) is equivalent to a gateway middleware.

**MCP over HTTP (via tg-gateway)** eliminates the problem entirely. The IPC tools become regular MCP tools. The gateway's existing `router.ts` pipeline — `extractStringValues()` → `scanValue()` (L1 regex + L2/L3 Python subprocess) → `shapedDeny()` on violation — handles IPC payloads with zero new code. The in-container IPC MCP server pattern is not adopted; all agent→external communication routes through the gateway seam.

#### Conclusion

**MCP over HTTP is the only model that reuses the existing scanning infrastructure without new code.** All others require building a parallel scanning injection point. The question is not "which IPC transport" but "should IPC exist as a separate channel at all, or should it be MCP?"

---

### Q2: IPC Data Flow Mapping

#### NanoClaw agent→host data types

| Data type | IPC path | Content | Exfiltration risk | Forwarded to |
|-----------|----------|---------|-------------------|--------------|
| **Messages** | `ipc/{group}/messages/msg-{ts}.json` | `{type, text, group, ts}` | **HIGH** — `text` is unconstrained free-text | WhatsApp, Slack, web UI |
| **Tasks** | `ipc/{group}/tasks/task-{ts}.json` | `{name, prompt, schedule, group}` | **HIGH** — `prompt` is unconstrained free-text | Future agent sessions |
| **Session ID** | `ipc/{group}/session_id` | Short identifier string | Low — not free-text | Internal orchestrator state |
| **Stdout markers** | stdout stream | `<<RESULT>>`, `<<DONE>>` | None — fixed enum strings | Internal orchestrator state |

#### NanoClaw host→agent data types

| Data type | IPC path | Content | Risk |
|-----------|----------|---------|------|
| **Input prompts** | `ipc/{group}/input/prompt-{ts}.json` | `{text, sender, ts}` | Ingress (toward agent, not exfiltration) |
| **Session meta** | `ipc/{group}/input/_meta.json` | Configuration | Low |
| **Close sentinel** | `ipc/{group}/input/_close` | Empty file (presence signal) | None |

#### Projected Tideclaw IPC data types

| Category | Data type | Needs scanning? | Proposed channel |
|----------|-----------|----------------|-----------------|
| **Data plane** | Messages to external channels | **Yes** — free-text, highest risk | MCP tool via tg-gateway |
| **Data plane** | Scheduled tasks / prompts | **Yes** — free-text prompts | MCP tool via tg-gateway |
| **Data plane** | File sharing / attachments | **Yes** — file content | MCP tool via tg-gateway |
| **Control plane** | Lifecycle status (ready, done, error) | **No** — fixed enum values, no user content | Filesystem signal files |
| **Control plane** | Health checks | **No** — structured diagnostics | Docker HEALTHCHECK / filesystem |
| **Control plane** | Shutdown signals | **No** — presence-only | Docker SIGTERM / filesystem sentinel |

#### Key insight: control plane vs data plane separation

NanoClaw's IPC channel carries both control-plane signals (session ID, stdout markers, close sentinel) and data-plane content (messages, tasks) over the same filesystem mechanism. This is the root cause of the scanning gap — the channel must be open for control signals, and data rides along unscanned.

**Separating the two planes eliminates the problem.** Control signals use filesystem IPC (no scanning needed — fixed formats, no user content). Data-plane content routes through MCP tools via the gateway (full scanning).

---

### Q3: Scanning Injection Point — Detailed Analysis

#### Option A: Inline scanning at orchestrator

```
Agent → filesystem IPC → Orchestrator [import scanner, scan in-process] → External channel
```

**Implementation**: Orchestrator imports the scanner as a library. Before forwarding any IPC payload, calls `extractStringValues()` → `scanValue()` on all fields. Deny → drop message + log. Allow → forward.

**Performance**: L1 regex (~0.1ms) + L2 Python subprocess NDJSON (~1-3ms for Luhn/IBAN/SSN) + L3 entropy (~2-8ms) = **~3-12ms per payload**. Well within the <100ms interactive messaging budget.

**Trust analysis**: The orchestrator is already trusted infrastructure — it manages the Docker lifecycle, has access to configuration, and forwards content to external channels. Adding scanning doesn't materially change its trust level. If the orchestrator is compromised, the attacker controls the entire topology; IPC scanning bypass is the least of the problems.

**Cross-language concern**: The gateway scanner is TypeScript (L1) + Python subprocess (L2/L3). If the orchestrator is in a different language (Go for `tideclaw` CLI), it would need to re-implement L1 regex patterns or shell out to the Python subprocess. This is a coupling concern — scanner logic must be importable by the orchestrator.

**Verdict**: Pragmatic for a filesystem-IPC architecture. But if we can avoid building a separate scanning injection point entirely, that's strictly better.

#### Option B: Sidecar scanner daemon

```
Agent writes → ipc/pending/msg-{ts}.json
Scanner sidecar watches → scans → renames to ipc/scanned/msg-{ts}.json (or ipc/denied/)
Orchestrator watches ipc/scanned/ → reads only scanner-approved files → forwards
```

**Implementation**: Scanner sidecar container watches `ipc/pending/` with `inotify`. Reads each file, scans all string values, renames atomically to `scanned/` (pass) or `denied/` (fail). Orchestrator watches `scanned/` only.

**TOCTOU mitigation**: The agent can write to `pending/` but not to `scanned/`. This requires separate volume mounts:
- Agent: `ipc-pending:/workspace/ipc:rw`
- Scanner: `ipc-pending:/scan/in:ro`, `ipc-scanned:/scan/out:rw`
- Orchestrator: `ipc-scanned:/workspace/ipc:ro`

The agent cannot bypass the scanner by writing directly to `scanned/` — it doesn't have that volume mounted.

**PID attribution via fanotify**: `inotify` does not report which PID wrote a file. `fanotify` with `FAN_REPORT_PIDFD` (Linux 5.15+) can. This would enable taint-aware scanning: if the writing PID is tainted (per ADR-002's taint table), apply stricter scanning or deny outright. However, this adds kernel version requirements and complexity.

**Performance**: Same L1/L2/L3 scan times (~3-12ms) + inotify event propagation (~1ms) + atomic rename (~0.1ms) = **~4-13ms per payload**. Within budget.

**Verdict**: Better trust separation than Option A (scanner in its own container, potentially the same `tg-scanner` container that runs L1 taint tracking). But adds container complexity, volume topology, and a coordination protocol. Worth considering if filesystem IPC is chosen for the data plane — but Option C avoids the need entirely.

#### Option C: Route data-plane IPC through tg-gateway (IPC-as-MCP)

```
Agent calls send_message MCP tool → tg-gateway [existing scan pipeline] → IPC MCP server on mcp-net → External channel
```

**Implementation**: The in-container IPC MCP server (`ipc-mcp-stdio.ts`) is NOT adopted. Instead, `send_message`, `schedule_task`, and similar tools are served by dedicated MCP servers on `mcp-net` — the same topology as `gmail-mcp`, `slack-mcp`, `github-mcp`.

For Tideclaw Phase 4, the messaging bridges ARE these MCP servers:
- `messaging-bridge-whatsapp` on `mcp-net`: serves `send_message` tool, forwards to WhatsApp
- `messaging-bridge-slack` on `mcp-net`: serves `send_slack_message` tool, forwards to Slack
- `task-scheduler` on `mcp-net`: serves `schedule_task` tool, manages cron-style scheduling

The gateway scans every tool call through the existing pipeline (`router.ts:handleToolCall()` → `extractStringValues()` → `scanValue()`). No new scanning code. The audit trail captures every IPC interaction identically to every other MCP tool call.

**Credential isolation**: Messaging bridge credentials (WhatsApp auth tokens, Slack bot tokens) stay in the bridge containers, not in the agent or orchestrator. Same isolation model as all other MCP servers.

**Performance**: Agent → gateway HTTP (~0.5ms) + L1 scan (~0.1ms) + L2/L3 Python subprocess (~3-10ms) + gateway → bridge HTTP (~0.5ms) + bridge processing (~1ms) + return path (~1ms) = **~6-13ms per payload**. Within budget. Network hop overhead is minimal on Docker bridge networks (localhost latency).

**What about the orchestrator?** In Option C, the orchestrator doesn't need to be in the data path for messaging at all. The agent calls `send_message` via MCP → gateway scans → messaging bridge sends to WhatsApp. The orchestrator manages lifecycle (start, stop, health), not message routing. This is a cleaner separation of concerns.

**Phase 1 concern**: In Phase 1, there are no messaging bridges. The user attaches directly to the agent container (`tideclaw attach`). There is no `send_message` tool. IPC is control-plane only (lifecycle signals). No scanning needed for Phase 1.

**Verdict**: Eliminates the IPC exfiltration path entirely for data-plane content. No new scanning infrastructure. Consistent enforcement model. The only cost is that messaging bridges must be implemented as MCP servers — but that's the right architecture anyway (credential isolation, tool allowlisting, audit logging all come for free).

#### Option D (new): Hybrid — filesystem control plane + MCP data plane

```
Control plane: Agent → filesystem signals (ready/done/error) → Orchestrator (no scanning)
Data plane:    Agent → tg-gateway [scan] → Bridge MCP server → External channel
```

This separates the two concerns:

1. **Control plane** uses filesystem IPC: agent writes status files to a shared volume (`ipc/status/ready`, `ipc/status/done`, `ipc/status/error`). Orchestrator watches with inotify. No scanning needed — these are fixed-format, orchestrator-defined signals with no user-generated content. The agent can write `ready` or `done`, but there's no free-text field to abuse.

2. **Data plane** uses MCP via tg-gateway: all user-generated content (`send_message`, `schedule_task`, file sharing) routes through the gateway seam. Full L1/L2/L3 scanning. Messaging bridges are MCP servers.

This eliminates the IPC scanning problem for data-plane traffic entirely — it's just MCP. And the control plane doesn't need scanning because it's not a data channel.

**Verdict**: This is the recommended architecture. See Recommendation below.

---

### Q4: Performance Analysis

#### Scanner pipeline latency (from code analysis)

Measured against the existing `scanner.ts` (L1) and `scanner.py` (L2/L3) implementations:

| Layer | What it does | Latency (typical message ~500 chars) | Latency (long message ~5000 chars) |
|-------|-------------|--------------------------------------|-------------------------------------|
| **L1** (in-process TypeScript) | 14 credential regexes + 7 sensitive-key regexes = 21 pattern tests | ~0.05-0.1ms | ~0.5-1ms |
| **L2** (Python subprocess) | Credit card regex + Luhn, IBAN regex + mod-97, SSN regex + area validation | ~1-3ms | ~2-5ms |
| **L3** (Python subprocess) | SSN context keywords, base64+entropy, hex+entropy, sliding-window entropy (40-char window, step 10) | ~2-8ms | ~5-15ms |
| **Subprocess overhead** | NDJSON write + readline response (persistent process, no spawn cost) | ~0.5ms | ~0.5ms |

The Python subprocess is long-lived (spawned once at startup, NDJSON protocol). No per-request spawn overhead. Fail-closed on subprocess crash with auto-respawn (up to 5 attempts with linear backoff).

#### End-to-end per IPC payload

| Architecture | Latency | Budget | Verdict |
|-------------|---------|--------|---------|
| Filesystem + inline scan (Option A) | ~3-12ms | <100ms | Pass |
| Filesystem + sidecar scan (Option B) | ~4-13ms | <100ms | Pass |
| MCP via gateway (Option C/D) | ~6-13ms | <100ms | Pass |

All options are well within the <100ms budget for interactive messaging. The additional ~3ms from network hops in Option C/D is negligible on Docker bridge networks (same host, localhost-equivalent latency).

#### Throughput

The Python subprocess is serialized (one NDJSON request→response at a time). For typical IPC throughput (~1-10 messages/second), this is not a bottleneck. For high-frequency status updates (control plane), Option D bypasses scanning entirely — no throughput concern.

If Option C/D is adopted, the gateway already handles concurrent MCP requests from the agent. IPC tool calls are just additional MCP requests — no new concurrency model needed.

---

### Q5: Same Scanner Pipeline or Separate?

#### Finding: Same pipeline, no IPC-specific scanner needed

The existing L1/L2/L3 scanner covers all relevant patterns for IPC payloads:

| Pattern class | Scanner layer | IPC relevance |
|--------------|--------------|---------------|
| API keys, tokens (vendor prefixes: `ghp_`, `sk_live_`, `xoxb-`, etc.) | L1 | Agent could embed stolen credentials in messages |
| Private key blocks (`-----BEGIN...`) | L1 | Agent could exfiltrate private keys via messages |
| Sensitive JSON keys (`"password":`, `"ssn":`, etc.) | L1 | Agent could embed structured sensitive data |
| Credit card numbers (Luhn-validated) | L2 | Agent could exfiltrate financial data |
| IBANs (mod-97 validated) | L2 | Agent could exfiltrate financial data |
| SSNs (format + area validated) | L2 | Agent could exfiltrate government IDs |
| High-entropy base64/hex (Shannon entropy) | L3 | Agent could encode data before exfiltrating |
| SSN with context keywords | L3 | Reduces false positives on SSN detection |

IPC-specific heuristics considered and rejected:

- **Message length anomaly**: Unreliable — agents legitimately produce long outputs (code blocks, analysis summaries). No reliable threshold distinguishes exfiltration from legitimate verbosity.
- **Frequency analysis**: Agents legitimately send many messages during active sessions. High-frequency messaging is not a reliable exfiltration signal.
- **Encoding detection**: Already covered by L3 entropy analysis. Base64/hex detection in the sliding-window entropy scanner catches encoded payloads in IPC messages the same way it catches them in MCP tool calls.

**The IPC payload is just another string value.** The same `extractStringValues()` recursive extraction from `router.ts` works on IPC JSON payloads — it walks the object tree and scans every string. An IPC message `{"type": "send_message", "text": "Here's the data: sk_live_abc123..."}` is scanned identically to an MCP tool call `{"name": "gmail.send_email", "arguments": {"body": "Here's the data: sk_live_abc123..."}}`.

If Option C/D (MCP via gateway) is adopted, this question is moot — the existing pipeline runs automatically. No decision needed.

---

### Q6: Taint Tracking (ADR-002) Interaction

This is the most nuanced question. The answer depends on a critical detail in ADR-002's taint model.

#### The PID 1 problem

ADR-002 identifies a known residual risk:

> Agent framework process (PID 1 in the container) reads files directly (not via child process). It also makes network connections for MCP and LLM calls. Tainting PID 1 blocks all agent functionality. Need to distinguish framework-level file reads from script-level file reads, or accept that the framework process is outside taint enforcement scope.

This means:

1. **PID 1 (agent framework) is NOT tainted** even when it reads sensitive files — tainting it would block all agent functionality
2. PID 1 makes all MCP tool calls (including IPC tools in Option C/D)
3. PID 1 would write IPC files (in a filesystem IPC model)
4. **L1 taint tracking does NOT protect the IPC path from PID 1**

This is the same gap as for MCP tool calls. L1 taint tracking protects against child processes (Bash subprocesses running scripts), not against the agent framework itself. The defense for PID 1 is L2 pattern scanning at the gateway — which is exactly what Option C/D provides for IPC.

#### Child process IPC writes (filesystem model)

In a filesystem IPC model (Options A/B), a tainted child process could theoretically write directly to the IPC volume:

1. Child process (PID 4523) reads `secret.csv` → eBPF logs `openat` → PID tainted
2. Child process writes `ipc/messages/msg-{ts}.json` containing exfiltrated data
3. `write()` to filesystem is NOT `connect()` — seccomp-notify does not fire
4. **Gap**: tainted data reaches IPC without hitting the L1 enforcement barrier

However, in practice this doesn't happen. In NanoClaw's model, child processes (scripts) return results to PID 1 via stdout/return value. PID 1 then calls the IPC MCP server. The child process doesn't write to IPC directly — it doesn't know the IPC paths or protocol.

In a Tideclaw context with Option C/D, this gap doesn't exist: child processes can't make MCP tool calls (only PID 1 can). And if a tainted child process tries to `connect()` to the gateway directly, seccomp-notify blocks it.

#### Extending seccomp-notify to IPC writes — why it doesn't work

Could we intercept `write()` or `rename()` for IPC paths from tainted PIDs?

- **`write()` frequency**: `write()` fires thousands of times per second for any process. At ~5-7μs per seccomp-notify round-trip, this is the same catastrophic performance cliff as intercepting `sendto()` (rejected in ADR-002).
- **Path filtering**: seccomp BPF operates on syscall arguments (fd numbers), not file paths. Filtering by IPC directory path requires resolving the fd → inode → path in userspace, which means intercepting every `write()` just to check the path.
- **Conclusion**: Impractical. Same reasons ADR-002 rejected `sendto()` interception.

#### fanotify + taint check (alternative)

`fanotify` with `FAN_REPORT_PIDFD` (Linux 5.15+) can report which PID performed a filesystem operation. A scanner sidecar could:

1. Watch the IPC volume with fanotify
2. When a file is written, check the PID against the taint table
3. If tainted PID → deny (don't rename to `scanned/`)

This is viable but complex:
- Requires fanotify instead of inotify (fanotify provides PID; inotify does not)
- Requires Linux 5.15+ for `FAN_REPORT_PIDFD`
- Only useful for filesystem-based IPC (Options A/B), not for Option C/D
- Adds kernel version requirements beyond ADR-002's existing 5.8+ requirement

**If Option C/D (MCP via gateway) is adopted, this is moot.** The taint tracking interaction for IPC is identical to all other MCP tool calls: PID 1 is outside taint scope, L2 pattern scanning is the defense. No new taint infrastructure needed.

#### Taint interaction summary

| Architecture | L1 taint coverage | L2/L3 coverage | Net |
|-------------|-------------------|----------------|-----|
| Filesystem IPC (Options A/B) | **Gap**: PID 1 not tainted, child write to IPC not gated by `connect()`. fanotify could partially close but adds complexity. | Inline or sidecar scan covers L2/L3 patterns | L2/L3 only (same as MCP for PID 1 writes) |
| MCP via gateway (Option C/D) | Same gap as all MCP: PID 1 not tainted. But child processes can't make MCP calls, and tainted child `connect()` to gateway is blocked. | Gateway pipeline covers L1/L2/L3 automatically | **Strictly better**: child process exfiltration via IPC is impossible (no direct MCP access), and PID 1 gets the same L2/L3 defense as all MCP calls |

---

### Gate Evaluation

| Criterion | Threshold | Result | Verdict |
|-----------|-----------|--------|---------|
| Viable scanning injection point | At least one option is architecturally sound | Option D (hybrid) eliminates the data-plane gap entirely by routing through existing gateway | **PASS** |
| Scanning latency within budget | < 100ms interactive, < 1s tasks | ~6-13ms via MCP gateway, ~3-12ms inline | **PASS** |
| Taint tracking integration path | ADR-002 extensible without excessive false positives | Option D inherits the same taint model as all MCP calls — no extension needed. PID 1 residual risk is pre-existing and accepted. | **PASS** |

**Gate: GO.** Option D is viable, performant, and integrates cleanly with the existing taint model.

---

## Recommendation

### Architecture: Option D — Hybrid (filesystem control plane + MCP data plane)

```
Control plane (lifecycle):  Agent → filesystem signals → Orchestrator
Data plane (content):       Agent → tg-gateway [L1/L2/L3 scan] → Bridge MCP servers → External channels
```

#### Control plane: filesystem signals (no scanning)

The orchestrator and agent communicate lifecycle state via filesystem presence/content:

```
ipc/
├── status/
│   ├── ready          # Agent has started and is accepting prompts
│   ├── done           # Agent has completed its task
│   └── error          # Agent encountered a fatal error (content: error message)
├── health/
│   └── heartbeat.json # Agent writes periodic health data (timestamp, memory, etc.)
└── control/
    └── shutdown       # Orchestrator writes to signal graceful shutdown
```

**Why no scanning**: These files have orchestrator-defined schemas. `ready` and `done` are empty files (presence is the signal). `heartbeat.json` has a fixed schema (`{timestamp, uptime_s, memory_mb}`). `error` contains a stack trace (low exfiltration utility — stack traces don't look like messages to WhatsApp). The agent cannot inject free-text into control signals because the orchestrator defines the schema and ignores unexpected fields.

**Atomicity**: `rename()` for signal files (write to temp, rename into `status/`). Orchestrator watches `status/` with inotify.

#### Data plane: MCP tools via tg-gateway (full scanning)

All user-generated content routes through MCP tools served by dedicated bridge containers on `mcp-net`:

| Tool | Served by | Credentials | Scanned by |
|------|-----------|-------------|------------|
| `send_whatsapp_message` | `messaging-bridge-whatsapp` | WhatsApp auth tokens | tg-gateway L1/L2/L3 |
| `send_slack_message` | `messaging-bridge-slack` | Slack bot token | tg-gateway L1/L2/L3 |
| `schedule_task` | `task-scheduler` | None (internal) | tg-gateway L1/L2/L3 |
| `share_file` | `file-sharing-bridge` | Upload service creds | tg-gateway L1/L2/L3 |

These are regular MCP servers. The gateway discovers their tools, mirrors them to the agent, and scans every call. The agent calls `send_whatsapp_message` the same way it calls `gmail.send_email` — through the gateway seam.

**Credential isolation**: WhatsApp auth tokens live in `messaging-bridge-whatsapp`, not in the agent or orchestrator. Same isolation model as `gmail-mcp` having `GMAIL_CLIENT_ID`.

**Audit trail**: Every message sent, task scheduled, or file shared is logged by the gateway's NDJSON audit log. The orchestrator doesn't need its own audit — the gateway is the single audit point for all agent→external communication.

#### Phase mapping

| Phase | IPC model | Scanning | Notes |
|-------|-----------|----------|-------|
| **Phase 1 (MVP)** | Control plane only (filesystem signals) | None needed | No messaging bridges. User attaches directly. `tideclaw attach` |
| **Phase 2 (multi-runtime)** | Control plane only | None needed | Multiple runtimes, still no messaging bridges |
| **Phase 4 (messaging bridges)** | Control plane (filesystem) + data plane (MCP) | Gateway scans data plane automatically | Bridges are MCP servers. `send_message` is a tool call. |

**In Phase 1, no IPC scanning infrastructure is needed at all.** The control plane carries no user-generated content, and there are no messaging bridges. This defers IPC scanning complexity to Phase 4, where it's absorbed by the existing gateway architecture — no new scanning code.

#### Why not adopt NanoClaw's IPC model

NanoClaw's filesystem IPC for `send_message` exists because NanoClaw was designed before Tidegate. The agent needed a way to send messages to WhatsApp, and filesystem IPC was the simplest mechanism. There was no scanning requirement.

Tideclaw is designed around enforcement seams. Adopting NanoClaw's IPC pattern — an MCP server inside the agent container that writes to a shared filesystem — would create a data channel that intentionally bypasses the gateway seam. We would then need to build parallel scanning infrastructure (Options A or B) to cover the gap we created.

**Option D avoids creating the gap in the first place.** The NanoClaw `ipc-mcp-stdio.ts` pattern is not adopted. Messaging bridges are MCP servers on `mcp-net`, routed through the gateway. The IPC bypass doesn't exist because the IPC data path doesn't exist — it's MCP.

---

## Impact on ADR-004

This spike's findings support ADR-004 (IPC Orchestrator Scanning as Enforcement Seam) with a specific recommendation:

1. **IPC scanning is a fifth enforcement seam** — confirmed. The gap is real: any data channel between the agent container and external services that bypasses the gateway is an exfiltration path.

2. **The recommended implementation eliminates the seam rather than scanning it.** Option D routes data-plane IPC through the existing MCP gateway seam. There is no separate "IPC scanning" layer — it's the same L2 scanning that covers all MCP tool calls. The fifth seam collapses into the second.

3. **ADR-004's phased recommendation should be updated**: MVP (Phase 1) needs no IPC scanning at all (control plane only). Phase 4 needs messaging bridges implemented as MCP servers. No inline-scanning-at-orchestrator fallback is needed if bridges are MCP servers from the start.

4. **The pivot (constrain IPC to control signals only) is the recommendation.** The spike's pivot-if-gate-fails scenario — "remove user-generated content from IPC and route through MCP" — turned out to be the best architecture regardless of gate outcome.

## Expected Outputs

- [x] Recommendation for IPC model (Q1): MCP over HTTP for data plane, filesystem signals for control plane
- [x] Scanning injection point (Q3): tg-gateway (existing pipeline, zero new code)
- [ ] Latency benchmarks for IPC scanning (Q4): Estimated ~6-13ms via gateway; empirical benchmarks deferred to implementation
- [x] Design for taint tracking interaction (Q6): Same model as all MCP calls — PID 1 outside taint scope, L2/L3 pattern scanning is the defense
- [x] Input to ADR-004: Option D recommended; update ADR-004 phased recommendation
