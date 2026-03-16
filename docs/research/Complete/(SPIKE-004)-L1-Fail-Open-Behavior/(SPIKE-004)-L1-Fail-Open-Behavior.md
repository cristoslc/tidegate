---
artifact: SPIKE-004
title: "L1 Fail-Open Behavior"
status: Complete
author: cristos
created: 2026-02-23
last-updated: 2026-03-12
question: "What happens when tg-scanner crashes — does L1 fail open, and how do we mitigate?"
parent-vision: VISION-002
gate: Pre-MVP
risks-addressed: []
depends-on: []
linked-artifacts:
  - ADR-001
  - ADR-002
---
# L1 Fail-Open Behavior

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Identified by adversarial threat model review; reframed for journal-based taint architecture (ADR-002) |
| Active | 2026-03-12 | 642e0a7 | Research initiated: seccomp-notify fd lifecycle, fail-closed design patterns, ring buffer overflow |
| Complete | 2026-03-12 | cdd85b1 | GO: fail-closed achievable via watchdog sidecar + fd-dup pattern; fallback filter approach impossible |

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

## Findings

The seccomp-notify mechanism is inherently fail-open: when the listener fd closes, the kernel returns ENOSYS to all pending and future intercepted syscalls. The originally proposed mitigation -- a layered seccomp-bpf fallback filter -- cannot work due to Linux's filter precedence rules. However, fail-closed L1 is achievable through a watchdog architecture that detects supervisor death and kills the agent container's cgroup before any connect() can complete with ENOSYS.

**Verdict: GO -- fail-closed is achievable, but requires a watchdog sidecar, not a seccomp filter trick.**

The naive "stacked fallback filter" approach from the threat model is impossible. The correct architecture uses an external watchdog process that monitors the seccomp-notify fd (or the tg-scanner PID) and kills the agent container on supervisor death. Combined with OOM hardening, process supervision, and ring buffer overflow detection, L1 can be made fail-closed with high confidence.

### Sub-question dispositions

| Sub-question | Answer |
|---|---|
| 1. seccomp-bpf fallback filter | **No.** Cannot stack KILL_PROCESS and USER_NOTIF on the same syscall. KILL_PROCESS has strictly higher precedence and always wins -- the notification is never delivered. The fallback filter approach is architecturally impossible. |
| 2. Notification fd lifecycle | When tg-scanner dies, all its fds close. The kernel detects no listener is attached and returns ENOSYS to (a) all currently-blocked threads waiting for a response, and (b) all future connect() calls that trigger the filter. No grace period. Immediate fail-open. |
| 3. Supervisor restart | **Cannot re-attach.** The notification fd is bound to the specific seccomp filter installation. There is no kernel API to obtain a new fd for an existing filter. The fd can be dup'd or passed via SCM_RIGHTS before the supervisor dies, but once all references are closed, the filter degrades to ENOSYS permanently. Agent container must restart. |
| 4. Crash resistance | Primary risks: OOM kill (tg-scanner accumulates taint table state), malformed eBPF ring buffer data causing panic, and deliberate resource exhaustion by the agent. Hardening: oom_score_adj=-1000, memory limits via cgroup, input validation on ring buffer events, Go/Rust with no unsafe memory operations. |
| 5. Kill vs deny | **Kill the container.** ENOSYS on connect() is ambiguous -- applications may retry or fall through. Killing the agent container's cgroup is unambiguous, auditable, and matches Firecracker/gVisor patterns. The session is compromised if the supervisor is dead. |
| 6. Scanner daemon crash recovery | Taint table is lost on crash. Ring buffer retains unread events (not a replay log -- consumed events are gone). On restart, must conservatively taint all active PIDs (fail-closed) until a full re-scan of the workspace can rebuild the taint table. |
| 7. eBPF ring buffer overflow | bpf_ringbuf_reserve() returns NULL on full buffer; the eBPF program silently drops the event. No callback mechanism for lost samples (unlike perf buffer). Missed events = missed taint = fail-open for those PIDs. Mitigation: large buffer (8-16 MB), overflow counter in eBPF map, scanner daemon checks counter and triggers conservative taint-all on mismatch. |

### Detailed analysis

#### 1. The seccomp filter stacking problem

The threat model proposed installing a base BPF filter that returns `SECCOMP_RET_KILL_PROCESS` for `connect()` as a fallback, with the expectation that `SECCOMP_RET_USER_NOTIF` from the notify filter would take precedence during normal operation.

This is backwards. The Linux kernel evaluates all stacked seccomp filters and applies the action with the **highest precedence**. The precedence order (highest to lowest) is:

1. `SECCOMP_RET_KILL_PROCESS`
2. `SECCOMP_RET_KILL_THREAD`
3. `SECCOMP_RET_TRAP`
4. `SECCOMP_RET_ERRNO`
5. `SECCOMP_RET_USER_NOTIF`
6. `SECCOMP_RET_TRACE`
7. `SECCOMP_RET_LOG`
8. `SECCOMP_RET_ALLOW`

If one filter returns `SECCOMP_RET_KILL_PROCESS` for `connect()` and another returns `SECCOMP_RET_USER_NOTIF`, the kernel always applies KILL_PROCESS. The documentation is explicit: "the supervisor process will not be notified if another filter returns an action value with a precedence greater than `SECCOMP_RET_USER_NOTIF`."

There is no mechanism to make a filter conditional on the notification fd being open. The BPF program runs in kernel space with no visibility into the userspace supervisor's liveness. Seccomp filters can only decrease privileges (make decisions more restrictive), never increase them.

The only stacking pattern that works is: the notify filter handles `connect()` via USER_NOTIF, and a separate filter handles other syscalls via ALLOW/ERRNO/KILL. You cannot have two filters producing different actions for the same syscall and expect the less-restrictive one to win.

**Conclusion:** The fallback filter approach is fundamentally impossible within the Linux seccomp architecture.

#### 2. Notification fd lifecycle and the ENOSYS window

When tg-scanner's connect enforcer process dies:

1. The kernel closes all file descriptors owned by the process, including the seccomp notification fd.
2. Any threads currently blocked in `connect()` (waiting for the supervisor's response via `SECCOMP_IOCTL_NOTIF_SEND`) are woken up and their syscall returns ENOSYS.
3. All future `connect()` calls that trigger the `SECCOMP_RET_USER_NOTIF` filter action also return ENOSYS immediately -- "if there is no attached supervisor (either because the filter was not installed with the `SECCOMP_FILTER_FLAG_NEW_LISTENER` flag or because the file descriptor was closed), the filter returns ENOSYS."

There is no grace period. The transition from "supervised" to "unsupervised" is instantaneous upon fd close.

The fd can be duplicated (`dup()`) and transferred between processes via Unix domain sockets (`SCM_RIGHTS`) or `pidfd_getfd()`. The OCI runtime spec supports this via `listenerPath` -- runc sends the seccomp fd to an external listener over a Unix socket. However, once **all** references to the fd are closed (all dup'd copies across all processes), the filter degrades to ENOSYS permanently for the lifetime of the target process's filter.

**Critical implication:** The ENOSYS fallback is not "fail-open" in the traditional sense -- `connect()` does not succeed. It returns an error. But ENOSYS is semantically wrong (it means "syscall not implemented") and applications may handle it unpredictably. Some may retry, some may fall through to alternative code paths. For security enforcement, ENOSYS is not a reliable deny -- it is ambiguous.

#### 3. Supervisor restart: no re-attachment

The seccomp notification fd is created at filter installation time via `seccomp(SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_NEW_LISTENER, ...)`. The kernel enforces that at most one filter per thread can use `SECCOMP_FILTER_FLAG_NEW_LISTENER` (returns EBUSY on second attempt).

There is no kernel API to:
- Obtain a new notification fd for an already-installed filter
- Re-install a USER_NOTIF filter on a thread that already has one
- Transfer supervision to a new process after the fd is lost

The fd itself can be held by multiple processes (via dup/SCM_RIGHTS), providing redundancy while at least one holder survives. But if all holders die, supervision is irrecoverable. The agent container must be restarted to re-establish seccomp-notify enforcement.

This is the fundamental reason a watchdog that prevents total fd loss is architecturally necessary -- once the fd is gone, there is no recovery short of container restart.

#### 4. Crash vectors and hardening

**OOM kill** is the most likely crash vector. tg-scanner maintains an in-memory taint table that grows with the number of active PIDs and observed files. An attacker who spawns many processes and opens many files can inflate the taint table's memory footprint. If the tg-scanner container hits its cgroup memory limit, the OOM killer terminates it.

Mitigations:
- Set `oom_score_adj=-1000` for the tg-scanner process (effectively OOM-immune within its cgroup).
- Set a generous but bounded memory limit on the tg-scanner container (separate from the agent container's limit).
- Bound taint table size: cap entries per PID, evict oldest entries, or use a fixed-size hash table with collision chaining.
- Monitor memory pressure via cgroup memory.pressure and trigger controlled shutdown before OOM.

**Ring buffer data corruption** could panic the scanner daemon if it reads malformed events. The eBPF program writes structured events into the ring buffer; the scanner daemon reads them. Since the eBPF program runs in kernel space (verified by the BPF verifier), the ring buffer data format is trusted. Malformed data would indicate a kernel bug, not an attacker action. Defensive parsing is still warranted (validate struct sizes, check path lengths), but this is a low-probability crash vector.

**Resource exhaustion** by the agent: rapid file open/close cycles to overwhelm the scanner daemon, or spawning thousands of short-lived processes to inflate taint table churn. Mitigations: rate limiting in the eBPF program (sample high-frequency openers), bounded work queues in the scanner daemon, process count limits via cgroup pids.max.

**Go/Rust runtime panics**: Use a language with memory safety guarantees. Avoid unsafe operations. Structured error handling with recovery at the top-level event loop.

#### 5. Kill vs. deny: kill the container

When the supervisor dies, the choice is between:

| Option | Behavior | Risk |
|---|---|---|
| ENOSYS (current default) | connect() returns "not implemented" | Applications may retry, fall through, or interpret as network-down. Ambiguous. Fail-open for applications that have alternative exfiltration paths. |
| Deny all connect (hypothetical) | Would require the kernel to return EPERM instead of ENOSYS | Not configurable. The kernel hardcodes ENOSYS for detached USER_NOTIF. |
| Kill the container | External watchdog sends SIGKILL or writes to cgroup.kill | Unambiguous. Session terminated. Auditable. Matches Firecracker/gVisor patterns. |

**Kill is the correct answer.** The precedents are clear:

- **Firecracker**: When the VMM panics, it emits a syscall outside its seccomp allowlist, causing SECCOMP_RET_KILL_PROCESS. The jailer's seccomp filter ensures a crashed VMM cannot continue running. Fail-closed by design.
- **gVisor**: The Sentry process has a minimal seccomp allowlist (53-68 syscalls). Any attempt to call outside the allowlist "is immediately blocked and the sandbox is killed by the Host OS." If the Sentry crashes, the container is dead.

Both systems treat supervisor crash as a terminal event for the workload. Tidegate should do the same. A dead tg-scanner means the security invariant is broken -- continuing the agent session is indefensible.

#### 6. Scanner daemon crash recovery

If the scanner daemon (ring buffer reader + file scanner + taint table maintainer) crashes independently of the connect enforcer:

- The connect enforcer is still alive and processing connect() notifications.
- But the taint table is stale -- new file accesses are not being processed.
- The eBPF program continues logging events to the ring buffer (it runs in-kernel, independent of userspace).
- Unprocessed events accumulate in the ring buffer.

On restart, the scanner daemon faces a cold-start problem:
- Events consumed before the crash are gone (ring buffer is FIFO, consumed events are not retained).
- Events that arrived during the crash window are in the ring buffer (if it hasn't overflowed).
- The taint table is empty.

**Recovery strategy: conservative taint-all until caught up.**

1. On restart, set a `recovery_mode = true` flag.
2. During recovery mode, the connect enforcer treats ALL connect() from the agent container as tainted (deny by default).
3. The scanner daemon reads all pending ring buffer events and rebuilds the taint table.
4. Additionally, scan all files currently open by active PIDs (via `/proc/[pid]/fd`).
5. Once the ring buffer is drained and active file descriptors are scanned, clear `recovery_mode`.

This is fail-closed recovery: the agent is blocked from network access during the recovery window, but the window is bounded by scanner processing time (seconds, not minutes).

**Shared state for recovery:** The taint table should be stored in a memory-mapped file or shared memory segment (not just in-process memory). This allows the connect enforcer (a separate thread/process within tg-scanner) to read taint state independently, and allows the scanner daemon to persist state across restarts. A memory-mapped taint table survives scanner daemon restarts as long as the connect enforcer (which holds the mmap) stays alive.

#### 7. eBPF ring buffer overflow

The BPF ring buffer uses a reserve/commit model:
- `bpf_ringbuf_reserve()` attempts to reserve space. Returns NULL if the buffer is full.
- On NULL return, the eBPF program must skip the event -- there is no retry or blocking mechanism in BPF.
- Unlike the perf buffer, the BPF ring buffer does not provide a lost-sample callback to userspace.

**Overflow = silent event loss = missed taint.** A PID that opened a sensitive file during a buffer overflow window will not be tainted. If that PID later calls connect(), the enforcer will allow it. This is a fail-open gap.

**Sizing:** The ring buffer is a single shared buffer across all CPUs (unlike per-CPU perf buffers). It must be a power of 2 and a multiple of the page size. For tg-scanner's workload:
- Each event is ~300 bytes (PID + path + timestamp + sequence number).
- At 1000 file opens/second (heavy workload), 300 KB/sec of ring buffer throughput.
- A 16 MB buffer provides ~53 seconds of headroom before overflow at sustained 1000 ops/sec.
- Most workloads are far lower (10-100 opens/sec), giving minutes of headroom.

**Overflow detection and mitigation:**
1. Maintain an atomic counter in a BPF map: the eBPF program increments on every `openat` event, and increments a separate counter on every reserve failure.
2. The scanner daemon reads both counters periodically. If the failure counter is non-zero, events were lost.
3. On detected overflow: enter conservative mode (same as crash recovery -- taint all PIDs, re-scan open file descriptors).
4. Alert/audit the overflow event for operational visibility.
5. Consider auto-scaling the ring buffer size if overflows are frequent (requires re-loading the eBPF program with a larger buffer).

### The watchdog architecture

Since the fallback filter approach is impossible, fail-closed requires an external mechanism to detect supervisor death and terminate the agent container. The design:

```
                  tg-scanner container
                 ┌──────────────────────┐
                 │  connect enforcer    │──── seccomp notify fd
                 │  scanner daemon      │──── eBPF ring buffer reader
                 │  taint table (mmap)  │
                 └──────────────────────┘
                           │
                     pidfd / pipe
                           │
                 ┌──────────────────────┐
                 │  tg-watchdog         │
                 │  (separate process   │
                 │   or sidecar)        │
                 └──────────────────────┘
                           │
                    cgroup.kill / SIGKILL
                           │
                 ┌──────────────────────┐
                 │  agent container     │
                 └──────────────────────┘
```

**How it works:**

1. **tg-watchdog** holds a duplicate of the seccomp notification fd (obtained via SCM_RIGHTS from runc's `listenerPath` socket at container startup).
2. tg-watchdog also monitors tg-scanner's liveness via:
   - `pidfd_open()` + `poll()` on tg-scanner's PID (POLLIN on process death, POLLHUP on reap).
   - A heartbeat pipe: tg-scanner writes a byte every N seconds; if read times out, tg-scanner is assumed dead or hung.
3. On detecting tg-scanner death:
   - tg-watchdog writes `1` to the agent container's `cgroup.kill` file (cgroup v2), sending SIGKILL to all processes in the agent cgroup. Or: tg-watchdog sends SIGKILL to the agent container's init PID (PID 1 in the container's PID namespace).
   - tg-watchdog logs the kill event to the audit log.
4. tg-watchdog is hardened against crash:
   - Minimal code: single event loop, no complex state.
   - `oom_score_adj=-1000` (OOM-immune).
   - Static binary, no dynamic dependencies.
   - Its own seccomp filter (tight allowlist: poll, read, write, kill, exit).

**Why the watchdog holding a dup'd fd matters:** As long as tg-watchdog holds a copy of the seccomp notification fd, the fd is not fully closed even if tg-scanner dies. This means the kernel does NOT return ENOSYS to blocked connect() calls. The threads remain blocked (waiting for a response that tg-watchdog won't provide), buying time for the watchdog to kill the container. Without the dup'd fd, the ENOSYS race begins immediately upon tg-scanner death.

**Race analysis:** The critical race is between (a) a connect() getting ENOSYS and completing, and (b) the watchdog killing the container. With the dup'd fd, there is no ENOSYS -- threads block indefinitely until either the watchdog kills them or a fatal signal arrives. This eliminates the race entirely. The fd dup is the key insight that makes the watchdog approach airtight.

### Recommendations

1. **Implement the watchdog sidecar (tg-watchdog).** Separate binary, separate process, holds a dup of the seccomp notification fd. Monitors tg-scanner via pidfd + heartbeat pipe. Kills the agent container on supervisor death. This is the primary fail-closed mechanism.

2. **Use the fd-dup pattern to eliminate the ENOSYS race.** tg-watchdog receives a copy of the notification fd at container startup. tg-scanner processes notifications. If tg-scanner dies, the fd remains open (via tg-watchdog's copy), so threads stay blocked rather than getting ENOSYS. The watchdog kills the container before releasing its copy.

3. **Implement conservative taint-all on scanner daemon restart.** If the scanner daemon crashes but the connect enforcer survives, enter recovery mode: deny all connect() until the taint table is rebuilt. Use mmap'd shared memory for the taint table so it persists across scanner daemon restarts.

4. **Detect and respond to ring buffer overflow.** Maintain counters in BPF maps for total events and dropped events. Scanner daemon monitors the drop counter. On any drops, enter conservative mode and audit the event.

5. **Harden tg-scanner against OOM.** Set `oom_score_adj=-1000`. Bound taint table size. Set memory limits on the tg-scanner container generously but below the host's pressure threshold.

6. **Size the ring buffer at 16 MB.** Provides 50+ seconds of headroom at heavy workload (1000 opens/sec). Most workloads will never approach overflow.

7. **Use SECCOMP_FILTER_FLAG_WAIT_KILLABLE_RECV.** This flag (Linux 5.19+) ensures that once the supervisor has received a notification, the target thread ignores non-fatal signals until the response is sent. Prevents signal-based interruption of the enforcement window.

8. **Document agent container restart as the recovery path.** If both tg-scanner and tg-watchdog die (e.g., the host is under extreme pressure), the seccomp-notify fd is fully closed and enforcement degrades to ENOSYS. Recovery requires container restart. This is an acceptable degradation mode because: (a) losing both supervisor processes simultaneously indicates a severe system failure, and (b) the agent container should have its own liveness probe that triggers restart.

### Prior art

| System | Fail-closed mechanism | Supervisor crash behavior |
|---|---|---|
| **Firecracker** | Jailer installs tight seccomp profile before exec'ing VMM. VMM panic emits disallowed syscall, triggering SECCOMP_RET_KILL_PROCESS. | VMM is killed by kernel seccomp. Microvm is dead. |
| **gVisor** | Sentry has minimal seccomp allowlist (53-68 syscalls). Host OS kills sandbox on any out-of-allowlist call. | Sandbox is killed. Container is dead. |
| **Tidegate (proposed)** | tg-watchdog holds dup'd seccomp-notify fd. Monitors tg-scanner liveness. Kills agent container cgroup on supervisor death. | Agent container is killed. Session is terminated. Audit event recorded. |

The key difference: Firecracker and gVisor achieve fail-closed through seccomp on the supervisor itself (the supervisor can't outlive its allowlist violation). Tidegate can't do this because tg-scanner needs to be a general-purpose daemon (reading files, scanning content, maintaining state) -- its syscall surface is too broad for a tight allowlist to be practical. Instead, Tidegate achieves fail-closed through an external watchdog that is simple enough to have a tight allowlist.

## Why it matters

"Three hard boundaries" is the core marketing and security claim. If L1 fails open on a component crash -- and an attacker can trigger that crash -- it's not a hard boundary. This needs to be resolved before L1 can honestly be called fail-closed.

## Related

- [ADR-002](../../../adr/Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) -- the current L1 architecture
- [ADR-001 (superseded)](../../../adr/Superseded/(ADR-001)-Seccomp-Notify-L1-Interception.md) -- original fail-open analysis still applies to seccomp-notify mechanism

## Context at time of writing

L1 is designed (ADR-002) but not implemented. ADR-001 (execve interception) is superseded by ADR-002 (journal-based taint tracking). Residual risk #8 in the scorecard acknowledges fail-open behavior and proposes a seccomp-bpf fallback, but this mitigation is not designed or implemented.

## References

- [seccomp_unotify(2) - Linux manual page](https://man7.org/linux/man-pages/man2/seccomp_unotify.2.html) -- notification fd lifecycle, ENOSYS behavior, one-filter-per-thread limitation
- [seccomp(2) - Linux manual page](https://man7.org/linux/man-pages/man2/seccomp.2.html) -- filter precedence ordering, stacked filter behavior, SECCOMP_FILTER_FLAG_NEW_LISTENER
- [Seccomp BPF - Linux Kernel documentation](https://www.kernel.org/doc/html/latest/userspace-api/seccomp_filter.html) -- kernel documentation on filter evaluation
- [BPF ring buffer - Linux Kernel documentation](https://docs.kernel.org/6.6/bpf/ringbuf.html) -- ring buffer overflow behavior
- [BPF ring buffer - Andrii Nakryiko](https://nakryiko.com/posts/bpf-ringbuf/) -- reserve/commit API, overflow handling, sizing guidance
- [Seccomp Notify - Christian Brauner](https://brauner.io/2020/07/23/seccomp-notify.html) -- seccomp notifier architecture, fd passing, LXD integration
- [Seccomp user-space notification and signals - LWN.net](https://lwn.net/Articles/851813/) -- WAIT_KILLABLE_RECV flag, signal handling during notifications
- [OCI runtime-spec config-linux.md](https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md) -- listenerPath for seccomp notify fd delivery
- [gVisor Security Basics](https://gvisor.dev/blog/2019/11/18/gvisor-security-basics-part-1/) -- Sentry seccomp allowlist, fail-closed sandbox design
- [Firecracker seccomp issue #1088](https://github.com/firecracker-microvm/firecracker/issues/1088) -- VMM panic causes seccomp violation (fail-closed pattern)
- [pidfd_open(2) - Linux manual page](https://man7.org/linux/man-pages/man2/pidfd_open.2.html) -- process death detection via pidfd + poll
- [linux/kernel/seccomp.c](https://github.com/torvalds/linux/blob/master/kernel/seccomp.c) -- kernel implementation of seccomp notification mechanism
