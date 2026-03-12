---
artifact: SPIKE-015
title: "SPIKE-015: Evaluate VM Isolation for Agent Container"
status: Complete
author: cristos
created: 2026-03-06
last-updated: 2026-03-12
parent-epic: EPIC-001
question: "Which VM technology best composes with Tidegate's Docker infrastructure for agent isolation?"
gate: Post-M7 hardening
risks-addressed:
  - Kernel-level container escape bypasses all scanning and network isolation
  - Shared-kernel attacks (CVE-2024-21626, CVE-2022-0185) give agent full host access
dependencies:
  - ADR-005 (Composable VM Isolation — architectural decision)
  - M2 (Agent Container — Docker baseline must exist first)
blocks:
  - EPIC-001 implementation work
---

# SPIKE-015: Evaluate VM Isolation for Agent Container

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-03-06 | b7482a6 | From claude-vm analysis; see ADR-005 |
| Active | 2026-03-12 | d4e8531 | Re-opened for expanded microVM research; broader candidate set + <2s boot target |
| Complete | 2026-03-12 | HASH | GO: Cloud Hypervisor (Linux) + Apple Containerization (macOS 26+); <2s achievable; snapshot/restore for <100ms |

## Question

Which VM technology best composes with Tidegate's existing Docker infrastructure (gateway, scanner, egress proxy, MCP servers on `agent-net`/`mcp-net`/`proxy-net`) to provide kernel-level isolation for the agent container?

## Candidates

### 1. claude-vm (Nix + QEMU)

[github.com/solomon-b/claude-vm](https://github.com/solomon-b/claude-vm)

- Nix flake that boots a headless QEMU VM with Claude Code pre-installed
- 4GB RAM, 4 cores, serial console with auto-login
- Workspace mounted via 9p at `/workspace`
- Minimal guest (git, curl, vim, Node.js, Claude Code)

**Strengths:** Already exists, Claude Code pre-configured, serial console solves PTY issues from M2.
**Concerns:** Requires Nix on host, QEMU overhead, networking not configured for proxy routing.

### 2. Firecracker microVMs

- AWS-developed, minimal device model, <125ms cold boot
- KVM-based, Linux-only
- virtio-net for networking, virtio-blk for storage
- No 9p; needs virtio-fs or block device for workspace

**Strengths:** Fast boot, minimal attack surface, production-proven (Lambda, Fargate).
**Concerns:** No 9p (need virtiofs or alternative), more setup complexity, Linux KVM required.

### 3. QEMU-direct (no Nix)

- QEMU with a pre-built disk image (cloud-init or packer)
- TAP networking, 9p or virtiofs for workspace
- Most flexible but most manual setup

**Strengths:** No Nix dependency, maximum configurability.
**Concerns:** Image management, slower boot than Firecracker, more moving parts.

### 4. Intermediate options (gVisor, Kata Containers)

- gVisor: user-space kernel, OCI-compatible, lighter than full VM
- Kata Containers: lightweight VM per container, OCI-compatible

**Strengths:** Drop-in Docker replacement, minimal topology changes.
**Concerns:** gVisor's syscall compatibility gaps may affect Claude Code; Kata adds complexity.

## Evaluation criteria

| Criterion | Weight | Notes |
|-----------|--------|-------|
| **Networking** | High | Must route all agent traffic through Tidegate gateway (port 4100) and egress proxy. Bridged/TAP to Docker's `agent-net`, or equivalent. |
| **Workspace mounting** | High | Read-only project files + scoped read-write for IPC. 9p, virtiofs, or block device. Performance matters for large codebases. |
| **Startup time** | Medium | <5s acceptable for interactive use, <1s preferred for session-per-task. |
| **Resource overhead** | Medium | RAM/CPU cost vs. Docker container. Must be reasonable on a developer laptop (16GB RAM). |
| **Host OS requirements** | Medium | KVM availability on Linux, feasibility on macOS (Hypervisor.framework), Windows (WSL2/Hyper-V). Linux-first is acceptable. |
| **Composability with docker-compose** | High | Infrastructure services stay in Docker. The VM must coexist, not replace the compose topology. |
| **ADR-002 compatibility** | Medium | eBPF on `openat` + seccomp-notify on `connect()` require the host kernel. Inside a VM, the host can't observe guest syscalls. Need guest-side equivalent or accept reduced taint tracking. |
| **Setup complexity** | Medium | How much additional tooling does the operator need? Nix, KVM modules, disk images? |

## Go/no-go criteria

**Go:** At least one candidate can route all agent traffic through existing Docker infrastructure (gateway + egress proxy) with <30 minutes additional setup beyond `./setup.sh`, and workspace mounting performs within 2x of native Docker bind mounts.

**No-go pivot:** If no candidate meets the networking and setup criteria, recommend gVisor/Kata as an intermediate hardening step (OCI-compatible, minimal topology changes) and defer full VM isolation.

## Key experiments

1. **Networking proof-of-concept**: Boot a QEMU VM, configure TAP interface bridged to Docker's `agent-net`, verify the VM can reach the gateway at `gateway:4100` and egress proxy.
2. **Workspace mount benchmark**: Compare 9p, virtiofs, and Docker bind mount performance for `git status` and `npm install` on a medium codebase (~10K files).
3. **ADR-002 taint tracking in VM**: Determine if eBPF tracepoints and seccomp-notify work from guest → host, or if a guest-side taint daemon is needed.
4. **claude-vm integration test**: Fork claude-vm, add TAP networking config, route traffic through a Tidegate gateway running in Docker on the host.

## Expanded Research (2026-03-12)

### Motivation

User requested deeper evaluation: more candidates, <2s boot target, compatibility with broad agentic runtimes (Node.js 18+, Python 3.11+, git, Claude Code CLI, tg-scanner daemon). The original spike evaluated 4 candidates at a high level. This expansion adds 7 more candidates, analyzes boot time decomposition, evaluates snapshot/restore and warm pool strategies, and produces a concrete tradeoff matrix.

### Additional candidates

#### 5. Cloud Hypervisor (Rust VMM, Linux Foundation)

Cloud Hypervisor is a Rust-based VMM forked from early Firecracker, now under the Linux Foundation. It deliberately trades ~75ms of boot time for significantly broader device support.

- **Boot time:** ~200ms to kernel ready (vs Firecracker's ~125ms). The extra time buys CPU/memory hotplug, vhost-user devices, and broader hardware compatibility.
- **virtiofs:** Native support via Rust-based virtiofsd. This is a key differentiator over Firecracker, which still lacks virtiofs entirely. Cloud Hypervisor's default I/O architecture uses Rust-based virtiofs and vhost-user-blk backends.
- **Networking:** virtio-net, vhost-user-net. Standard TAP-based networking, bridgeable to Docker networks.
- **macOS support:** No. Runs on KVM (Linux) and Microsoft Hypervisor (Windows/Hyper-V). There are experimental macOS Hypervisor.framework bindings in the org, but the VMM itself does not run on macOS.
- **Viability:** Strong for Linux hosts. The virtiofs support makes it the best Firecracker alternative for workspace mounting. The 200ms boot is well under the <2s target. Not viable for macOS development.

#### 6. krunvm / libkrun (Red Hat, containers project)

libkrun is a dynamic library that embeds a VMM (KVM on Linux, HVF on macOS/ARM64), allowing programs to launch processes in hardware-isolated microVMs. krunvm is a CLI that creates microVMs from OCI images using libkrun and buildah.

- **Boot time:** Claimed ~60ms in early materials, though specific benchmark methodology is not publicly documented. Practical experience suggests "a couple of seconds" end-to-end for OCI image extraction + VM boot + userspace ready. The VMM init is fast; the OCI layer extraction dominates.
- **virtiofs:** Yes, via virtio-fs for host-guest file sharing. Used for macOS-to-Linux file sharing in the Podman integration.
- **Networking:** Novel "Transparent Socket Impersonation" (TSI) allows VM network connectivity without a virtual interface by intercepting socket calls. Also supports conventional virtio-net with passt or gvproxy for bridged networking.
- **macOS support:** Yes, native Apple Silicon via HVF. This is a major differentiator. Podman 5.0+ uses libkrun on macOS, replacing QEMU entirely.
- **Viability:** High. macOS + Linux support, virtiofs, and OCI compatibility make it compelling. The TSI networking model needs evaluation for compatibility with Tidegate's proxy routing (traffic must go through gateway:4100 and egress proxy, not bypass via host sockets). GPU passthrough work in progress for AI inference workloads.

#### 7. crosvm (Google, Chrome OS)

crosvm is Google's Rust VMM used in Chrome OS (Crostini) and Android (ARCVM). Designed for security with per-device sandboxing via Minijail.

- **Boot time:** Not publicly benchmarked for cold-start scenarios. Optimized for persistent VM lifecycle (Chrome OS launches Crostini VMs at user login, not per-request).
- **virtiofs:** Supported. Also supports virtio-9p. Requires Linux kernel 5.4+.
- **Networking:** virtio-net with standard TAP backend.
- **macOS support:** No. Linux-only (KVM). Primarily used on Chrome OS and Android.
- **Viability:** Low for Tidegate. Designed for long-lived desktop VMs, not ephemeral microVMs. No macOS support. Per-device Minijail sandboxing is interesting from a security perspective but adds complexity without clear benefit for our use case. The project is tightly coupled to Chrome OS infrastructure.

#### 8. Podman machine

Podman machine manages the Linux VM that Podman uses on non-Linux hosts to run containers. Not itself a microVM solution, but instructive for understanding VM lifecycle management.

- **Boot time:** First boot requires Ignition provisioning (several seconds). Subsequent starts are faster but still measured in seconds, not milliseconds. The VM is long-lived, not ephemeral.
- **virtiofs:** Yes, via Apple Virtualization.framework on macOS (Podman 5.0+). Replaced QEMU's 9p on macOS entirely.
- **Networking:** gvproxy manages port mapping between host and VM. Not designed for arbitrary network topology integration.
- **macOS support:** Yes. Podman 5.0+ uses Apple Virtualization.framework (QEMU dropped for Mac). Intel Macs fall back to QEMU.
- **Viability:** Low as a direct solution. Podman machine is designed for a single long-lived VM running a container engine, not for per-session ephemeral VMs. However, it validates that Apple Virtualization.framework + virtiofs + libkrun is a production-viable stack on macOS.

#### 9. Lima (Linux Machines on macOS)

Lima creates Linux VMs on macOS, functioning as a WSL2 equivalent. Supports both QEMU and Apple Virtualization.framework (VZ) backends.

- **Boot time:** First boot: 30-60 seconds (provisioning, package installation). Subsequent starts: 5-15 seconds depending on backend. VZ is faster than QEMU. Not optimized for ephemeral use.
- **virtiofs:** Yes, via VZ driver (Apple Virtualization.framework). The VZ driver is now the default on macOS 13.5+. QEMU backend uses 9p.
- **Networking:** Bridged or shared networking via vmnet.framework on macOS. Socket-based forwarding also available.
- **macOS support:** macOS-only (that is the entire point).
- **Viability:** Low as a direct solution. Lima is designed for persistent development VMs, not ephemeral per-session isolation. Boot times are far above the <2s target. However, Lima validates that VZ + virtiofs is mature on macOS, and Lima's krunkit backend (using libkrun) shows that container-native microVMs on macOS are achievable.

#### 10. Apple Containerization Framework (macOS 26+)

Announced at WWDC 2025, Apple's Containerization framework provides native Linux container support where each container runs in its own lightweight VM. Open-source Swift framework.

- **Boot time:** Sub-second (200-300ms to container ready). Uses an optimized Linux kernel configuration and minimal root filesystem with a lightweight init system. EXT4 block devices for container filesystems.
- **virtiofs:** Yes, native virtiofs for host-guest file sharing. Secure data sharing while maintaining per-container VM isolation.
- **Networking:** Each container gets a private IP from a local subnet (192.168.64.x) via vmnet.framework. In macOS 15, containers share a virtual bridge. macOS 26 promises fully isolated per-container networking.
- **macOS support:** macOS 26+ only. Apple Silicon optimized. Written in Swift.
- **Viability:** High for macOS 26+ environments. Sub-second boot, native virtiofs, per-container VM isolation is exactly the Tidegate use case. However: macOS-only, requires macOS 26 (not yet released), no Linux support, and the networking model needs evaluation for Tidegate's proxy routing requirements. Long-term, this could be the macOS path while Cloud Hypervisor/libkrun serve Linux.

#### 11. Cloud microVM providers (Fly Machines, E2B, Daytona)

These are cloud-hosted solutions, not self-hosted VMMs, but their architectures inform the design space.

**Fly Machines:** VMs with a REST API. Boot a stopped machine in <1s (~300ms typical). Uses Firecracker on Linux. Warm pool strategy: pre-create machines, assign on demand. Cold creation takes low-double-digit seconds (registry pull + rootfs build).

**E2B:** Firecracker-based sandboxes for AI agents. Launch in ~125-200ms. Up to 150 microVMs/second on a single host. Production-proven at Fortune 500 scale. Demonstrates that Firecracker + snapshot/restore is viable for agentic workloads.

**Daytona:** Pivoted to AI agent infrastructure in early 2025. Claims sub-90ms sandbox creation — but uses Docker containers (not microVMs) by default. Enhanced isolation available via Kata Containers or Sysbox. The 90ms figure is for namespace-based containers, not VM-isolated containers.

- **Viability as architecture reference:** High. E2B's Firecracker + snapshot/restore pattern and Fly's warm pool strategy directly inform Tidegate's approach. Daytona's 90ms is misleading for VM isolation comparison (it uses containers). The key insight: cloud providers use warm pools and snapshot/restore to hide boot latency, not faster VMMs.

### Minimal kernel compatibility analysis

The agentic runtime requires: Node.js 18+, Python 3.11+, git, Claude Code CLI (Node.js-based), and tg-scanner daemon (Python). The question: can a stripped kernel run these?

**Syscall requirements:**

Node.js 18+ requires a broad syscall surface: `epoll_*` (event loop), `io_uring` (optional, falls back to epoll), `clone`/`clone3` (worker threads), `mmap`/`mprotect` (V8 JIT), `futex` (threading), `eventfd` (libuv), `timerfd_create` (timers), `signalfd` (signal handling), `pipe2`, `socket`, `connect`, `bind`, `listen`, `accept4` (networking), `openat`/`read`/`write`/`close`/`stat` (filesystem). V8's JIT compiler requires `mmap` with `PROT_EXEC`.

Python 3.11+ has a similar but slightly narrower surface. Does not require JIT-related `mmap(PROT_EXEC)` in standard usage. Needs `clone`/`fork` for multiprocessing, `select`/`poll`/`epoll` for I/O.

git requires standard POSIX filesystem operations plus `clone`/`fork`/`exec` for subprocess spawning.

**Kernel config analysis:**

A minimal kernel can safely disable: USB subsystem, sound/audio, GPU/DRM, Bluetooth, wireless, most hardware drivers, RAID/MD, NFS client/server, most filesystems (keep ext4, tmpfs, proc, sysfs, devtmpfs), most network protocols (keep IPv4, TCP, UDP, Unix sockets), module loading (compile everything built-in), ACPI (if using microvm machine type).

A minimal kernel must keep: virtio drivers (virtio-net, virtio-blk, virtiofs/9p), cgroups v2, namespaces (for container-in-VM if needed), futex, epoll, eventfd, timerfd, signalfd, io_uring (optional), seccomp (for tg-scanner), eBPF (for taint tracking per ADR-002), ext4, tmpfs, proc, sysfs, devtmpfs.

**eBPF consideration:** eBPF tracepoints and seccomp-notify operate on the kernel the process runs under. Inside a VM, the agent's syscalls are intercepted by the guest kernel, invisible to the host. A guest-side taint daemon running eBPF tracepoints on `openat` is required. This means the guest kernel must have `CONFIG_BPF=y`, `CONFIG_BPF_SYSCALL=y`, `CONFIG_BPF_JIT=y`, and relevant tracepoint configs. This adds to kernel size but is not incompatible with a minimal config.

**musl vs glibc:** Alpine uses musl. Node.js has official musl builds (marked "linux-x64-musl"). Python builds cleanly with musl. git works with musl. The risk is native Node.js addons compiled against glibc — these require recompilation or a glibc compatibility layer. For Claude Code CLI (pure JS + Node.js builtins), musl is fine. For tg-scanner (pure Python + python-stdnum), musl is fine.

**Verdict:** A stripped kernel (~10-15MB compressed) can run the full agentic runtime. The critical requirement is eBPF support for taint tracking, which adds ~2MB but is essential per ADR-002.

### Boot time optimization strategies

#### Where the time goes

VM boot decomposes into these phases:

| Phase | Firecracker | Cloud Hypervisor | QEMU (standard) | QEMU (microvm) |
|-------|------------|-----------------|-----------------|----------------|
| VMM init | ~3ms | ~10ms | ~40ms | ~10ms |
| Kernel decompression | ~10-20ms | ~10-20ms | ~10-20ms | ~10-20ms |
| Kernel init | ~50-80ms | ~80-100ms | ~200-500ms | ~80-100ms |
| Userspace init | ~30-50ms | ~50-80ms | ~500ms+ | ~100-200ms |
| Application ready | +50-200ms | +50-200ms | +500ms+ | +100-200ms |
| **Total to app-ready** | **~150-350ms** | **~200-400ms** | **~1.5-3s** | **~300-500ms** |

Notes: Firecracker's <125ms figure measures kernel ready (init started), not application ready. Application-ready adds userspace init + application startup. Cloud providers' "boot time" claims often measure different things.

Optimization levers:
- **No bootloader:** Direct kernel boot (all microVMs do this). Saves 200-500ms over BIOS/UEFI.
- **lz4 kernel compression:** Faster decompression than gzip/zstd at cost of ~20% larger image. Saves ~5-10ms.
- **Custom init (no systemd):** A shell script or compiled init that starts only the required daemons. Saves 100-500ms over systemd.
- **Built-in kernel modules:** No module loading, everything compiled in. Saves modprobe time.
- **Minimal device model:** Fewer emulated devices = less kernel init time. QEMU microvm and Firecracker excel here.

#### Snapshot/restore

Firecracker's snapshot/restore is production-proven (AWS Lambda). The flow:

1. Boot a VM with the full agentic runtime (Node.js, Python, git, tg-scanner).
2. Wait for all daemons to reach ready state.
3. Snapshot: saves VM memory + device state to files.
4. On session start: restore from snapshot. Memory is MAP_PRIVATE + lazy-loaded (copy-on-write). Restore takes ~4-10ms.

**Implications for Tidegate:**
- First snapshot creation: ~2-5s (one-time cost at image build or deploy time).
- Session start from snapshot: <50ms (memory page fault on demand).
- virtiofs compatibility: Unclear. Firecracker does not support virtiofs. Cloud Hypervisor has snapshot support but maturity with virtiofs mounts is undocumented. QEMU's savevm/loadvm works with virtiofs but is less mature for microVM use cases.
- State freshness: Snapshots capture a point-in-time. The restored VM thinks time hasn't passed. Need to re-sync clocks and potentially re-mount workspace virtiofs shares with fresh content.

#### Warm pool

Pre-boot N VMs, keep them idle. When a session starts, assign a warm VM from the pool. When it finishes, destroy the VM and replenish the pool.

- **Fly Machines pattern:** Pre-create machines via API. Assign on request. Machine start is <1s because it is already provisioned.
- **AWS Lambda pattern:** Warm pool of Firecracker microVMs. Snapshot/restore from pool. Cold start hidden from user.
- **Memory cost:** Each warm VM consumes its allocated RAM (e.g., 2-4GB for agentic workload). A pool of 5 warm VMs = 10-20GB idle memory. Acceptable on a server, tight on a developer laptop.
- **For Tidegate:** On a server deployment, a warm pool of 2-3 VMs eliminates boot latency entirely. On a developer laptop, snapshot/restore is preferred (lower memory overhead, <50ms restore).

### Tradeoff matrix

| Candidate | Isolation level | Boot time (to app-ready) | virtiofs | macOS | Networking | Viability |
|-----------|----------------|--------------------------|----------|-------|------------|-----------|
| Firecracker | Full VM (KVM) | 150-350ms | No | No | virtio-net, TAP | High (Linux only; no virtiofs is a significant gap) |
| Cloud Hypervisor | Full VM (KVM) | 200-400ms | Yes (native) | No | virtio-net, TAP | High (Linux; best virtiofs + fast boot combo) |
| krunvm/libkrun | Full VM (KVM/HVF) | ~500ms-2s (OCI overhead) | Yes | Yes (Apple Silicon) | TSI or virtio-net | High (only cross-platform VM option) |
| QEMU microvm | Full VM (KVM/HVF) | 300-500ms | Yes | Partial (HVF on macOS, no microvm type) | TAP, user-mode | Medium (flexible but more moving parts) |
| QEMU standard | Full VM (KVM/HVF) | 1.5-3s | Yes | Yes | TAP, bridged | Low (too slow for <2s target) |
| crosvm | Full VM (KVM) | Unknown (not benchmarked) | Yes | No | virtio-net | Low (Chrome OS-focused, not ephemeral) |
| Apple Containerization | Full VM (VZ) | 200-300ms | Yes | macOS 26 only | vmnet | High (macOS 26+ only; ideal for Mac) |
| Lima | Full VM (QEMU/VZ) | 5-15s (restart) | Yes (VZ) | macOS only | vmnet, bridged | Low (too slow; persistent VM model) |
| Podman machine | Full VM (VZ/libkrun) | Seconds | Yes | Yes | gvproxy | Low (single long-lived VM, not ephemeral) |
| gVisor (runsc) | User-space kernel | ~50ms | N/A (OCI) | No | Host networking | Medium (fast boot, weaker isolation) |
| Kata Containers | Full VM (various VMMs) | 500ms-1s | Yes | No | virtio-net | Medium (OCI-compatible but complex) |
| Firecracker + snapshot | Full VM (KVM) | <50ms (restore) | No | No | virtio-net | High (fastest option; no virtiofs) |
| Cloud Hypervisor + snapshot | Full VM (KVM) | ~50-100ms (restore, est.) | Yes | No | virtio-net | High (if snapshot+virtiofs works) |

### The gVisor question

gVisor (runsc) deserves special analysis because it occupies a unique point in the tradeoff space: ~50ms boot, zero kernel setup, OCI-compatible, memory-safe Go implementation.

**Syscall compatibility (2025-2026 status):**
- Node.js: Works. gVisor regression-tests popular language runtimes including Node.js. The systrap mechanism (default since 2023) improved performance significantly. npm operations work — the previous issues were primarily with native addons requiring unsupported syscalls, not npm itself.
- Python: Works. Standard library and pip are compatible.
- git: Works. Standard POSIX operations are supported.
- eBPF: Not supported. gVisor implements its own syscall surface and does not expose eBPF. This is a hard blocker for ADR-002 taint tracking inside the sandbox. The guest-side taint daemon cannot use eBPF tracepoints under gVisor.

**Security model comparison:**
- gVisor: Dual-kernel (Go Sentry + host Linux). Attacker must exploit the Sentry (memory-safe Go, ~200 syscalls implemented) AND then escape the seccomp-filtered Sentry process. The Sentry does return to the host kernel for a limited set of ~70 host syscalls.
- Full VM: Dual-kernel (guest Linux + host Linux). Attacker must exploit the guest kernel AND escape the VMM (Firecracker/Cloud Hypervisor, also Rust/memory-safe). The VMM exposes a much smaller surface (~5 emulated devices) than gVisor's ~70 host syscalls.

**Verdict on gVisor:** The ~50ms boot and OCI compatibility are compelling. But two factors make it unsuitable for Tidegate:
1. **No eBPF support** — blocks ADR-002 taint tracking entirely. Without guest-side eBPF, we lose the ability to trace file access and network connections for taint propagation.
2. **Weaker isolation guarantee** — the Sentry's ~70 host syscalls present a larger attack surface than a microVM's ~5 emulated virtio devices. For a security product protecting against agent container escape, the stronger isolation of a full VM is the appropriate choice.

### Revised recommendation

The original spike had 4 candidates and no boot time target. The expanded research with 11+ candidates and a <2s boot target yields a clearer picture.

**Primary recommendation: Cloud Hypervisor (Linux) + Apple Containerization (macOS 26+)**

This is a dual-path strategy:

1. **Linux hosts (servers, CI):** Cloud Hypervisor with virtiofs. ~200-400ms to app-ready, well under <2s target. Native virtiofs eliminates the workspace mounting gap that blocks Firecracker. Snapshot/restore can bring this to <100ms for session reuse. Cloud Hypervisor is the only fast VMM that combines sub-second boot with native virtiofs.

2. **macOS hosts (developer laptops):** Apple Containerization framework on macOS 26+. Sub-second boot, native virtiofs, per-container VM isolation. For macOS <26, libkrun/krunvm provides a viable bridge with HVF + virtiofs support, though with slower boot times (~1-2s).

**Why not Firecracker?** Despite being the fastest VMM (~125ms to kernel), Firecracker's persistent lack of virtiofs is a dealbreaker for workspace mounting. The workaround (virtio-blk with pre-built images) adds significant complexity and eliminates live workspace access.

**Why not gVisor?** No eBPF support blocks ADR-002 taint tracking. Weaker isolation than a full VM is inappropriate for a security product.

**Boot time strategy (layered):**
- **Baseline:** Cloud Hypervisor cold boot + custom init (no systemd) + minimal kernel. Target: 300-400ms.
- **Optimization 1:** Snapshot/restore for session reuse. Target: <100ms.
- **Optimization 2:** Warm pool (2-3 VMs) for server deployments. Target: ~0ms perceived latency.

**Open questions for implementation:**
1. Cloud Hypervisor snapshot + virtiofs interaction — does restoring a snapshot correctly reconnect to a virtiofsd instance with fresh workspace content?
2. libkrun's TSI networking — can Tidegate's proxy routing work with socket impersonation, or does it require conventional virtio-net?
3. Apple Containerization's networking — can we route all traffic through Tidegate's gateway, or does vmnet bypass the proxy?
4. Guest-side eBPF taint daemon — needs a prototype to validate that eBPF tracepoints on `openat` and seccomp-notify on `connect()` work correctly inside a minimal guest kernel.

## References

- ADR-005 — Composable VM Isolation
- EPIC-001 — VM-Isolated Agent Runtime
- ADR-002 — Taint-and-Verify Data Flow Model
- ADR-003 — Agent Runtime Selection
- [claude-vm](https://github.com/solomon-b/claude-vm) — Nix flake for headless QEMU VM with Claude Code
- [Firecracker](https://firecracker-microvm.github.io/) — AWS microVM
- CVE-2024-21626 — runc container escape
- CVE-2022-0185 — Linux namespace escape
- [Cloud Hypervisor](https://www.cloudhypervisor.org/) — Rust VMM, Linux Foundation
- [libkrun](https://github.com/containers/libkrun) — Container-native microVM library (Red Hat)
- [krunvm](https://github.com/containers/krunvm) — CLI for creating microVMs from OCI images
- [crosvm](https://github.com/google/crosvm) — Chrome OS VMM (Google)
- [Lima](https://lima-vm.io/) — Linux VMs on macOS
- [Apple Containerization](https://github.com/apple/containerization) — Native Linux containers on macOS 26+
- [E2B](https://e2b.dev/) — Firecracker-based AI agent sandboxes
- [Fly Machines](https://fly.io/machines) — Fast-booting VMs with REST API
- [Daytona](https://www.daytona.io/) — AI agent sandbox infrastructure
- [gVisor](https://gvisor.dev/) — User-space kernel for containers (Google)
- [QEMU microvm](https://www.qemu.org/docs/master/system/i386/microvm.html) — Minimal QEMU machine type
- [SlicerVM — Sub-300ms microVM sandboxes](https://slicervm.com/blog/microvms-sandboxes-in-300ms/) — Boot time breakdown analysis
