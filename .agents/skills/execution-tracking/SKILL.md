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
| **abandon** | Close a task that will not be completed | `bd close <id> --reason "Abandoned: <why>" --json` |
| **escalate** | Abandon + invoke spec-management to update upstream artifacts | Abandon, then invoke spec-management skill |

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

To express abandonment, use `bd close <id> --reason "Abandoned: ..."` — see [Escalation](#escalation).

## Operating rules

1. **Always use `--json`** on create/update/close for structured output. Capture issue IDs from the response.
2. **Always include `--description`** when creating issues. Context prevents rework.
3. Create/update tasks at the start of work, after each major milestone, and before final response.
4. Keep task titles short and action-oriented.
5. Store handoff notes in task notes (`--notes` or `--append-notes`) rather than ephemeral chat context.
6. Include references to related artifact IDs in labels. Valid prefixes: `VISION-NNN`, `EPIC-NNN`, `SPEC-NNN`, `SPIKE-NNN`, `ADR-NNN`, `STORY-NNN`.
7. **Never use `bd edit`** — it opens `$EDITOR` (vim/nano) which blocks agents. Use `bd update` with inline flags instead.
8. **Prefix abandonment reasons with `Abandoned:`** when closing tasks that were not completed. This makes abandoned work queryable: `bd search "Abandoned:"`.

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

## Escalation

When work cannot proceed as designed, use this protocol to abandon tasks and flow control back to spec-management for upstream changes before re-planning.

### Triage table

| Scope | Situation | Action |
|-------|-----------|--------|
| Single task | Alternative approach exists | Abandon task, create replacement under same plan |
| Single task | Spec assumption is wrong | Abandon task, invoke spec-management to update SPEC, create replacement task |
| Multiple tasks | Direction change needed | Abandon affected tasks, create ADR + update SPEC via spec-management, seed new tasks |
| Entire plan | Fundamental rethink required | Abandon all tasks, abandon SPEC (and possibly EPIC) via spec-management, create new SPEC if needed |

### Abandoning tasks

```bash
# Single task
bd close <id> --reason "Abandoned: <why>" --json

# Batch — close all open tasks under an epic
for id in $(bd list --parent <epic-id> --status=open --json | jq -r '.[].id'); do
  bd close "$id" --reason "Abandoned: <why>" --json
done

# Preserve in-progress notes before closing
bd update <id> --append-notes "Abandoning: <context about partial work>"
bd close <id> --reason "Abandoned: <why>" --json
```

### Escalation workflow

1. **Record the blocker.** Append notes to the plan epic explaining why work cannot proceed:
   ```bash
   bd update <epic-id> --append-notes "Blocked: <description of blocker>"
   ```

2. **Invoke spec-management.** Choose the appropriate scope:
   - **Spec tweak** — update the SPEC's assumptions or requirements, then return here.
   - **Design pivot** — create an ADR documenting the decision change, update affected SPECs, then return here.
   - **Full abandon** — transition the SPEC (and possibly EPIC) to Abandoned phase via spec-management.

3. **Seed replacement plan** from the updated spec. Create a new implementation plan linked to the same (or new) SPEC via origin ref:
   ```bash
   bd create "Implement <updated approach>" -t epic --external-ref <SPEC-ID> --json
   ```

4. **Link lineage.** Preserve traceability between abandoned and replacement work:
   - Use the same `spec:<SPEC-ID>` labels on new tasks.
   - Reference abandoned task IDs in the new epic's description or notes:
     ```bash
     bd update <new-epic-id> --append-notes "Replaces abandoned tasks: <old-id-1>, <old-id-2>"
     ```

### Cross-spec escalation

When abandoned tasks carry multiple `spec:` labels, each referenced spec may need upstream changes. Check every spec label on the abandoned tasks and invoke spec-management for each affected spec before re-planning.

```bash
# List spec labels on an abandoned task
bd show <id> --json | jq -r '.labels[]' | grep '^spec:'
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

