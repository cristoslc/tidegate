# AGENTS.md

## Skill routing

When the user wants to create, plan, write, update, transition, or review any documentation artifact (Vision, Journey, Epic, Story, Agent Spec, Spike, ADR, Persona) or their supporting docs (architecture overviews, competitive analyses, journey maps), **always invoke the spec-management skill**. This includes requests like "write a spec", "let's plan the next feature", "create an ADR for this decision", "move the spike to Active", "add a user story", or "update the architecture overview." The skill contains the procedures, formats, and validation rules — do not improvise artifact creation from the reference tables below.

**For all task tracking and execution progress**, use the **execution-tracking** skill instead of any built-in todo or task system. This applies whether tasks originate from spec-management (implementation plans) or from standalone work. The execution-tracking skill bootstraps and operates the external task backend — it will install the CLI if missing, manage fallback if installation fails, and translate abstract operations (create plan, add task, set dependency) into concrete commands. Do not use built-in agent todos when this skill is available.

## Pre-implementation protocol (MANDATORY)

**Before writing ANY code to implement a SPEC artifact** (Epic, Story, Agent Spec, Spike), you MUST:

1. **Invoke the execution-tracking skill** to bootstrap the task backend.
2. **Create an implementation plan** (tracked epic) linked to the artifact via `origin ref`.
3. **Break the work into tracked tasks** with `spec:<ID>` labels and dependencies.
4. **Only then begin coding**, updating task status as you go.

Skipping straight to code is not allowed. If the user says "implement STORY-005" or "build what SPEC-003 describes," that is a trigger for this protocol — not a trigger to start editing source files immediately.

## Documentation lifecycle workflow

### General rules

- Each top-level directory within `docs/` must include a `README.md` with an explanation and index.
- All artifacts MUST be titled AND numbered.
  - Good: `(ADR-192)-Multitenant-Gateway-Architecture.md`
  - Bad: `{ADR} Multitenant Gateway Architectre (#192).md`
- **Every artifact is the authoritative record of its own lifecycle.** Each must embed a lifecycle table in its frontmatter tracking every phase transition with date, commit hash, and notes. Index files (`list-<type>.md`) mirror this data as a project-wide dashboard but are not the source of truth — the artifact is.
- Each doc-type directory keeps a single lifecycle index (`list-<type>.md`, e.g., `list-specs.md`) with one table per phase and commit hash stamps for auditability.

### Artifact types

Phases are **available waypoints**, not mandatory gates. Artifacts may skip intermediate phases (e.g., Draft → Adopted) when the work is completed conversationally in a single session. The lifecycle table records only the phases the artifact actually occupied. **Abandoned** is a universal end-of-life phase available from any state — it signals the artifact was intentionally not pursued.

| Type | Path | Format | Phases |
|------|------|--------|--------|
| Product Vision | `docs/vision/` | Folder containing titled `.md` + supporting docs (architecture overview, roadmap, competitive analysis, etc.) | Draft → Active → Sunset · Abandoned |
| User Journey | `docs/journey/` | Folder containing titled `.md` with embedded Mermaid journey diagram + supporting docs | Draft → Validated · Archived · Abandoned |
| Epics | `docs/epic/` | Folder containing titled `.md` + supporting docs | Proposed → Active → Testing → Complete · Abandoned |
| User Story | `docs/story/` | Markdown file per story | Draft → Ready → Implemented · Abandoned |
| Agent Specs | `docs/spec/` | Folder containing titled `.md` + supporting docs | Draft → Review → Approved → Testing → Implemented → Deprecated · Abandoned |
| Research / Spikes | `docs/research/` | Folder containing titled `.md` (not `README.md`) | Planned → Active → Complete · Abandoned |
| ADRs | `docs/adr/` | Markdown file in `<Phase>/` subdirectory (e.g., `docs/adr/Adopted/(ADR-001)-Title.md`) | Draft → Proposed → Adopted → Retired · Superseded · Abandoned |
| Personas | `docs/persona/` | Folder containing titled `.md` + supporting docs (interview notes, research data) | Draft → Validated → Archived · Abandoned |

### Artifact hierarchy

```
Product Vision (VISION-NNN) — one per product or product area
  ├── User Journey (JOURNEY-NNN) — end-to-end user experience map
  ├── Epic (EPIC-NNN) — strategic initiative / major capability
  │     ├── User Story (STORY-NNN) — atomic user-facing requirement
  │     ├── Agent Spec (SPEC-NNN) — behavior contract
  │     │     └── Implementation Plan (via execution-tracking)
  │     └── ADR (ADR-NNN) — architectural decision (cross-cutting)
  ├── Persona (PERSONA-NNN) — user archetype (cross-cutting)
  └── Research Spike (SPIKE-NNN) — can attach to any artifact ↑
```

**Relationship rules:**
- Every Epic MUST reference a parent Vision in its frontmatter.
- Every User Journey MUST reference a parent Vision.
- Every User Story MUST reference a parent Epic.
- Every Agent Spec MUST reference a parent Epic.
- Spikes can belong to any artifact type (Vision, Journey, Epic, Story, Agent Spec, ADR, Persona). The owning artifact controls all spike tables.
- ADRs are cross-cutting: they link to all affected Epics/Agent Specs but are not owned by any single one.
- Personas are cross-cutting: they link to all Journeys, Stories, and other artifacts that reference them but are not owned by any single one.
- An artifact may only have one parent in the hierarchy but may reference siblings or cousins via `related` links.
- Blocking dependencies are declared via `depends-on:` in frontmatter (list of bare TYPE-NNN IDs). Parent fields (`parent-vision:`, `parent-epic:`) encode hierarchy. Informational links (`linked-epics:`, `related:`, etc.) are cross-references and do not imply blocking.

For detailed procedures, see the **spec-management** skill (referenced in Skill routing above).

<!-- BEGIN BEADS INTEGRATION -->
## Issue Tracking with bd (beads)

**IMPORTANT**: This project uses **bd (beads)** for ALL issue tracking. Do NOT use markdown TODOs, task lists, or other tracking methods.

### Why bd?

- Dependency-aware: Track blockers and relationships between issues
- Git-friendly: Dolt-powered version control with native sync
- Agent-optimized: JSON output, ready work detection, discovered-from links
- Prevents duplicate tracking systems and confusion

### Quick Start

**Check for ready work:**

```bash
bd ready --json
```

**Create new issues:**

```bash
bd create "Issue title" --description="Detailed context" -t bug|feature|task -p 0-4 --json
bd create "Issue title" --description="What this issue is about" -p 1 --deps discovered-from:bd-123 --json
```

**Claim and update:**

```bash
bd update <id> --claim --json
bd update bd-42 --priority 1 --json
```

**Complete work:**

```bash
bd close bd-42 --reason "Completed" --json
```

### Issue Types

- `bug` - Something broken
- `feature` - New functionality
- `task` - Work item (tests, docs, refactoring)
- `epic` - Large feature with subtasks
- `chore` - Maintenance (dependencies, tooling)

### Priorities

- `0` - Critical (security, data loss, broken builds)
- `1` - High (major features, important bugs)
- `2` - Medium (default, nice-to-have)
- `3` - Low (polish, optimization)
- `4` - Backlog (future ideas)

### Workflow for AI Agents

1. **Check ready work**: `bd ready` shows unblocked issues
2. **Claim your task atomically**: `bd update <id> --claim`
3. **Work on it**: Implement, test, document
4. **Discover new work?** Create linked issue:
   - `bd create "Found bug" --description="Details about what was found" -p 1 --deps discovered-from:<parent-id>`
5. **Complete**: `bd close <id> --reason "Done"`

### Auto-Sync

bd automatically syncs via Dolt:

- Each write auto-commits to Dolt history
- Use `bd dolt push`/`bd dolt pull` for remote sync
- No manual export/import needed!

### Important Rules

- ✅ Use bd for ALL task tracking
- ✅ Always use `--json` flag for programmatic use
- ✅ Link discovered work with `discovered-from` dependencies
- ✅ Check `bd ready` before asking "what should I work on?"
- ❌ Do NOT create markdown TODO lists
- ❌ Do NOT use external issue trackers
- ❌ Do NOT duplicate tracking systems

For more details, see README.md and docs/QUICKSTART.md.

<!-- END BEADS INTEGRATION -->

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
