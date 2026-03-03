# Research Spikes (SPIKE-NNN)

**Template:** [spike-template.md.j2](spike-template.md.j2)

```mermaid
stateDiagram-v2
    [*] --> Planned
    Planned --> Active
    Active --> Complete
    Complete --> [*]
    Planned --> Abandoned
    Active --> Abandoned
    Abandoned --> [*]
```

A time-boxed investigation to reduce uncertainty before committing to a path. Follow **Kent Beck's spike concept** (from *Extreme Programming Explained*): a Spike is a short, focused experiment that answers a specific technical or design question — it produces *knowledge*, not shippable code. When sensible, use an agent (with a separate worktree, if necessary) to explore multiple candidates from within the spike simultaneously.

- Number in intended execution order — sequence communicates priority.
- Gating spikes must define go/no-go criteria with measurable thresholds (not just "investigate X").
- Gating spikes must recommend a specific pivot if the gate fails (not just "reconsider approach").
- Spikes can belong to any artifact type (Vision, Epic, Agent Spec, ADR, Persona). The owning artifact controls all spike tables: questions, risks, gate criteria, dependency graph, execution order, phase mappings, and risk coverage. There is no separate research roadmap document.
