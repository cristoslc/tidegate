---
title: "EPIC-002: Agent Enforcement Boundary"
artifact: EPIC-002
status: Active
author: cristos
created: 2026-03-13
last-updated: 2026-03-14
parent-vision: VISION-002
parent-initiative: INITIATIVE-001
success-criteria:
  - Agent runs inside a libkrun VM with workspace mounted via virtiofs on both macOS (Apple Silicon) and Linux (KVM)
  - All MCP traffic routes from the VM through the MCP scanning gateway (SPEC-007), which scans every tool-call argument and response for structured sensitive data
  - All HTTP egress routes through a CONNECT-only proxy allowlisted to LLM API domains, enforced by gvproxy IP:port allowlist (infrastructure-embedded, cross-platform)
  - The gateway, egress proxy, and MCP servers run as Docker containers on isolated networks (agent-net, mcp-net, proxy-net)
  - macOS uses Lima v2.0 for VM orchestration; Linux uses a thin libkrun wrapper
  - Defense-in-depth layers active where available (Seatbelt on macOS, network namespace on Linux, TSI scope on both)
  - A single `tidegate.yaml` configures the entire topology (gateway, proxy, MCP servers, VM resources)
depends-on: []
addresses:
  - JOURNEY-001.PP-01
trove: ""
linked-artifacts:
  - ADR-002
  - ADR-005
  - ADR-008
  - ADR-009
  - ADR-010
  - EPIC-001
  - SPEC-002
  - SPEC-004
  - SPEC-005
  - SPEC-006
  - SPEC-007
  - SPIKE-015
  - SPIKE-017
  - SPIKE-018
  - SPIKE-019
  - SPIKE-020
  - SPIKE-022
---
# EPIC-002: Agent Enforcement Boundary

## Goal / Objective

Provide a **complete enforcement boundary** around the AI agent: the agent runs in a VM, all MCP traffic passes through a scanning gateway, and all network egress is restricted to allowlisted destinations. These components are inseparable — the VM is not a hardening layer on top of Docker infrastructure, it IS the mechanism that makes egress enforcement possible (gvproxy is the VM's only network path), and the gateway is what makes MCP scanning possible (the agent can only reach MCP servers through it).

Supersedes EPIC-001, which was created before the full research picture was clear. Incorporates findings from 8 research spikes (SPIKE-015 through SPIKE-022) and 3 architectural decisions (ADR-002, ADR-009, ADR-010).

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

- MCP scanning gateway (L2 enforcement — regex + checksum scanning on tool-call payloads)
- gvproxy egress allowlist patch (cross-platform primary enforcement)
- VM launcher CLI (`tidegate vm start`) with platform-specific orchestration
- Minimal guest image (Alpine, custom init, virtiofs, <2s boot)
- Egress proxy (CONNECT-only to LLM API domains — Squid or equivalent, minimal config)
- Docker Compose topology with isolated networks (agent-net, mcp-net, proxy-net)
- `tidegate.yaml` unified configuration
- Defense-in-depth layers: Seatbelt (macOS), network namespace (Linux), TSI scope (both)

### Out of scope

- L1 taint tracking (ADR-002 eBPF + seccomp-notify) — future hardening, not MVP
- Semantic or ML-based content analysis
- Per-tool allowlists/denylists in the gateway
- Building a custom VMM or hypervisor
- Multi-tenant VM orchestration
- Windows host support
- Upstream gvproxy merge (we maintain a fork; upstream contribution is a separate effort)

## Child Specs

| Type | ID | Title | Status | Track |
|------|----|-------|--------|-------|
| Spec | SPEC-005 | [gvproxy Egress Allowlist](../../../spec/Approved/(SPEC-005)-gvproxy-Egress-Allowlist/(SPEC-005)-gvproxy-Egress-Allowlist.md) | Approved | A — no deps |
| Spec | SPEC-007 | [MCP Scanning Gateway](../../../spec/Approved/(SPEC-007)-MCP-Scanning-Gateway/(SPEC-007)-MCP-Scanning-Gateway.md) | Approved | B — no deps |
| Spec | SPEC-006 | [VM Guest Image](../../../spec/Approved/(SPEC-006)-VM-Guest-Image/(SPEC-006)-VM-Guest-Image.md) | Approved | C — no deps |
| Spec | SPEC-004 | [VM Launcher CLI](../../../spec/Approved/(SPEC-004)-VM-Launcher-CLI/(SPEC-004)-VM-Launcher-CLI.md) | Approved | Integration — depends on 005, 006, 007 |

## Key Dependencies

- **ADR-002**: Taint-and-verify data flow model — defines L2 (gateway scanning) as Step 1 of implementation sequence
- **ADR-009**: Egress enforcement is infrastructure-embedded (gvproxy allowlist)
- **ADR-010**: Platform-specific VM orchestration; libkrun is the VMM on both platforms
- **Lima v2.0**: macOS orchestration layer (CNCF Incubating, Apache-2.0)
- **gvproxy fork**: IP:port allowlist patch (~90 LOC) on containers/gvisor-tap-vsock
- **python-stdnum**: Checksum validation for credit cards, IBANs, SSNs in the gateway scanner

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
