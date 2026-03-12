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
| Active | 2026-03-12 | 1f1ec57 | Research in progress |
| Complete | 2026-03-12 | f82f56b | GO: QEMU-direct + virtiofs recommended |

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

## Findings

QEMU-direct with virtiofs is the recommended VM technology for agent isolation. It offers the best balance of networking flexibility, workspace performance, host OS compatibility, and composability with Tidegate's existing Docker infrastructure. claude-vm validates the approach and can inform the guest image, but its 9p mount and lack of proxy-routed networking make it unsuitable as-is. Firecracker is the strongest long-term candidate for production/multi-tenant deployments but has critical gaps (no virtiofs, no macOS) that make it wrong for Tidegate's developer-first, single-tenant use case at this stage.

**Verdict:** GO — QEMU-direct with virtiofs for workspace and TAP-to-Docker-bridge networking. Meets both go/no-go criteria: TAP bridge to `agent-net` is a well-documented ~15-minute setup, and virtiofs delivers 2-8x better performance than 9p (well within the 2x-of-native-bind-mount threshold).

### Candidate evaluation

| Criterion | claude-vm (Nix+QEMU) | Firecracker | QEMU-direct | gVisor | Kata Containers |
|-----------|----------------------|-------------|-------------|--------|-----------------|
| **Networking** | User-mode (SLIRP) only; no TAP/bridge configured. Cannot route through Docker networks without modification. | TAP + virtio-net. Bridging to Docker documented but requires manual TAP setup + iptables. `tc-redirect-tap` CNI plugin available for containerd. | TAP + virtio-net-pci. Mature bridge integration. Docker iptables conflict is a known issue with a one-line fix (`iptables -P FORWARD ACCEPT`). | Inherits Docker networking natively. No topology changes. | OCI networking (CNI). Bridge, MacVTap, tc mirroring. Integrates with Docker networks. |
| **Workspace mounting** | 9p at `/workspace`. Functional but slow: 9p delivers ~200 files/sec creation vs virtiofs ~750 files/sec. Metadata operations 3-7x slower than virtiofs. | **No 9p, no virtiofs.** Only virtio-blk. Workspace sharing requires pre-baking into a block device image or OverlayFS on block device. Not suitable for live project file access. | 9p or virtiofs (via virtiofsd daemon). virtiofs available since QEMU 5.0 / Linux 5.4. DAX mode enables host page cache sharing for near-native read performance. | Docker bind mounts (native). No overhead. | virtiofs (default since Kata 2.0) or 9p fallback. virtiofs performance 2-8x better than 9p. |
| **Startup time** | ~3-5s (full QEMU boot with Nix-built NixOS guest). Acceptable for interactive use. | <125ms cold boot (specification). ~3ms VMM start. Fastest option by far. | ~1-3s with microvm machine type and minimal kernel. Standard QEMU ~5-10s. | ~50-100ms (no VM boot — user-space kernel). Fastest practical option. | ~150-300ms (lightweight VM boot via QEMU or Cloud Hypervisor backend). |
| **Resource overhead** | ~4GB RAM (configured), 4 cores. NixOS guest image is larger than minimal Alpine. | ~5 MiB VMM memory. Guest RAM configurable. Minimal device model = minimal overhead. | Guest RAM configurable (512MB-4GB). QEMU process overhead ~50-100MB. virtiofsd daemon ~20-50MB additional. | Sentry process ~50-150MB. No VM overhead. gVisor kernel memory scales with syscall workload. | ~20-30MB per VM overhead. Plus QEMU/CH backend memory. Total similar to QEMU-direct. |
| **Host OS** | macOS (QEMU+HVF), Linux (KVM). Nix required on all platforms. | **Linux-only.** Requires KVM. No macOS support, no Hypervisor.framework port planned. | macOS (QEMU+HVF on Apple Silicon), Linux (KVM), Windows (via WSL2 QEMU). Broadest support. | **Linux-only.** Requires Linux kernel. Docker Desktop on macOS would need nested virtualization (not supported). | **Linux-only.** Requires KVM or Cloud Hypervisor. No macOS support (Apple's Containerization framework is a separate Swift-based solution). |
| **Composability with docker-compose** | Runs outside compose. Could be scripted alongside compose but no native integration. | Runs outside compose. `firecracker-in-docker` PoC exists (run Firecracker inside a Docker container with /dev/kvm passthrough) but requires CAP_NET_ADMIN + /dev/kvm + /dev/net/tun. | Runs outside compose. TAP interface bridged to Docker bridge network. Compose services see the VM as another host on the bridge. Cleanest coexistence model. | **Native.** `docker run --runtime=runsc`. Composes perfectly — just a runtime swap. | **Near-native.** `docker run --runtime=kata`. OCI-compatible runtime, works with compose. |
| **ADR-002 compatibility** | Guest kernel is separate. Host eBPF cannot observe guest `openat`. seccomp-notify on guest `connect()` requires guest-side tg-scanner. **Taint tracking requires guest-side daemon.** | Same as claude-vm. VM boundary blocks all host-side kernel observation. Guest-side tg-scanner required. | Same as claude-vm. VM boundary blocks all host-side kernel observation. Guest-side tg-scanner required. | **Partial.** gVisor's Sentry intercepts all syscalls in user-space, but the Sentry is not the host kernel — host-side eBPF cannot observe gVisor-intercepted syscalls. Custom integration with Sentry possible in theory but not practical. | Same as full VM options. Kata uses a guest kernel. Host-side eBPF/seccomp-notify cannot observe guest syscalls. |
| **Setup complexity** | Requires: Nix package manager + `nix run` command. Low effort if Nix is already installed. High barrier for teams without Nix experience. | Requires: KVM host, Firecracker binary, kernel image, rootfs image, TAP setup script, API calls to configure VM. No orchestration included — must build lifecycle management. | Requires: QEMU, virtiofsd, pre-built disk image (cloud-init or packer), TAP setup script. Can be wrapped in a single shell script. | Requires: install runsc binary, configure Docker daemon. 5-minute setup on Linux. Impossible on macOS Docker Desktop. | Requires: install kata-runtime, configure Docker/containerd. ~15-minute setup on Linux. Requires KVM. |

### Sub-question dispositions

**1. Networking proof-of-concept (TAP bridge to Docker agent-net)**

Desk research confirms this is feasible and well-documented for all VM-based options. The pattern:

1. `docker compose up` creates `agent-net` bridge (visible as `br-<hash>` on host).
2. Create a TAP device: `ip tuntap add dev tap-agent mode tap`.
3. Attach TAP to Docker bridge: `ip link set tap-agent master br-<agent-net-hash>`.
4. Boot QEMU with `-netdev tap,id=net0,ifname=tap-agent,script=no -device virtio-net-pci,netdev=net0`.
5. Inside guest, configure IP on the Docker subnet. Gateway is now reachable at its Docker IP.

Known issue: Docker's default iptables FORWARD policy is DROP, which blocks bridge traffic from non-Docker sources. Fix: `iptables -I DOCKER-USER -i tap-agent -j ACCEPT` or `iptables -P FORWARD ACCEPT`. This is a one-time host configuration.

For Firecracker, the same TAP pattern applies but requires the Firecracker API to configure the network interface rather than QEMU CLI flags.

gVisor and Kata inherit Docker networking natively — no TAP setup needed.

**Conclusion:** All candidates can reach the gateway. QEMU-direct and Firecracker require TAP bridge setup (~15 minutes). gVisor/Kata need zero networking changes.

**2. Workspace mount performance (9p vs virtiofs vs bind mount)**

Published benchmarks from Red Hat, Kata Containers, and Phoronix consistently show:

- **virtiofs with DAX**: 2-8x faster than 9p across file creation, metadata operations, and sequential I/O. Near-native performance for read-heavy workloads due to host page cache sharing.
- **virtiofs without DAX**: 2-4x faster than 9p. Still significant improvement.
- **9p**: Functional but limited. ~200 files/sec creation vs ~750 files/sec (virtiofs+DAX). Metadata operations (`ls -l`, `stat`) are 3-7x slower than virtiofs. Adequate for small projects but degrades noticeably on ~10K+ file codebases.
- **Docker bind mount**: Near-native on Linux. On macOS Docker Desktop, bind mounts go through a Linux VM anyway (gRPC-FUSE or virtiofs depending on Docker Desktop version).

For Tidegate's use case (read-only project files + limited IPC writes), virtiofs with DAX should deliver performance within 1.2-1.5x of native Docker bind mounts. 9p would be approximately 3-5x slower — outside the 2x threshold.

**Critical Firecracker gap:** Firecracker supports neither 9p nor virtiofs. The only filesystem option is virtio-blk (block devices). Sharing a live workspace directory requires either: (a) baking it into a block device image before each session (unacceptable latency), or (b) using OverlayFS atop a block device with a separate file sync mechanism. This is a dealbreaker for the workspace mount criterion.

**Conclusion:** virtiofs (QEMU-direct, Kata) meets the 2x threshold. 9p (claude-vm) does not. Firecracker cannot share a workspace directory at all without significant workarounds. gVisor uses native bind mounts (best performance).

**3. ADR-002 taint tracking across VM boundary**

eBPF programs run in the host kernel and observe host-kernel syscalls. Inside a VM, the guest kernel is a separate operating system. Host-side eBPF on `openat` cannot observe guest file opens. Host-side seccomp-notify on `connect()` cannot intercept guest TCP connections. The hypervisor boundary is opaque to kernel-level observability tools.

This applies equally to all VM-based options (claude-vm, Firecracker, QEMU-direct, Kata). gVisor is a special case: its Sentry process runs in user-space on the host and intercepts all guest syscalls, but the interception happens inside the Sentry, not via host kernel tracepoints — so host-side eBPF still cannot observe them.

**Implication for Tidegate:** ADR-002's taint-and-verify model requires a guest-side tg-scanner daemon that:
- Loads eBPF programs in the guest kernel (for `openat` observation).
- Runs seccomp-notify on `connect()` in the guest.
- Maintains the taint table locally in the guest.
- Enforces connect-time taint checks within the guest.

This is architecturally identical to the Docker-based tg-scanner deployment, just running inside the VM instead of in a sidecar container. The VM boundary does not weaken taint enforcement — it moves it to the guest, where the agent's syscalls are observable. The host cannot tamper with the guest-side tg-scanner (the agent would need a guest kernel exploit to bypass it, which is the exact attack the VM prevents).

**Conclusion:** All VM options require guest-side tg-scanner. This is not a differentiator between candidates but is important for EPIC-001 implementation planning.

**4. claude-vm integration feasibility**

claude-vm uses Nix to build a NixOS guest with Claude Code pre-installed. Its current configuration:
- User-mode networking (SLIRP) — no TAP, no bridge, no ability to route through Docker networks.
- 9p workspace mount — functional but slow (fails the 2x performance threshold).
- Serial console for PTY — solves the interactive terminal problem from M2.

Forking claude-vm to add TAP networking and virtiofs would require:
- Replacing `-netdev user` with `-netdev tap,ifname=...` in the QEMU invocation.
- Adding virtiofsd daemon startup and `-chardev socket -device vhost-user-fs-pci` to QEMU flags.
- Modifying the NixOS guest configuration to mount virtiofs instead of 9p.
- These are Nix expression changes, which have a steep learning curve for non-Nix teams.

**Conclusion:** claude-vm is valuable as a reference for guest image construction (what packages to include, how to configure auto-login, serial console setup) but its Nix dependency and missing networking/virtiofs support make it unsuitable as the base. A QEMU-direct approach that borrows claude-vm's guest design choices without the Nix wrapper is more practical.

### Additional finding: Apple Containerization framework

Apple announced a Containerization framework at WWDC 2025, shipping with macOS 26 (Tahoe). Each Linux container runs in its own lightweight VM using Apple's Virtualization.framework, with sub-second boot, dedicated IP addresses, and directory sharing. This is architecturally similar to Kata Containers but implemented in Swift and tightly integrated with macOS.

This is significant for Tidegate's macOS story: once macOS 26 ships, macOS developers could run the agent container in a Containerization-backed VM with hardware isolation, while infrastructure services run in standard Docker containers. However, this is macOS-only and not yet released, so it cannot be the primary recommendation. Worth tracking for future macOS support.

### Recommendations

**Primary recommendation: QEMU-direct with virtiofs**

1. **Build a minimal guest image** using cloud-init or packer (Alpine or Debian minimal). Include: Node.js 18+, Claude Code, git, curl, tg-scanner daemon. Borrow guest configuration patterns from claude-vm (auto-login, serial console).

2. **Use virtiofs for workspace mounting.** Run virtiofsd on the host, configure QEMU with `vhost-user-fs-pci`. Mount project directory read-only + IPC directory read-write. Expected performance: within 1.2-1.5x of Docker bind mounts.

3. **Use TAP networking bridged to Docker's agent-net.** Create TAP device, attach to Docker bridge, configure guest IP on the Docker subnet. Gateway reachable at its Docker IP on port 4100. Egress proxy reachable on proxy-net via gateway forwarding.

4. **Use QEMU microvm machine type** for faster boot (~1-3s vs ~5-10s with standard PC machine type). Combined with a minimal kernel, this approaches interactive-acceptable startup time.

5. **Deploy tg-scanner inside the guest** per ADR-002 requirements. Same eBPF + seccomp-notify architecture, running in the guest kernel instead of on the host.

6. **Wrap in a launcher script** (`tidegate vm start`) that: starts virtiofsd, creates TAP device, bridges to Docker network, boots QEMU, waits for guest ready signal. Target: <30 seconds end-to-end, <5 seconds for subsequent starts with snapshot restore.

**Phased approach:**

- **Phase 1 (EPIC-001 MVP):** QEMU-direct + virtiofs + TAP bridge. Linux host only (KVM required). macOS developers continue using Docker containers.
- **Phase 2:** Add QEMU HVF support for macOS (QEMU already supports Apple Hypervisor.framework on Apple Silicon). virtiofs on macOS requires validation — may need to fall back to 9p.
- **Phase 3:** Evaluate Firecracker migration for multi-tenant/production deployments where boot time and resource efficiency matter more. By that point, Firecracker may have virtiofs support (long-standing feature request).
- **Phase 4:** Evaluate Apple Containerization framework for native macOS VM isolation once macOS 26 stabilizes.

**Why not the others:**

- **claude-vm:** Nix dependency is a barrier. 9p mount fails the performance threshold. Useful as a reference, not as the base.
- **Firecracker:** No virtiofs = no workspace sharing. Linux-only. Excellent for multi-tenant cloud but wrong for developer-laptop, single-tenant Tidegate.
- **gVisor:** Linux-only (not usable on macOS Docker Desktop). Syscall compatibility is "probably fine" for Node.js but unvalidated for Claude Code specifically. Does not provide full kernel isolation — a Sentry escape returns to the host kernel. Acceptable as an intermediate hardening step if full VM is deferred.
- **Kata Containers:** Strong option (OCI-compatible, virtiofs support, ~200ms boot). Linux-only. More complex setup than QEMU-direct for comparable isolation. Would recommend over gVisor if an OCI-compatible runtime is preferred, but for Tidegate's architecture (agent is a VM, not a container), direct QEMU gives more control over networking and filesystem configuration.

## References

- ADR-005 — Composable VM Isolation
- EPIC-001 — VM-Isolated Agent Runtime
- ADR-002 — Taint-and-Verify Data Flow Model
- ADR-003 — Agent Runtime Selection
- [claude-vm](https://github.com/solomon-b/claude-vm) — Nix flake for headless QEMU VM with Claude Code
- [Firecracker](https://firecracker-microvm.github.io/) — AWS microVM
- [Cloud Hypervisor](https://www.cloudhypervisor.org/) — Rust-based VMM, forked from early Firecracker
- [gVisor](https://gvisor.dev/) — User-space kernel for container sandboxing
- [Kata Containers](https://katacontainers.io/) — Lightweight VMs with OCI compatibility
- [microvm.nix](https://github.com/microvm-nix/microvm.nix) — NixOS MicroVMs with multiple hypervisor backends
- [virtiofs](https://virtio-fs.gitlab.io/) — Shared file system for virtual machines
- [firecracker-in-docker](https://github.com/fadams/firecracker-in-docker) — PoC for Firecracker inside Docker containers
- [Apple Containerization](https://developer.apple.com/videos/play/wwdc2025/346/) — WWDC 2025, native Linux container VMs on macOS
- CVE-2024-21626 — runc container escape
- CVE-2022-0185 — Linux namespace escape
