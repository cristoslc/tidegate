---
name: spec-management
description: Create, validate, and transition documentation artifacts (Vision, Journey, Epic, Story, Agent Spec, Spike, ADR, Persona, Runbook) and their supporting docs (architecture overviews, journey maps, competitive analyses) through their lifecycle phases. Use when the user wants to write a spec, plan a feature, create an epic, add a user story, draft an ADR, start a research spike, define a persona, create a user persona, create a runbook, define a validation procedure, update the architecture overview, document the system architecture, move an artifact to a new phase, seed an implementation plan, or validate cross-references between artifacts. When a SPEC transitions to implementation, always chain into the execution-tracking skill to create a tracked plan before any code is written. Covers any request to create, update, review, or transition spec artifacts and supporting docs.
license: UNLICENSED
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
metadata:
  short-description: Manage spec artifact creation and lifecycle
  version: 1.1.0
  author: cristos
---

# Spec Management

Create, transition, and validate documentation artifacts defined in AGENTS.md. The authoritative list of artifact types, phases, and hierarchy lives in AGENTS.md — this skill provides the operational procedures.

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

**Log format:** When stale references are found, they are written to `.agents/specwatch.log` (gitignored) in a structured format:
```
STALE <source-file>:<line>
  broken: <relative-path-as-written>
  found: <suggested-new-path>
  artifact: <TYPE-NNN>
```

### Specwatch check (MANDATORY pre-step)

**Before every artifact operation** (create, edit, transition, audit), check for stale references:

1. If `.agents/specwatch.log` exists and is non-empty, read its contents and surface the stale references as warnings.
2. Present each entry: source file, line number, broken path, and suggested fix.
3. Fix stale references before proceeding with the operation (or acknowledge them if they are false positives).
4. After addressing, delete the log file to clear the warnings.

### Sentinel keepalive

**After every artifact operation** (create, edit, transition, audit), refresh the specwatch sentinel:

```bash
scripts/specwatch.sh touch
```

This keeps the background watcher alive. If no spec-management operation runs for the timeout period (default 1 hour), the watcher self-terminates.

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

**When to use:**
- Before transitioning an artifact to a new phase, run `blocks <ID>` to verify dependencies are resolved.
- To find unblocked work, run `ready` — it lists active/planned artifacts whose dependencies are all in resolved statuses.
- To understand the full dependency chain, run `tree <ID>` for transitive closure.
- To generate a visual overview, pipe `mermaid` output into a `.md` file or render it directly.

**Edge types:**
- `depends-on` — explicit blocking dependency (from `depends-on:` frontmatter)
- `parent-vision` — hierarchy edge (from `parent-vision:` frontmatter)
- `parent-epic` — hierarchy edge (from `parent-epic:` frontmatter)

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

Run `specgraph.sh status` for a project-wide progress snapshot — one table per artifact type, listing every artifact with its ID, current phase, and title.

Run `specgraph.sh next` for a quick "what should I work on?" view — shows ready items (unblocked, in-progress or not-yet-started) with what completing each would unblock, plus any blocked items and what they're waiting on.

Both are read-only operations. They do not modify any files.

### Combined "what's next?" flow

When asked "what's next?" or "what should I work on?", combine **both** layers:

1. **Spec layer** — run `specgraph.sh next` to find which artifacts are ready at the planning level (all dependencies resolved).
2. **Task layer** — invoke the **execution-tracking** skill and run `bd ready --json` to find concrete unblocked tasks in the execution backend.
3. **Present both together:** spec-level ready items (with what they'd unblock) and task-level ready items (claimable work). If bd is not initialized or has no tasks, note that and show only the spec layer.

This ensures "what's next?" answers both "which specs can move forward?" and "which concrete tasks can I pick up right now?"

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

Implementation plans are not a doc-type artifact. They bridge declarative specs (`docs/`) and execution tracking. All concrete CLI operations are handled by the **execution-tracking** skill — this skill describes *what* to do, not *how*.

### Prerequisites

Before creating or modifying implementation plans, invoke the **execution-tracking** skill to bootstrap the task backend (availability check, installation if missing, initialization). That skill owns the install, recovery, and CLI command layer.

### Seeding a plan from a spec

1. An Agent Spec (or Epic) may include an "Implementation Approach" section sketching the high-level plan. This seeds the implementation plan but is not the plan of record.
2. When work begins, create an **implementation plan** for the spec artifact, linked via an **origin ref** (e.g., `SPEC-003`).
3. Create **tasks** under the implementation plan with dependencies between them. Tag each task with a **spec tag** for the originating spec.

### Lineage and cross-spec impact

- Every implementation plan has an **origin ref** — an immutable link to the spec that seeded it.
- Every task carries one or more **spec tags** — mutable labels recording which specs it currently affects.
- When a task impacts additional specs, add spec tags for the new specs and create **dependencies** linking related tasks across plans.
- Track provenance when tasks spawn from existing ones.

### Parallel coordination

- Use the execution-tracking skill's parallel coordination features (swarms, formulas) when multiple agents need to pick up **ready work** from the same implementation plan.

### Closing the loop

- Progress is tracked in the execution backend, not in the spec doc. The Agent Spec's lifecycle table records the transition to "Implemented" once the implementation plan completes.
- Cross-spec tasks should be noted in each affected artifact's lifecycle table entry (e.g., "Implemented — shared serializer also covers SPEC-007").

### Fallback

If the **execution-tracking** skill is not available in the current agent environment, fall back to the agent's built-in todo system with canonical states (`todo`, `in_progress`, `blocked`, `done`). The plan structure (ordered steps, dependencies, completion tracking) remains the same — only the backend changes. Lineage is maintained by including artifact IDs in task titles or notes (e.g., `[SPEC-003] Add export endpoint`).
