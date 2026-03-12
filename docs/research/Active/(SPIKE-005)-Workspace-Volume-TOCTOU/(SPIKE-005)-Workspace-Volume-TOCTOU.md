---
artifact: SPIKE-005
title: "Workspace Volume TOCTOU"
status: Active
author: cristos
created: 2026-02-23
last-updated: 2026-03-12
question: "Can a TOCTOU race between file open observation and scanner read allow taint evasion?"
parent-vision: VISION-002
gate: Pre-MVP
risks-addressed: []
depends-on: []
---

# Workspace Volume TOCTOU

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Identified by adversarial threat model review; reframed for journal-based taint architecture (ADR-002) |
| Active | 2026-03-12 | 7506197 | Research in progress |

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

## Why it matters

The scanner daemon reading a file asynchronously (after the process already read it) means the scanner may see different contents than the process saw. An attacker who can trigger a file write between the process's read and the scanner daemon's read could evade taint.

## Related

- [ADR-002](../../../adr/Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) residual risk #5: TOCTOU between file open observation and file scan.
- [ADR-001 (superseded)](../../../adr/Superseded/(ADR-001)-Seccomp-Notify-L1-Interception.md) residual risk #1: TOCTOU on `/proc/<pid>/mem` (no longer applicable — no `execve` interception).

## Context at time of writing

L1 (journal-based taint tracking) is designed (ADR-002) but not implemented. The shared workspace volume is read-only for tg-scanner but writable by the agent container. No snapshot or CoW mechanism is planned. The scanner daemon processes file-open events asynchronously, creating a window between the actual file read and the scan.
