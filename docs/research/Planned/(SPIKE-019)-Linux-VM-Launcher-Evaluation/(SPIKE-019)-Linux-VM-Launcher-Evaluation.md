---
title: "Linux VM Launcher Evaluation"
artifact: SPIKE-019
status: Planned
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
question: "Can an existing VM management tool replace a custom launcher for SPEC-001 on Linux (KVM)?"
parent-epic: EPIC-001
gate: Pre-SPEC-001 Linux support
risks-addressed:
  - Building a custom KVM launcher when mature VMMs (Cloud Hypervisor, Firecracker) or orchestrators (Kata, Lima) already solve the problem
  - Assuming macOS and Linux need the same launcher architecture
depends-on: []
blocks:
  - SPEC-001 Linux support decision
evidence-pool: ""
---

# SPIKE-019: Linux VM Launcher Evaluation

## Question

SPIKE-018 evaluates macOS VM launcher options and recommends Lima as a wrapper. Linux has a different landscape: KVM is the hypervisor, TAP networking can bridge directly to Docker networks (no port-publishing workaround), and fast VMMs like Cloud Hypervisor and Firecracker are available. **Does an existing tool provide what SPEC-001 needs on Linux, and should the Linux path diverge from the macOS path?**

SPIKE-015 recommended Cloud Hypervisor for Linux based on boot time + virtiofs support. This spike goes deeper: evaluate whether an existing orchestration layer (not just a VMM) can replace a custom launcher.

## Go / No-Go Criteria

**Go (adopt existing tool):** An open-source tool (Apache-2.0 or equivalent) can:

1. Boot a Linux VM on a Linux KVM host with virtio-net networking in <2 seconds.
2. Bridge the VM's virtual NIC to a Docker network (`agent-net`) or otherwise route traffic through the Tidegate gateway and egress proxy.
3. Mount a host directory into the VM via virtiofs.
4. Inject environment variables (`HTTP_PROXY`, `HTTPS_PROXY`, `TIDEGATE_GATEWAY`) into the guest.
5. Be driven programmatically (CLI or API).
6. Support a custom/minimal guest image.

All six must pass.

**No-go pivot:** If no tool meets all six, identify the VMM that covers the most and document the thin orchestration layer needed on top.

## Candidates to Evaluate

### Tier 1: VMMs (need orchestration on top)

| Candidate | Boot time | virtiofs | Notes |
|-----------|-----------|----------|-------|
| **Cloud Hypervisor** | ~200-400ms | Native Rust virtiofsd | SPIKE-015 recommended. Linux Foundation. Snapshot/restore. |
| **Firecracker** | ~125ms | **No** | AWS Lambda/Fargate. Fastest boot but no virtiofs — workspace mounting is the gap. |
| **QEMU microvm** | ~300-500ms | Yes (vhost-user-fs) | Minimal device model. Flexible but more moving parts. |
| **libkrun (KVM mode)** | ~500ms-2s | Yes | Same codebase as macOS path. Slower than Cloud Hypervisor but cross-platform. |

### Tier 2: Orchestrators (may provide launcher functionality)

| Candidate | VMM backend | Notes |
|-----------|-------------|-------|
| **Kata Containers** | Cloud Hypervisor, QEMU, Firecracker | OCI-compatible, per-container VMs. Full lifecycle management. Evaluate if it can replace a custom launcher entirely. |
| **Lima (Linux mode)** | QEMU | Lima also runs on Linux. Less mature than on macOS (no Virtualization.framework). Worth evaluating for consistency with macOS path. |
| **crun/krun** | libkrun | OCI runtime with libkrun backend. `podman run --runtime krun`. Evaluate if this provides enough control. |
| **Flintlock / ignite** | Firecracker | MicroVM management for Kubernetes. May be overkill for single-VM use case. |

### Tier 3: Cloud-native patterns (architecture reference)

| Pattern | Used by | Notes |
|---------|---------|-------|
| **Firecracker + snapshot/restore** | AWS Lambda, E2B | <50ms restore. Pre-boot VM, snapshot at app-ready, restore per session. |
| **Cloud Hypervisor + snapshot** | — | Estimated ~50-100ms restore. virtiofs compatibility with snapshots is the open question. |
| **Warm pool** | Fly Machines | Pre-boot N VMs, assign on demand. Zero perceived latency. Memory cost: N × VM RAM. |

## Sub-questions

1. **TAP-to-Docker bridge**: On Linux, can a VM's virtio-net TAP interface be bridged directly to Docker's `agent-net`? This would eliminate the NAT/port-publishing workaround needed on macOS.
2. **Kata Containers for single-VM**: Kata is designed for Kubernetes/containerd. Can it be used standalone (without K8s) to run a single agent VM with controlled networking?
3. **Cloud Hypervisor virtiofs + snapshot**: Does restoring a Cloud Hypervisor snapshot correctly reconnect to a virtiofsd instance with fresh workspace content?
4. **libkrun consistency**: If macOS uses Lima + krunkit, should Linux also use Lima + libkrun (KVM mode) for codebase consistency, even if Cloud Hypervisor is faster?
5. **Egress enforcement on Linux**: Without macOS Seatbelt, how to enforce egress? Options: iptables/nftables on host, Docker network isolation (run gvproxy in a container on `agent-net`), eBPF, network namespaces.
6. **Guest-side eBPF taint tracking**: SPIKE-015 identified that eBPF tracepoints must run inside the guest kernel (not host). Validate that a minimal guest kernel with CONFIG_BPF supports the `openat` tracepoints needed for ADR-002.

## Key Experiments

1. **Cloud Hypervisor + virtiofs + TAP**: Boot a Cloud Hypervisor VM with virtiofs workspace mount and TAP interface bridged to a Docker network. Verify gateway reachability.
2. **Kata standalone**: Install Kata Containers without Kubernetes. Run a container with `--runtime kata-runtime`. Verify networking and workspace mount.
3. **libkrun on Linux**: Boot a VM with krunvm or libkrun C API. Compare boot time and virtiofs performance to Cloud Hypervisor.
4. **Egress enforcement**: Configure iptables/nftables rules on the host to restrict the VM's TAP traffic to only gateway:4100 and proxy:3128. Verify direct internet blocked.
5. **Snapshot/restore**: Create a Cloud Hypervisor snapshot at app-ready state. Restore and verify virtiofs reconnects with current workspace content.
6. **Latency**: MCP tool call round-trip from VM vs Docker container.

## Pivot Recommendation

If no orchestrator provides full launcher functionality:
- Use Cloud Hypervisor as the VMM (fastest with virtiofs)
- Write a thin launcher shell script (~200 LOC) that starts virtiofsd, configures TAP + bridge, boots Cloud Hypervisor, and injects env vars via kernel cmdline or virtiofs-shared config
- This is the Linux equivalent of SPIKE-018's Option B

## References

- SPIKE-015: Evaluate VM Isolation for Agent Container (Cloud Hypervisor recommendation)
- SPIKE-018: macOS VM Launcher Evaluation (parallel spike)
- [Cloud Hypervisor](https://www.cloudhypervisor.org/)
- [Firecracker](https://firecracker-microvm.github.io/)
- [Kata Containers](https://katacontainers.io/)
- [libkrun KVM mode](https://github.com/containers/libkrun)
- [crun/krun](https://github.com/containers/crun/blob/main/krun.1.md)
- [E2B Firecracker sandboxes](https://e2b.dev/)
- [Flintlock microVM management](https://github.com/weaveworks-liquidmetal/flintlock)

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-03-13 | 65c695e | Parallel to SPIKE-018 (macOS); scoped to Linux/KVM |
