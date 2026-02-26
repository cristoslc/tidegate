# Spike Lifecycle Index

Dashboard mirroring lifecycle data from individual Spike artifacts. Source of truth is each artifact's own lifecycle table. Numbered in intended execution order.

## Planned

| ID | Title | Phase | Date | Commit |
|----|-------|-------|------|--------|
| SPIKE-001 | [MCP Protocol Abuse Resistance](./(SPIKE-001)-MCP-Protocol-Abuse-Resistance/(SPIKE-001)-MCP-Protocol-Abuse-Resistance.md) | Planned | 2026-02-21 | db146de |
| SPIKE-002 | [Luhn False Positive Rate](./(SPIKE-002)-Luhn-False-Positive-Rate/(SPIKE-002)-Luhn-False-Positive-Rate.md) | Planned | 2026-02-23 | 138d920 |
| SPIKE-003 | [Shaped Deny Oracle](./(SPIKE-003)-Shaped-Deny-Oracle/(SPIKE-003)-Shaped-Deny-Oracle.md) | Planned | 2026-02-23 | 138d920 |
| SPIKE-004 | [L1 Fail-Open Behavior](./(SPIKE-004)-L1-Fail-Open-Behavior/(SPIKE-004)-L1-Fail-Open-Behavior.md) | Planned | 2026-02-23 | 138d920 |
| SPIKE-005 | [Workspace Volume TOCTOU](./(SPIKE-005)-Workspace-Volume-TOCTOU/(SPIKE-005)-Workspace-Volume-TOCTOU.md) | Planned | 2026-02-23 | 138d920 |
| SPIKE-006 | [Agent Memory Exfiltration](./(SPIKE-006)-Agent-Memory-Exfiltration/(SPIKE-006)-Agent-Memory-Exfiltration.md) | Planned | 2026-02-23 | 138d920 |

## Completed

Legacy research (predates spec-management):

| Title | Notes |
|-------|-------|
| [Data Flow Taint Model](./completed/) | → ADR-002 |
| [L1 Coverage Gap](./completed/) | → informed ADR-002 |
| [Leak Detection Tool Selection](./completed/) | Shipped with initial commit |

## Superseded

| Title | Notes |
|-------|-------|
| [Shell Wrapper](./superseded/) | → ADR-001 adopted seccomp-notify |
