# AGENTS.md

## Documentation lifecycle workflow

### General rules

- Each top-level directory within `docs/` must include a `README.md` with an explanation and index.
- All artifacts MUST be titled AND numbered.
  - Good: `(ADR-192)-Multitenant-Gateway-Architecture.md`
  - Bad: `{ADR} Multitenant Gateway Architectre (#192).md`
- **Every artifact is the authoritative record of its own lifecycle.** Each must embed a lifecycle table in its frontmatter tracking every phase transition with date, commit hash, and notes. Index files (`list-<type>.md`) mirror this data as a project-wide dashboard but are not the source of truth — the artifact is.
- Each doc-type directory keeps a single lifecycle index (`list-<type>.md`, e.g., `list-prds.md`) with one table per phase and commit hash stamps for auditability.

### Lifecycle table format (embedded in every artifact)

```markdown
### Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-24 | abc1234 | Initial creation |
| Active  | 2026-02-25 | def5678 | Dependency X satisfied |
```

Commit hashes reference the repo state at the time of the transition, not the commit that writes the hash stamp itself. Commit first, then stamp the hash and amend — the pre-amend hash is the correct value.

When moving an artifact between phase directories: update the artifact's status field, append a row to its lifecycle table, then update the index file to match.

### Artifact types

| Type | Path | Format | Phases |
|------|------|--------|--------|
| Product Vision | `docs/vision/` | Single markdown file per product/area | Draft → Active → Sunset |
| Epics | `docs/epic/` | Folder containing titled `.md` + supporting docs | Proposed → Active → Complete → Archived |
| PRDs | `docs/prd/` | Folder containing titled `.md` + supporting docs | Draft → Review → Approved → Implemented → Deprecated |
| Research / Spikes | `docs/research/` | Folder containing titled `.md` (not `README.md`) | Planned → Active → Complete |
| ADRs | `docs/adr/` | Markdown file directly in phase directory | Draft → Proposed → Adopted → Retired · Superseded |

### Artifact hierarchy

```
Product Vision (VISION-NNN) — one per product or product area
  ├── Epic (EPIC-NNN) — strategic initiative / major capability
  │     ├── PRD (PRD-NNN) — feature specification
  │     │     └── Implementation Plan (bd epic + swarm)
  │     └── ADR (ADR-NNN) — architectural decision (cross-cutting)
  └── Research Spike (SPIKE-NNN) — can attach to any artifact ↑
```

**Relationship rules:**
- Every Epic MUST reference a parent Vision in its frontmatter.
- Every PRD MUST reference a parent Epic.
- Spikes can belong to any artifact type (Vision, Epic, PRD, ADR). The owning artifact controls all spike tables.
- ADRs are cross-cutting: they link to all affected Epics/PRDs but are not owned by any single one.
- An artifact may only have one parent in the hierarchy but may reference siblings or cousins via `related` links.

### Product Vision (VISION-NNN)

The highest-level specification artifact. Defines *what the product is* and *why it exists*. There is typically one per product or major product area.

- Frontmatter must include: title, status, author, created date, last updated date.
- Must define: target audience, value proposition, success metrics, non-goals.
- Should be stable — update infrequently. If a Vision needs frequent revision, it is likely scoped too narrowly (should be an Epic) or too early (needs a Spike first).
- Vision documents do NOT contain implementation details, timelines, or task breakdowns.

### Epics (EPIC-NNN)

A strategic initiative that decomposes into multiple PRDs, Spikes, and ADRs. Epics are the **coordination layer** between product vision and feature-level work.

- Frontmatter must include: title, status, author, created date, last updated date, parent Vision, success criteria.
- Must define: goal/objective, scope boundaries, child PRD list (updated as PRDs are created), and key dependencies on other Epics.
- An Epic is "Complete" when all child PRDs reach "Implemented" and success criteria are met.
- An Epic is "Archived" after completion, when it no longer requires active reference.

### PRDs (PRD-NNN)

- Spec file frontmatter must include: title, status, author, created date, last updated date, parent Epic, and linked research artifacts and/or ADRs.
- Should be scoped to something a team (or agent) can ship and validate independently.

### Research spikes (SPIKE-NNN)

- Number in intended execution order — sequence communicates priority.
- Frontmatter must state: question, gate (e.g., Pre-MVP), PRD risks addressed, dependencies, and what it blocks.
- Gating spikes must define go/no-go criteria with measurable thresholds (not just "investigate X").
- Gating spikes must recommend a specific pivot if the gate fails (not just "reconsider approach").
- Spikes can belong to any artifact type (Vision, Epic, PRD, ADR). The owning artifact controls all spike tables: questions, risks, gate criteria, dependency graph, execution order, phase mappings, and risk coverage. There is no separate research roadmap document.

### Implementation plans (bd execution bridge)

Implementation Plans are **not** a doc-type artifact. They are the bridge between declarative specs (`docs/`) and execution tracking (`bd`). A static Markdown plan goes stale the moment work begins — instead, plans are materialized as live `bd` epics with dependency-ordered child tasks.

**Seeding a plan from a spec:**
1. A PRD (or Epic) may include an "Implementation Approach" section sketching the high-level plan. This is guidance that seeds the `bd` plan, not the plan of record.
2. When work begins, the agent creates a `bd` epic from that outline:
   ```
   bd create "Implement PRD-003 CSV Export" --type=epic --external-ref PRD-003
   ```
3. Child tasks are created under the epic with dependencies:
   ```
   bd create "Add export endpoint" --parent <epic-id> --labels spec:PRD-003
   bd create "Write serializer" --parent <epic-id> --deps <endpoint-id> --labels spec:PRD-003
   ```

**Lineage and cross-PRD impact:**
- **`--external-ref`** records which spec *seeded* the plan (immutable origin).
- **`spec:<ID>` labels** record which specs a task *currently affects* (mutable, may grow).
- When an agent discovers a task impacts additional PRDs, it adds labels and links:
  ```
  bd label add <task-id> spec:PRD-007
  bd dep relate <task-id> <other-prd-task-id>
  ```
- Use `bd dep add --type=discovered-from` to capture provenance when new tasks spawn from existing ones.
- To query all work affecting a spec: `bd list --label spec:PRD-003`.

**Parallel coordination:**
- `bd swarm create <epic-id>` sets up a swarm — agents use `bd ready` to pick up unblocked work.
- For repeatable workflows, define a formula in `.beads/formulas/` and instantiate with `bd mol pour`.

**Closing the loop:**
- Progress is tracked in `bd`, not in the spec doc. The PRD's lifecycle table records the phase transition to "Implemented" once the `bd` epic completes.
- Cross-PRD tasks should be noted in each affected PRD's lifecycle table entry (e.g., "Implemented — shared serializer also covers PRD-007").

**Fallback:** If `bd` is unavailable, use the agent's built-in todo system with the same canonical states (`todo`, `in_progress`, `blocked`, `done`) per the external-task-management skill. The plan structure (ordered steps, dependencies, completion tracking) remains the same — only the backend changes. Lineage is maintained by including artifact IDs in task titles or notes (e.g., `[PRD-003] Add export endpoint`).
