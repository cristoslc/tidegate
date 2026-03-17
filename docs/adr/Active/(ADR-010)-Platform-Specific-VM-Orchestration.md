---
title: "Platform-Specific VM Orchestration"
artifact: ADR-010
status: Active
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
linked-artifacts:
  - EPIC-002
linked-epics:
  - EPIC-002
linked-specs:
  - SPEC-004
  - SPEC-005
  - SPEC-006
depends-on:
  - ADR-005
trove: ""
affected-artifacts:
  - ADR-008
  - ADR-009
  - SPIKE-018
  - SPIKE-019
  - SPIKE-020
---
# Platform-Specific VM Orchestration

## Context

ADR-008 selected libkrun as the single VMM for agent isolation on both macOS (HVF) and Linux (KVM). It also prescribed a single custom shell script launcher (`tidegate vm start`) that would orchestrate krunvm + gvproxy + virtiofs identically on both platforms. That VMM selection is reaffirmed — SPIKE-018, SPIKE-019, and SPIKE-020 all confirm libkrun as the right VMM.

However, SPIKE-018 and SPIKE-019 found that the launcher architecture should differ by platform:

- **macOS:** Lima v2.0 (CNCF Incubating, Apache-2.0) wraps krunkit and provides VM lifecycle management, cloud-init provisioning, virtiofs configuration, and YAML-based declarative VM definitions. Writing a custom launcher on macOS would duplicate what Lima already does. Lima's `vmType: krunkit` backend uses the same libkrun VMM.

- **Linux:** No equivalent orchestrator exists. Lima on Linux only supports QEMU (wrong VMM). Kata Containers and crun/krun don't provide sufficient networking control. microsandbox is promising but pre-1.0 and TSI-only (no virtio-net). A thin custom wrapper around libkrun's C/Rust API (~200 LOC) is the right approach.

ADR-008 also prescribed egress enforcement mechanisms (Seatbelt on macOS, iptables on Linux). That decision has been superseded by ADR-009, which moves primary enforcement into gvproxy itself. This ADR does not revisit egress — see ADR-009.

## Decision

**The `tidegate vm start` CLI uses platform-specific orchestration layers: Lima v2.0 on macOS, a thin libkrun wrapper on Linux. The underlying VMM (libkrun) is the same on both platforms.**

Specifically:

1. **macOS (Apple Silicon, HVF):** Lima v2.0 with `vmType: krunkit`. `tidegate vm start` generates a Lima YAML template from `tidegate.yaml`, invokes `limactl start`, and manages the gvproxy sidecar (patched per SPEC-005). Custom code: ~200 LOC to generate Lima YAML and bridge `tidegate.yaml` configuration.

2. **Linux (KVM, x86_64/aarch64):** Direct libkrun C/Rust API. `tidegate vm start` calls libkrun functions to configure the VM (CPU, memory, virtiofs, networking via gvproxy), then boots it. Custom code: ~200 LOC Rust or C wrapper. Reference implementation: Podman's `pkg/machine/libkrun/stubber.go` and muvm's passt integration.

3. **Same VMM, same networking, same image.** Both platforms use libkrun, virtio-net via gvproxy (patched with IP:port allowlist per SPEC-005), virtiofs for workspace mounting, and the same OCI guest image (SPEC-006). The orchestration layer differs; the security properties are identical.

4. **TSI scope as defense-in-depth.** Both platforms call `krun_set_tsi_scope(1)` (Group) as layer 3 defense-in-depth per ADR-009's enforcement hierarchy. This restricts socket-level networking even if gvproxy enforcement is bypassed.

5. **Convergence path.** If microsandbox adds virtio-net support (FFI bindings exist but are unused), it could replace both Lima and the custom wrapper as a single cross-platform orchestrator. This ADR does not block that future option.

### What this reaffirms from ADR-008

- libkrun is the single VMM on both platforms
- OCI guest images via Dockerfile
- virtio-net networking (not TSI) as the primary network path
- virtiofs for workspace mounting
- Guest-side tg-scanner for file taint tracking

### What this changes from ADR-008

- Platform-specific orchestration (Lima + custom wrapper) replaces a single custom launcher
- Egress enforcement is deferred to ADR-009 (gvproxy allowlist replaces Seatbelt/iptables as primary)
- TSI scope is defense-in-depth layer 3, not categorically rejected

## Alternatives Considered

| Alternative | Why not chosen |
|---|---|
| **Single custom launcher for both platforms (ADR-008's approach)** | Duplicates Lima's VM lifecycle, provisioning, and virtiofs orchestration on macOS. ~500 LOC of unnecessary custom code when Lima already solves the problem. |
| **Lima on both platforms** | Lima on Linux only supports QEMU — wrong VMM, slower, GPL. Defeats the libkrun consistency guarantee. |
| **microsandbox on both platforms** | Pre-1.0, TSI-only networking (no virtio-net), insufficient egress granularity for Tidegate. FFI bindings for passt exist but are unused. Promising future option, not ready today. |
| **microsandbox on Linux + Lima on macOS (SPIKE-019 Option D)** | microsandbox's TSI-only networking is insufficient for gvproxy-based egress enforcement (ADR-009). Would require contributing a virtio-net mode upstream before adoption. |
| **Cloud Hypervisor on Linux + Lima on macOS** | Different VMMs per platform. Doubles the VMM test surface. Cloud Hypervisor's virtiofs requires external virtiofsd daemon (vs libkrun's built-in). Only justified if sub-200ms boot becomes a requirement. |

## Consequences

### Positive

- **Minimal custom code on macOS.** Lima handles VM lifecycle, cloud-init provisioning, virtiofs config, and state management. `tidegate vm` is a thin config translator.
- **Same VMM everywhere.** libkrun with KVM (Linux) and HVF (macOS). One VMM to understand, debug, and upgrade.
- **Same security properties.** Both platforms use gvproxy allowlist (ADR-009), virtio-net, virtiofs, and TSI scope defense-in-depth. Orchestration differs; enforcement is identical.
- **CNCF-backed macOS path.** Lima is CNCF Incubating with active maintenance, documented AI agent sandboxing patterns, and community tooling (lima-devbox skill).
- **Clear fallback.** If Lima's krunkit backend proves unstable, `vmType: vz` (Apple Virtualization.framework) provides a production-quality alternative with slightly slower boot.

### Negative

- **Two orchestration codepaths.** Platform-specific code in SPEC-004, requiring platform-specific tests. The CLI interface is uniform but the implementation diverges.
- **Lima dependency on macOS.** Adds Lima v2.0 + krunkit as install requirements. Users must `brew install lima krunkit`.
- **Lima krunkit backend is experimental.** Marked as such in Lima docs. Primary use case is GPU passthrough, not agent sandboxing. Risk of stability issues.
- **No existing Linux orchestrator.** The ~200 LOC Linux wrapper is custom code that must be maintained. muvm's source is a reference but not a drop-in.

## Related

- [EPIC-002](../../epic/Active/(EPIC-002)-VM-Isolated-Agent-Runtime/(EPIC-002)-VM-Isolated-Agent-Runtime.md) — Epic delivering platform-specific VM orchestration for agent isolation

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Adopted | 2026-03-13 | 8cacbfa | Supersedes ADR-008 launcher/orchestration; reaffirms libkrun VMM selection |
