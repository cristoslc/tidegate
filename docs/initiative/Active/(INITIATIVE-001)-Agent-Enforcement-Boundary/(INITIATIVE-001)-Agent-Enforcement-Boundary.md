---
title: "Agent Enforcement Boundary"
artifact: INITIATIVE-001
track: container
status: Active
author: cristos
created: 2026-03-16
last-updated: 2026-03-16
parent-vision: VISION-002
priority-weight: high
success-criteria:
  - Every data path from the agent to the outside world passes through an enforcement boundary — no bypass without a VM escape
  - Each leg of the lethal trifecta (private data access, untrusted content, external communication) has a dedicated control
  - The enforcement topology works on both macOS (Apple Silicon) and Linux (KVM)
  - A single operator can deploy and maintain the full boundary
depends-on-artifacts: []
addresses:
  - JOURNEY-001.PP-01
trove: "agent-runtime-security"
---

# INITIATIVE-001: Agent Enforcement Boundary

## Strategic Focus

Break the lethal trifecta structurally. An AI agent that combines private data access, untrusted content exposure, and external communication ability can be tricked into exfiltrating data. Tidegate removes the third leg — external communication — at the infrastructure level, and scans the remaining channels for sensitive data leakage.

This initiative coordinates all the work required to make that enforcement boundary real: the VM that contains the agent, the gvproxy allowlist that controls its only network path, the MCP scanning gateway that inspects tool-call traffic, and the guest image that boots in under two seconds. These components are inseparable — the VM is what makes the egress allowlist inescapable, and the gateway is what makes MCP scanning possible.

## Scope Boundaries

**In scope:**
- VM isolation (libkrun on both platforms, Lima orchestration on macOS)
- Infrastructure-embedded egress enforcement (gvproxy IP:port allowlist)
- MCP scanning gateway (regex + checksum on tool-call payloads)
- Minimal guest image (Alpine, virtiofs, <2s boot)
- Unified configuration (`tidegate.yaml`)
- Defense-in-depth layers (Seatbelt, network namespace, TSI scope)

**Out of scope:**
- L1 taint tracking (eBPF + seccomp-notify) — future initiative
- Semantic/ML-based content analysis
- Windows host support
- Multi-tenant orchestration

## Child Epics

| Epic | Title | Status | Notes |
|------|-------|--------|-------|
| EPIC-002 | [Agent Enforcement Boundary](../../epic/Active/(EPIC-002)-VM-Isolated-Agent-Runtime/(EPIC-002)-VM-Isolated-Agent-Runtime.md) | Active | Primary delivery vehicle — VM launcher, guest image, egress allowlist, MCP gateway |
| EPIC-001 | [VM-Isolated Agent Runtime](../../epic/Abandoned/(EPIC-001)-VM-Isolated-Agent-Runtime/(EPIC-001)-VM-Isolated-Agent-Runtime.md) | Abandoned | Superseded by EPIC-002 after research spikes established the full architecture |

## Small Work (Epic-less Specs)

None yet.

## Key Dependencies

- **VISION-002** — product direction and lethal trifecta framing
- **ADR-002** — taint-and-verify data flow model (defines L2 scanning as Step 1)
- **ADR-009** — egress enforcement must be infrastructure-embedded
- **ADR-010** — platform-specific VM orchestration (Lima on macOS, thin wrapper on Linux)
- **agent-runtime-security trove** — 13 external sources validating the threat model and control selection

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-03-16 | pending | Initial creation; groups EPIC-001 and EPIC-002 under Vision-Initiative-Epic hierarchy |
