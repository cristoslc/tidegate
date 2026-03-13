---
title: "Linux VM Launcher Evaluation"
artifact: SPIKE-019
status: Complete
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

## Findings

### Tier 1: VMM evaluation

#### Cloud Hypervisor (Linux Foundation, Apache-2.0 + BSD-3)

- **Boot time:** ~200ms to kernel ready. ~50k lines Rust (vs QEMU's ~2M lines C).
- **virtiofs:** Supported but **requires external `virtiofsd` daemon** (Rust implementation from `gitlab.com/virtio-fs/virtiofsd`). Two-process model:
  1. `virtiofsd --socket-path=/tmp/virtiofs --shared-dir=/workspace --cache=never`
  2. `cloud-hypervisor --memory size=4G,shared=on --fs tag=myfs,socket=/tmp/virtiofs`
  3. Guest: `mount -t virtiofs myfs /workspace`
  The `shared=on` memory flag is mandatory for virtiofsd to access guest RAM.
- **Snapshot/restore + virtiofs: BROKEN.** Issue [#6931](https://github.com/cloud-hypervisor/cloud-hypervisor/issues/6931) — VM hangs on restore when virtiofs is attached. PR #7104 attempted a fix but issue remains open. Migration to `fuse-backend-rs` ([#7250](https://github.com/cloud-hypervisor/cloud-hypervisor/issues/7250)) could fix this by eliminating external virtiofsd.
- **Networking:** `--net "tap=<name>,mac=..."` or `--net fd=<N>` for pre-created TAP FDs. Needs `CAP_NET_ADMIN` or pre-created TAPs.
- **Programmatic API:** Full REST API over Unix socket (OpenAPI 3.0). Endpoints for create, boot, shutdown, add-net, add-fs, pause/resume, snapshot/restore, delete. Rust client crate available.
- **Custom images:** Direct kernel boot (`--kernel vmlinux --cmdline "..."`) + disk image. Raw and qcow2.
- **Env var injection:** Via `--cmdline` kernel args or virtiofs-shared config file.

**Assessment:** Strongest raw VMM. Meets criteria 1 (boot <2s), 2 (TAP bridge), 3 (virtiofs), 5 (REST API), 6 (custom image). Needs ~200 LOC wrapper for virtiofsd lifecycle, TAP setup, and config injection.

#### Firecracker (AWS, Apache-2.0)

- **Boot time:** ~125ms (fastest VMM). VMM init ~3ms.
- **virtiofs: Permanently rejected.** Issue [#1180](https://github.com/firecracker-microvm/firecracker/issues/1180) closed 2020. PR #1351 closed without merge. Outside Firecracker's threat model.
- **Workspace mounting:** virtio-blk only. Must pre-build ext4 image with workspace contents. No live host-to-guest filesystem sharing. Rebuild on every workspace change — unacceptable for interactive agent editing.
- **Networking:** TAP-based, bridgeable. Well-documented.

**Assessment: Disqualified.** No virtiofs = no live workspace mounting. Block device workaround does not support bidirectional real-time file sharing.

#### QEMU microvm (GPL-2.0)

- **Boot time:** ~300-500ms. ~3x slower than Firecracker, ~1.5x slower than Cloud Hypervisor.
- **virtiofs:** Full support via `vhost-user-fs-pci` device. Same external virtiofsd. Can boot directly from virtiofs root.
- **Programmatic API:** QMP (JSON over Unix socket). More complex than Cloud Hypervisor's REST.

**Assessment:** Viable but worse than Cloud Hypervisor on every dimension. GPL license, slower, more complex CLI, larger attack surface.

#### libkrun on Linux (KVM mode, Apache-2.0)

- **Boot time:** Sub-second, estimated ~200-500ms. No published benchmarks.
- **virtiofs: Built-in.** Major differentiator — no external virtiofsd daemon. `krun_set_root()` + `krun_add_virtiofs()`. Init binary also embedded.
- **Networking:** TSI (default, no virtio-net) or virtio-net via passt/gvproxy (Unix socket). **No direct TAP interface** — must use gvproxy, which adds a NAT hop.
- **Programmatic API:** C API (`libkrun.h`). Rust bindings available.
- **Cross-platform:** Same codebase on Linux (KVM) and macOS (HVF). This is the same VMM SPIKE-018 recommends via krunkit on macOS.

**Assessment: Most architecturally consistent.** Same launcher code on both platforms. Built-in virtiofs simplifies deployment. Tradeoff: no direct TAP bridge (gvproxy routing only), which means egress enforcement follows the same gvproxy pattern as macOS.

### Tier 2: Orchestrator evaluation

#### Kata Containers (Apache-2.0)

- Works standalone: `docker run --runtime=kata-clh` (no K8s needed).
- Supports Cloud Hypervisor backend. virtiofs via external virtiofsd.
- **Networking:** Creates TAP + bridge, but configuration for a specific Docker bridge is complex.
- **Overhead:** Pulls in containerd dependency, TOML configuration layer, OCI runtime spec compliance.

**Assessment: Not recommended.** Over-engineered for single-VM use case. Networking model doesn't naturally map to "VM on a Docker bridge with controlled egress."

#### Lima on Linux (Apache-2.0)

- Only backend on Linux is **QEMU**. No Cloud Hypervisor, no libkrun.
- Lima's value on macOS is wrapping Virtualization.framework. On Linux, it's just a QEMU wrapper with cloud-init.

**Assessment: Not recommended.** Lima on Linux = QEMU with extra overhead. Different VMM than macOS path, defeating the consistency argument.

#### crun/krun (Apache-2.0)

- `podman run --runtime=krun` boots libkrun microVM.
- **Uses TSI by default.** No TAP, no bridge, no egress routing control.

**Assessment: Not recommended.** TSI doesn't support controlled egress routing.

#### Flintlock (MPL-2.0)

- Still maintained but lost corporate sponsor (Weaveworks shutdown).
- gRPC API, requires containerd. Designed for multi-VM K8s node provisioning.

**Assessment: Not recommended.** Over-engineered, uncertain future.

### Sub-question answers

#### SQ1: TAP-to-Docker bridge on Linux

**Yes, this works.** Steps:

```sh
# Create Docker network (creates Linux bridge br-<hash>)
docker network create --driver bridge agent-net
BRIDGE=$(docker network inspect agent-net -f '{{(index .Options "com.docker.network.bridge.name")}}')

# Create TAP, attach to Docker bridge
sudo ip tuntap add dev tap-agent mode tap
sudo ip link set tap-agent up
sudo ip link set tap-agent master $BRIDGE

# Boot Cloud Hypervisor with TAP
cloud-hypervisor --net "tap=tap-agent,mac=AA:BB:CC:DD:EE:01"
```

VM gets IP on Docker bridge subnet. Reaches containers on `agent-net` directly. **Eliminates the NAT/port-publishing workaround needed on macOS.**

**Caveat:** Docker's IPAM doesn't know about the VM's IP. Must statically assign an IP outside Docker's allocation range.

#### SQ2: Cloud Hypervisor virtiofs + snapshot

**Broken.** Issue #6931 confirms VM hangs on restore with virtiofs. Snapshot/restore only works without virtiofs currently. Migration to `fuse-backend-rs` may fix this.

#### SQ3: Egress enforcement on Linux

Without macOS Seatbelt, the primary option is **nftables on the host TAP:**

```sh
# Default deny on TAP outbound
nft add rule inet filter forward iifname "tap-agent" drop
# Allow only gateway and proxy
nft add rule inet filter forward iifname "tap-agent" ip daddr <gateway-ip> tcp dport 4100 accept
nft add rule inet filter forward iifname "tap-agent" ip daddr <proxy-ip> tcp dport 3128 accept
```

This is the Linux-native equivalent of Seatbelt egress enforcement. Kernel-enforced, outside VM trust boundary, performant.

Other options: network namespace isolation, eBPF/XDP on TAP, gvproxy-in-container.

#### SQ4: Consistency vs optimization

| Factor | libkrun (both platforms) | Cloud Hypervisor (Linux) + Lima/krunkit (macOS) |
|--------|------------------------|-------------------------------------------------|
| Launcher codebase | One | Two (divergent) |
| virtiofs | Built-in (no daemon) | External virtiofsd on Linux |
| Networking | gvproxy (both) | TAP bridge (Linux), gvproxy (macOS) |
| Egress enforcement | gvproxy-in-container or nftables | nftables on TAP (Linux), Seatbelt on gvproxy (macOS) |
| Boot time | ~200-500ms | ~200ms (Cloud Hypervisor) |
| Maintenance | 1 VMM | 2 VMMs |

**Recommendation: libkrun on both for initial implementation.** Consistency benefit is substantial. If Linux-specific needs emerge (TAP bridging, sub-200ms boot), Cloud Hypervisor can be added as a second backend behind the same CLI interface.

#### SQ5: virtiofs performance on Linux

On native Linux KVM (not macOS VM-in-VM), virtiofs with DAX approaches native filesystem performance. Without DAX, it performs like a high-performance FUSE filesystem — more than adequate for agent workspace use (editing source files, running builds).

libkrun's built-in virtiofs avoids the two-process coordination complexity of Cloud Hypervisor's external virtiofsd.

### Go / No-Go assessment

| # | Criterion | Cloud Hypervisor | libkrun |
|---|-----------|-----------------|---------|
| 1 | Boot <2s | ~200ms GO | ~200-500ms GO |
| 2 | Bridge to Docker or route through gateway | TAP bridge GO | gvproxy routing GO |
| 3 | virtiofs | External daemon GO | Built-in GO |
| 4 | Env var injection | Kernel cmdline GO | C API GO |
| 5 | Programmatic API | REST API GO | C/Rust API GO |
| 6 | Custom image | Direct kernel boot GO | disk + virtiofs GO |

**Both candidates meet all six criteria.** No existing orchestrator provides a turnkey solution — a thin wrapper (~200 LOC) is needed regardless.

### Comparison matrix

| Candidate | License | Boot | virtiofs | TAP bridge | API | SPEC-001 fit |
|-----------|---------|------|----------|------------|-----|-------------|
| **Cloud Hypervisor** | Apache-2.0 | ~200ms | External daemon | Direct | REST | Thin wrapper |
| **Firecracker** | Apache-2.0 | ~125ms | **NO** | Direct | REST | **Disqualified** |
| **QEMU microvm** | GPL-2.0 | ~300-500ms | External daemon | Direct | QMP | Viable but inferior |
| **libkrun** | Apache-2.0 | ~200-500ms | **Built-in** | gvproxy only | C/Rust | **Same as macOS** |
| **Kata** | Apache-2.0 | ~200-500ms | External daemon | Configurable | OCI | Over-engineered |
| **Lima (Linux)** | Apache-2.0 | ~1-3s | External daemon | N/A | CLI | Wrong backend |
| **crun/krun** | Apache-2.0 | ~200-500ms | Built-in | TSI only | OCI | No egress control |
| **Flintlock** | MPL-2.0 | ~200-500ms | N/A | Direct | gRPC | Over-engineered |

### Recommendation

**Primary: libkrun on both macOS and Linux.** One launcher codebase, built-in virtiofs, same gvproxy networking, Apache-2.0. Egress enforcement via nftables (Linux) or Seatbelt (macOS) on the gvproxy process.

**Fallback: Cloud Hypervisor on Linux** if requirements diverge (TAP bridging needed for multi-container topology, sub-200ms boot, REST API management). ~200 LOC wrapper + external virtiofsd.

**Disqualified:** Firecracker (no virtiofs), QEMU microvm (GPL, slower), Kata (over-engineered), Lima on Linux (wrong backend), crun/krun (no egress), Flintlock (over-engineered).

### Impact on SPEC-001

SPIKE-018 recommends Lima as the macOS orchestration layer. This spike finds no equivalent orchestrator for Linux — Lima on Linux uses QEMU (wrong VMM), Kata is over-engineered. The options are:

**Option A: libkrun on both, Lima on macOS only.** macOS uses Lima + krunkit (SPIKE-018). Linux uses a thin custom wrapper around libkrun directly. The wrapper is ~200 LOC since libkrun's built-in virtiofs eliminates the virtiofsd daemon management. Different orchestration layers but same VMM.

**Option B: libkrun on both, custom wrapper on both.** Skip Lima, write one cross-platform launcher using libkrun's C/Rust API. Simpler architecture but loses Lima's provisioning/lifecycle features on macOS.

**Option C: libkrun on macOS (via Lima), Cloud Hypervisor on Linux (custom wrapper).** Best-of-breed per platform. Two VMMs, two wrappers, more maintenance.

**Recommended: Option A.** It combines SPIKE-018's Lima recommendation (macOS) with this spike's finding that libkrun is the best Linux VMM for consistency. The Linux wrapper is minimal because libkrun's built-in virtiofs eliminates the biggest orchestration burden.

## References

- SPIKE-015: Evaluate VM Isolation for Agent Container (Cloud Hypervisor recommendation)
- SPIKE-018: macOS VM Launcher Evaluation (parallel spike)
- [Cloud Hypervisor](https://www.cloudhypervisor.org/)
- [Cloud Hypervisor API docs](https://intelkevinputnam.github.io/cloud-hypervisor-docs-HTML/docs/api.html)
- [Cloud Hypervisor virtiofs docs](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/fs.md)
- [Cloud Hypervisor snapshot/virtiofs issue #6931](https://github.com/cloud-hypervisor/cloud-hypervisor/issues/6931)
- [Cloud Hypervisor TAP FD discussion #2514](https://github.com/cloud-hypervisor/cloud-hypervisor/discussions/2514)
- [Firecracker](https://firecracker-microvm.github.io/)
- [Firecracker virtiofs rejection #1180](https://github.com/firecracker-microvm/firecracker/issues/1180)
- [Kata Containers](https://katacontainers.io/)
- [Kata with Cloud Hypervisor](https://katacontainers.io/blog/kata-containers-with-cloud-hypervisor/)
- [libkrun KVM mode](https://github.com/containers/libkrun)
- [libkrun architecture (DeepWiki)](https://deepwiki.com/containers/libkrun/3-architecture-overview)
- [RamaLama + libkrun (Red Hat)](https://developers.redhat.com/articles/2025/07/02/supercharging-ai-isolation-microvms-ramalama-libkrun)
- [crun/krun](https://github.com/containers/crun/blob/main/krun.1.md)
- [Lima on Linux](https://lima-vm.io/docs/config/vmtype/)
- [E2B Firecracker sandboxes](https://e2b.dev/)
- [E2B OverlayFS scaling](https://e2b.dev/blog/scaling-firecracker-using-overlayfs-to-save-disk-space)
- [Flintlock microVM management](https://github.com/liquidmetal-dev/flintlock)
- [RunCVM](https://github.com/newsnowlabs/runcvm)
- [virtiofsd Rust crate](https://crates.io/crates/virtiofsd)
- [TAP and bridge networking on Linux](https://dev.to/krjakbrjak/setting-up-vm-networking-on-linux-bridges-taps-and-more-2bbc)
- [nftables (ArchWiki)](https://wiki.archlinux.org/title/Nftables)

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
| Active | 2026-03-13 | 1a52155 | Begin Linux/KVM investigation |
