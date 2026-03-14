---
artifact: ADR-005
title: "ADR-005: Composable VM Isolation"
status: Accepted
author: cristos
created: 2026-03-06
last-updated: 2026-03-11
affected-artifacts:
  - VISION-001
  - EPIC-001
---

# ADR-005: Composable VM Isolation

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Proposed | 2026-03-06 | b7482a6 | Prompted by claude-vm analysis and kernel exploit discussion |
| Accepted | 2026-03-11 | — | Decision scope: use a microVM for agent containment; specific microVM technology (Firecracker, QEMU, etc.) remains open for SPIKE-015 |

## Context

Docker containers share the host kernel. A container escape (CVE-2024-21626 runc, CVE-2022-0185 namespace escape, CVE-2024-29018 DNS exfiltration) gives the agent full host access — past all scanning, past all network isolation, past credential separation. Tidegate's per-container hardening (`cap_drop: ALL`, `no-new-privileges`, `read_only: true`) reduces attack surface but does not eliminate the shared-kernel risk.

The [claude-vm](https://github.com/solomon-b/claude-vm) project demonstrates a lightweight approach: a Nix flake that boots a headless QEMU VM with Claude Code pre-installed, mounting only `/workspace` via 9p. The VM boundary eliminates kernel-level container escapes entirely — a compromised guest kernel cannot touch the host.

This raises the question: should Tidegate build its own VM isolation layer?

### What Tidegate enforces vs. what a VM enforces

Tidegate's value is **data flow control at the MCP/transport layer**:

- L1/L2/L3 scanning of tool call arguments and responses
- Egress proxy domain allowlisting
- Credential isolation (API keys in MCP server containers, never in the agent)
- Structured audit trail of every tool call decision

None of this requires running inside a VM. These are network-layer and application-layer controls that work regardless of how the agent process is isolated.

A VM provides **compute isolation**: the agent's kernel is separate from the host's. This protects against kernel exploits, container escapes, and hardware-level side channels. But a VM alone provides no data flow control — a VM with NAT networking gives the agent full outbound internet access.

### The ecosystem is solving compute isolation

- [claude-vm](https://github.com/solomon-b/claude-vm): Nix + QEMU, serial console, 9p workspace mount
- [Firecracker](https://firecracker-microvm.github.io/): AWS microVMs, <125ms boot, minimal device model
- gVisor, Kata Containers: varying points on the container-to-VM spectrum

Building a VM layer inside Tidegate would duplicate work the ecosystem already does, tie Tidegate to a specific VM technology, and add significant complexity to the setup flow.

## Decision

**Tidegate stays Docker-native for infrastructure, uses a microVM to contain the agent runtime, and makes the agent container interface transport-based so the specific microVM technology remains a deferred choice.**

Specifically:

1. **Infrastructure services remain Docker containers.** The gateway, scanner, egress proxy, and MCP servers are trusted code under the operator's control. Docker-level hardening is sufficient — the kernel escape threat applies to the *untrusted agent*, not to infrastructure.

2. **The agent container interface is transport-based, not runtime-based.** Tidegate talks to the agent over HTTP (Streamable HTTP MCP) and controls its egress via network routing. Whether the agent runs in a Docker container, a QEMU VM, or a Firecracker microVM is irrelevant to the gateway — it only needs the agent's traffic to arrive at port 4100 and leave through the egress proxy.

3. **Container escape is an accepted risk for Docker-only deployments.** The most likely attack path is prompt injection through MCP tool calls, which Tidegate's scanning architecture covers. Kernel exploits require a separate vulnerability chain and are lower probability for the personal-assistant threat model.

4. **VM isolation is a hardening layer (EPIC-002).** For users who need defense against kernel-level escapes (e.g., processing highly sensitive data, running untrusted community skills), Tidegate documents VM-based agent deployment that routes through the existing Docker infrastructure.

### Alternatives considered

| Alternative | Why rejected |
|---|---|
| **Build VM management into Tidegate** | Duplicates ecosystem work, ties to specific VM tech, massively increases complexity and host requirements (KVM, Nix/QEMU toolchain) |
| **Replace Docker entirely with VMs** | Infrastructure services don't need VM isolation; loses `docker compose` simplicity; breaks the "one `./setup.sh`" goal |
| **Ignore the kernel escape risk** | Dishonest; the risk is real even if lower probability. Better to document it and plan hardening. |
| **Require gVisor/Kata for agent container** | Reasonable middle ground but adds host requirements and doesn't match the full VM isolation of claude-vm/Firecracker. Could be offered as an intermediate option. |

## Consequences

- Docker containers are the default agent runtime, with container escape documented as an accepted risk in the threat model.
- EPIC-002 (VM-Isolated Agent Runtime) provides VM-based hardening for users who need defense against kernel-level escapes.
- The gateway and egress proxy make no assumptions about the agent's runtime — only that traffic arrives on the expected network interfaces.
- The agent runtime (Docker or VM) should be swappable without changing infrastructure services.

## References

- [claude-vm](https://github.com/solomon-b/claude-vm) — Nix flake for headless QEMU VM with Claude Code
- ADR-002 — Taint-and-Verify Data Flow Model (eBPF + seccomp-notify, requires shared kernel — implications for VM mode)
- ADR-003 — Agent Runtime Selection (NanoClaw process boundary enables Tidegate wrapping)
- EPIC-001 — VM-Isolated Agent Runtime
- SPIKE-015 — Evaluate VM Isolation for Agent Container
