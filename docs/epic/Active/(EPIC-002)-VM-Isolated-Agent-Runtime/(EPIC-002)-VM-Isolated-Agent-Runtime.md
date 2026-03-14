---
title: "EPIC-002: VM-Isolated Agent Runtime"
artifact: EPIC-002
status: Active
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
parent-vision: VISION-002
success-criteria:
  - Agent runs inside a libkrun VM with workspace mounted via virtiofs on both macOS (Apple Silicon) and Linux (KVM)
  - All MCP traffic routes from the VM through the Tidegate gateway via published ports
  - All HTTP egress routes through the egress proxy, enforced by gvproxy IP:port allowlist (infrastructure-embedded, cross-platform)
  - macOS uses Lima v2.0 for VM orchestration; Linux uses a thin libkrun wrapper
  - Defense-in-depth layers active where available (Seatbelt on macOS, network namespace on Linux, TSI scope on both)
  - Docker infrastructure services (gateway, scanner, egress proxy, MCP servers) remain unchanged
depends-on: []
addresses:
  - JOURNEY-001.PP-01
evidence-pool: ""
---

# EPIC-002: VM-Isolated Agent Runtime

## Goal / Objective

Provide **VM-based agent isolation** that composes with Tidegate's Docker infrastructure, for users who need defense against kernel-level container escapes. Supersedes EPIC-001, which was created before the full research picture was clear.

Docker containers share the host kernel. A single container escape gives the agent full host access, bypassing all scanning, network isolation, and credential separation. VM isolation provides a separate kernel boundary — a compromised guest cannot touch the host without a VM escape.

This epic incorporates findings from 8 research spikes (SPIKE-015 through SPIKE-022) and 2 architectural decisions (ADR-008, ADR-009) into a cohesive implementation plan.

## Research Foundation

| Spike | Finding | Implication |
|-------|---------|-------------|
| SPIKE-015 | libkrun viable on both platforms; <2s boot achievable | VMM selection confirmed |
| SPIKE-017 | gvproxy + Seatbelt validated on macOS | Seatbelt works but is defense-in-depth (ADR-009) |
| SPIKE-018 | Lima v2.0 recommended for macOS orchestration | macOS launcher = thin Lima wrapper |
| SPIKE-019 | No equivalent orchestrator on Linux; thin libkrun wrapper needed | Linux launcher = ~200 LOC Rust/C |
| SPIKE-020 | TSI scope: NO-GO as sole enforcement, YES defense-in-depth | TSI is layer 3, not primary |
| SPIKE-022 | gvproxy IP:port allowlist is cross-platform infrastructure enforcement | Primary egress = gvproxy patch (~90 LOC) |

| ADR | Decision | Constraint |
|-----|----------|------------|
| ADR-010 | Platform-specific VM orchestration (Lima on macOS, thin libkrun wrapper on Linux); reaffirms libkrun as single VMM | No Firecracker, no Cloud Hypervisor |
| ADR-009 | Egress enforcement must be infrastructure-embedded (gvproxy) | No device-level OS sandboxes as primary |

## Scope Boundaries

### In scope

- VM launcher CLI (`tidegate vm start`) with platform-specific orchestration
- gvproxy egress allowlist patch (cross-platform primary enforcement)
- Minimal guest image (Alpine, custom init, virtiofs, <2s boot)
- Defense-in-depth layers: Seatbelt (macOS), network namespace (Linux), TSI scope (both)
- Integration with existing Docker infrastructure (gateway, proxy, MCP servers)

### Out of scope

- Replacing Docker for infrastructure services
- Building a custom VMM or hypervisor
- Multi-tenant VM orchestration
- Windows host support
- Upstream gvproxy merge (we maintain a fork; upstream contribution is a separate effort)

## Child Specs

| Type | ID | Title | Status |
|------|----|-------|--------|
| Spec | SPEC-004 | [VM Launcher CLI](../../../spec/Approved/(SPEC-004)-VM-Launcher-CLI/(SPEC-004)-VM-Launcher-CLI.md) | Approved |
| Spec | SPEC-005 | [gvproxy Egress Allowlist](../../../spec/Approved/(SPEC-005)-gvproxy-Egress-Allowlist/(SPEC-005)-gvproxy-Egress-Allowlist.md) | Approved |
| Spec | SPEC-006 | [VM Guest Image](../../../spec/Approved/(SPEC-006)-VM-Guest-Image/(SPEC-006)-VM-Guest-Image.md) | Approved |

## Key Dependencies

- **ADR-010**: Platform-specific VM orchestration; libkrun is the VMM on both platforms
- **ADR-009**: Egress enforcement is infrastructure-embedded (gvproxy allowlist)
- **Lima v2.0**: macOS orchestration layer (CNCF Incubating, Apache-2.0)
- **gvproxy fork**: IP:port allowlist patch (~90 LOC) on containers/gvisor-tap-vsock

## Supersedes

EPIC-001 (abandoned). EPIC-001 was created before SPIKE-018 through SPIKE-022 established the full architecture. Key differences:
- EPIC-001 assumed Seatbelt as primary macOS egress enforcement → EPIC-002 uses gvproxy allowlist (ADR-009)
- EPIC-001 had no clear Linux egress strategy ("TBD") → EPIC-002 uses the same gvproxy allowlist on both platforms
- EPIC-001 referenced SPIKE-015 only → EPIC-002 incorporates all 8 spikes
- EPIC-001's SPEC-002 (Seatbelt) was macOS-only → EPIC-002's SPEC-005 (gvproxy allowlist) is cross-platform

## References

- ADR-005 — Composable VM Isolation
- ADR-008 — libkrun as Single VMM for Agent Isolation (Superseded by ADR-009 + ADR-010)
- ADR-010 — Platform-Specific VM Orchestration
- ADR-009 — Infrastructure-Embedded Egress Enforcement
- SPIKE-015 through SPIKE-022 — Research foundation
- [gvproxy PR #609](https://github.com/containers/gvisor-tap-vsock/pull/609) — upstream outbound filtering
- [Lima v2.0](https://lima-vm.io/) — macOS VM orchestration
- EPIC-001 — Superseded predecessor

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-03-13 | e6a1bcb | Supersedes EPIC-001; incorporates SPIKE-015 through SPIKE-022 and ADR-008/009 |
