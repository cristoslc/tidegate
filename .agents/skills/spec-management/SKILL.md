---
name: spec-management
description: Create, validate, and transition documentation artifacts (Vision, Journey, Epic, Story, Agent Spec, Spike, ADR, Persona, Runbook, Bug) and their supporting docs (architecture overviews, journey maps, competitive analyses) through their lifecycle phases. Use when the user wants to write a spec, plan a feature, create an epic, add a user story, draft an ADR, start a research spike, define a persona, create a user persona, create a runbook, define a validation procedure, file a bug, report a defect, update the architecture overview, document the system architecture, move an artifact to a new phase, seed an implementation plan, or validate cross-references between artifacts. When a SPEC transitions to implementation, always chain into the execution-tracking skill to create a tracked plan before any code is written. Covers any request to create, update, review, or transition spec artifacts and supporting docs.
license: UNLICENSED
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
metadata:
  short-description: Manage spec artifact creation and lifecycle
  version: 1.1.0
  author: cristos
---

# Spec Management

Create, transition, and validate documentation artifacts defined in AGENTS.md. The authoritative list of artifact types, phases, and hierarchy lives in AGENTS.md — this skill provides the operational procedures.

## Artifact relationship model

```mermaid
erDiagram
    VISION ||--o{ EPIC : "parent-vision"
    VISION ||--o{ JOURNEY : "parent-vision"
    EPIC ||--o{ SPEC : "parent-epic"
    EPIC ||--o{ STORY : "parent-epic"
    JOURNEY ||--|{ PAIN_POINT : "PP-NN"
    PAIN_POINT }o--o{ EPIC : "addresses"
    PAIN_POINT }o--o{ SPEC : "addresses"
    PAIN_POINT }o--o{ STORY : "addresses"
    PERSONA }o--o{ JOURNEY : "linked-personas"
    PERSONA }o--o{ STORY : "linked-stories"
    ADR }o--o{ SPEC : "linked-adrs"
    ADR }o--o{ EPIC : "linked-epics"
    SPEC }o--o{ SPIKE : "linked-research"
    SPEC ||--o| IMPL_PLAN : "seeds"
    RUNBOOK }o--o{ EPIC : "validates"
    RUNBOOK }o--o{ SPEC : "validates"
    BUG }o--o{ SPEC : "affected-artifacts"
    BUG }o--o{ EPIC : "affected-artifacts"
    BUG ||--o| IMPL_PLAN : "fix-ref"
    SPIKE }o--o{ ADR : "linked-research"
    SPIKE }o--o{ EPIC : "linked-research"
    SPIKE }o--o{ BUG : "linked-research"

    EPIC {
        string parent_vision FK
        list success_criteria "required"
        list depends_on "optional"
    }
    JOURNEY {
        string parent_vision FK
        list linked_personas "optional"
    }
    SPEC {
        string parent_epic FK
        list linked_research "optional"
        list linked_adrs "optional"
        list addresses "optional"
    }
    STORY {
        string parent_epic FK
        list addresses "optional"
    }
    ADR {
        list linked_epics "optional"
        list linked_specs "optional"
    }
    PERSONA {
        list linked_journeys "optional"
        list linked_stories "optional"
    }
    RUNBOOK {
        list validates "required"
        string parent_epic "optional"
        string mode "agentic or manual"
        string trigger "required"
    }
    BUG {
        string severity "critical/high/medium/low"
        list affected_artifacts "optional"
        string discovered_in "required"
        string fix_ref "optional"
    }
    SPIKE {
        string question "required"
        string gate "required"
        list depends_on "optional"
    }
    IMPL_PLAN {
        string origin_ref "SPEC-NNN"
        list spec_tags "mutable"
    }
```

**Key:** Solid lines (`||--o{`) = mandatory hierarchy. Diamond lines (`}o--o{`) = informational cross-references. SPIKE can attach to any artifact type, not just SPEC. Any artifact can declare `depends-on:` blocking dependencies on any other artifact.

## Stale reference watcher

The `specwatch.sh` script monitors `docs/` for file moves, renames, and deletes, and flags stale markdown link references with suggested fixes.

**Script location:** `scripts/specwatch.sh` (relative to this skill)

**Subcommands:**

| Command | What it does |
|---------|-------------|
| `scan` | Run a full stale-reference scan (no watcher needed) |
| `watch` | Start background filesystem watcher (requires `fswatch`) |
| `stop` | Stop a running watcher |
| `status` | Show watcher status and log summary |
| `touch` | Refresh the sentinel keepalive timer |

**Log format:** When stale references are found, they are written to `.agents/specwatch.log` in a structured format. This file is a runtime artifact — add `specwatch.log` to your `.gitignore` if it isn't already.
```
STALE <source-file>:<line>
  broken: <relative-path-as-written>
  found: <suggested-new-path>
  artifact: <TYPE-NNN>
```

### Mandatory bookends for every artifact operation

**Before:** If `.agents/specwatch.log` exists and is non-empty, read it, surface stale references as warnings, and fix them (or acknowledge false positives) before proceeding. Delete the log when clear.

**After:** Run `scripts/specwatch.sh touch` to keep the background watcher alive (self-terminates after 1 hour of inactivity).

## Dependency graph

The `specgraph.sh` script builds and queries the artifact dependency graph from frontmatter. It caches a JSON graph in `/tmp/` and auto-rebuilds when any `docs/*.md` file changes.

**Script location:** `scripts/specgraph.sh` (relative to this skill)

**Subcommands:**

| Command | What it does |
|---------|-------------|
| `build` | Force-rebuild graph from frontmatter |
| `blocks <ID>` | What does this artifact depend on? (direct dependencies) |
| `blocked-by <ID>` | What depends on this artifact? (inverse lookup) |
| `tree <ID>` | Transitive dependency tree (all ancestors) |
| `ready` | Active/Planned artifacts with all deps resolved |
| `next` | What to work on next (ready items + what they unblock, blocked items + what they need) |
| `mermaid` | Mermaid diagram to stdout |
| `status` | Summary table by type and phase |

Run `blocks <ID>` before phase transitions to verify dependencies are resolved. Run `ready` to find unblocked work. Run `tree <ID>` for transitive dependency chains.

## Lifecycle table format

Every artifact embeds a lifecycle table tracking phase transitions:

```markdown
### Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-24 | abc1234 | Initial creation |
| Active  | 2026-02-25 | def5678 | Dependency X satisfied |
```

Commit hashes reference the repo state at the time of the transition, not the commit that writes the hash stamp itself. Commit the transition first, then stamp the resulting hash into the lifecycle table and index in a second commit. This keeps the stamped hash reachable in git history.

## Index maintenance

Every doc-type directory keeps a single lifecycle index (`list-<type>.md`). **Refreshing the index is the final step of every artifact operation** — creation, content edits, phase transitions, and abandonment. No artifact change is complete until the index reflects it.

Use sub-agents to parallelize this work: Agent 1 should audit all lifecycle tables across docs/ for correctness. Agent 2 should check all cross-references between specs resolve to valid files. Agent 3 should verify naming conventions match our standards.

### What "refresh" means

1. Read (or create) `docs/<type>/list-<type>.md`.
2. Ensure one table per active lifecycle phase, plus a table for each end-of-life phase that has entries.
3. For the affected artifact, update its row: title, current phase, last-updated date, and commit hash of the change.
4. If the artifact moved phases, remove it from the old phase table and add it to the new one.
5. Sort rows within each table by artifact number.

### When to refresh

| Operation | Trigger |
|-----------|---------|
| Create artifact | New row in the appropriate phase table |
| Edit artifact content or frontmatter | Update last-updated date and commit hash |
| Transition phase | Move row between phase tables |
| Abandon / end-of-life | Move row to the end-of-life table |

This rule is referenced as the **index refresh step** in the workflows below. Do not skip it.

## Auditing Artifacts

Use an agent to audit all spec artifacts in docs/ for lifecycle compliance — check each has valid status, hash stamps, and matching index entries — then report gaps as a structured table with file paths and missing fields.

Always include a 1-2 sentence summary of an artifact, not just its title, in tables.

## Status overview

- `specgraph.sh status` — project-wide progress snapshot (one table per artifact type).
- `specgraph.sh next` — ready items (unblocked) + what they'd unblock, plus blocked items + what they need.

Both are read-only.

### Combined "what's next?" flow

When asked "what's next?", combine both layers: (1) **Spec layer** via `specgraph.sh next` for unblocked artifacts, and (2) **Task layer** via the execution-tracking skill (`bd ready --json`) for claimable work items. Present both together. If bd has no tasks, show only the spec layer.

## Creating artifacts

### Workflow

1. Scan `docs/<type>/` to determine the next available number for the prefix.
2. Create the artifact using the appropriate format (see AGENTS.md artifact types table).
3. Read the artifact's definition file and template from the lookup table below.
4. Populate frontmatter with the required fields for the type (see the template).
5. Initialize the lifecycle table with the appropriate phase and current date. This is usually the first phase (Draft, Planned, etc.), but an artifact may be created directly in a later phase if it was fully developed during the conversation (see [Phase skipping](#phase-skipping)).
6. Validate parent references exist (e.g., the Epic referenced by a new Agent Spec must already exist).
7. **Index refresh step** — update `list-<type>.md` (see [Index maintenance](#index-maintenance)).

### Artifact type definitions

Each artifact type has a definition file (lifecycle phases, conventions, folder structure) and a template (frontmatter fields, document skeleton). **Read the definition for the artifact type you are creating or transitioning.**

| Type | Definition | Template |
|------|-----------|----------|
| Product Vision (VISION-NNN) | [references/vision-definition.md](references/vision-definition.md) | [references/vision-template.md.j2](references/vision-template.md.j2) |
| User Journey (JOURNEY-NNN) | [references/journey-definition.md](references/journey-definition.md) | [references/journey-template.md.j2](references/journey-template.md.j2) |
| Epic (EPIC-NNN) | [references/epic-definition.md](references/epic-definition.md) | [references/epic-template.md.j2](references/epic-template.md.j2) |
| User Story (STORY-NNN) | [references/story-definition.md](references/story-definition.md) | [references/story-template.md.j2](references/story-template.md.j2) |
| Agent Spec (SPEC-NNN) | [references/spec-definition.md](references/spec-definition.md) | [references/spec-template.md.j2](references/spec-template.md.j2) |
| Research Spike (SPIKE-NNN) | [references/spike-definition.md](references/spike-definition.md) | [references/spike-template.md.j2](references/spike-template.md.j2) |
| Persona (PERSONA-NNN) | [references/persona-definition.md](references/persona-definition.md) | [references/persona-template.md.j2](references/persona-template.md.j2) |
| ADR (ADR-NNN) | [references/adr-definition.md](references/adr-definition.md) | [references/adr-template.md.j2](references/adr-template.md.j2) |
| Runbook (RUNBOOK-NNN) | [references/runbook-definition.md](references/runbook-definition.md) | [references/runbook-template.md.j2](references/runbook-template.md.j2) |
| Bug (BUG-NNN) | [references/bug-definition.md](references/bug-definition.md) | [references/bug-template.md.j2](references/bug-template.md.j2) |

## Phase transitions

### Phase skipping

Phases listed in AGENTS.md are available waypoints, not mandatory gates. An artifact may skip intermediate phases and land directly on a later phase in the sequence. This is normal in single-user workflows where drafting and review happen conversationally in the same session.

- The lifecycle table records only the phases the artifact actually occupied — one row per state it landed on, not rows for states it skipped past.
- Skipping is forward-only: an artifact cannot skip backward in its phase sequence.
- **Abandoned** is a universal end-of-life phase available from any state, including Draft. It signals the artifact was intentionally not pursued. Use it instead of deleting artifacts — the record of what was considered and why it was dropped is valuable.
- Other end-of-life transitions (Sunset, Retired, Superseded, Archived, Deprecated) require the artifact to have been in an active state first — you cannot skip directly from Draft to Retired.

### Workflow

1. Validate the target phase is reachable from the current phase (same or later in the sequence; intermediate phases may be skipped).
2. Update the artifact's status field in frontmatter.
3. Commit the change.
4. Append a row to the artifact's lifecycle table with the commit hash from step 3.
5. Amend the commit to include the hash stamp.
6. **Index refresh step** — move the artifact's row to the new phase table (see [Index maintenance](#index-maintenance)).

### Completion rules

- An Epic is "Complete" only when all child Agent Specs are "Implemented" and success criteria are met.
- An Agent Spec is "Implemented" only when its implementation plan is closed (or all tasks are done in fallback mode).
- An ADR is "Superseded" only when the superseding ADR is "Adopted" and links back.

## Implementation plans

Implementation plans bridge declarative specs (`docs/`) and execution tracking. They are not doc-type artifacts. All CLI operations are handled by the **execution-tracking** skill — invoke it to bootstrap the task backend before creating plans.

### Workflow

1. A Spec/Epic's "Implementation Approach" section seeds the plan but is not the plan of record.
2. Create an implementation plan linked via an **origin ref** (e.g., `SPEC-003`). Create tasks with dependencies, each tagged with **spec tags** for originating specs.
3. When a task impacts additional specs, add spec tags and cross-plan dependencies.

### Closing the loop

- Progress lives in the execution backend, not the spec doc. Transition the spec to "Implemented" once the plan completes.
- Note cross-spec tasks in each affected artifact's lifecycle entry (e.g., "Implemented — shared serializer also covers SPEC-007").

### Fallback

If execution-tracking is unavailable, fall back to the agent's built-in todo system (`todo`, `in_progress`, `blocked`, `done`). Maintain lineage by including artifact IDs in task titles (e.g., `[SPEC-003] Add export endpoint`).
