# Skills Drafts

This directory houses skills that are not yet ready for active use:

- Work-in-progress skills
- Temporarily disabled skills undergoing debugging
- Experimental features being explored
- Archived skills retained for reference

No agent CLI scans this directory — contents are invisible to agents unless explicitly referenced by path.

## Promoting / demoting skills

```bash
# Promote a draft to active
mv .agents/skills-drafts/my-skill .agents/skills/

# Demote an active skill to draft
mv .agents/skills/my-skill .agents/skills-drafts/
```

No changes are needed to `SKILL.md` content when moving between `skills/` and `skills-drafts/`.

## Structure

Draft skills use the same layout as active skills:

```
skills-drafts/
└── my-skill/
    ├── SKILL.md
    ├── scripts/       # optional
    ├── references/    # optional
    └── assets/        # optional
```
