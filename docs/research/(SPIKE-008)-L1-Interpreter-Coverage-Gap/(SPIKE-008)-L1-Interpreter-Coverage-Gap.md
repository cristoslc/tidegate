---
title: "SPIKE-008: L1 Interpreter Coverage Gap"
status: Complete
author: cristos
created: 2026-02-23
last_updated: 2026-02-23
question: "Does seccomp-notify on execve miss in-process interpreter execution, and what complements it?"
parent: VISION-001
---

# L1 Coverage Gap — In-Process Interpreter Execution

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Identified by adversarial threat model review |
| Active | 2026-02-23 | 138d920 | Execution model audit + Falco/eBPF research |
| Complete | 2026-02-23 | — | seccomp-notify validated as correct L1 mechanism; eBPF complements as L1+; findings absorbed into ADR-002 (taint-and-verify) |

## Source

External review: `tidegate-threatmodel-review(1).md` — central finding.

## Original claim

> Agent frameworks run skills as function calls inside persistent interpreters, not as new processes. `execve` never fires. Encode-before-exfil via interpreted code is an open residual risk, not a blocked attack.

## Key finding: the mechanism is right, the strategy needs revision

~~The current L1 design (ADR-001) intercepts `execve` and has tg-scanner statically analyze scripts to decide allow/deny. The original version of this spike recommended replacing seccomp-notify with eBPF/Tetragon. That was wrong.~~

**seccomp-notify is the correct L1 mechanism.** tg-scanner needs userspace capabilities that eBPF programs fundamentally cannot provide:

| tg-scanner needs | Why eBPF can't do it |
|---|---|
| Read workspace files (glob for CSVs, resolve references) | eBPF programs can't do arbitrary file I/O — no `open()`/`read()` from BPF context |
| Run Luhn/regex/mod-97/entropy checks | 512-byte stack limit, 1M instruction budget — insufficient for complex pattern matching |
| Return shaped denies with explanations | eBPF hooks return 0 (allow) or -EPERM (deny) — no rich error information |
| Parse commands, resolve file paths, orchestrate multi-step analysis | Verifier rejects anything it can't statically prove terminates — no general-purpose logic |
| Maintain stateful context across events | BPF maps exist but are limited to fixed-size key-value pairs — no complex data structures |

The linux kernel tradeoff spectrum makes this clear:
- **seccomp-bpf**: nanoseconds, limited to syscall number + raw args (no pointer dereference)
- **eBPF LSM**: nanoseconds, semantic hooks but verifier-constrained
- **seccomp-notify**: microseconds, **unlimited userspace logic** — this is what tg-scanner requires

### What IS the problem then?

The real issues are:

1. **Static analysis of Turing-complete scripts is fundamentally limited.** Obfuscation, second-stage downloads, ctypes/FFI, `memfd_create` + `fexecve` — all defeat static analysis. This is the halting problem. But this is a **strategy** problem, not a **mechanism** problem. seccomp-notify is the right mechanism; tg-scanner's analysis strategy needs to be practical rather than comprehensive.

2. **In-process operations don't trigger `execve`.** When Claude Code's Node.js process calls `fs.readFileSync()` or `fetch()`, no `execve` fires. seccomp-notify on `execve` is blind to these paths. But these operations ARE visible to L2 (gateway scans MCP tool call parameters) and L3 (agent-proxy scans HTTP traffic). The coverage gap is real but addressed by defense-in-depth, not by replacing L1.

3. **The gap between execve-visible and L2/L3-visible paths.** An agent-written Python script that reads a sensitive file and encodes it before sending it through an allowed MCP tool. `execve` fires for `python script.py` — tg-scanner can analyze the script. But static analysis may miss the encoding. L2 sees the encoded output but can't detect it. **This is the genuine residual risk** — and it's bounded by tg-scanner's heuristic analysis, not eliminated by it.

### Revised understanding: seccomp-notify + bounded heuristics + defense-in-depth

tg-scanner doesn't need to solve the halting problem. It needs to make the attack surface **small and expensive**:

1. **File content scanning** (strong): tg-scanner reads the workspace files that a script references. If `bank.csv` contains credit card numbers, tg-scanner knows this regardless of what the script does with them. The correlation "script accesses sensitive file + has encoding/network capabilities" is a strong signal.

2. **Pattern-based command analysis** (bounded): Block obvious encoding pipelines (`cat secret.csv | base64 | curl`). Won't catch all obfuscation — doesn't need to. Forces the attacker into increasingly exotic approaches that trigger other signals.

3. **Defense-in-depth covers the gaps**: L2 scans MCP tool call parameters for sensitive patterns in the encoded output. L3 does the same for HTTP. eBPF observability (see below) adds a fourth layer of visibility. No single layer needs to be perfect.

---

## eBPF as complement, not replacement

eBPF can't replace tg-scanner's userspace decision-making, but it provides valuable capabilities seccomp-notify on `execve` alone doesn't have:

### What eBPF adds

| Capability | How | Value to Tidegate |
|---|---|---|
| **File access telemetry** | TracingPolicy on `openat`/`read` scoped to `/workspace/` | Know which processes touch sensitive files, even without `execve` |
| **Network write correlation** | `FollowFD` + `sendto`/`connect` monitoring | Detect "process that read sensitive file now writing to network" |
| **In-process operation visibility** | Monitors I/O syscalls regardless of how the process was started | Catches Node.js `fs.readFileSync()` → `fetch()` paths invisible to seccomp-notify on `execve` |
| **Enforcement backstop** | Tetragon's `override` action on `sendto` or SIGKILL | Hard block on network writes from processes that accessed sensitive files |

### What eBPF cannot do (and why it doesn't replace seccomp-notify)

- **Can't read workspace files to determine sensitivity.** eBPF sees the `read()` syscall and buffer contents, but can't run pattern matching on those contents (Luhn, regex, entropy) within the verifier's constraints. Must ship buffer data to userspace for analysis.
- **Can't return shaped denies.** SIGKILL or -EPERM — no explanation to the agent about what went wrong. seccomp-notify + tg-scanner can return meaningful information that lets the agent adjust.
- **Can't do multi-step analysis.** "Read this file, check for globs, resolve them, read those files too, scan all of them, then decide" requires general-purpose logic that the BPF verifier won't allow.

### Architectural role

eBPF occupies a **complementary observability + enforcement** role within L1, not a replacement:

```
L1: seccomp-notify on execve (primary enforcement)
    tg-scanner: userspace decision-maker
    ├── reads /proc/<pid>/mem for command args
    ├── reads workspace files (shared volume)
    ├── runs scanner (Luhn, regex, entropy)
    ├── analyzes command for encoding/exfil patterns
    └── returns ALLOW or EPERM

L1+: eBPF observability (complementary, defense-in-depth)
    Tetragon TracingPolicies
    ├── monitors openat/read on /workspace/ paths
    ├── monitors connect/sendto from agent container
    ├── correlates: sensitive file access → network write
    └── enforcement: override sendto or SIGKILL

L2: MCP gateway (network-enforced, independent)
    Scans all MCP tool call parameter values
    Safety net for anything exfiltrated through MCP

L3: agent-proxy (network-enforced, independent)
    Scans skill HTTP traffic
    Domain allowlisting, credential injection
```

**L1 and L1+ are not redundant.** L1 (seccomp-notify) catches command-level attacks with rich analysis. L1+ (eBPF) catches I/O-level patterns that don't go through `execve`. Together they cover both process-spawning and in-process execution paths.

---

## Execution model audit

The review claimed `execve` never fires for most agent frameworks. This is partially wrong for our targets but correctly identifies operations where seccomp-notify is blind.

### Claude Code

Skills are **prompt expansions** (markdown injected into conversation), not executable code. All code execution goes through tools.

| Operation | `execve`? | L1 (seccomp-notify) | L1+ (eBPF) | L2/L3 |
|---|---|---|---|---|
| Bash tool | **Yes** | Full analysis | I/O monitoring | Scans output if sent via MCP |
| Agent writes script, runs via Bash | **Yes** | Script analysis + file scanning | I/O monitoring | Scans output |
| Grep/Glob tool | **Yes** (spawns `rg`) | Sees command | I/O monitoring | N/A (local) |
| Read/Write/Edit | No (in-process Node.js) | **Blind** | **Sees file I/O** | N/A (local) |
| MCP tool calls (HTTP) | No (in-process `fetch()`) | **Blind** | **Sees `connect`/`sendto`** | **L2 scans parameters** |
| WebFetch/WebSearch | No (in-process HTTP) | **Blind** | **Sees `connect`/`sendto`** | **L3 scans HTTP** |

**Key insight**: Every operation is visible to at least one layer. The in-process paths that seccomp-notify misses are covered by L2 (MCP gateway), L3 (agent-proxy), and L1+ (eBPF observability). No single layer covers everything; defense-in-depth provides full coverage.

### OpenClaw

Same pattern. `exec`/`process` tools spawn child processes (L1 visible); read/write/MCP are in-process (L1+/L2/L3 visible).

---

## Revised layer model: input × output coverage

Each layer is **primary** for different input-output pairs:

| Input channel | Output channel | Primary layer | Why |
|---|---|---|---|
| Workspace files | `execve` (encoding tool) | **L1** (seccomp-notify) | tg-scanner reads files, analyzes command, correlates |
| Workspace files | Network socket (in-process) | **L1+** (eBPF) | Correlates file read + network write |
| Workspace files | MCP tool call | **L2** (gateway) | Scans file content in tool parameters |
| MCP response | MCP tool call | **L2** (gateway) | Scans all parameter values (circular flow) |
| MCP response | HTTP request | **L3** (agent-proxy) | Scans request body |
| Conversation context | Any output | L2 or L3 | Semantic rephrasing is undetectable (residual risk) |

**L1 is load-bearing for encode-before-exfil**: an agent reads `bank.csv`, base64-encodes it in a script, and sends the encoded blob through an MCP tool. L2 sees high-entropy data but no credit card patterns. L1 (seccomp-notify) catches this because tg-scanner reads `bank.csv` directly and finds credit card numbers before the encoding command executes.

**L1+ (eBPF) is load-bearing for in-process I/O**: an agent's Node.js process reads a sensitive file via `fs.readFileSync()` and then `fetch()`es the data to an API. No `execve` fires. eBPF sees the `read()` on the sensitive file and the `connect()`/`sendto()` to the network.

---

## Falco/Tetragon technical details

### What eBPF can monitor

| Syscall | Parameters captured | Relevance |
|---|---|---|
| `openat` | file path, flags, fd | Track which files a process opens |
| `read` | **buffer data**, size, fd | See raw file content (before encoding) |
| `connect` | sockaddr, socktuple | See network destinations |
| `sendto`/`sendmsg` | **buffer data**, size, dest | See data being sent to network |
| `write` | **buffer data**, size, fd | See data written to sockets/files |

Buffer contents captured via `bpf_probe_read_user`, subject to configurable `snaplen`.

### What eBPF cannot see or do

- **In-memory computation.** `base64.b64encode(data)` produces no syscall. eBPF sees data entering the process (`read`) and leaving it (`sendto`) but not transformations in between. This is fine — L1+ correlates "read sensitive file" with "wrote to network," regardless of what happened in between.
- **Complex pattern matching.** eBPF programs have a 512-byte stack and instruction budget. Can't run Luhn, regex, or entropy detection. Buffer contents must be shipped to userspace for scanning — adding latency and complexity.
- **Shaped denies.** Can only return allow/deny at the kernel level. No explanation to the agent.
- **File I/O.** Can't glob workspace directories or read files on behalf of the decision logic.

### Cross-event correlation

Needed to connect "process read sensitive file" with "process wrote to network socket."

- **Falco**: Cannot correlate events (per-event rule engine). Insufficient alone.
- **Tetragon**: `FollowFD` tracks fd-to-path mapping. TracingPolicy can match "write to socket from process that opened /workspace/*.csv." In-kernel filtering keeps overhead low.
- **Custom eBPF with BPF maps**: Full per-process state tracking. Maximum flexibility, highest development cost.

**Tetragon is the best fit for L1+** — YAML-based TracingPolicies, in-kernel filtering, enforcement capability (SIGKILL/return override), and fd tracking. Avoids the development cost of raw eBPF while providing the correlation we need.

### Tool comparison

| Tool | Role | Correlation | Enforcement | Overhead |
|---|---|---|---|---|
| **seccomp-notify** (ADR-001) | L1 primary enforcement | Via tg-scanner userspace analysis | Synchronous block on `execve` | Negligible |
| **Tetragon** | L1+ complementary | FollowFD, in-kernel filtering | SIGKILL, return override | <1-3% (scoped) |
| **Falco** | Alerting only | None (per-event) | Detection only | 5-10% with I/O |
| **Custom eBPF** | Maximum flexibility | Full (BPF maps) | Via LSM hooks | Depends |

### Privileged container concern

Tetragon requires a privileged container (`CAP_SYS_ADMIN`, `pid: host`). This seems to conflict with Tidegate's `cap_drop: ALL` posture.

But Docker itself requires root on the host. Adding a privileged monitoring container doesn't meaningfully expand the trust boundary — the host already trusts Docker. The `cap_drop: ALL` posture applies to the *agent* container (untrusted workload), not to infrastructure containers.

Precedent: Kubernetes security stacks (Falco, Tetragon, Tracee) all run as privileged DaemonSets.

### Performance: scoped monitoring reduces overhead

Tetragon's in-kernel filtering drops non-matching events before the ring buffer, so overhead scales with the volume of *matching* events, not all events:

- `openat`/`read` scoped to `/workspace/` paths only
- `sendto`/`write` scoped to network sockets from the agent container only
- `connect` from the agent container only

Estimated overhead with scoped Tetragon monitoring: **1-3%** (comparable to seccomp-notify on `execve` alone).

---

## Emerging recommendation

**Keep seccomp-notify + tg-scanner as the primary L1 enforcement mechanism (ADR-001 stands). Add Tetragon-based eBPF observability as a complementary L1+ layer for defense-in-depth.**

### Why not "just eBPF"

eBPF can observe I/O but can't perform the userspace analysis tg-scanner needs. Replacing seccomp-notify with eBPF would mean shipping all buffer data to userspace for scanning anyway — at which point you've reinvented a slower, more complex version of what seccomp-notify already provides. seccomp-notify gives you the pause-analyze-decide loop natively.

### Why add eBPF at all

seccomp-notify on `execve` is blind to in-process operations (Node.js `fs.readFileSync()`, `fetch()`). eBPF sees all I/O syscalls regardless of how the process was started. The combination covers both execution paths.

### What this means for ADR-001

ADR-001 (seccomp-notify on `execve`) is **validated as the right L1 mechanism**. The static analysis concern is real but bounded — tg-scanner uses heuristic analysis (pattern matching, file content scanning, encoding detection), not comprehensive script prediction. Defense-in-depth (L2, L3, and future L1+) handles the gaps.

A future ADR-002 would add Tetragon-based eBPF as a complementary L1+ layer, not as a replacement for L1.

### tg-scanner strategy refinement

Given that static analysis is bounded, tg-scanner's strategy should prioritize:

1. **File content scanning** (highest value): Resolve file references in commands, read those files, scan for sensitive data. This doesn't depend on understanding what the script does — it determines what the script can *reach*.
2. **Known-dangerous command blocking** (fast path): `execve("base64", ...)`, `execve("curl", ...)`, `execve("openssl", ...)` with sensitive file arguments → immediate deny.
3. **Encoding/exfiltration pattern detection** (heuristic): Look for patterns like piped encoding + network tools. Won't catch everything. Doesn't need to.
4. **Accept bounded coverage**: Scripts with obfuscated encoding that defeats static analysis are a residual risk, mitigated by L2/L3 safety nets and future L1+ eBPF observability.

## Open questions

- **Tetragon TracingPolicy prototype**: Can we write a policy that detects "agent container process read /workspace/*.csv + wrote to external socket"? What's the false positive rate for legitimate workflows?
- **Enforcement granularity in Tetragon**: SIGKILL is blunt. Can `override` action on `sendto` block just the network write without killing the process?
- **Buffer scanning in userspace**: If Tetragon ships `read()` buffer data to a userspace daemon for scanning, what's the latency impact? Is this practical for the L1+ role, or should L1+ be detection-only with enforcement deferred to network layers?
- **Docker Compose integration**: Tetragon typically runs as a Kubernetes DaemonSet. What's the Docker Compose equivalent?
- **macOS development**: Tetragon requires Linux eBPF. Docker Desktop's Linux VM may work. What's the dev experience?
- **L1+ priority**: Is eBPF observability worth the deployment complexity for Tidegate's Docker Compose target, or should it be deferred to a Kubernetes deployment option?
- **LLM-computed encoding**: Can an LLM mentally base64-encode enough data to be a real exfiltration vector? Bounded by LLM capabilities, caught by L2 pattern matching on the output. Probably not practical for bulk data.
