# Documentation

Specification artifacts and supporting documents for Tidegate. Each subdirectory contains a specific artifact type with its own README and lifecycle index.

## Artifact directories

| Directory | Type | Description |
|-----------|------|-------------|
| [vision/](vision/) | Product Vision | High-level product direction and value proposition |
| [journey/](journey/) | User Journey | End-to-end user experience maps with Mermaid diagrams |
| [epic/](epic/) | Epic | Strategic initiatives decomposed into Specs and Stories |
| [story/](story/) | User Story | Atomic user-facing requirements with acceptance criteria |
| [research/](research/) | Research Spike | Investigations and exploratory analysis |
| [adr/](adr/) | ADR | Architecture Decision Records with alternatives and rationale |
| [persona/](persona/) | Persona | User archetypes informing design and prioritization |

## Supporting directories

| Directory | Description |
|-----------|-------------|
| [threat-model/](threat-model/) | Threat model, defenses, and security scorecard |

## Other files

| File | Description |
|------|-------------|
| [ROADMAP.md](ROADMAP.md) | Milestone tracker |
| [testing.md](testing.md) | Testing guide |

## Conventions

- All artifacts are titled and numbered: `(TYPE-NNN)-Title.md`
- Each artifact embeds a lifecycle table tracking phase transitions
- Each directory has a `list-<type>.md` index mirroring lifecycle data
- The artifact is the source of truth; index files are dashboards
- See [AGENTS.md](../AGENTS.md) for full lifecycle rules and artifact hierarchy
