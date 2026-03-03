# AGENTS.md

## Skill routing

When the user wants to create, plan, write, update, transition, or review any documentation artifact (Vision, Journey, Epic, Story, Agent Spec, Spike, ADR, Persona, Runbook) or their supporting docs (architecture overviews, competitive analyses, journey maps), **always invoke the spec-management skill**. This includes requests like "write a spec", "let's plan the next feature", "create an ADR for this decision", "move the spike to Active", "add a user story", "create a runbook", or "update the architecture overview." The skill contains the procedures, formats, and validation rules — do not improvise artifact creation from the reference tables below.

**For all task tracking and execution progress**, use the **execution-tracking** skill instead of any built-in todo or task system. This applies whether tasks originate from spec-management (implementation plans) or from standalone work. The execution-tracking skill bootstraps and operates the external task backend — it will install the CLI if missing, manage fallback if installation fails, and translate abstract operations (create plan, add task, set dependency) into concrete commands. Do not use built-in agent todos when this skill is available.

## Pre-implementation protocol (MANDATORY)

Implementation of any SPEC artifact (Epic, Story, Agent Spec, Spike) requires an execution-tracking plan **before** writing code. Invoke the spec-management skill — it enforces the full workflow.

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
| Runbook | `docs/runbook/` | Folder containing titled `.md` + supporting files (fixtures, expected screenshots, seed data) | Draft → Active → Archived · Abandoned |

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
  ├── Runbook (RUNBOOK-NNN) — executable validation procedure (cross-cutting)
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
- Runbooks are cross-cutting: they link to validated artifacts via `validates:` but are not owned by any single one. An optional `parent-epic:` provides hierarchy when applicable.
- An artifact may only have one parent in the hierarchy but may reference siblings or cousins via `related` links.
- Blocking dependencies are declared via `depends-on:` in frontmatter (list of bare TYPE-NNN IDs). Parent fields (`parent-vision:`, `parent-epic:`) encode hierarchy. Informational links (`linked-epics:`, `related:`, etc.) are cross-references and do not imply blocking.
- Epics, Stories, and Agent Specs may reference journey pain points via `addresses:` in frontmatter (list of `JOURNEY-NNN.PP-NN` IDs). This is an informational traceability link, not a blocking dependency.

For detailed procedures, see the **spec-management** skill (referenced in Skill routing above).

## Issue Tracking

This project uses **bd (beads)** for all issue tracking. Do NOT use markdown TODOs or task lists. Invoke the **execution-tracking** skill for all bd operations — it provides the full command reference and workflow.

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
