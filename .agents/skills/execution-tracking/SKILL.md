---
name: execution-tracking
description: Bootstrap, install, and operate an external task-management CLI as the source of truth for agent execution tracking (instead of built-in todos). Provides the abstraction layer between spec-management intent (implementation plans and tasks) and concrete CLI commands. MUST be invoked before beginning implementation of any SPEC artifact (Epic, Story, Agent Spec, Spike) — create a tracked implementation plan and task breakdown before writing code. Also use for standalone tasks that require backend portability, persistent progress across agent runtimes, or external supervision.
license: UNLICENSED
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
metadata:
  short-description: Bootstrap and operate external task tracking
  version: 2.0.0
  author: cristos
---

# Execution Tracking

Abstraction layer for agent execution tracking. Other skills (e.g., spec-management) express intent using abstract terms; this skill translates that intent into concrete CLI commands.

**Before first use:** Read [references/bd-cheatsheet.md](references/bd-cheatsheet.md) for complete command syntax, flags, ID formats, and anti-patterns.

## Term mapping

Other skills use these abstract terms. This skill maps them to the current backend (`bd`):

| Abstract term | Meaning | bd command |
|---------------|---------|------------|
| **implementation plan** | Top-level container grouping all tasks for a spec artifact | `bd create "Title" -t epic --external-ref <SPEC-ID> --json` |
| **task** | An individual unit of work within a plan | `bd create "Title" -t task --parent <epic-id> --json` |
| **origin ref** | Immutable link from a plan to the spec that seeded it | `--external-ref <ID>` flag on epic creation |
| **spec tag** | Mutable label linking a task to every spec it affects | `--labels spec:<ID>` on create, `--add-label spec:<ID>` on update |
| **dependency** | Ordering constraint between tasks | `bd dep add <child> <parent>` (child depends on parent) |
| **ready work** | Unblocked tasks available for pickup | `bd ready --json` (NOT `bd list --ready`) |
| **claim** | Atomically take ownership of a task | `bd update <id> --claim --json` |
| **complete** | Mark a task as done | `bd close <id> --reason "..."` |

## Bootstrap workflow

1. **Check availability:** `command -v bd`
2. **If missing, install:**
   - macOS: `brew install beads`
   - Linux: `cargo install beads`
   - If install fails, go to [Fallback](#fallback).
3. **Check for existing database:** look for `.beads/` directory.
4. **If no `.beads/`, initialize:** `bd init`.
5. **Validate:** `bd doctor --json`. If errors, try `bd doctor --fix`.
6. **If `git status` shows modified `.beads/dolt-*.pid` or `.beads/dolt-server.activity`:** these are ephemeral runtime files that were tracked by mistake. See `.beads/README.md` § "Remediation: Untrack Ephemeral Runtime Files" for the fix.
7. **Load context:** `bd prime` for dynamic workflow context.

## Statuses

bd uses these status values — pass them exactly:

| Status | Meaning |
|--------|---------|
| `open` | Identified, not started |
| `in_progress` | Actively being worked |
| `blocked` | Cannot proceed (set automatically by dep chains, or manually) |
| `closed` | Completed |

Do NOT use `todo`, `done`, or other aliases — bd will reject them.

## Operating rules

1. **Always use `--json`** on create/update/close for structured output. Capture issue IDs from the response.
2. **Always include `--description`** when creating issues. Context prevents rework.
3. Create/update tasks at the start of work, after each major milestone, and before final response.
4. Keep task titles short and action-oriented.
5. Store handoff notes in task notes (`--notes` or `--append-notes`) rather than ephemeral chat context.
6. Include references to related artifact IDs in labels. Valid prefixes: `VISION-NNN`, `EPIC-NNN`, `SPEC-NNN`, `SPIKE-NNN`, `ADR-NNN`, `STORY-NNN`.
7. **Never use `bd edit`** — it opens `$EDITOR` (vim/nano) which blocks agents. Use `bd update` with inline flags instead.

## Spec lineage tagging

When creating tasks that implement a spec artifact:

```bash
# Create epic with immutable origin ref
bd create "Implement auth" -t epic --external-ref SPEC-003 --json

# Create child tasks with spec label
bd create "Add JWT middleware" -t task \
  --parent <epic-id> --labels spec:SPEC-003 --json

# Add cross-spec impact later
bd update <task-id> --add-label spec:SPEC-007

# Query all work for a spec
bd list -l spec:SPEC-003

# Bidirectional link between tasks in different plans
bd dep relate <task-a> <task-b>
```

## Parallel coordination

- `bd swarm create <epic-id>` — agents use `bd ready` to pick up unblocked work.
- For repeatable workflows, define a formula in `.beads/formulas/` and instantiate with `bd mol pour`.

## "What's next?" flow

When asked what to work on next, show ready work from the execution backend:

```bash
# Check for bd availability and initialization
command -v bd && [ -d .beads ]

# Show unblocked tasks (blocker-aware)
bd ready --json

# If there are in-progress tasks, show those too
bd list --status=in_progress --json
```

If bd is initialized and has tasks, present the results. If bd is not initialized or has no tasks, report that and defer to the spec-management skill's `specgraph.sh next` for artifact-level guidance.

When invoked from the spec-management skill's combined "what's next?" flow, this skill provides the **task layer** — concrete claimable work items — complementing the spec layer's artifact-level readiness view.

## Observer pattern expectations

1. Maintain compact current-status view: `bd status` and `bd list --pretty`.
2. Ensure blockers are explicit: `bd blocked` shows issues with unsatisfied deps.
3. Use consistent labels so supervisors can filter by stream, owner, or phase.

## Fallback

If `bd` cannot be installed or is unavailable:

1. Log the failure reason.
2. Fall back to a neutral text task ledger (JSONL or Markdown checklist) in the working directory.
3. Use the same status model (`open`, `in_progress`, `blocked`, `closed`) and keep updates externally visible.
4. Mark that this fallback should be replaced once a preferred CLI is selected by SPIKE-001.

## Pending decision

The default CLI may change after `SPIKE-001 External Task CLI Evaluation`. Update this skill when the spike completes.
