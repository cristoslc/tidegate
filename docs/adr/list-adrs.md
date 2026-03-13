# ADR Lifecycle Index

Dashboard mirroring lifecycle data from individual ADR artifacts. Source of truth is each artifact's own lifecycle table.

## Draft

| ID | Title | Phase | Date | Commit |
|----|-------|-------|------|--------|
| ADR-007 | [Human-in-the-Loop Exception Approval](./Draft/(ADR-007)-Human-in-the-Loop-Exception-Approval.md) | Draft | 2026-03-12 | 01eb2ac |

## Proposed

_No proposed ADRs._

## Accepted

| ID | Title | Phase | Date | Commit |
|----|-------|-------|------|--------|
| ADR-002 | [Taint-and-Verify Data Flow Model](./Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) | Accepted | 2026-03-11 | — |
| ADR-004 | [IPC Orchestrator Scanning as Enforcement Seam](./Accepted/(ADR-004)-IPC-Orchestrator-Scanning-as-Enforcement-Seam.md) | Accepted | 2026-03-11 | — |
| ADR-005 | [Composable VM Isolation](./Accepted/(ADR-005)-Composable-VM-Isolation.md) | Accepted | 2026-03-11 | — |
| ADR-006 | [Opaque Deny Responses](./Adopted/(ADR-006)-Opaque-Deny-Responses.md) | Adopted | 2026-03-12 | 37e4a9b |
| ADR-008 | [libkrun as Single VMM for Agent Isolation](./Adopted/(ADR-008)-libkrun-Single-VMM-for-Agent-Isolation.md) | Adopted | 2026-03-13 | — |

## Superseded

| ID | Title | Phase | Date | Commit | Superseded by |
|----|-------|-------|------|--------|---------------|
| ADR-001 | [Seccomp-Notify L1 Interception](./Superseded/(ADR-001)-Seccomp-Notify-L1-Interception.md) | Superseded | 2026-02-23 | 94efd00 | ADR-002 |
| ADR-003 | [Agent Runtime Selection](./Superseded/(ADR-003)-Agent-Runtime-Selection.md) | Superseded | 2026-03-11 | — | ADR-005 + runtime-agnostic architecture |
