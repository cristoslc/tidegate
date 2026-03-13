---
artifact: EPIC-001
title: "EPIC-001: VM-Isolated Agent Runtime"
status: Abandoned
author: cristos
created: 2026-03-06
last-updated: 2026-03-13
parent-vision: VISION-002
success-criteria:
  - Agent runs inside a libkrun VM with workspace mounted via virtiofs
  - All MCP traffic routes from the VM through the Tidegate gateway via published ports
  - All HTTP egress routes through the egress proxy, enforced by Seatbelt sandbox on gvproxy (macOS) or Docker network isolation (Linux)
  - Docker infrastructure services (gateway, scanner, egress proxy, MCP servers) remain unchanged
  - Setup documentation covers VM deployment as an alternative to Docker agent container
---

# EPIC-001: VM-Isolated Agent Runtime

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Proposed | 2026-03-06 | b7482a6 | From claude-vm analysis; see ADR-005 |
| Active | 2026-03-13 | b530c62 | Both spikes complete (SPIKE-015, SPIKE-017); decomposed into SPECs |
| Abandoned | 2026-03-13 | e6a1bcb | Superseded by EPIC-002; SPIKE-018 through SPIKE-022 invalidated assumptions (device-level egress, incomplete Linux strategy) |

## Goal

Provide **optional VM-based agent isolation** that composes with Tidegate's Docker infrastructure, for users who need defense against kernel-level container escapes.

Docker containers share the host kernel. A single container escape vulnerability gives the agent full host access, bypassing all scanning, network isolation, and credential separation. For operators processing highly sensitive data or running untrusted community skills, this risk may be unacceptable.

VM isolation (QEMU, Firecracker) provides a separate kernel boundary. A compromised guest cannot touch the host without a VM escape — a significantly harder attack than a container escape.

## Scope

### In scope

- Evaluate VM technologies for agent isolation (SPIKE-015)
- Define networking configuration to route VM traffic through Tidegate gateway and egress proxy
- Define workspace mounting strategy (9p, virtiofs) with appropriate read/write boundaries
- Document VM deployment as an alternative to the Docker agent container (M2)
- Ensure ADR-002 taint tracking (eBPF + seccomp-notify) either works inside the VM or has an equivalent enforcement path

### Out of scope (non-goals)

- Replacing Docker for infrastructure services (gateway, scanner, egress proxy, MCP servers)
- Building a custom VM manager or hypervisor
- Multi-tenant VM orchestration
- Windows host support (macOS via HVF and Linux via KVM are in scope per ADR-008)

## Dependencies

- **M2 (Agent Container)**: The Docker-based agent container ships first. VM isolation is an alternative deployment mode, not a replacement.
- **ADR-005**: Architectural decision that Tidegate composes with external VM isolation rather than building it.
- **SPIKE-015**: Research spike evaluating specific VM approaches.

## Key questions

- Does ADR-002 taint tracking (eBPF on `openat`, seccomp-notify on `connect()`) work inside a VM guest, or does it need a guest-side equivalent?
- Can the VM networking be configured to use Docker's existing `agent-net` bridge, or does it need a separate TAP/bridge setup?
- What is the cold-start time budget? (claude-vm uses QEMU; Firecracker boots in <125ms)
- How does credential passthrough work? (Claude API key for the agent, OAuth tokens for Claude Code)

## Child artifacts

| Type | ID | Title | Status |
|------|----|-------|--------|
| Spike | SPIKE-015 | [Evaluate VM Isolation for Agent Container](../../../research/Complete/(SPIKE-015)-Evaluate-VM-Isolation-for-Agent-Container/(SPIKE-015)-Evaluate-VM-Isolation-for-Agent-Container.md) | Complete |
| Spike | SPIKE-017 | [Validate libkrun virtio-net on macOS](../../../research/Complete/(SPIKE-017)-Validate-libkrun-virtio-net-macOS/(SPIKE-017)-Validate-libkrun-virtio-net-macOS.md) | Complete |
| Spec | SPEC-001 | [VM Launcher CLI](../../../spec/Approved/(SPEC-001)-VM-Launcher-CLI/(SPEC-001)-VM-Launcher-CLI.md) | Approved |
| Spec | SPEC-002 | [Seatbelt Egress Enforcement](../../../spec/Approved/(SPEC-002)-Seatbelt-Egress-Enforcement/(SPEC-002)-Seatbelt-Egress-Enforcement.md) | Approved |
| Spec | SPEC-003 | [VM Guest Image](../../../spec/Approved/(SPEC-003)-VM-Guest-Image/(SPEC-003)-VM-Guest-Image.md) | Approved |

## Roadmap position

Post-M7. This epic is a hardening layer, not a prerequisite for MVP. The dependency graph:

```
M1–M4 (MVP) → M5 (agent-proxy) → M6 (taint tracking) → M7 (skill hardening)
                                                                    ↓
                                                              EPIC-001 (VM isolation)
```

## References

- ADR-005 — Composable VM Isolation (architectural decision)
- ADR-008 — libkrun as Single VMM for Agent Isolation
- [claude-vm](https://github.com/solomon-b/claude-vm) — Nix flake for headless QEMU VM with Claude Code
- ADR-002 — Taint-and-Verify Data Flow Model
