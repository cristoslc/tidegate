# Research

Spikes and exploratory investigations for Tidegate. Each spike is a numbered artifact (`SPIKE-NNN`) in its own folder.

See [list-spikes.md](list-spikes.md) for lifecycle tracking. Architecture Decision Records live in `../adr/`, not here. A spike may produce an ADR as its output.

## Convention

Each spike folder contains a primary `.md` file with a lifecycle table:

```markdown
## Lifecycle

| Phase | Commit | Date | Notes |
|---|---|---|---|
| Planned | `abc1234` | 2026-02-20 | Question identified during X |
| Active | `def5678` | 2026-02-21 | Started investigation |
| Complete | `ghi9012` | 2026-02-23 | Findings informed ADR-002 |
```

## Active

### `tideclaw-architecture/` — Tideclaw: Secure Wrapper for Login-Based AI Coding Tools

Architecture spike for **Tideclaw** — a standalone product that wraps any login-based AI coding tool (Claude Code, Codex CLI, Aider, etc.) with credential isolation, MCP scanning, egress control, and taint tracking. Key decisions: tool-agnostic wrapping via three modes (MCP gateway, network proxy, hybrid), compose generation from `tideclaw.yaml`, pre-built container images per tool, NanoClaw becomes optional orchestrator.

| Phase | Commit | Date | Notes |
|---|---|---|---|
| Active | — | 2026-02-25 | Spike started; comprehensive external research completed |

### `claudeclaw-vs-nanoclaw/` — ClaudeClaw vs NanoClaw as Agent-Container Runtime

Evaluates ClaudeClaw as an alternative to NanoClaw for Tidegate's agent runtime. Finding: no process boundary, no container, prompt-based security only — cannot be wrapped at tool-call level. Same category as OpenClaw (network-level wrapping only). Reinforces ADR-003.

| Phase | Commit | Date | Notes |
|---|---|---|---|
| Active | — | 2026-02-25 | Source pulled, comparison written |

## Planned

| ID | Title |
|----|-------|
| SPIKE-001 | [MCP Protocol Abuse Resistance](./(SPIKE-001)-MCP-Protocol-Abuse-Resistance/(SPIKE-001)-MCP-Protocol-Abuse-Resistance.md) |
| SPIKE-002 | [Luhn False Positive Rate](./(SPIKE-002)-Luhn-False-Positive-Rate/(SPIKE-002)-Luhn-False-Positive-Rate.md) |
| SPIKE-003 | [Shaped Deny Oracle](./(SPIKE-003)-Shaped-Deny-Oracle/(SPIKE-003)-Shaped-Deny-Oracle.md) |
| SPIKE-004 | [L1 Fail-Open Behavior](./(SPIKE-004)-L1-Fail-Open-Behavior/(SPIKE-004)-L1-Fail-Open-Behavior.md) |
| SPIKE-005 | [Workspace Volume TOCTOU](./(SPIKE-005)-Workspace-Volume-TOCTOU/(SPIKE-005)-Workspace-Volume-TOCTOU.md) |
| SPIKE-006 | [Agent Memory Exfiltration](./(SPIKE-006)-Agent-Memory-Exfiltration/(SPIKE-006)-Agent-Memory-Exfiltration.md) |

## Completed (legacy, predates spec-management)

| Title | Outcome |
|-------|---------|
| Data Flow Taint Model | → [ADR-002](../adr/proposed/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) |
| L1 Coverage Gap | → informed ADR-002 |
| Agent Runtime Selection | → [ADR-003](../adr/proposed/(ADR-003)-Agent-Runtime-Selection.md) |
| Leak Detection Tool Selection | Shipped with initial commit |

## Superseded (legacy)

| Title | Outcome |
|-------|---------|
| Shell Wrapper | → [ADR-001](../adr/superseded/(ADR-001)-Seccomp-Notify-L1-Interception.md) adopted seccomp-notify |
