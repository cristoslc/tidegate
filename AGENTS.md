# AGENTS.md — Tidegate

MCP gateway that sits between an agent and downstream MCP servers. Scans all string values in tool call parameters and responses for sensitive data, returns shaped denies on policy violations. Plus Squid egress proxy and Docker packaging.

See `docs/ROADMAP.md` for milestones, `docs/vision/` for product vision, `docs/threat-model/` for threat model.

## Directory structure

```
src/
├── gateway/               # TypeScript MCP gateway
│   ├── src/
│   │   ├── index.ts       # Entry: load config → connect downstream → start host
│   │   ├── host.ts        # Streamable HTTP server (agent-facing, port 4100)
│   │   ├── router.ts      # Enforcement pipeline + extractStringValues()
│   │   ├── policy.ts      # Config loading + tool allowlists
│   │   ├── scanner.ts     # L1 in-process + L2/L3 Python subprocess
│   │   ├── servers.ts     # Downstream MCP client connections
│   │   └── audit.ts       # NDJSON structured logging
│   ├── test-echo-server.ts
│   ├── tidegate.yaml      # Dev config (localhost URLs)
│   └── Dockerfile
├── scanner/               # Python L2/L3 subprocess
│   └── scanner.py         # Stateless: {value} → {allow/deny}
├── egress-proxy/          # Squid CONNECT-only proxy
├── hello-world/           # Demo MCP server
└── test/echo-server/      # Docker echo server for compose testing

docs/
├── vision/                # Product vision (VISION-NNN)
├── persona/               # User personas (PERSONA-NNN)
├── adr/                   # Architecture Decision Records (ADR-NNN)
├── research/              # Research spikes (SPIKE-NNN)
├── threat-model/
├── testing.md
└── ROADMAP.md
```

Root: `tidegate.yaml` (runtime config), `docker-compose.yaml`.

## Running

```sh
# Dev (no Docker)
cd src/gateway
npx tsx test-echo-server.ts &    # echo server on :4200
npm run dev                       # gateway on :4100

# Docker
docker compose up --build
```

## Conventions

**TypeScript** (gateway): strict mode, no `any`. MCP SDK from `@modelcontextprotocol/sdk`.

**Python** (scanner): stateless, no framework deps. `python-stdnum` for checksums. L2 patterns must have zero mathematical false positives.

**MCP SDK pattern**: per-request `Server` + `StreamableHTTPServerTransport` pair. `Server.connect()` is one-shot — fresh `Server` per request.

**Module boundaries**: `servers.ts` has zero knowledge of policy or scanning. `router.ts` only calls `servers.forward()` on the pass path. `scanner.ts` has no knowledge of tool names or field names.

**Docker**: pin base image versions, `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, non-root user, `HEALTHCHECK` in every Dockerfile.

**Security**: never commit secrets. Fail-closed on all error paths. Credentials only in MCP server containers, never in agent/gateway containers.

**Shell**: POSIX sh, not bash. Must work in Alpine.

## Key files for common tasks

| Task | Start here |
|---|---|
| Add a scanning pattern | `src/gateway/src/scanner.ts` (L1) or `src/scanner/scanner.py` (L2/L3) |
| Change enforcement pipeline | `src/gateway/src/router.ts` |
| Change config schema | `src/gateway/src/policy.ts` |
| Add transport support | `src/gateway/src/servers.ts` |
| Modify HTTP handling | `src/gateway/src/host.ts` |
| Change audit format | `src/gateway/src/audit.ts` |
| Docker topology | `docker-compose.yaml` |

## Skill routing

When the user wants to create, plan, write, update, transition, or review any documentation artifact (Vision, Journey, Epic, Story, PRD, Spike, ADR, Persona) or their supporting docs (architecture overviews, competitive analyses, journey maps), **always invoke the spec-management skill**. This includes requests like "write a PRD", "let's plan the next feature", "create an ADR for this decision", "move the spike to Active", "add a user story", or "update the architecture overview." The skill contains the procedures, formats, and validation rules — do not improvise artifact creation from the reference tables below.

## Documentation lifecycle workflow

### General rules

- Each top-level directory within `docs/` must include a `README.md` with an explanation and index.
- All artifacts MUST be titled AND numbered.
  - Good: `(ADR-192)-Multitenant-Gateway-Architecture.md`
  - Bad: `{ADR} Multitenant Gateway Architectre (#192).md`
- **Every artifact is the authoritative record of its own lifecycle.** Each must embed a lifecycle table in its frontmatter tracking every phase transition with date, commit hash, and notes. Index files (`list-<type>.md`) mirror this data as a project-wide dashboard but are not the source of truth — the artifact is.
- Each doc-type directory keeps a single lifecycle index (`list-<type>.md`, e.g., `list-prds.md`) with one table per phase and commit hash stamps for auditability.

### Artifact types

Phases are **available waypoints**, not mandatory gates. Artifacts may skip intermediate phases (e.g., Draft → Adopted) when the work is completed conversationally in a single session. The lifecycle table records only the phases the artifact actually occupied. **Abandoned** is a universal end-of-life phase available from any state — it signals the artifact was intentionally not pursued.

| Type | Path | Format | Phases |
|------|------|--------|--------|
| Product Vision | `docs/vision/` | Folder containing titled `.md` + supporting docs (competitive analysis, market research, etc.) | Draft → Active → Sunset · Abandoned |
| User Journey | `docs/journey/` | Folder containing titled `.md` with embedded Mermaid journey diagram + supporting docs | Draft → Validated → Archived · Abandoned |
| Epics | `docs/epic/` | Folder containing titled `.md` + supporting docs | Proposed → Active → Complete → Archived · Abandoned |
| User Story | `docs/story/` | Markdown file per story | Draft → Ready → Implemented · Abandoned |
| PRDs | `docs/prd/` | Folder containing titled `.md` + supporting docs | Draft → Review → Approved → Implemented → Deprecated · Abandoned |
| Research / Spikes | `docs/research/` | Folder containing titled `.md` (not `README.md`) | Planned → Active → Complete · Abandoned |
| ADRs | `docs/adr/` | Markdown file directly in phase directory | Draft → Proposed → Adopted → Retired · Superseded · Abandoned |
| Personas | `docs/persona/` | Folder containing titled `.md` + supporting docs (interview notes, research data) | Draft → Validated → Archived · Abandoned |

### Artifact hierarchy

```
Product Vision (VISION-NNN) — one per product or product area
  ├── User Journey (JOURNEY-NNN) — end-to-end user experience map
  ├── Epic (EPIC-NNN) — strategic initiative / major capability
  │     ├── User Story (STORY-NNN) — atomic user-facing requirement
  │     ├── PRD (PRD-NNN) — feature specification
  │     │     └── Implementation Plan (bd epic + swarm)
  │     └── ADR (ADR-NNN) — architectural decision (cross-cutting)
  ├── Persona (PERSONA-NNN) — user archetype (cross-cutting)
  └── Research Spike (SPIKE-NNN) — can attach to any artifact ↑
```

**Relationship rules:**
- Every Epic MUST reference a parent Vision in its frontmatter.
- Every User Journey MUST reference a parent Vision.
- Every User Story MUST reference a parent Epic.
- Every PRD MUST reference a parent Epic.
- Spikes can belong to any artifact type (Vision, Journey, Epic, Story, PRD, ADR, Persona). The owning artifact controls all spike tables.
- ADRs are cross-cutting: they link to all affected Epics/PRDs but are not owned by any single one.
- Personas are cross-cutting: they link to all Journeys, Stories, and other artifacts that reference them but are not owned by any single one.
- An artifact may only have one parent in the hierarchy but may reference siblings or cousins via `related` links.

For detailed procedures, see the **spec-management** skill (referenced in Skill routing above).
