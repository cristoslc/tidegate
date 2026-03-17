---
title: "macOS VM Launcher Evaluation"
artifact: SPIKE-018
status: Complete
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
question: "Can an existing VM management tool (Lima, vfkit, or equivalent) replace the custom launcher proposed in SPEC-001 on macOS?"
parent-epic: EPIC-001
gate: Pre-SPEC-001 implementation
risks-addressed:
  - Building a custom launcher when a mature open-source tool already provides the required primitives
  - Maintaining custom libkrun C API bindings when Lima/vfkit abstract them
supersedes:
  - SPIKE-015
depends-on: []
blocks:
  - SPEC-001 implementation approach decision
trove: ""
linked-artifacts:
  - EPIC-001
  - SPEC-001
  - SPIKE-015
  - SPIKE-017
  - SPIKE-019
---
# SPIKE-018: macOS VM Launcher Evaluation

## Question

SPEC-001 proposes a custom `tidegate vm start` CLI that orchestrates libkrun + gvproxy + virtiofs on macOS. SPIKE-015 evaluated VM technologies broadly; SPIKE-017 validated virtio-net routing on macOS. This spike asks the narrower question: **does an existing tool already do what SPEC-001 describes, eliminating the need for a custom launcher on macOS?**

Scoped to macOS Apple Silicon only. Linux is covered by SPIKE-019.

## Go / No-Go Criteria

**Go (adopt existing tool):** An open-source tool (Apache-2.0 or equivalent) can:

1. Boot a Linux VM on macOS Apple Silicon with virtio-net networking (not just NAT/TSI) in <5 seconds.
2. Mount a host directory into the VM via virtiofs.
3. Inject environment variables (`HTTP_PROXY`, `HTTPS_PROXY`, `TIDEGATE_GATEWAY`) into the guest.
4. Allow Tidegate to control egress routing (traffic through proxy, not direct internet).
5. Be driven programmatically (CLI or API) — not just interactive.
6. Support a custom/minimal guest image (not locked to a specific distro).

All six must pass. If any fail, a custom launcher (or a thin wrapper) is still needed.

**No-go pivot:** If no tool meets all six criteria, identify the tool that covers the most and document what thin wrapping is needed on top.

## Candidates Evaluated

### 1. Lima v2.0 (CNCF Incubating, Apache-2.0)

Lima wraps both Apple Virtualization.framework (`vmType: vz`) and libkrun (`vmType: krunkit`) as VM backends on macOS. v2.0 (Nov 2025) explicitly added AI agent sandboxing as a use case.

**Criterion assessment:**

| # | Criterion | Lima `vz` | Lima `krunkit` |
|---|-----------|-----------|----------------|
| 1 | virtio-net, <5s boot | vzNAT (real IP, no gvproxy needed), ~3-5s | Via gvproxy, ~1-2s |
| 2 | virtiofs host mount | Native VZVirtioFileSystemDeviceConfiguration | libkrun built-in virtiofs |
| 3 | Env var injection | Cloud-init, `PARAM_*` env vars, boot/provisioning scripts | Same |
| 4 | Egress control | Via guest provisioning (proxy env vars + iptables) or Squid integration (documented pattern) | Same, plus Seatbelt on gvproxy per SPIKE-017 |
| 5 | Programmatic CLI | `limactl start/stop/shell/copy`, YAML-based VM definitions | Same |
| 6 | Custom guest image | Yes — arbitrary disk images, cloud-init provisioned | Yes |

**Lima-specific features relevant to Tidegate:**
- YAML template system for declarative VM definitions
- MCP tools for sandboxed file read/write/exec inside the VM
- Documented Squid egress proxy pattern (matches `src/egress-proxy/`)
- VM state save/restore (skip boot initialization on restart)
- Community `lima-devbox` Claude skill already exists
- CNCF Incubating — active maintenance, not a personal project

**Concerns:**
- vzNAT networking gives the VM a real IP reachable from host, but it's NAT — not a bridge to Docker's `agent-net`. Same topology constraint as SPIKE-017's Topology A (published ports).
- krunkit backend on Lima is marked "experimental." GPU passthrough is the primary use case, not agent sandboxing.
- First boot requires provisioning (cloud-init): 30-60s. Subsequent starts: 5-15s (vz) or 1-2s (krunkit). The first-boot cost can be amortized by pre-provisioning the image.
- Lima v2.0 krunkit backend networking details are unclear — may not expose all gvproxy configuration options.

### 2. vfkit (Red Hat, Apache-2.0)

CLI wrapping Apple Virtualization.framework. Used by Podman and minikube on macOS.

| # | Criterion | Assessment |
|---|-----------|------------|
| 1 | virtio-net, <5s boot | `--device virtio-net,unixSocketPath=...` for gvproxy; NAT also available. Boot depends on guest image. |
| 2 | virtiofs | `--device virtio-fs,sharedDir=/path,mountTag=tag` |
| 3 | Env var injection | No built-in. Must use kernel cmdline, cloud-init, or init script. |
| 4 | Egress control | Via gvproxy unix socket — same Seatbelt pattern as SPIKE-017. |
| 5 | Programmatic CLI | Yes, but lower-level than Lima. No YAML templates, no provisioning. |
| 6 | Custom guest image | Yes — boots raw/qcow2 disk images. |

**Assessment:** vfkit provides the same primitives as krunkit but backed by Virtualization.framework. It's more mature (used in production by Podman) but requires more wrapping than Lima — you'd still need to build the gvproxy orchestration, provisioning, and env injection yourself. It's essentially the same amount of custom work as wrapping krunkit directly.

### 3. krunkit (containers project, Apache-2.0)

Already evaluated in SPIKE-017. Provides virtio-net + virtiofs + vsock on macOS. Lacks OCI handling, env injection, and provisioning. Podman's `pkg/machine/libkrun/stubber.go` is the reference for orchestrating krunkit + gvproxy.

### 4. Apple Containerization Framework (Apple, Apache-2.0)

Per-container VMs via Virtualization.framework. Sub-second boot, native virtiofs, OCI image support.

| # | Criterion | Assessment |
|---|-----------|------------|
| 1-6 | All | Promising, but **requires macOS 26** (not yet stable). Proxy support is limited — `HTTP_PROXY`/`HTTPS_PROXY` env vars not respected for network config ([issue #156](https://github.com/apple/container/issues/156)). |

**Assessment:** Not viable today. Revisit when macOS 26 ships and proxy support is resolved. Long-term, this could be the ideal macOS path.

### 5. microsandbox (Apache-2.0)

libkrun-based, <200ms boot, OCI-compatible. No documented proxy egress control. Experimental (4.7k stars). Interesting but too immature and missing egress control.

### 6. Lume / Cua (open source)

macOS VM management via Virtualization.framework. NAT-only networking (no gvproxy integration). No egress control. Focused on GUI agents (screen control), not coding agent isolation.

### Not evaluated (not macOS)

- Firecracker, Cloud Hypervisor, crosvm, Kata Containers, crun/krun — all Linux/KVM only. See SPIKE-019.

## Findings

### Comparison matrix

| Tool | Criteria met | Missing | Custom work needed |
|------|-------------|---------|-------------------|
| **Lima v2.0 (vz)** | 1,2,3,5,6 | 4 (egress control is guest-side only, no kernel enforcement from outside VM) | Squid/Seatbelt integration, Lima YAML template |
| **Lima v2.0 (krunkit)** | 1,2,3,5,6 | 4 (same, but Seatbelt-on-gvproxy from SPIKE-017 applies) | Lima YAML template, gvproxy Seatbelt wrapper |
| **vfkit** | 1,2,4,6 | 3 (no env injection), 5 (low-level) | Provisioning, env injection, gvproxy orchestration |
| **krunkit** | 1,2,4,6 | 3 (no env injection), 5 (low-level) | Same as vfkit |
| **Apple Containerization** | — | Requires macOS 26, no proxy support | Wait |

### Key insight: Lima is a wrapper, not a replacement

Lima wraps krunkit (or vfkit/QEMU). Using "Lima instead of a custom launcher" means using Lima's orchestration (YAML templates, cloud-init, lifecycle management) instead of writing your own krunkit orchestration. The underlying VM technology is the same.

What Lima provides that a custom launcher would need to build:
- VM lifecycle management (create, start, stop, delete)
- Cloud-init provisioning (user setup, package install, env vars)
- virtiofs mount configuration via YAML
- Multiple networking backends with consistent configuration
- State save/restore

What Lima does NOT provide that Tidegate still needs:
- Seatbelt-wrapped gvproxy for kernel-enforced egress control (SPIKE-017 pattern)
- Integration with Tidegate's `tidegate.yaml` config
- The `tidegate vm start` CLI surface itself (Lima's CLI is `limactl`)

### Architecture options

**Option A: Lima as the VM backend, thin `tidegate vm` wrapper**

```
tidegate vm start
  → reads tidegate.yaml
  → generates Lima YAML template (VM config, mounts, env vars)
  → limactl start --name tidegate-agent tidegate.yaml
  → wraps gvproxy in Seatbelt (SPIKE-017 pattern)
```

Custom code: ~200 LOC shell/Python to generate Lima YAML and manage Seatbelt. Delegates all VM plumbing to Lima.

**Option B: krunkit directly, custom orchestration**

```
tidegate vm start
  → reads tidegate.yaml
  → starts gvproxy (Seatbelt-wrapped)
  → starts krunkit with virtio-net + virtiofs + disk image
  → injects env vars via virtiofs-shared config file
```

Custom code: ~500 LOC Rust or shell. Reference: Podman's `pkg/machine/libkrun/stubber.go`.

**Option C: vfkit directly, custom orchestration**

Same as Option B but with vfkit instead of krunkit. Slightly more mature, available via `brew install vfkit`.

### Recommendation

**Option A (Lima wrapper) is the lowest-risk path.** Lima is CNCF Incubating, actively maintained, and already solves the VM lifecycle, provisioning, and virtiofs orchestration problems. The custom work is limited to:

1. A Lima YAML template for the Tidegate agent VM
2. A thin `tidegate vm` CLI that generates the template from `tidegate.yaml` and invokes `limactl`
3. Seatbelt-wrapped gvproxy for egress enforcement (already validated in SPIKE-017)

This reframes SPEC-001 from "build a VM launcher" to "build a Lima integration layer."

**Risk:** Lima's krunkit backend is experimental. If it proves unstable, fall back to `vmType: vz` (slightly slower boot, but production-quality) or Option B (krunkit directly).

### Validation of prior spike findings

| Prior finding | Still valid? | Notes |
|---------------|-------------|-------|
| SPIKE-015: Cloud Hypervisor recommended for Linux | Yes | Covered by SPIKE-019 |
| SPIKE-015: libkrun recommended for macOS | Yes | Lima wraps libkrun via krunkit backend |
| SPIKE-017: gvproxy + Seatbelt for egress enforcement | Yes | Applies regardless of Lima vs custom launcher |
| SPIKE-017: Published ports topology (Topology A) | Yes | Lima doesn't change the Docker networking constraint |
| SPIKE-017: Custom launcher required | **Partially superseded** | Lima reduces custom work from "build a launcher" to "build a Lima integration layer" |

## References

- [EPIC-001](../../../epic/Abandoned/(EPIC-001)-VM-Isolated-Agent-Runtime/(EPIC-001)-VM-Isolated-Agent-Runtime.md) — Parent epic requesting macOS VM launcher evaluation
- [Lima v2.0 — CNCF Blog](https://www.cncf.io/blog/2025/12/11/lima-v2-0-new-features-for-secure-ai-workflows/)
- [Lima krunkit docs](https://lima-vm.io/docs/config/vmtype/krunkit/)
- [Lima network docs](https://lima-vm.io/docs/config/network/)
- [Lima AI agent sandboxing](https://lima-vm.io/docs/config/ai/outside/)
- [lima-devbox Claude skill](https://github.com/recodelabs/lima-devbox)
- [vfkit GitHub](https://github.com/crc-org/vfkit)
- [vfkit usage docs](https://github.com/crc-org/vfkit/blob/main/doc/usage.md)
- [krunkit GitHub](https://github.com/containers/krunkit)
- [Apple Containerization](https://github.com/apple/containerization)
- [Apple container proxy issue #156](https://github.com/apple/container/issues/156)
- [microsandbox](https://github.com/zerocore-ai/microsandbox)
- [Lume / Cua](https://github.com/trycua/cua)
- [Podman machine libkrun stubber](https://github.com/containers/podman/blob/main/pkg/machine/libkrun/stubber.go)
- [Claude Cowork architecture](https://claudecn.com/en/blog/claude-cowork-architecture/) — validates VM + proxy + workspace mount pattern
- [Sandbox AI dev tools with Lima](https://www.metachris.dev/2025/11/sandbox-your-ai-dev-tools-a-practical-guide-for-vms-and-lima/)
- SPIKE-015: Evaluate VM Isolation for Agent Container
- SPIKE-017: Validate libkrun virtio-net macOS

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-03-13 | 65c695e | Supersedes SPIKE-015 for macOS scope; populated with research findings |
| Complete | 2026-03-13 | 1a52155 | Lima v2.0 recommended; reframes SPEC-001 for macOS |
