# Spec Lifecycle Index

Dashboard mirroring lifecycle data from individual Spec artifacts. Source of truth is each artifact's own lifecycle table.

## Draft

_No draft specs._

## Approved

| ID | Title | Date | Commit | Notes |
|----|-------|------|--------|-------|
| SPEC-004 | [VM Launcher CLI](./Approved/(SPEC-004)-VM-Launcher-CLI/(SPEC-004)-VM-Launcher-CLI.md) | 2026-03-13 | e6a1bcb | Supersedes SPEC-001; Lima (macOS) + thin wrapper (Linux) |
| SPEC-005 | [gvproxy Egress Allowlist](./Approved/(SPEC-005)-gvproxy-Egress-Allowlist/(SPEC-005)-gvproxy-Egress-Allowlist.md) | 2026-03-13 | e6a1bcb | Supersedes SPEC-002; cross-platform infrastructure egress per ADR-009 |
| SPEC-006 | [VM Guest Image](./Approved/(SPEC-006)-VM-Guest-Image/(SPEC-006)-VM-Guest-Image.md) | 2026-03-13 | e6a1bcb | Supersedes SPEC-003; same requirements, new parent EPIC-002 |

## Implemented

_No implemented specs._

## Abandoned

| ID | Title | Date | Commit | Notes |
|----|-------|------|--------|-------|
| SPEC-001 | [VM Launcher CLI](./Abandoned/(SPEC-001)-VM-Launcher-CLI/(SPEC-001)-VM-Launcher-CLI.md) | 2026-03-13 | e6a1bcb | Superseded by SPEC-004; egress model revised per ADR-009 |
| SPEC-002 | [Seatbelt Egress Enforcement](./Abandoned/(SPEC-002)-Seatbelt-Egress-Enforcement/(SPEC-002)-Seatbelt-Egress-Enforcement.md) | 2026-03-13 | e6a1bcb | Superseded by SPEC-005; device-level enforcement replaced by gvproxy allowlist |
| SPEC-003 | [VM Guest Image](./Abandoned/(SPEC-003)-VM-Guest-Image/(SPEC-003)-VM-Guest-Image.md) | 2026-03-13 | e6a1bcb | Superseded by SPEC-006; same requirements, new parent |
