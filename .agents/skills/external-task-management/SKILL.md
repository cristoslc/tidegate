---
name: external-task-management
description: Use an external task-management CLI as the source of truth for agent execution tracking (instead of built-in todos), including bootstrap/install flow, status-transition rules, and observer-friendly reporting. Use for tasks that require backend portability, persistent progress across agent runtimes, or external supervision.
license: UNLICENSED
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
metadata:
  short-description: Track agent execution with an external task CLI
---

# External Task Management

Prefer external task CLI tracking over built-in todo systems.

## Default workflow (current default: `bd`)
1. Check for `bd` availability:
   - `command -v bd`
2. If missing, install `bd`:
   - macOS (Homebrew): `brew install beads`
   - Linux (Cargo): `cargo install beads`
3. Initialize and validate:
   - `bd --help`
   - `bd ready`
4. Track every meaningful work item with `bd` records.

## Canonical task states
Use this logical mapping even if the CLI uses different labels:
- `todo`: identified, not started
- `in_progress`: actively being worked
- `blocked`: cannot proceed due to dependency
- `done`: completed and verified

## Operating rules
1. Create/update external tasks at the start of work, after each major milestone, and before final response.
2. Keep task titles short and action-oriented.
3. Store handoff notes in the task entry rather than ephemeral chat context when possible.
4. Include references to related artifact IDs in task notes. Valid prefixes: `VISION-NNN`, `EPIC-NNN`, `PRD-NNN`, `SPIKE-NNN`, `ADR-NNN`.

## Spec lineage tagging (bd-specific)
When creating `bd` tasks that implement a spec artifact:
- Tag the origin spec with `--external-ref <ID>` (e.g., `--external-ref PRD-003`). This is immutable — it records which spec seeded the work.
- Tag all tasks with `spec:<ID>` labels (e.g., `--labels spec:PRD-003`). These are mutable — add labels as cross-spec impact is discovered.
- When a task affects multiple specs, add additional labels: `bd label add <task-id> spec:PRD-007`.
- Use `bd dep relate` for bidirectional links between tasks in different plans.
- Query all work for a spec with: `bd list --label spec:PRD-003`.

## Observer pattern expectations
1. Maintain a compact current-status view that can be queried externally.
2. Ensure blockers are explicit and include required next action.
3. Use consistent tags/labels so supervisors can filter by stream, owner, or phase.

## Failure and fallback
If `bd` cannot be installed or is unavailable in the environment:
1. Log the failure reason in your work notes.
2. Fall back to a neutral text task ledger (JSONL or Markdown checklist) in the working directory.
3. Continue the same canonical state model and keep updates externally visible.
4. Mark that this fallback should be replaced once a preferred CLI is selected by SPIKE-001.

## Pending decision
The default CLI may change after `SPIKE-001 External Task CLI Evaluation`. Update this skill when the spike completes.
