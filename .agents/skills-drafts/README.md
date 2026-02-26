# skills-drafts/

Disabled, draft, and experimental skills. No agent CLI scans this directory — contents are invisible to agents unless explicitly referenced by path.

## When to use this directory

- **Work in progress**: Skills being authored or iterated on before they're ready for use.
- **Temporarily disabled**: Active skills pulled out of rotation (debugging, seasonal, etc.).
- **Experimental**: Ideas being explored that may never graduate to `skills/`.
- **Archived**: Previously active skills kept for reference but no longer needed.

## Promoting a skill

```bash
mv .agents/skills-drafts/my-skill .agents/skills/
```

## Demoting a skill

```bash
mv .agents/skills/my-skill .agents/skills-drafts/
```

## Structure

Skill directories here follow the same format as active skills:

```
skills-drafts/
└── my-skill/
    ├── SKILL.md          # Standard frontmatter + instructions
    ├── scripts/          # Optional
    ├── references/       # Optional
    └── assets/           # Optional
```

No changes are needed to `SKILL.md` content when moving between `skills/` and `skills-drafts/`.
