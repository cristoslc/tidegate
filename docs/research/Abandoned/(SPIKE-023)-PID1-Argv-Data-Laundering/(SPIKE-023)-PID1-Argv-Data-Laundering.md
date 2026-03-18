---
artifact: SPIKE-023
title: "PID 1 Argv Data Laundering via Allowlisted Domains"
track: container
status: Abandoned
author: cristos
created: 2026-03-17
last-updated: 2026-03-17
question: "Can the agent framework (PID 1) launder sensitive data through argument passing to clean child processes that connect to allowlisted domains, bypassing all three enforcement layers?"
parent-vision: VISION-002
gate: Pre-MVP
risks-addressed:
  - "Residual risk #10 (agent framework process outside taint scope)"
depends-on:
  - SPIKE-009
linked-artifacts:
  - ADR-002
  - SPEC-005
  - SPIKE-008
  - SPIKE-009
  - SPIKE-014
  - SPIKE-016
evidence-pool: "agent-attack-patterns"
---

# PID 1 Argv Data Laundering via Allowlisted Domains

## Summary

**Abandoned.** The privilege separation model from SPIKE-014 (Tideclaw IPC Orchestrator Scanning) already resolves this structurally. The orchestrator has network access but no workspace access (can't become tainted). Subagents have workspace access but no network access (can't exfiltrate). The interceptor scans everything crossing the boundary. No single process needs both file access and external network access, so PID 1 argv laundering cannot occur. This spike was created before recognizing that SPIKE-014's findings apply directly.

## Question

Can the agent framework process (PID 1) exfiltrate sensitive data by reading workspace files — which it must do to function — and then passing that data via argv, env, stdin, or temp files to a clean child process (pip, npm, curl, etc.) that connects to an allowlisted domain? If so, do all three enforcement layers miss this, and what architectural options exist to close the gap without breaking agent functionality?

## Background

### The seam

Tidegate's taint-and-verify model (ADR-002) makes two correct design decisions that create an untracked exfiltration path when combined:

1. **PID 1 is exempt from taint enforcement.** The agent framework process reads files, makes MCP/LLM calls, and spawns child processes. Tainting PID 1 would block all agent functionality. L1 taint enforcement targets child processes that call `openat` on sensitive files, not the framework itself. (Residual risk #10 in scorecard.md)

2. **Skill domains must be allowlisted.** Skills need HTTP access to registries (pypi.org, registry.npmjs.org, api.github.com) and their own APIs. L3 agent-proxy allowlists these domains and does MITM+scan on the traffic. (SPEC-005)

The seam: PID 1 reads a sensitive file → PID 1 encodes the data into a command → PID 1 spawns a child process with the data as argv/env → the child process never calls `openat` on any sensitive file → the child's `connect()` is not blocked by L1 (clean PID) → the child connects to an allowlisted domain → L3 allows it → L2 never sees it (not an MCP call).

### Discovery

Identified during cross-reference of the `agent-attack-patterns` trove (14 sources, March 2026) against Tidegate's enforcement model. The trove's CVE catalog revealed that every documented exfiltration CVE assumes unrestricted outbound network access. Tidegate's egress enforcement closes most of those paths, but the pypi model exposed this specific gap: data flows from PID 1 through argument passing to a clean child, entirely within the enforcement boundary, using legitimate infrastructure.

### Why existing accepted risks don't fully cover this

Residual risk #10 says: "Taint enforcement primarily targets child processes spawned to run scripts." This is framed as PID 1 making its own network connections (which go through L2/L3). It doesn't address PID 1 **laundering data through a clean child process** — a child that connects to an allowlisted domain without ever having touched a sensitive file itself.

SPIKE-009's taint propagation model identifies three types: syntactic, protocol, and semantic. This is a fourth: **argument propagation** — data crosses a process boundary via argv/env/stdin/tmpfile, and the taint doesn't follow.

## Go / No-Go Criteria

**Go** (architectural fix exists): At least one mitigation achieves >90% coverage of the argv-laundering path without breaking legitimate agent operations (package installation, API calls, file management).

**No-Go** (raise the bar only): No mitigation can distinguish PID 1 passing sensitive data as argv from PID 1 passing legitimate commands. Update residual risk #10 and scorecard to explicitly document the gap, quantify the exfiltration bandwidth, and add it to the SPIKE-016 future-work queue.

## Pivot Recommendation

If no architectural fix is viable, the recommended pivot is:
1. Update the threat model to explicitly document this as a distinct residual risk (not a variant of #10)
2. Quantify the exfiltration bandwidth (bytes/second achievable via package name encoding, URL path encoding, etc.)
3. Evaluate whether L3 MITM scanning of requests to allowlisted domains can catch common encoding patterns (base64 in URL paths, unusual package names)
4. Consider whether allowlisted domain subsets (read-only allowlists that permit GET but not POST/PUT) reduce the attack surface

## Investigation threads

### Thread 1: Data flow from PID 1 to child processes

Map all channels through which PID 1 passes data to spawned children:

| Channel | Mechanism | Bandwidth | Taint-trackable? |
|---------|-----------|-----------|-------------------|
| **argv** | `execve(path, argv, envp)` | ~128KB (ARG_MAX) | eBPF can observe execve args |
| **envp** | Environment variables passed at fork | Unlimited (practical ~1MB) | eBPF can observe execve envp |
| **stdin** | Pipe from parent to child | Unlimited | eBPF can observe pipe write/read |
| **temp files** | Parent writes file, child reads | Unlimited | eBPF can observe both openat calls |
| **shared memory** | mmap/shm | Unlimited | Not observable via syscall tracing |
| **Unix socket** | socketpair passed across fork | Unlimited | eBPF can observe send/recv |

**Key question**: Can eBPF observe `execve` arguments AND correlate them with PID 1's prior file reads to detect data laundering? This would be a cross-PID taint check: "PID 1 read bank.csv; PID 1 then called execve with argv containing data similar to bank.csv contents."

### Thread 2: Taint propagation across fork/exec

Explore whether taint can propagate from parent to child without breaking agent functionality:

- **Option A: Inherit taint on fork.** PID 1 is always tainted (it reads files). Every child inherits taint. Every child's `connect()` is blocked. **Breaks everything.**

- **Option B: Conditional taint inheritance.** PID 1 taint resets after each tool call completes. Children spawned during a "tainted window" (between file read and tool call completion) inherit taint. **Complex, fragile, race-prone.**

- **Option C: Argv content scanning at execve.** When PID 1 calls `execve`, the seccomp-notify handler (or eBPF hook) inspects argv/envp for patterns matching recently-read sensitive data. If the scanner finds a match, the child PID is pre-tainted before it ever calls `openat`. **Most promising — extends L1 without changing the taint model.**

- **Option D: Scan at connect, not at execve.** When ANY child process (regardless of taint) calls `connect()` to an allowlisted domain, the seccomp-notify handler inspects the outbound request for sensitive data patterns. **Essentially extends L3 scanning to cover connect() from all children, not just tainted ones.** But this requires request-content visibility at the syscall level, which `connect()` doesn't provide (it only sees the destination address).

- **Option E: L3 deep scanning on allowlisted domains.** Extend the agent-proxy's MITM scanning to apply the same L1/L2 pattern set to ALL requests to allowlisted domains, not just skill HTTP. If `pip install base64-of-credit-card` hits pypi.org, the proxy sees the full HTTP request and can scan the URL path, query params, and body. **Doesn't require any L1 changes.**

### Thread 3: L3 MITM scanning extension

Evaluate extending agent-proxy scanning for allowlisted domains:

- Current: MITM + scan + credential injection for skill-allowed domains
- Extension: Apply L2-equivalent pattern scanning (Luhn, credential prefixes, SSN structure) to HTTP request URLs, headers, and bodies on all allowlisted domains
- Catches: Raw sensitive data in URL paths, query params, POST bodies
- Misses: Encoded data (base64 package names, URL-encoded paths), data split across multiple requests
- Complexity: Low — proxy already does MITM on these domains

### Thread 4: Allowlisted domain access modes

Evaluate whether allowlists can be decomposed by HTTP method:

| Domain | Needed methods | Exfil risk from method |
|--------|---------------|----------------------|
| pypi.org | GET (install) | Medium (data in URL path) |
| pypi.org | POST (publish) | **High** (arbitrary data in body) |
| registry.npmjs.org | GET (install) | Medium (data in URL path) |
| registry.npmjs.org | PUT (publish) | **High** (arbitrary data in body) |
| api.github.com | GET, POST | POST carries data (issue bodies, comments) |

Read-only allowlists (GET only) for package registries would prevent the highest-bandwidth exfil path (publishing a package with embedded data) while still allowing package installation. The URL-path encoding channel remains but has lower bandwidth.

### Thread 5: Quantify exfiltration bandwidth

For each channel, estimate maximum bytes/second achievable:

- **pypi.org GET (package name encoding)**: ~200 bytes per request (URL path limit), limited by HTTP overhead → ~50KB/s
- **pypi.org POST (package upload)**: Arbitrary → MB/s
- **URL query params to any allowlisted domain**: ~2KB per request → ~100KB/s
- **POST body to GitHub API**: ~65KB per request (issue body limit) → ~100KB/s

Compare to existing accepted channels:
- **LLM API covert channel**: ~1KB/s (estimated, token-by-token encoding)
- **Semantic rephrasing**: Low bandwidth (limited by LLM context processing)

If the argv laundering bandwidth significantly exceeds existing accepted channels, it changes the risk calculus.

## Findings

<!-- Populated during Active phase -->

## Related

- [ADR-002](../../adr/Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) — Taint-and-verify model that this spike challenges
- [SPIKE-009](../Complete/(SPIKE-009)-Data-Flow-Taint-Model/(SPIKE-009)-Data-Flow-Taint-Model.md) — Data flow model missing argument propagation type
- [SPIKE-008](../Complete/(SPIKE-008)-L1-Interpreter-Coverage-Gap/(SPIKE-008)-L1-Interpreter-Coverage-Gap.md) — L1 mechanism validation
- [SPEC-005](../../spec/Approved/(SPEC-005)-gvproxy-Egress-Allowlist/(SPEC-005)-gvproxy-Egress-Allowlist.md) — Egress allowlist design
- [scorecard.md](../../threat-model/scorecard.md) — Residual risk #10

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-03-17 | — | Identified from trove cross-reference; PID 1 argv laundering via allowlisted domains |
| Abandoned | 2026-03-17 | — | Already resolved by SPIKE-014 privilege separation model (orchestrator/subagent split) |
