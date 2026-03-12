---
artifact: SPIKE-004
title: "L1 Fail-Open Behavior"
status: Active
author: cristos
created: 2026-02-23
last-updated: 2026-03-12
question: "What happens when tg-scanner crashes — does L1 fail open, and how do we mitigate?"
parent-vision: VISION-002
gate: Pre-MVP
risks-addressed: []
depends-on: []
---

# L1 Fail-Open Behavior

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Identified by adversarial threat model review; reframed for journal-based taint architecture (ADR-002) |
| Active | 2026-03-12 | 642e0a7 | Research initiated: seccomp-notify fd lifecycle, fail-closed design patterns, ring buffer overflow |

## Source

External review: `tidegate-threatmodel-review(1).md` — problem #5.

## Question

If tg-scanner crashes, pending seccomp-notify `connect()` syscalls get `ENOSYS` — fail-open. An attacker who crashes tg-scanner gets unrestricted network access from the agent container. The threat model describes a mitigation (seccomp-bpf fallback filter that kills the agent container) but the current design is fail-open. A "hard boundary" that fails open on component crash isn't a hard boundary.

Under ADR-002, tg-scanner has three components that can fail independently:
- **eBPF program** (in-kernel): crash-resistant — loaded into kernel, runs even if tg-scanner userspace dies. But if the userspace ring buffer reader stops, events accumulate and may be dropped.
- **Scanner daemon** (userspace): if it crashes, file-open events stop being processed. Taint table stops being updated. connect() enforcer has stale/incomplete taint data.
- **Connect enforcer** (userspace, seccomp-notify listener): if it crashes, `connect()` syscalls return `ENOSYS` — fail-open.

## Sub-questions

1. **seccomp-bpf fallback filter**: Can we install a base BPF filter that returns `SECCOMP_RET_KILL_PROCESS` for `connect` if the notification fd is closed? Does the kernel support layered seccomp filters (notify + bpf fallback)?
2. **Notification fd lifecycle**: What exactly happens when tg-scanner's connect enforcer dies? Does the fd close? Does the kernel have a grace period? What's the behavior for in-flight notifications?
3. **Supervisor restart**: If tg-scanner restarts, can it re-attach to the notification fd? Or does the agent container need to be restarted too?
4. **Crash-resistance**: What could crash tg-scanner? OOM? Malformed ring buffer data? Stale taint table entries? Can we harden against these?
5. **Kill vs deny**: Should the fallback kill the entire agent container (fail-closed, disruptive) or deny all `connect()` (fail-closed, less disruptive but wedges the agent)?
6. **Scanner daemon crash recovery**: If the scanner daemon crashes and restarts, it has lost taint table state. Should it re-scan all files referenced in the eBPF ring buffer? How much history does the ring buffer retain?
7. **eBPF ring buffer overflow**: If events accumulate faster than the scanner daemon processes them, events are dropped. This means some file accesses go unobserved — PIDs that should be tainted are not. How large should the ring buffer be? What's the behavior on overflow?

## Why it matters

"Three hard boundaries" is the core marketing and security claim. If L1 fails open on a component crash — and an attacker can trigger that crash — it's not a hard boundary. This needs to be resolved before L1 can honestly be called fail-closed.

## Related

- [ADR-002](../../../adr/Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) — the current L1 architecture
- [ADR-001 (superseded)](../../../adr/Superseded/(ADR-001)-Seccomp-Notify-L1-Interception.md) — original fail-open analysis still applies to seccomp-notify mechanism

## Context at time of writing

L1 is designed (ADR-002) but not implemented. ADR-001 (execve interception) is superseded by ADR-002 (journal-based taint tracking). Residual risk #8 in the scorecard acknowledges fail-open behavior and proposes a seccomp-bpf fallback, but this mitigation is not designed or implemented.
