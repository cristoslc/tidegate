---
artifact: ADR-008
title: "libkrun as Single VMM for Agent Isolation"
status: Proposed
author: cristos
created: 2026-03-12
last-updated: 2026-03-12
linked-epics:
  - EPIC-001
linked-specs: []
depends-on:
  - ADR-005
evidence-pool: ""
---

# libkrun as Single VMM for Agent Isolation

## Context

ADR-005 decided that Tidegate uses a microVM for agent containment (post-MVP) while keeping infrastructure services in Docker. It deliberately deferred the VMM technology choice to SPIKE-015.

SPIKE-015 evaluated 11+ candidates across two rounds of research. The first round recommended a dual-path strategy: Cloud Hypervisor on Linux (~200-400ms boot) and Apple Containerization on macOS 26+ (~200-300ms). The second round, prompted by relaxing the boot time target to <2s, revealed that libkrun/krunvm occupies a unique position in the candidate set:

- **Only cross-platform VMM** with full VM isolation (KVM on Linux, HVF on macOS Apple Silicon)
- **virtiofs on both platforms** — workspace mounting solved everywhere
- **OCI-compatible** — guest image is a container image, no custom image pipeline
- **Production-validated** — Podman 5.0+ uses libkrun for its macOS VM backend

The dual-path strategy saves ~1s of boot time but doubles the integration and testing surface. Two VMMs means two networking models, two image pipelines, two sets of bugs, and platform-specific code paths through EPIC-001. For a single-tenant security product, engineering simplicity matters more than sub-second boot optimization.

### The boot time question

libkrun cold boot to app-ready is ~1-2s. The OCI layer extraction dominates — the VMM itself initializes fast, but unpacking the container image into the guest rootfs takes time. By comparison:

- Cloud Hypervisor: ~200-400ms (but no macOS, requires separate image pipeline)
- Firecracker: ~150-350ms (but no virtiofs, no macOS)
- Apple Containerization: ~200-300ms (but macOS 26+ only, not yet released)

For Tidegate's use case — an agent session running minutes to hours — a 1-2s boot is noise. The user starts a session, waits 1-2s, then works for 30 minutes. If boot time becomes a bottleneck for future multi-tenant or session-per-task deployments, Cloud Hypervisor can be added as an optimized Linux backend without changing the agent interface (per ADR-005's transport-based design).

### The networking question

libkrun offers two networking modes:

1. **TSI (Transparent Socket Impersonation)**: Intercepts guest socket calls and maps them to host sockets. Fast, zero-config. **But it bypasses Tidegate's network topology entirely** — guest `connect()` becomes a host `connect()`, never hitting the gateway on port 4100 or the egress proxy. Incompatible with Tidegate's architecture.

2. **virtio-net via passt/gvproxy**: Conventional virtual network interface. Guest traffic traverses a virtual NIC, routable through Docker bridge to reach the gateway and egress proxy. Compatible with Tidegate's topology.

Tidegate must use virtio-net mode and explicitly disable TSI. This is a supported configuration (Podman uses virtio-net for bridged networking), but **macOS + virtio-net + Docker bridge routing has not been validated end-to-end**. SPIKE-017 covers this validation.

## Decision

**libkrun/krunvm is the single VMM for agent isolation across all platforms (Linux and macOS).**

Specifically:

1. **One VMM, all platforms.** libkrun with KVM on Linux and HVF on macOS Apple Silicon. No platform-specific VMM code paths.

2. **OCI guest image.** The agent guest image is built as a standard container image (Dockerfile). krunvm launches it directly. Image contains: minimal Alpine base, Node.js 18+, Python 3.11+, git, Claude Code CLI, tg-scanner daemon. Same image, both platforms.

3. **virtio-net networking (not TSI).** TSI is disabled. Guest traffic flows through a virtual NIC, bridged to Docker's `agent-net`, reaching the gateway at port 4100 and egress via the proxy. This preserves Tidegate's network control plane.

4. **virtiofs for workspace mounting.** Project directory mounted read-only via virtiofs. IPC directory mounted read-write. Performance within 2x of native Docker bind mounts (per SPIKE-015 benchmarks).

5. **Guest-side tg-scanner.** Per SPIKE-015 finding: host-side eBPF/seccomp-notify cannot observe guest syscalls across the hypervisor boundary. The tg-scanner daemon runs inside the guest with eBPF on `openat` and seccomp-notify on `connect()`, identical to the Docker deployment architecture (ADR-002). The VM boundary means a guest kernel exploit is required to bypass it — which is the exact attack the VM prevents.

6. **`tidegate vm start` launcher.** A shell script that: pulls/verifies the OCI guest image, starts virtiofsd, launches krunvm with virtio-net + virtiofs configuration, waits for guest ready signal. Target: <5s end-to-end including image verification.

### What this does not decide

- **Snapshot/restore**: libkrun does not currently support snapshot/restore. If session startup latency becomes critical, this ADR does not preclude adding Cloud Hypervisor as an optimized backend for Linux server deployments. ADR-005's transport-based interface means the VMM is swappable without changing gateway or proxy code.
- **Intel Mac support**: libkrun requires Apple Silicon (HVF) on macOS. Intel Macs fall back to Docker containers (accepted risk per ADR-005).

## Alternatives Considered

| Alternative | Why not chosen |
|---|---|
| **Dual-path: Cloud Hypervisor (Linux) + Apple Containerization (macOS)** | Saves ~1s boot time but doubles integration surface. Two VMMs, two networking models, two image pipelines. Apple Containerization requires macOS 26 (not yet released). Engineering cost outweighs boot time benefit for single-tenant use. |
| **Cloud Hypervisor everywhere** | No macOS support. Would require a separate macOS solution, recreating the dual-path problem. |
| **Firecracker everywhere** | No virtiofs (dealbreaker for workspace mounting). No macOS support. |
| **QEMU microvm everywhere** | Viable but more moving parts (QEMU process overhead, manual image management, less OCI integration). libkrun is a smaller, purpose-built VMM with better OCI ergonomics. |
| **gVisor everywhere** | No eBPF support blocks ADR-002 taint tracking. Weaker isolation (user-space kernel, not full VM). Linux-only. |
| **Kata Containers** | Full VM isolation with OCI compatibility, but Linux-only and more complex setup than libkrun for comparable isolation. |
| **Stay with Docker containers** | Already the MVP default (ADR-005). This ADR selects the technology for the post-MVP hardening layer. |

## Consequences

### Positive

- **Single integration path** for EPIC-001. One VMM, one image format, one networking model, one test matrix.
- **macOS support today**, not dependent on macOS 26 release timeline.
- **OCI compatibility** eliminates custom image pipeline — standard Dockerfile, standard registry, standard tooling.
- **virtiofs everywhere** — workspace mounting works identically on Linux and macOS.
- **Podman ecosystem validation** — libkrun is not experimental; it's Podman's production macOS backend.

### Negative

- **1-2s cold boot** vs ~200-400ms with Cloud Hypervisor. Acceptable for interactive sessions, potentially slow for session-per-task patterns.
- **No snapshot/restore** — cold boot every session. Cannot pre-warm VMs from snapshots.
- **TSI must be disabled** — the more ergonomic networking mode is incompatible with Tidegate's proxy routing. virtio-net via passt adds a small performance overhead.
- **Intel Mac fallback to Docker** — users on Intel Macs don't get VM isolation. Acceptable given Apple Silicon adoption trajectory.
- **Younger project than QEMU/Firecracker** — smaller community, fewer production war stories outside Podman.

### Validation required

- **SPIKE-017**: Validate virtio-net mode with passt on macOS, routing through Docker bridge to gateway:4100 and egress proxy. This is the critical path — if it doesn't work, the networking assumption fails and we need to revisit.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Proposed | 2026-03-12 | — | SPIKE-015 findings (expanded); depends on SPIKE-017 networking validation |
