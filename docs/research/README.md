# Research

Spikes and exploratory investigations for Tidegate. Each spike is a numbered artifact (`SPIKE-NNN`) in its own folder.

See [list-spikes.md](list-spikes.md) for lifecycle tracking. Architecture Decision Records live in `../adr/`, not here. A spike may produce an ADR as its output.

## Convention

Each spike folder contains a primary `.md` file with a lifecycle table:

```markdown
## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-20 | abc1234 | Question identified during X |
| Active | 2026-02-21 | def5678 | Started investigation |
| Complete | 2026-02-23 | ghi9012 | Findings informed ADR-002 |
```

Supporting docs (evaluation files, research data, diagrams) live alongside the primary file in the same folder.
