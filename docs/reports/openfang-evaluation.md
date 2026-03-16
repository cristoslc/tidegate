# OpenFang Evaluation Against Tidegate Reference Architecture

**Date:** 2025-03-13
**Subject:** [OpenFang](https://www.openfang.sh/) v1.x (MIT, Rust, RightNow AI)
**Evaluator:** Tidegate reference architecture (this repo)
**Method:** Public documentation review (website, /docs/architecture, /docs/security, /docs/mcp-a2a)

---

## 1. Executive Summary

OpenFang is a large, feature-rich "Agent Operating System" — 14 Rust crates, 137K LOC, 1,700+ tests — that bundles agent runtime, 40 channel adapters, 38 built-in tools, 60 skills, MCP client/server, A2A protocol, OFP peer-to-peer networking, WASM sandbox, and a desktop app. It markets "16 security systems" and positions itself as the most security-layered agent framework available.

**Verdict against Tidegate's threat model:** OpenFang addresses a fundamentally different problem — agent *runtime* — and leaves critical data-flow enforcement gaps that Tidegate's architecture is designed to close. OpenFang's security is strong for agent sandboxing and capability control but structurally unable to prevent the exfiltration attack classes that motivate Tidegate's design.

| Tidegate Concern | OpenFang Coverage | Assessment |
|---|---|---|
| MCP tool-call payload scanning | None | **Gap** |
| MCP response scanning | None | **Gap** |
| Credential isolation from agent | Partial (env_clear) | **Weak** |
| Egress mediation (network allowlist) | Partial (SSRF + capability) | **Incomplete** |
| Encoding-before-exfiltration | Not addressed | **Gap** |
| Opaque deny responses | Not applicable | **Gap** |
| Structural network topology enforcement | Not addressed | **Gap** |
| Taint-and-verify (file-access → connect) | In-process label propagation | **Different model** |

---

## 2. Architecture Comparison

### 2.1 Fundamental Design Difference

| Dimension | Tidegate | OpenFang |
|---|---|---|
| **What it is** | Enforcement infrastructure external to the agent | Agent runtime with embedded security |
| **Trust boundary** | Agent is *untrusted*; all enforcement runs outside it | Agent kernel is *trusted*; security is self-enforced |
| **Deployment** | Sidecar / gateway / proxy topology | Single binary (monolith) |
| **Scanning target** | Every string value crossing trust boundaries | In-process taint labels on data flow |
| **Credential model** | Credentials never enter agent container | Credentials in-process (zeroized on drop) |
| **Network model** | Agent can only reach gateway + proxy | Agent makes direct outbound connections (SSRF-filtered) |

**Implication:** OpenFang's security systems protect the agent *from itself* — a cooperative model where the kernel enforces rules on its own subsystems. Tidegate assumes the agent (or anything running inside it) may be adversarial and enforces rules from outside, structurally.

### 2.2 What OpenFang Does Well

**Capability-based authorization.** Fine-grained `Capability` enum (`ToolInvoke`, `NetConnect(host)`, `MemoryRead`, `ShellExec`, etc.) checked before every operation. Inheritance validation prevents privilege escalation when spawning child agents. This is well-designed access control.

**WASM dual metering.** Fuel (instruction count) + epoch (wall-clock) prevents resource exhaustion from untrusted WASM modules. This is a real sandbox, not a promise.

**Subprocess isolation.** `env_clear()` + selective variable injection for Python/Node skill execution. No shell invocation (prevents metacharacter injection). This is solid process-level isolation.

**Merkle audit trail.** SHA-256 chained log entries with integrity verification. Tamper-evident, not tamper-proof (the chain lives in-process), but better than append-only files.

**OFP mutual authentication.** HMAC-SHA256 with nonces and constant-time comparison via `subtle`. Textbook-correct for peer-to-peer authentication.

**Loop guard.** SHA-256 hashing of `(tool_name, params)` with graduated response (warn → block → circuit-break). Prevents stuck agent loops without false positives on varied queries.

---

## 3. Gap Analysis: Tidegate Threat Model vs. OpenFang

### 3.1 No MCP Interposition (Seam 1)

Tidegate's primary enforcement seam is an MCP gateway that sits between the agent and downstream MCP servers, scanning every string value in tool-call arguments and responses.

**OpenFang's model:** The agent kernel *is* the MCP client. It connects directly to MCP servers (stdio or SSE), namespaces their tools as `mcp_{server}_{tool}`, and forwards calls. The security pipeline checks *capabilities* (can this agent call this tool?) but does not scan *payloads* (does this tool call contain a credit card number?).

**What this means for Tidegate-class threats:**

- **ClawHavoc-style credential theft** — A malicious MCP server response containing `AKIA...` or `ghp_...` tokens flows directly into the agent's context. No L1 pattern scan intercepts it.
- **EchoLeak-style prompt injection** — A compromised MCP server returns a response containing instructions to exfiltrate data via a subsequent tool call. OpenFang's prompt injection scanner checks *skill manifests*, not MCP server responses.
- **Credit card / SSN in tool arguments** — An agent instructed (via prompt injection) to send a credit card number through a Slack `post_message` tool call will succeed. No Luhn/mod-97 validation occurs on outbound payloads.

**OpenFang's partial mitigation:** Capability-based `NetConnect(host)` restrictions limit which hosts an agent can reach. But MCP tool calls are forwarded to trusted servers that *themselves* make network requests — the capability check applies to the agent, not to what the MCP server does with the data.

### 3.2 No Egress Mediation (Seam 2)

Tidegate routes all agent network traffic through a CONNECT-only Squid proxy with a domain allowlist. The agent container has no direct internet access.

**OpenFang's model:** The agent process makes direct HTTP requests (via `web_fetch` tool, channel adapters, MCP SSE connections, OFP connections). SSRF protection blocks private IPs and cloud metadata endpoints. `NetConnect(host)` capabilities restrict which hosts an agent can reach.

**What this misses:**

- **Capability bypass via MCP servers.** If an agent has `NetConnect` to an MCP server, and the MCP server has unrestricted network access, the agent can exfiltrate data through the MCP server's tools (e.g., a GitHub MCP server's `create_gist` with sensitive content).
- **DNS-based exfiltration.** SSRF protection validates resolved IPs but doesn't restrict DNS queries. An attacker can encode data in DNS lookups to an attacker-controlled domain.
- **No structural guarantee.** Capability checks are software enforcement within the same process. A vulnerability in the kernel (memory corruption, logic bug) could bypass capability checks entirely. Tidegate's network isolation is structural — even a fully compromised agent process cannot reach the internet because the Docker network doesn't route there.

### 3.3 Credentials In-Process (Seam 3)

Tidegate mounts API keys only into the MCP server containers that need them. The agent container never sees credentials.

**OpenFang's model:** API keys live in the kernel process memory as `Zeroizing<String>`. Channel adapter tokens (Discord, Slack, etc.), LLM API keys, and MCP server credentials are all in the same process. Zeroization cleans up on `Drop`, but during runtime, credentials are accessible to any code path that can read the relevant struct fields.

**What this means:**

- **Memory disclosure.** A vulnerability that allows arbitrary memory reads (buffer over-read, format string, deserialization bug) could expose all credentials simultaneously. In Tidegate's model, compromising the agent reveals zero credentials.
- **Core dump / crash dump.** Process crashes may dump memory containing credentials. Zeroization only works on orderly shutdown via `Drop`.
- **WASM escape.** If a WASM module escapes the sandbox (Wasmtime vulnerability), it has access to the kernel's address space, which contains all credentials.

### 3.4 Encoding-Before-Exfiltration Not Addressed

Tidegate's ADR-002 (taint-and-verify) addresses the scenario: agent reads `secret.csv`, base64-encodes it, and sends the encoded blob to an allowed domain. Pattern scanning fails because the encoded data has no recognizable patterns.

**Tidegate's solution:** eBPF observes `openat` syscalls, scanner daemon analyzes file contents, `seccomp-notify` on `connect()` blocks any process that read a sensitive file from making network connections.

**OpenFang's model:** In-process taint tracking with labels (`ExternalNetwork`, `UserInput`, `PII`, `Secret`, `UntrustedAgent`). Taint sinks block labeled data from reaching `net_fetch()` or `shell_exec()`.

**Why OpenFang's taint tracking is insufficient for this threat:**

1. **In-process enforcement.** The taint labels exist in Rust structs. An attacker who achieves code execution within the process can construct untainted values. Tidegate's eBPF/seccomp approach operates at the kernel level — the agent process cannot forge clean taint state.

2. **LLM as taint launderer.** The agent reads a sensitive file (tainted). The file content enters the LLM prompt. The LLM produces a response (new `String`, no taint label). The response is untainted but contains the sensitive data rephrased. This is the "semantic rephrasing" attack — both Tidegate and OpenFang acknowledge it as a fundamental limit, but OpenFang's in-process taint tracking is additionally vulnerable to the LLM breaking the taint chain.

3. **No syscall-level observation.** OpenFang doesn't observe which files the agent actually reads at the OS level. Taint labels are applied by application code. If a skill or MCP tool reads a file through a code path that doesn't apply taint labels, the data flows untainted.

### 3.5 Opaque Deny Responses Not Applicable

Tidegate's ADR-006 specifies that deny responses contain no detection metadata — preventing RL-trained agents from mapping scanner boundaries through feedback iteration.

**OpenFang has no deny responses for data-flow violations.** Capability checks return allow/deny, but these are structural (does the agent have `NetConnect` to this host?) not content-based (does this payload contain sensitive data?). There is no content scanning to produce denies, so opaque deny design is not applicable — but this is a symptom of the missing scanning layer, not an independent gap.

### 3.6 No Structural Network Topology

Tidegate uses Docker network isolation (agent-net, mcp-net) and post-MVP VM isolation (libkrun + gvproxy) to create structural enforcement:

- Agent can only reach gateway and egress proxy (network routing)
- MCP servers are on a separate network (agent cannot reach them directly)
- Egress proxy allowlists LLM API domains only

**OpenFang runs as a single process.** There is no network topology to enforce. The kernel process has the union of all network permissions that any of its subsystems need. Capability checks are software-enforced within this process.

---

## 4. Threat Scenario Walkthrough

### 4.1 ClawHavoc — Malicious Marketplace Skill

**Attack:** Skill steals `ANTHROPIC_API_KEY` from environment and `fetch()`s it to attacker server.

| Step | Tidegate | OpenFang |
|---|---|---|
| Skill reads env var | Blocked — credentials not in agent container | `env_clear()` blocks inherited vars; API key in separate config |
| Skill calls fetch() | Blocked — agent-net only routes to gateway/proxy | `NetConnect` capability check; SSRF blocks private IPs |
| Skill encodes data in MCP tool call | Scanned at gateway; L1 catches `AKIA`/`ghp_` patterns | Not scanned — tool call forwarded directly |

**Assessment:** OpenFang's `env_clear()` for subprocess skills is effective against naive env-var theft. But API keys are in the kernel's memory, and a WASM skill with a sandbox escape, or a `builtin:chat` agent with prompt injection, could access them. Tidegate's structural isolation is stronger.

### 4.2 Credit Card Exfiltration via Tool Call

**Attack:** Prompt injection causes agent to include credit card from a document in a Slack message.

| Step | Tidegate | OpenFang |
|---|---|---|
| Agent reads document | Allowed (workspace access) | Allowed |
| Agent calls `post_message` with CC | Gateway scans args; L2 Luhn check catches CC | Capability check passes (agent has `ToolInvoke(post_message)`); no content scan |
| Deny returned to agent | Opaque deny, no detection metadata | N/A — message sent |

**Assessment:** Clear gap. OpenFang has no mechanism to detect sensitive data in tool-call payloads.

### 4.3 Encoding-Before-Exfiltration

**Attack:** Agent reads sensitive file, encrypts to blob, sends via allowed channel.

| Step | Tidegate | OpenFang |
|---|---|---|
| Agent reads file | eBPF logs `openat` event; scanner taints PID | In-process taint label applied (if code path uses `TaintedValue`) |
| Agent encrypts data | Irrelevant — PID already tainted | Encryption produces new `String` — taint label may or may not propagate depending on implementation |
| Agent calls `connect()` | seccomp-notify pauses thread; taint check → EPERM | `net_fetch()` checks taint sink — *if* the value is still a `TaintedValue` struct, blocked. If taint was lost through string manipulation, allowed |

**Assessment:** Tidegate's kernel-level enforcement is robust against encoding. OpenFang's in-process taint tracking depends on all code paths preserving `TaintedValue` wrappers through every string operation, which is fragile.

---

## 5. Complementarity Analysis

Despite the gaps, OpenFang and Tidegate address complementary concerns:

| Layer | Tidegate Provides | OpenFang Provides |
|---|---|---|
| **Data-flow enforcement** | MCP scanning, egress proxy, credential isolation | — |
| **Agent capability control** | — | Fine-grained capability model with inheritance |
| **Tool sandbox** | — | WASM dual metering, subprocess isolation |
| **Multi-agent coordination** | — | A2A protocol, OFP wire protocol |
| **Channel integration** | — | 40 messaging adapters |
| **Audit** | NDJSON structured logging | Merkle hash chain |
| **Prompt injection defense** | Scans MCP responses for injected content | Scans skill manifests for injection patterns |
| **Resource exhaustion** | — | Fuel + epoch metering, GCRA rate limiting |
| **Network topology** | Docker/VM isolation, proxy routing | — |

**Could they compose?** In principle, yes. OpenFang could run as the agent inside Tidegate's enforcement topology:

```
┌─────────────────────────────────────────────┐
│  Tidegate VM / Container                     │
│  ┌───────────────────────────────────────┐  │
│  │  OpenFang (agent runtime)             │  │
│  │  - capabilities, WASM sandbox, etc.   │  │
│  │  - MCP client → Tidegate gateway      │  │
│  │  - HTTP_PROXY → Tidegate egress proxy │  │
│  └───────────────────────────────────────┘  │
│                    │                         │
│          agent-net (only routes to):         │
│           ├─ tg-gateway:4100                 │
│           └─ egress-proxy:3128               │
└─────────────────────────────────────────────┘
```

OpenFang's in-process security would function as defense-in-depth *inside* the agent, while Tidegate's structural enforcement would provide the hard boundary *outside* it. OpenFang's MCP client would connect to downstream servers through the Tidegate gateway (scanning all payloads), and its `web_fetch` / channel adapter traffic would route through the egress proxy.

**Practical obstacle:** OpenFang's architecture assumes it *is* the infrastructure. Its channel adapters, MCP servers, API endpoints, and OFP listeners would all need to route through Tidegate's enforcement seams, which conflicts with OpenFang's assumption of direct network access.

---

## 6. Security Claims Assessment

OpenFang markets "16 security systems." Here is an honest assessment of each against the standard Tidegate applies (does it prevent data exfiltration by a compromised or manipulated agent?):

| # | System | Exfil-Relevant? | Notes |
|---|---|---|---|
| 1 | Capability-based security | Partially | Controls *which* tools/hosts, not *what data* flows through them |
| 2 | WASM dual metering | No | Resource exhaustion defense, not data-flow |
| 3 | Merkle audit trail | No | Detection after the fact, not prevention |
| 4 | Taint tracking | Partially | Correct model, but in-process enforcement is bypassable |
| 5 | Ed25519 signing | No | Supply chain integrity, not runtime data-flow |
| 6 | SSRF protection | Partially | Blocks private IPs, not data exfil to public endpoints |
| 7 | Secret zeroization | No | Cleanup on drop, not access prevention during runtime |
| 8 | OFP HMAC auth | No | Peer authentication, not data-flow control |
| 9 | Security headers | No | Browser-level protections for API consumers |
| 10 | GCRA rate limiter | No | Abuse prevention, not data-flow |
| 11 | Path traversal prevention | Partially | Filesystem access control, not data-flow |
| 12 | Subprocess sandbox | Partially | Prevents env-var leakage, not payload scanning |
| 13 | Prompt injection scanner | Partially | Scans skill manifests, not MCP responses or tool payloads |
| 14 | Loop guard | No | Agent stability, not security |
| 15 | Session repair | No | API compatibility, not security |
| 16 | Health redaction | No | Information disclosure prevention for API |

**Of 16 systems, 0 directly address MCP payload scanning or structural data-flow enforcement.** The systems are real and well-implemented, but they solve a different problem than what Tidegate targets.

---

## 7. Key Findings

1. **Different threat models.** OpenFang secures an agent runtime against resource abuse, capability escalation, and untrusted code execution. Tidegate secures the data-flow boundary between an untrusted agent and the services it accesses. These are complementary, not competing.

2. **No MCP payload scanning.** OpenFang forwards MCP tool calls without inspecting argument or response content for sensitive data. This is the largest gap relative to Tidegate's architecture.

3. **In-process security model.** All 16 security systems run within the same process as the agent. A single memory-safety vulnerability (unlikely in Rust, but not impossible via `unsafe`, FFI, or dependency bugs) could compromise all enforcement simultaneously. Tidegate's out-of-process, multi-container model requires independent compromise of each enforcement seam.

4. **Credentials co-located with agent.** API keys and tokens reside in kernel memory alongside agent execution. Tidegate's container-mount isolation ensures credentials never enter the agent's address space.

5. **No structural network enforcement.** OpenFang relies on software-level capability checks for network access. Tidegate uses Docker network topology and egress proxy routing — structural guarantees that survive process-level compromise.

6. **Taint tracking is the right idea, wrong layer.** OpenFang's `TaintedValue` with label propagation is architecturally sound. But in-process enforcement means the taint system can be bypassed by any code path that creates raw `String` values, and the LLM itself launders taint by producing new text from tainted context.

7. **Complementary composition is theoretically possible** but practically difficult given OpenFang's assumption of direct network access for channels, MCP, OFP, and API endpoints.

---

## 8. Methodology Notes

- Evaluation based on publicly available documentation only (openfang.sh website, /docs/architecture, /docs/security, /docs/mcp-a2a).
- Source code not reviewed. Claims about implementation quality are taken at face value where documentation is specific (e.g., `env_clear()`, `Zeroizing<String>`, constant-time HMAC).
- OpenFang is under active development; gaps identified here may be addressed in future versions.
- This evaluation applies Tidegate's specific threat model (data-flow enforcement against exfiltration). OpenFang may perform well against other threat models not assessed here.                                  
