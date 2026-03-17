---
artifact: SPIKE-005
title: "Workspace Volume TOCTOU"
status: Complete
author: cristos
created: 2026-02-23
last-updated: 2026-03-12
question: "Can a TOCTOU race between file open observation and scanner read allow taint evasion?"
parent-vision: VISION-002
gate: Pre-MVP
risks-addressed: []
depends-on: []
linked-artifacts:
  - ADR-001
  - ADR-002
  - VISION-002
---
# Workspace Volume TOCTOU

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Identified by adversarial threat model review; reframed for journal-based taint architecture (ADR-002) |
| Active | 2026-03-12 | 7506197 | Research in progress |
| Complete | 2026-03-12 | e3372ce | Confirmed high severity; overlayfs isolation recommended |

## Source

External review: `tidegate-threatmodel-review(1).md` — problem #3.

## Question

Under ADR-002's journal architecture, the TOCTOU surface changes from the ADR-001 framing:

**Old TOCTOU (ADR-001)**: tg-scanner reads a file during `execve` interception, scans it, approves the command — then the agent container modifies the file before the approved command actually reads it.

**New TOCTOU (ADR-002)**: eBPF logs a file-open event. Scanner daemon reads the file from the shared volume *some time later*. The file could change between the process's actual read and the scanner daemon's read. If the file was sensitive when the process read it but modified to be clean when the scanner reads it, the PID escapes taint.

The window is potentially larger under ADR-002 because the scanner daemon processes events asynchronously (vs. ADR-001 where scanning happened synchronously during the paused `execve`).

## Sub-questions

1. **Time window**: How large is the gap between eBPF logging the `openat` and the scanner daemon reading the file? Under heavy load, this could be seconds.
2. **Snapshot-on-read**: Could tg-scanner take a snapshot (copy or content hash) of the file when the scanner daemon processes the event? Storage and performance cost?
3. **Read-only workspace**: Could the workspace volume be mounted read-only in the agent container, with writes going through a controlled API? What breaks?
4. **Overlayfs/copy-on-write**: Could the agent see a CoW overlay, so tg-scanner always reads the stable lower layer?
5. **Multi-file atomicity**: If a process opens multiple files and one is modified between scans, the taint result is inconsistent.
6. **Reverse TOCTOU**: A file is clean when the process opens it and the scanner reads it, but later modified to contain sensitive data. The PID is not tainted. This is less concerning — the process read clean data.

## Findings

### Verdict: High severity, exploitable — mitigable via overlayfs or seccomp-notify on openat

The TOCTOU window between eBPF `openat` observation and scanner daemon file read is a confirmed, exploitable taint evasion vector. The async design in ADR-002 deliberately accepts this window for performance (eBPF observation is non-blocking; scanning is async), relying on seccomp-notify `connect()` as the synchronization barrier. But the barrier only ensures the scanner *has processed* the event — it does not ensure the scanner *saw the same file contents* the process saw. An attacker who can write to the workspace volume between the process's read and the scanner's read evades taint entirely.

The severity is high because:
- The attack requires only write access to the shared workspace volume, which the agent container has by design.
- The window is unbounded under load — seconds, not microseconds.
- No race-winning is needed if the attacker controls both the reading process and a writing process (or the same process reads then overwrites).
- Real-world precedent: CVE-2025-59497 (Microsoft Defender for Endpoint on Linux) is a TOCTOU in the same pattern — file checked by security daemon, modified before use. ESET antivirus products had analogous TOCTOU vulnerabilities on Windows.

Three mitigations are viable, in order of recommendation:
1. **Overlayfs isolation** (recommended): agent container sees a CoW overlay; tg-scanner reads the immutable lower layer.
2. **seccomp-notify on `openat` with fd capture**: intercept `openat` synchronously, open the file in tg-scanner's namespace, scan it, then inject the fd into the target process.
3. **fanotify `FAN_OPEN_PERM`**: synchronous permission hook blocks the open until the scanner decides.

### Sub-question dispositions

| Sub-question | Answer |
|---|---|
| 1. Time window | Unbounded under load. eBPF logs to ring buffer in nanoseconds; scanner daemon reads asynchronously. Under heavy I/O (Python imports, Node.js module loading), the scanner can lag seconds behind. The `connect()` barrier ensures the scanner catches up before network access, but it catches up by reading files that may have changed. |
| 2. Snapshot-on-read | Feasible but expensive. Scanner daemon could `cp` or hash files at processing time, but this only captures the file at scanner-read time, not at process-open time. The file may already have been modified. A true snapshot requires capturing content at open time, which requires synchronous interception (not async eBPF). |
| 3. Read-only workspace | Breaks most agent workflows. Agents write code, create files, run builds. A read-only workspace makes the agent non-functional. Writes through a controlled API are possible but require reimplementing basic filesystem operations, creating a large compatibility surface. Not viable as a primary mitigation. |
| 4. Overlayfs/CoW | **Best mitigation.** Agent sees an overlayfs mount with the workspace as lower layer. Agent writes go to the upper layer (CoW). tg-scanner reads the lower layer directly, seeing the original file contents. Modified files show up in the upper layer; tg-scanner scans both layers. The agent's view includes its modifications; the scanner's view preserves originals. See detailed analysis below. |
| 5. Multi-file atomicity | Real concern but secondary. If a process opens files A and B, and B is modified between scans, the taint decision for the PID is based on a mix of original-A and modified-B. Overlayfs mitigates this: the scanner reads both files from the immutable lower layer. Without overlayfs, multi-file atomicity requires either snapshot-all-at-once (impractical) or accepting inconsistency as a residual. |
| 6. Reverse TOCTOU | Low severity as stated. A file clean at open/scan time, later made sensitive, means the process read clean data. The process is not tainted, correctly — it never accessed the sensitive version. The only risk is if the process holds the fd open and re-reads after modification, but eBPF logs the `openat`, not subsequent `read` calls. This is a monitoring gap, not a TOCTOU race. Addressable by additionally hooking `read`/`pread64` for already-open fds to sensitive files. |

### Detailed analysis of mitigations

#### Mitigation 1: Overlayfs isolation (recommended)

**Mechanism:** Mount the workspace as an overlayfs in the agent container:
- **Lower layer** (read-only): the original workspace contents, bind-mounted into the tg-scanner container.
- **Upper layer** (writable): agent's modifications, stored in a container-local tmpfs or volume.
- **Merged view**: what the agent sees — lower + upper, with upper taking precedence for modified files.

tg-scanner reads files from the lower layer path directly. When the scanner daemon processes an `openat` event for `/workspace/secret.csv`, it reads `/workspace-lower/secret.csv` from the lower layer. Even if the agent has since overwritten `secret.csv` (creating a copy in the upper layer), the lower layer is immutable — the scanner sees the original.

**TOCTOU elimination:** The race disappears because the scanner reads from a layer the agent cannot write to. The lower layer is the ground truth for what was originally on disk. The agent's writes create upper-layer copies (copy-on-write) that don't affect the lower layer.

**What about files the agent creates?** New files exist only in the upper layer. tg-scanner must also scan the upper layer for new files. But new files have no TOCTOU risk — they didn't exist in the lower layer, so there's no "original vs modified" race. The scanner reads them from the upper layer at processing time. An attacker could modify a newly-created file between creation and scan, but newly-created files were never sensitive (they were created by the agent, not present in the original workspace).

**Costs:**
- Copy-up overhead: first write to any lower-layer file triggers a full copy to the upper layer. For large files, this adds latency to the first write. Subsequent writes are fast (upper layer only).
- Storage: upper layer duplicates modified files. For typical agent workloads (editing code, creating artifacts), this is modest.
- Complexity: requires overlayfs mount setup in container orchestration. Docker/OCI supports overlayfs natively — this is how container layers already work.
- Kernel requirement: overlayfs in mainline since Linux 3.18. Universally available in Docker environments.

**Limitations:**
- If the attacker's goal is to modify a file *created by the agent* (upper-layer only), the scanner still reads asynchronously from the upper layer. The TOCTOU window exists for agent-created files, but these files were never in the original workspace — the attacker would need to inject sensitive data into a file they create and then scrub it before the scanner reads it. This is a self-inflicted scenario (the agent is the attacker), not an external TOCTOU.
- Overlayfs has had security vulnerabilities (CVE-2023-0386: SUID binary smuggling across layers). The overlayfs mount must be configured without user namespace remapping or with careful UID mapping.

#### Mitigation 2: seccomp-notify on openat with fd capture

**Mechanism:** Instead of (or alongside) eBPF observation, add `openat` to the seccomp-notify filter. When the agent process calls `openat`:
1. Kernel pauses the thread (seccomp-notify behavior).
2. tg-scanner receives the notification, reads the filename from `/proc/<pid>/mem`.
3. tg-scanner opens the file itself (in its own mount namespace, from the shared volume).
4. tg-scanner scans the file contents synchronously.
5. tg-scanner injects the opened fd into the target process using `SECCOMP_IOCTL_NOTIF_ADDFD` with `SECCOMP_ADDFD_FLAG_SEND` (Linux 5.14+).
6. The target process receives the fd. It reads the *same file contents* the scanner saw, because the fd was opened by the scanner.

**TOCTOU elimination:** The scanner opens and scans the file while the target process is paused. The target receives an fd to the file the scanner already scanned. Even if the file is modified after the scanner's open, the target's fd points to the original inode/data (file descriptors reference the inode, not the path). The race is eliminated.

**Costs:**
- Performance: every `openat` syscall incurs seccomp-notify overhead (~5-7 microseconds for two context switches) plus scanner processing time. This is the same performance concern ADR-002 considered and rejected for `sendto`/`sendmsg` — but `openat` fires less frequently than `sendto`. Still, Python imports and Node.js module loading generate hundreds to thousands of `openat` calls. Latency would be noticeable.
- Complexity: syscall emulation via `SECCOMP_IOCTL_NOTIF_ADDFD` is delicate. The scanner must correctly handle all `openat` flags, relative paths, `AT_FDCWD`, symlinks, etc.
- TOCTOU on path resolution: the filename read from `/proc/<pid>/mem` could be modified by another thread between the seccomp-notify pause and the scanner's read. Mitigation: use `SECCOMP_IOCTL_NOTIF_ID_VALID` to check the notification is still valid before proceeding, and use `openat2` with `RESOLVE_NO_SYMLINKS | RESOLVE_BENEATH` for safe path resolution.
- Kernel requirement: `SECCOMP_ADDFD_FLAG_SEND` requires Linux 5.14+. Available in Docker Desktop's LinuxKit kernel and modern distros.

**Hybrid approach:** Use eBPF for observation (non-blocking, for journal/audit) and seccomp-notify on `openat` for enforcement (blocking, for taint-critical files). The scanner daemon maintains a "hot list" of files known to be sensitive from previous scans. Only `openat` calls targeting hot-list files trigger synchronous scanning; others fall through to async eBPF processing. This bounds the performance overhead to files that actually matter.

#### Mitigation 3: fanotify FAN_OPEN_PERM

**Mechanism:** Use fanotify with `FAN_OPEN_PERM` on the workspace volume. When any process opens a file, the kernel blocks the open until the fanotify listener (tg-scanner) responds with `FAN_ALLOW` or `FAN_DENY`.

**TOCTOU elimination:** The file cannot be read by the target process until the scanner has decided. The scanner reads and scans the file while the open is blocked. Same effective guarantee as seccomp-notify on `openat`.

**Costs:**
- Performance: synchronous blocking on every file open. Same concern as seccomp-notify, but fanotify has lower per-event overhead (no seccomp round-trip; the kernel delivers the event directly to the fanotify fd). Still blocks every `open`, including non-sensitive files.
- Deadlock risk: if the scanner daemon itself needs to open files on the watched filesystem (e.g., to read a config file or log), it triggers its own fanotify event and deadlocks. Mitigated by marking the scanner's own opens with `FAN_MARK_IGNORE` or by ensuring the scanner only opens files from a different mount.
- Privilege: fanotify requires `CAP_SYS_ADMIN` (or `CAP_DAC_READ_SEARCH` for `FAN_CLASS_CONTENT`). tg-scanner already runs privileged for seccomp-notify and eBPF.
- Kernel compatibility: fanotify `FAN_OPEN_PERM` available since Linux 2.6.36. Universally available. New `FAN_PRE_ACCESS` (Linux 6.14+) adds pre-read hooks with byte-range information, but is more than needed for this use case.

**Comparison with seccomp-notify:** fanotify is purpose-built for this exact use case (it was designed for antivirus on-access scanning). It is simpler than seccomp-notify syscall emulation — no fd injection needed, just allow/deny. But it cannot provide the fd-capture guarantee that seccomp-notify gives (where the target reads the exact bytes the scanner scanned). With fanotify, the scanner allows the open, and the target then reads — if the file is modified between allow and read, there's a (very small) residual window. In practice this window is negligible because the open and first read are typically adjacent syscalls in the same thread.

#### Mitigation comparison

| Property | Overlayfs | seccomp-notify openat | fanotify FAN_OPEN_PERM |
|---|---|---|---|
| TOCTOU eliminated | Yes (lower layer immutable) | Yes (fd capture) | Mostly (tiny residual between allow and read) |
| Performance impact | Copy-up on first write; zero overhead on reads | ~5-7us per openat + scan time | Lower per-event cost than seccomp; still blocks every open |
| Complexity | Low (container orchestration config) | High (syscall emulation, path resolution) | Medium (fanotify setup, deadlock avoidance) |
| Kernel requirement | Linux 3.18+ | Linux 5.14+ | Linux 2.6.36+ |
| Agent-created files | TOCTOU for upper-layer-only files (low risk) | Covered (all openat intercepted) | Covered (all opens intercepted) |
| Compatibility with ADR-002 | Additive (eBPF observation still works) | Alternative to eBPF for openat observation | Alternative to eBPF for openat observation |

### The attack in detail

To concretize the threat, here is the exploit sequence without mitigation:

1. Compromised agent spawns a child process (PID 5000) that runs a Python script.
2. The script opens `workspace/secrets.csv` containing credit card numbers. Kernel `openat` fires; eBPF logs `{pid=5000, path="workspace/secrets.csv", seq=42}` to ring buffer.
3. The script reads the file contents into memory.
4. The script immediately overwrites `workspace/secrets.csv` with innocuous data (or truncates it).
5. The scanner daemon picks up event seq=42, reads `workspace/secrets.csv` from the shared volume — sees the innocuous data. Scanner returns `{allow: true}`. PID 5000 is NOT tainted.
6. PID 5000 calls `connect()`. seccomp-notify fires. Scanner has processed through seq=42 for PID 5000. Taint table says clean. Connection ALLOWED.
7. PID 5000 exfiltrates the credit card data read in step 3. **Taint evasion successful.**

With overlayfs mitigation, step 4 creates a copy in the upper layer. Step 5 reads from the lower layer, which still contains the original `secrets.csv` with credit card numbers. PID 5000 is tainted. Step 6 blocks the connection.

### Prior art: how EDR/DLP systems handle this

**Microsoft Defender for Endpoint (Linux):** Uses fanotify for on-access scanning. CVE-2025-59497 (October 2025) demonstrated that even production-grade EDR with synchronous file hooks is vulnerable to TOCTOU when the implementation has race windows. The vulnerability was a DoS (crash the scanner to disable protection), not taint evasion, but it illustrates that TOCTOU in file-scanning systems is an active, real-world attack class.

**ESET:** Had TOCTOU vulnerabilities where attackers exploited NTFS file handle swapping between detection and remediation.

**ClamAV/on-access scanners:** Typically use fanotify `FAN_OPEN_PERM` for synchronous scanning. The scanner blocks the open, scans, and then allows or denies. This is the standard pattern for Linux antivirus on-access scanning.

**Content-addressed storage (CAS):** An alternative approach used in some integrity systems: store files by their content hash. The file's address *is* its hash — if the content changes, the address changes. The scanner can verify it's reading the same content the process accessed by comparing hashes. This requires the eBPF observation to capture a content hash at open time, which is not feasible in eBPF's execution constraints (512-byte stack, no arbitrary memory access). A userspace component would need to compute the hash synchronously.

### Recommendations

Ranked by effectiveness and implementation cost:

1. **Overlayfs isolation (recommended for MVP).** Mount the workspace as an overlayfs in the agent container with the original workspace as the immutable lower layer. tg-scanner reads from the lower layer. This eliminates the TOCTOU for all files present in the original workspace, requires no changes to the eBPF observation or scanner daemon, and has minimal performance overhead. Implementation is container orchestration configuration, not code. Add this to ADR-002 or create a new ADR.

2. **Hybrid seccomp-notify for sensitive files (recommended for post-MVP).** Maintain eBPF observation for the journal and audit trail. Add seccomp-notify on `openat` for files matching a hot list (paths previously flagged as containing sensitive data). Hot-list files get synchronous scanning with fd capture; all other files get async eBPF processing. This bounds the performance cost to files that matter, and provides the strongest TOCTOU guarantee (fd capture ensures byte-for-byte consistency).

3. **fanotify FAN_OPEN_PERM (alternative to #2).** If seccomp-notify on `openat` proves too complex (syscall emulation is delicate), fanotify provides the same synchronous scanning with simpler semantics (allow/deny instead of fd injection). Trade-off: slightly weaker TOCTOU guarantee (residual window between allow and read), but simpler implementation.

4. **Monitor upper-layer writes (complementary to #1).** When using overlayfs, additionally watch the upper layer for writes. Any write to the upper layer that creates a modified copy of a lower-layer file should trigger re-scanning of the upper-layer version. This catches the case where the agent modifies a file to inject sensitive data that wasn't in the original.

5. **Document the residual.** Even with overlayfs, agent-created files (upper-layer only) have a TOCTOU window. This is lower risk because the agent is creating the file (not reading pre-existing sensitive data), but it should be documented as a residual risk in ADR-002.

## Why it matters

The scanner daemon reading a file asynchronously (after the process already read it) means the scanner may see different contents than the process saw. An attacker who can trigger a file write between the process's read and the scanner daemon's read could evade taint.

## Related

- [VISION-002](../../../vision/Active/(VISION-002)-Tidegate/(VISION-002)-Tidegate.md) — Parent vision requiring robust data-flow enforcement
- [ADR-002](../../../adr/Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) residual risk #5: TOCTOU between file open observation and file scan.
- [ADR-001 (superseded)](../../../adr/Superseded/(ADR-001)-Seccomp-Notify-L1-Interception.md) residual risk #1: TOCTOU on `/proc/<pid>/mem` (no longer applicable — no `execve` interception).
- CVE-2025-59497: TOCTOU in Microsoft Defender for Endpoint on Linux. Same vulnerability class — file checked by security daemon, state changes before enforcement.
- fanotify `FAN_OPEN_PERM`: kernel mechanism designed for exactly this use case (on-access antivirus scanning with synchronous permission decisions).
- `SECCOMP_ADDFD_FLAG_SEND` (Linux 5.14+): enables TOCTOU-free fd injection for syscall emulation in seccomp-notify handlers.

## Context at time of writing

L1 (journal-based taint tracking) is designed (ADR-002) but not implemented. The shared workspace volume is read-only for tg-scanner but writable by the agent container. No snapshot or CoW mechanism is planned. The scanner daemon processes file-open events asynchronously, creating a window between the actual file read and the scan.
