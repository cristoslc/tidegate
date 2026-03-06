---
artifact: SPIKE-014
title: "SPIKE-014: Tideclaw IPC Orchestrator Scanning"
status: Active
author: cristos
created: 2026-02-28
last-updated: 2026-02-28
question: "How should Tideclaw scan IPC between agent sub-containers and the orchestrator to prevent data exfiltration through the orchestrator bridge?"
parent-vision: VISION-001
related: [SPIKE-013, SPIKE-011, ADR-003, ADR-002, ADR-004]
gate: Pre-MVP (Tideclaw Phase 1)
risks-addressed:
  - Agent exfiltration via orchestrator IPC bypass
  - Unscanned data reaching external messaging channels
blocks: [ADR-004]
---

# Tideclaw IPC Orchestrator Scanning

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-28 | bb16b22 | Initial creation |
| Active | 2026-02-28 | 4bd2303 | Initial findings: transport evaluation, data plane separation |
| Active | 2026-02-28 | 5391e13 | Revised: privilege separation model (orchestrator/subagent/interceptor) |

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

### The key insight: privilege separation, not IPC scanning

The original framing — "how do we scan the IPC channel?" — is the wrong question. Scanning IPC is trying to add a checkpoint to a channel that shouldn't carry unchecked data in the first place. The right question: **how do we structure the agent hierarchy so that processes with access to sensitive data can never reach external channels directly?**

The answer is privilege separation between an orchestrator agent and its subagents, with an interceptor at the boundary.

#### The model

```
                         User
                          ↕
                  ┌───────────────┐
                  │  Orchestrator  │  Can talk to the outside world.
                  │  Agent         │  Cannot touch the workspace.
                  │                │
                  │  Tools:        │
                  │  · send_message│
                  │  · schedule_task
                  │  · spawn_agent │
                  └──┬──────┬──┬──┘
                     │      │  │
                ┌────┴──┐┌──┴──┴──┐
                │Intrcp ││Intrcp  │   Scans subagent output.
                │A      ││B       │   Sanitizes or terminates.
                └────┬──┘└────┬───┘
                     │        │
                ┌────┴──┐┌────┴───┐
                │Sub    ││Sub     │   Can touch the workspace.
                │agent A││agent B │   Cannot talk to the outside world.
                │       ││        │
                │Tools: ││Tools:  │
                │· read  ││· read  │
                │· write ││· write │
                │· bash  ││· bash  │
                │· grep  ││· grep  │
                └───────┘└────────┘
```

**Orchestrator agent**: Has messaging tools (`send_message`, `schedule_task` — via tg-gateway). Can spawn and manage subagents. Has **no** workspace access — cannot read files, cannot run code, cannot call filesystem tools. Its only inputs are user prompts and sanitized subagent results.

**Subagents**: Have workspace tools (read, write, edit, bash, glob, grep). Can read sensitive files, run code, modify the workspace. Have **no** messaging tools — cannot call `send_message`, cannot reach external channels. Their only output path is IPC back to the orchestrator, which passes through the interceptor.

**Interceptor**: Sits on the IPC channel between each subagent and the orchestrator. Processes every subagent→orchestrator message. Three outcomes:

1. **Pass** — output is clean, forward to orchestrator
2. **Sanitize** — output contains detectable sensitive data, redact specific values and forward
3. **Terminate** — output is opaque or unsalvageable, signal the orchestrator to kill this subagent and retry

#### Why this resolves the PID 1 problem

ADR-002 identifies a fundamental residual risk: the agent framework process (PID 1) reads files directly and makes network connections. Tainting PID 1 blocks all agent functionality. The taint model accepts that PID 1 is outside enforcement scope.

Privilege separation eliminates this problem structurally:

- The **orchestrator** (which needs network access for messaging) **never reads workspace files**. It has no filesystem tools. It can't become tainted because it never accesses sensitive data.
- The **subagents** (which read sensitive files) **can't reach external channels**. They have no messaging tools and no network path to the gateway or proxy.
- The **interceptor** bridges the two: it inspects everything crossing the privilege boundary before the orchestrator sees it.

There is no PID 1 problem because no single process needs both file access and external network access. The two capabilities are split across separate agents with an enforcement boundary between them.

#### Sanitize vs terminate: why this is better than shaped denies

The existing gateway returns a shaped deny — a binary decision (block the entire tool call) delivered back to the *same* agent that has the sensitive data in its context window. The agent retries, but the sensitive data is still in its context. It may rephrase, encode, or try a different tool.

The interceptor is a **filter**, not a **gate**:

| | Gateway shaped deny | Interceptor |
|---|---|---|
| **Granularity** | Binary: block the entire call | Surgical: redact specific values, pass the rest |
| **Data path** | Deny bounces back to tainted agent | Clean/redacted data reaches untainted orchestrator |
| **Retry model** | Same agent, same context window, same tainted data | Fresh subagent, clean context, modified prompt |
| **Encoding evasion** | Agent can encode data and retry | Interceptor terminates on opaque output; orchestrator spawns clean subagent that never sees the original data |

Sanitization example:
- Subagent returns: `"Found 47 transactions. Largest: card 4532-0151-2345-6789, amount $12,500"`
- Interceptor L2 scan: Luhn-valid credit card detected
- Sanitize: `"Found 47 transactions. Largest: card [REDACTED: credit card], amount $12,500"`
- Orchestrator receives the redacted result and can forward it to the user

Termination example:
- Subagent returns: `"Here is the analysis: aGVyZSBpcyB0aGUgY3JlZGl0IGNhcmQgbnVtYmVyOiA0NTMyLTAxNTEtMjM0NS02Nzg5..."` (base64-encoded exfiltration attempt)
- Interceptor L3 scan: high-entropy base64 blob, can't sanitize (the entire payload is opaque)
- Terminate: signal orchestrator "Subagent A terminated: opaque output detected"
- Orchestrator kills subagent A, spawns subagent B with prompt: "Summarize the transactions without including specific card numbers or account details"
- Subagent B reads the same files, produces a clean summary
- Interceptor passes the clean summary to orchestrator

The retry works because the **new subagent has a clean context window**. It never saw the orchestrator's messaging tools. It can't "remember" a previous exfiltration attempt. The orchestrator — which has messaging tools — never saw the raw sensitive data.

---

### Q1: IPC Transport — Implementation Detail

The transport between subagent and interceptor is an implementation detail. The security model is defined by the privilege separation (tool disjointness + interceptor enforcement), not by the byte-level IPC mechanism.

Any structured transport works:

| Model | Mechanism | Fit |
|-------|-----------|-----|
| **Filesystem JSON** | Shared volume, `rename()` | Good. Interceptor watches pending dir, scans, promotes to scanned dir. Same pattern as SPIKE-011's sidecar model. |
| **Unix domain socket** | UDS in shared volume | Good. Interceptor is a proxy on the UDS. Structured framing needed. |
| **MCP over stdio** | JSON-RPC over pipe | Good. Interceptor wraps the subagent's MCP server. Natural fit for agent frameworks that already speak MCP. |
| **MCP over HTTP** | JSON-RPC via network | Good. Interceptor runs as an HTTP proxy between subagent and orchestrator on an internal network. |

The filesystem JSON model (NanoClaw-style) works fine when the interceptor is between the subagent's write and the orchestrator's read. The previous analysis correctly identified that scanning must happen at this boundary — the privilege separation model just makes the boundary explicit.

The transport choice should be driven by operational concerns (debugging, latency, atomicity), not security concerns. Security is enforced by the interceptor regardless of transport.

---

### Q2: Data Flow Mapping

#### NanoClaw IPC data types (unchanged from initial analysis)

| Data type | Direction | Content | Exfiltration risk | Proposed handler |
|-----------|-----------|---------|-------------------|-----------------|
| **Messages** | Agent→Host | `{type, text, group, ts}` | **HIGH** — `text` is unconstrained free-text | Interceptor scans; orchestrator forwards via messaging tool |
| **Tasks** | Agent→Host | `{name, prompt, schedule, group}` | **HIGH** — `prompt` is unconstrained free-text | Interceptor scans; orchestrator calls `schedule_task` |
| **Status** | Agent→Host | `ready`, `done`, `error` | Low — fixed enum | Pass through; orchestrator lifecycle management |
| **Input prompts** | Host→Agent | `{text, sender, ts}` | Ingress (toward agent) | Orchestrator→interceptor→subagent; not an exfiltration path |

#### Privilege separation changes the flow

In NanoClaw's model, one agent handles everything — reads files, runs code, AND sends messages. All data types flow through the same IPC channel.

In the privilege separation model:

```
Subagent reads files, runs code
    ↓ (results, analysis, summaries)
Interceptor scans all string values
    ↓ (clean/sanitized)
Orchestrator receives task results
    ↓ (decides what to forward externally)
Orchestrator calls send_message via tg-gateway [L2 scan]
    ↓
Messaging bridge → WhatsApp/Slack
```

The data is scanned **twice**: once at the interceptor (subagent→orchestrator boundary) and once at the gateway (orchestrator→external boundary). Defense in depth — the interceptor catches sensitive data before it enters the orchestrator's context, and the gateway catches anything that slips through when the orchestrator composes outbound messages.

The control plane (status, health, shutdown) doesn't need an interceptor — these signals use fixed schemas with no free-text fields. Same conclusion as the initial analysis: control plane is filesystem signals, no scanning needed.

---

### Q3: Interceptor Design

The interceptor replaces Options A through D from the initial analysis. Those options asked "where do we inject scanning into the IPC channel?" The interceptor asks "what happens at the privilege boundary?"

#### Processing pipeline

For every subagent→orchestrator message:

```
1. Receive message from subagent
2. Parse structured payload (JSON)
3. Extract all string values (same extractStringValues() recursive walk)
4. Scan each value through L1/L2/L3 pipeline
5. Decision:
   ├─ All clean           → PASS: forward message to orchestrator
   ├─ Some values flagged → evaluate: can we redact?
   │   ├─ Yes (isolated pattern in a field) → SANITIZE: replace with [REDACTED: reason], forward
   │   └─ No (entire field is opaque/encoded) → TERMINATE
   └─ Opaque payload      → TERMINATE: signal orchestrator
```

#### Sanitization criteria

| Scanner result | Redactable? | Action |
|---------------|-------------|--------|
| L1: credential pattern (`ghp_`, `sk_live_`, etc.) | **Yes** — pattern has clear boundaries | Replace matched substring with `[REDACTED: credential pattern]` |
| L2: credit card (Luhn-validated) | **Yes** — number has clear boundaries | Replace with `[REDACTED: credit card ****NNNN]` |
| L2: IBAN (mod-97 validated) | **Yes** — clear boundaries | Replace with `[REDACTED: IBAN CC**]` |
| L2: SSN (format + area) | **Yes** — clear boundaries | Replace with `[REDACTED: SSN]` |
| L3: high-entropy base64 blob | **No** — can't distinguish sensitive from non-sensitive content in the blob | Terminate |
| L3: high-entropy hex string | **No** — same as base64 | Terminate |
| L3: high-entropy sliding window | **No** — region boundaries are fuzzy | Terminate |
| Multiple L1/L2 hits across many fields | **Depends** — evaluate density | If >N fields flagged, terminate (suggests deliberate exfiltration, not accidental inclusion) |

The key distinction: **L1 and L2 patterns have clear boundaries** (the regex match defines exactly which bytes to redact). **L3 patterns are fuzzy** (entropy detection identifies a suspicious region but can't delimit the sensitive content). Redaction is safe when boundaries are known; termination is the only safe option when they're not.

#### Termination signal

When the interceptor terminates a subagent, it sends a structured signal to the orchestrator:

```json
{
  "type": "subagent_terminated",
  "subagent_id": "A",
  "reason": "opaque_output",
  "detail": "High-entropy base64 blob detected in response field (L3, entropy 5.7 bits/char). Cannot sanitize — entire payload is opaque.",
  "recommendation": "Retry with constrained prompt: request summary without raw data"
}
```

The orchestrator uses this signal to:
1. Kill the subagent container (clean up resources, prevent further IPC attempts)
2. Decide whether to retry with a modified prompt or report failure to the user
3. Log the incident for audit

The orchestrator makes the retry decision — not the interceptor. The interceptor is stateless; the orchestrator has the task context needed to reformulate the prompt.

#### Interceptor is not a gateway

| Property | tg-gateway | Interceptor |
|----------|-----------|-------------|
| **Position** | Between agent and MCP servers | Between subagent and orchestrator agent |
| **Protocol** | MCP JSON-RPC over HTTP | IPC (filesystem, UDS, pipe — implementation detail) |
| **On deny** | Shaped deny (isError: false) back to the same agent | Sanitize if possible; terminate subagent if not |
| **Retry** | Same agent retries with same context window | Orchestrator spawns fresh subagent with clean context |
| **Scanner** | Same L1/L2/L3 pipeline | Same L1/L2/L3 pipeline + sanitization logic |
| **Trust** | Agent is untrusted; MCP servers hold credentials | Subagent is untrusted; orchestrator holds messaging capability |

The scanner pipeline is identical — both use `extractStringValues()` → `scanValue()`. The difference is what happens after a scan violation: the gateway blocks; the interceptor transforms or kills.

---

### Q4: Performance

#### Scanner pipeline latency (unchanged)

| Layer | Latency (typical ~500 char message) | Latency (long ~5000 char message) |
|-------|--------------------------------------|-------------------------------------|
| **L1** (in-process regex, 21 patterns) | ~0.05-0.1ms | ~0.5-1ms |
| **L2** (Python subprocess: Luhn, IBAN, SSN) | ~1-3ms | ~2-5ms |
| **L3** (Python subprocess: entropy, base64, hex) | ~2-8ms | ~5-15ms |
| **Subprocess NDJSON overhead** | ~0.5ms | ~0.5ms |

#### Interceptor overhead

| Operation | Latency | Notes |
|-----------|---------|-------|
| Message receipt (filesystem inotify or UDS read) | ~1ms | Depends on transport |
| String extraction | ~0.1ms | Same `extractStringValues()` as router.ts |
| L1/L2/L3 scan | ~3-12ms | Same pipeline as gateway |
| Sanitization (if needed) | ~0.1ms | String replacement at known offsets |
| Forward to orchestrator | ~1ms | Depends on transport |
| **Total (pass or sanitize)** | **~5-15ms** | Well within <100ms interactive budget |

Termination has no latency budget — it's an error path. The orchestrator decides when (and whether) to retry.

#### Double-scan overhead

Data is scanned twice: at the interceptor (subagent→orchestrator) and at the gateway (orchestrator→external). Total overhead per outbound message: ~10-30ms. Still well within the <100ms interactive messaging budget.

The double scan is not redundant — each catches different things:
- Interceptor catches sensitive data leaking from workspace to orchestrator context
- Gateway catches sensitive data in the orchestrator's composed outbound message (which may include data from multiple subagents, user prompts, or orchestrator-generated content)

---

### Q5: Interceptor Scanning — Same Pipeline, New Actions

The existing L1/L2/L3 scanner is the right detection engine. The question from the original framing ("same pipeline or separate?") becomes: **same detection, different response actions.**

| Scanner layer | Detection | Gateway action | Interceptor action |
|--------------|-----------|----------------|-------------------|
| L1 (credential patterns) | Vendor-prefix regex | Shaped deny (block call) | **Sanitize** (redact matched pattern, forward rest) |
| L2 (checksum-validated) | Luhn, mod-97, SSN format | Shaped deny (block call) | **Sanitize** (redact validated number, forward rest) |
| L3 (entropy/statistical) | Shannon entropy, base64 | Shaped deny (block call) | **Terminate** (opaque — can't delimit sensitive content) |

The scanner's `ScanResult` already returns `{ allowed, reason, layer }`. The interceptor uses `layer` to choose its response:
- `scanner_l1` or `scanner_l2` → attempt sanitization (clear match boundaries)
- `scanner_l3` → terminate (fuzzy boundaries, can't safely redact)

No new detection logic. The scanner is reused as-is. What changes is the *enforcement action* downstream of the scan.

#### IPC-specific heuristics (reconsidered)

The initial analysis rejected IPC-specific heuristics (message length anomaly, frequency analysis). In the interceptor model, one additional heuristic becomes viable:

- **Taint-aware escalation**: If the subagent's IPC output triggers many L1/L2 matches in a single message (e.g., >3 distinct sensitive values across different fields), escalate from sanitize to terminate. A single accidental inclusion is normal; many hits suggests the subagent is attempting bulk exfiltration. The orchestrator retries with a more constrained prompt.

This is a density threshold, not a new detection pattern. It uses the existing L1/L2 scanner — just counts hits instead of stopping at the first one.

---

### Q6: Taint Model — Per-Subagent, Not Per-PID

The privilege separation model changes the taint granularity from PID to subagent.

#### ADR-002's PID-level taint model

ADR-002 tracks taint per-PID:
1. eBPF observes `openat` → logs `{pid, file_path, seq}`
2. Scanner daemon reads file contents → if sensitive, taints the PID
3. seccomp-notify on `connect()` → blocks tainted PIDs from TCP connections

**Residual risk (PID 1)**: The agent framework process (PID 1) reads files and makes network connections. Tainting it blocks all functionality. PID 1 is outside taint scope.

#### Subagent-level taint model

In the privilege separation model, the taint boundary is the subagent:

1. **Subagent reads sensitive file** → subagent is tainted (per-subagent state, not per-PID)
2. **Tainted subagent produces output** → interceptor applies stricter scrutiny
3. **Interceptor action on tainted subagent output**:
   - L1/L2 match → sanitize (redact)
   - L3 match (opaque) → terminate
   - Clean output from tainted subagent → **pass, but flag** (the subagent accessed sensitive data; output looks clean, but semantic rephrasing can't be ruled out)
4. **Orchestrator receives sanitized/flagged output** → never tainted itself

The "pass, but flag" case is important. A tainted subagent that produces apparently clean output may have semantically rephrased sensitive data. The interceptor can't detect this (fundamental limit of pattern-based detection). But the orchestrator can log the flag for audit: "This response originates from a subagent that accessed sensitive files X, Y, Z." The audit trail preserves the provenance even when detection fails.

#### How the interceptor knows taint state

Two options:

**Option 1: eBPF journal (ADR-002 infrastructure)**. The interceptor queries ADR-002's taint table for the subagent container's PIDs. If any PID in the subagent's cgroup is tainted, the subagent is tainted. This reuses the existing L1 infrastructure (eBPF on `openat` + scanner daemon + taint table). The interceptor becomes a consumer of the taint table, not a separate taint tracker.

**Option 2: Interceptor-level file access tracking**. The interceptor watches the subagent's workspace volume with inotify/fanotify. When the subagent opens a file, the interceptor scans the file contents. If sensitive, the subagent is tainted at the interceptor level. This is simpler (no eBPF, no taint table) but less precise (inotify doesn't report PIDs; fanotify with `FAN_REPORT_PIDFD` does but requires Linux 5.15+).

Recommendation: **Option 1** if ADR-002's eBPF infrastructure is available (Tideclaw Phase 3+). **Option 2** as a fallback for environments without eBPF (Phase 1-2), or if the interceptor needs to work independently of L1.

#### What this solves

| Problem | PID-level taint (ADR-002) | Subagent-level taint (this model) |
|---------|--------------------------|----------------------------------|
| PID 1 reads sensitive files + makes network calls | Residual risk: PID 1 outside taint scope | **Solved**: orchestrator never reads files; subagents can't make network calls |
| Encrypted exfiltration via IPC | Not covered (IPC writes not gated by `connect()`) | **Solved**: interceptor terminates on opaque output; orchestrator retries with clean subagent |
| Tainted data in agent context window | Agent retries with same context (shaped deny) | **Solved**: terminated subagent is killed; new subagent has clean context |
| Semantic rephrasing | Fundamental limit — undetectable | Still a limit, but **flagged**: audit trail records that output came from tainted subagent |

The privilege separation model doesn't eliminate semantic rephrasing (nothing can — it's a fundamental limit of pattern-based detection). But it strictly reduces the attack surface: a compromised subagent can't directly reach external channels, and the orchestrator — which can reach external channels — never has raw sensitive data in its context.

---

### Gate Evaluation

| Criterion | Threshold | Result | Verdict |
|-----------|-----------|--------|---------|
| Viable scanning injection point | At least one option is architecturally sound | Interceptor at privilege boundary; scans with existing L1/L2/L3 pipeline; adds sanitization and termination semantics | **PASS** |
| Scanning latency within budget | < 100ms interactive, < 1s tasks | ~5-15ms at interceptor + ~5-15ms at gateway = ~10-30ms double scan | **PASS** |
| Taint tracking integration path | ADR-002 extensible without excessive false positives | Per-subagent taint via eBPF taint table or interceptor-level file tracking; eliminates PID 1 residual risk | **PASS** |

**Gate: GO.**

---

## Recommendation

### Architecture: Orchestrator/Subagent Privilege Separation

```
                         User
                          ↕
              ┌───────────────────────┐
              │  Orchestrator Agent    │  Tools: send_message, schedule_task, spawn_agent
              │  (no workspace access) │  Network: can reach tg-gateway on agent-net
              │                        │  Mounts: NO workspace volume
              └────┬────────────┬──────┘
                   │            │
             ┌─────┴──┐  ┌─────┴──┐
             │Intercpt │  │Intercpt │  Scans: L1/L2/L3 pipeline (same as gateway)
             │  A      │  │  B      │  Actions: pass / sanitize / terminate
             └─────┬───┘  └────┬───┘
                   │            │
             ┌─────┴──┐  ┌─────┴──┐
             │Subagent │  │Subagent │  Tools: read, write, edit, bash, glob, grep
             │  A      │  │  B      │  Network: NONE (no gateway, no proxy, no internet)
             │         │  │         │  Mounts: workspace volume (rw)
             └─────────┘  └─────────┘
```

#### Tool separation (enforced by container topology)

| Agent | Tools | Network | Workspace | Rationale |
|-------|-------|---------|-----------|-----------|
| **Orchestrator** | `send_message`, `schedule_task`, `spawn_agent` (via tg-gateway on agent-net) | agent-net → tg-gateway | **None** | Messaging capability, no sensitive data access |
| **Subagents** | `read`, `write`, `edit`, `bash`, `glob`, `grep` (local, in-process) | **None** | Read-write | Workspace capability, no external communication |

Disjoint tool sets enforce the privilege boundary at the container level. A subagent literally cannot call `send_message` — the tool doesn't exist in its MCP server list, and it has no network path to the gateway.

#### Interceptor placement

One interceptor per subagent. The interceptor can be:
- A sidecar container that sits between the subagent's IPC output and the orchestrator's IPC input (filesystem model)
- A proxy process that mediates UDS or pipe connections (socket model)
- A component of the orchestrator that scans all inbound subagent data before it enters the orchestrator agent's context window

The third option (interceptor as orchestrator component) is simplest for Phase 1. The orchestrator process reads subagent IPC, scans before injecting into the orchestrator agent's context. The security property holds as long as the scanning runs *before* the data enters the LLM's context window — once the orchestrator agent "sees" the data, it can rephrase and forward.

#### Retry semantics

```
Orchestrator spawns subagent A with task: "Analyze transactions in /data/financials/"
    ↓
Subagent A reads files, produces results
    ↓
Interceptor scans results
    ├─ Clean → pass to orchestrator
    ├─ L1/L2 match → sanitize (redact), pass to orchestrator
    └─ L3 match or too many hits → TERMINATE
         ↓
    Orchestrator receives: { type: "subagent_terminated", reason: "opaque_output", ... }
         ↓
    Orchestrator kills subagent A
         ↓
    Orchestrator spawns subagent B with modified prompt:
        "Analyze transactions in /data/financials/.
         Summarize patterns and totals only.
         Do not include specific account numbers, card numbers, or raw data."
         ↓
    Subagent B reads same files, produces sanitized summary
         ↓
    Interceptor scans → clean → pass to orchestrator
         ↓
    Orchestrator calls send_message via gateway [L2 scan] → user
```

The orchestrator can implement retry policies:
- **Max retries**: Kill the task after N terminations (prevent infinite retry loops)
- **Prompt refinement**: Each retry adds more constraints ("do not include...", "summarize only...", "aggregate without individual records")
- **Escalate to user**: After max retries, inform the user: "I couldn't produce a safe summary of the financial data. The files contain sensitive information that I'm not able to relay."

#### Phase mapping

| Phase | Orchestrator | Subagents | Interceptor | Notes |
|-------|-------------|-----------|-------------|-------|
| **Phase 1 (MVP)** | CLI wrapper (`tideclaw` binary) | Single agent container (Claude Code / Codex / Goose) | Not yet needed — no messaging bridges, user attaches directly | Headless mode: `tideclaw attach` |
| **Phase 2 (multi-runtime)** | CLI wrapper manages multiple runtimes | One container per runtime | Not yet needed | Still headless |
| **Phase 3 (taint tracking)** | CLI + L1 infrastructure | Subagent containers with eBPF observation | Interceptor can query taint table | L1 infrastructure available |
| **Phase 4 (messaging)** | **Orchestrator agent** (LLM-powered, with messaging tools) | Task subagents (workspace tools only) | **Required** — scans all subagent→orchestrator IPC | Full privilege separation model activates |

Phase 1-3 don't need the full privilege separation model because there are no messaging bridges — the user talks to the agent directly. The interceptor becomes necessary in Phase 4 when the orchestrator gains the ability to send messages to external channels.

However, the **tool separation** principle should be established from Phase 1: even in headless mode, the agent container should not have messaging tools in its MCP server list. When messaging bridges are added in Phase 4, they're added to the orchestrator's tool set, not the subagents'.

---

## Impact on ADR-004

1. **The IPC enforcement seam is the interceptor**, not a scanner sidecar or gateway extension. The interceptor sits at the privilege boundary between orchestrator and subagents.

2. **Scanning is necessary but not sufficient.** The interceptor adds two capabilities the gateway lacks: surgical sanitization (redact and forward) and termination with retry (kill tainted subagent, orchestrator spawns fresh one).

3. **The PID 1 problem is structurally resolved.** No process needs both workspace access and external network access. The taint boundary is the subagent, not PID 1.

4. **Phase 1-3 don't need IPC scanning.** The interceptor activates in Phase 4 (messaging bridges). But tool separation should be established early.

## Expected Outputs

- [x] Recommendation for IPC model (Q1): Transport is an implementation detail; privilege separation is the architecture
- [x] Scanning injection point (Q3): Interceptor at subagent/orchestrator privilege boundary
- [x] Scanner design (Q5): Same L1/L2/L3 pipeline; L1/L2 → sanitize, L3 → terminate
- [ ] Latency benchmarks (Q4): Estimated ~10-30ms double scan (interceptor + gateway); empirical benchmarks deferred
- [x] Taint tracking interaction (Q6): Per-subagent taint, not per-PID; eliminates PID 1 problem
- [x] Input to ADR-004: Privilege separation model; interceptor with sanitize/terminate semantics
