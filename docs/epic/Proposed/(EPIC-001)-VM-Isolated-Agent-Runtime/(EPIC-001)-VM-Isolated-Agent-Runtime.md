---
artifact: EPIC-001
title: "EPIC-001: VM-Isolated Agent Runtime"
status: Proposed
author: cristos
created: 2026-03-06
last-updated: 2026-03-06
parent-vision: VISION-002
success-criteria:
  - Agent can run inside a VM (QEMU or Firecracker) with workspace mounted read-only
  - All MCP traffic routes from the VM through the Tidegate gateway on the host
  - All HTTP egress routes from the VM through the egress proxy on the host
  - Docker infrastructure services (gateway, scanner, egress proxy, MCP servers) remain unchanged
  - Setup documentation covers VM deployment as an alternative to Docker agent container
---

# EPIC-001: VM-Isolated Agent Runtime

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Proposed | 2026-03-06 | b7482a6 | From claude-vm analysis; see ADR-005 |

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
- Windows/macOS host support for VM mode (Linux KVM first)

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

## Roadmap position

Post-M7. This epic is a hardening layer, not a prerequisite for MVP. The dependency graph:

```
M1–M4 (MVP) → M5 (agent-proxy) → M6 (taint tracking) → M7 (skill hardening)
                                                                    ↓
                                                              EPIC-001 (VM isolation)
```

## References

- ADR-005 — Composable VM Isolation (architectural decision)
- [claude-vm](https://github.com/solomon-b/claude-vm) — Nix flake for headless QEMU VM with Claude Code
- ADR-002 — Taint-and-Verify Data Flow Model
- ADR-003 — Agent Runtime Selection
