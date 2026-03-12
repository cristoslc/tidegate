---
artifact: SPIKE-015
title: "SPIKE-015: Evaluate VM Isolation for Agent Container"
status: Active
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

## References

- ADR-005 — Composable VM Isolation
- EPIC-001 — VM-Isolated Agent Runtime
- ADR-002 — Taint-and-Verify Data Flow Model
- ADR-003 — Agent Runtime Selection
- [claude-vm](https://github.com/solomon-b/claude-vm) — Nix flake for headless QEMU VM with Claude Code
- [Firecracker](https://firecracker-microvm.github.io/) — AWS microVM
- CVE-2024-21626 — runc container escape
- CVE-2022-0185 — Linux namespace escape
