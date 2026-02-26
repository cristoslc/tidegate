# .agents/ Directory

The `.agents/` directory is the canonical home for cross-CLI agent infrastructure. All three major coding agent CLIs (Claude Code, Codex CLI, Gemini CLI) discover skills and configuration here.

## Directory Structure

```
.agents/
├── README.md              # This file
├── AGENTS-SETUP.md        # First-run bootstrap verification
├── skills/                # Active skills — auto-discovered by agents
│   └── my-skill/
│       └── SKILL.md
└── skills-drafts/         # Disabled/draft skills — invisible to agents
    └── wip-skill/
        └── SKILL.md
```

## Skills Lifecycle

### Active skills (`skills/`)

Any directory under `skills/` containing a `SKILL.md` file is automatically discovered by all three CLIs at session start. Metadata loads immediately; full instructions load on demand (progressive disclosure).

### Disabled skills (`skills-drafts/`)

Skills that aren't ready for use — works in progress, experimental ideas, or temporarily disabled skills — live in `skills-drafts/`. No CLI scans this directory, so its contents are completely invisible to agents unless explicitly referenced by path.

This relies on the Agent Skills spec's **inclusion model**: CLIs scan specific paths (`skills/`), and anything outside those paths doesn't exist to the agent. This is more robust than frontmatter flags like `disable-model-invocation` (Claude Code only, ignored by Codex and Gemini) or dotfile-prefix conventions (not specced, could break with future CLI versions).

### Promote / demote workflow

```bash
# Enable a draft skill
mv .agents/skills-drafts/my-skill .agents/skills/

# Disable an active skill
mv .agents/skills/my-skill .agents/skills-drafts/
```

The directory structure inside `skills-drafts/` mirrors `skills/` exactly — same `SKILL.md` format, same subdirectories (`scripts/`, `references/`, `assets/`). No reformatting needed when promoting or demoting.

## Why `.agents/` and not `.claude/` or `.gemini/`?

`.agents/skills/` is the path that Codex CLI and Gemini CLI scan natively. Claude Code scans `.claude/skills/` instead, bridged by a symlink:

```bash
ln -sfn ../.agents/skills .claude/skills
```

One canonical location, one symlink — all three CLIs see the same skills. See `AGENTS-SETUP.md` for the full bootstrap verification.
