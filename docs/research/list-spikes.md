# Spike Lifecycle Index

Dashboard mirroring lifecycle data from individual Spike artifacts. Source of truth is each artifact's own lifecycle table. Numbered in intended execution order.

## Planned

| ID | Title | Date | Commit |
|----|-------|------|--------|
| SPIKE-001 | [MCP Protocol Abuse Resistance](./Planned/(SPIKE-001)-MCP-Protocol-Abuse-Resistance/(SPIKE-001)-MCP-Protocol-Abuse-Resistance.md) | 2026-02-21 | db146de |
| SPIKE-002 | [Luhn False Positive Rate](./Planned/(SPIKE-002)-Luhn-False-Positive-Rate/(SPIKE-002)-Luhn-False-Positive-Rate.md) | 2026-02-23 | 138d920 |
| SPIKE-003 | [Shaped Deny Oracle](./Planned/(SPIKE-003)-Shaped-Deny-Oracle/(SPIKE-003)-Shaped-Deny-Oracle.md) | 2026-02-23 | 138d920 |
| SPIKE-004 | [L1 Fail-Open Behavior](./Planned/(SPIKE-004)-L1-Fail-Open-Behavior/(SPIKE-004)-L1-Fail-Open-Behavior.md) | 2026-02-23 | 138d920 |
| SPIKE-005 | [Workspace Volume TOCTOU](./Planned/(SPIKE-005)-Workspace-Volume-TOCTOU/(SPIKE-005)-Workspace-Volume-TOCTOU.md) | 2026-02-23 | 138d920 |
| SPIKE-006 | [Agent Memory Exfiltration](./Planned/(SPIKE-006)-Agent-Memory-Exfiltration/(SPIKE-006)-Agent-Memory-Exfiltration.md) | 2026-02-23 | 138d920 |

## Active

| ID | Title | Date | Commit | Notes |
|----|-------|------|--------|-------|
| SPIKE-012 | [ClaudeClaw vs NanoClaw Comparison](./Active/(SPIKE-012)-ClaudeClaw-vs-NanoClaw-Comparison/(SPIKE-012)-ClaudeClaw-vs-NanoClaw-Comparison.md) | 2026-02-25 | 0ec6eb8 | Evaluating ClaudeClaw as alternative to NanoClaw |
| SPIKE-013 | [Tideclaw Architecture](./Active/(SPIKE-013)-Tideclaw-Architecture/(SPIKE-013)-Tideclaw-Architecture.md) | 2026-02-25 | 0ec6eb8 | Security-first orchestrator design |

## Complete

| ID | Title | Date | Commit | Notes |
|----|-------|------|--------|-------|
| SPIKE-007 | [Leak Detection Tool Selection](./Complete/(SPIKE-007)-Leak-Detection-Tool-Selection/(SPIKE-007)-Leak-Detection-Tool-Selection.md) | 2026-02-21 | db146de | Informed L1 scanner design |
| SPIKE-008 | [L1 Interpreter Coverage Gap](./Complete/(SPIKE-008)-L1-Interpreter-Coverage-Gap/(SPIKE-008)-L1-Interpreter-Coverage-Gap.md) | 2026-02-23 | 138d920 | Fed ADR-002 |
| SPIKE-009 | [Data Flow Taint Model](./Complete/(SPIKE-009)-Data-Flow-Taint-Model/(SPIKE-009)-Data-Flow-Taint-Model.md) | 2026-02-23 | 138d920 | Became ADR-002 |
| SPIKE-011 | [NanoClaw Tidegate Design](./Complete/(SPIKE-011)-NanoClaw-Tidegate-Design/(SPIKE-011)-NanoClaw-Tidegate-Design.md) | 2026-02-24 | 6749250 | Informed ADR-003 |

## Superseded

| ID | Title | Date | Commit | Notes |
|----|-------|------|--------|-------|
| SPIKE-010 | [Shell Wrapper Command Interception](./Superseded/(SPIKE-010)-Shell-Wrapper-Command-Interception/(SPIKE-010)-Shell-Wrapper-Command-Interception.md) | 2026-02-22 | 138d920 | ADR-001 adopted seccomp-notify; journal-based taint (ADR-002) replaced shell interception |
