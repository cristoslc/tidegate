# Agent Environment Setup

One-time verification that the cross-CLI skill infrastructure is in place.
Run these checks, fix anything missing, then remove the `@.agents/AGENTS-SETUP.md` line from `AGENTS.md` so this doesn't consume context on future sessions.

## 1. Skill directory

Verify `.agents/skills/` exists at the repo root. This is the canonical location for all agent skills — Codex CLI and Gemini CLI discover it natively.

```bash
# Expected: directory exists
test -d .agents/skills && echo "OK" || echo "MISSING: mkdir -p .agents/skills"
```

## 2. Claude Code symlink

Claude Code only scans `.claude/skills/`, not `.agents/skills/`. A symlink bridges the gap.

```bash
# Expected: symlink .claude/skills -> ../.agents/skills
test -L .claude/skills && echo "OK" || echo "MISSING: mkdir -p .claude && ln -sfn ../.agents/skills .claude/skills"
```

If missing:

```bash
mkdir -p .claude
ln -sfn ../.agents/skills .claude/skills
```

Verify the symlink target resolves:

```bash
ls .claude/skills/ > /dev/null 2>&1 && echo "OK" || echo "BROKEN: symlink target does not resolve"
```

## 3. Gemini CLI context (optional)

If using Gemini CLI, verify it discovers `AGENTS.md` as a context file. Two options — either works:

**Option A**: A `GEMINI.md` redirect file exists at the repo root containing `@AGENTS.md`.

**Option B**: User's Gemini CLI settings include `AGENTS.md` in the filename list (`~/.gemini/settings.json`):

```json
{
  "context": {
    "fileName": ["AGENTS.md", "GEMINI.md"]
  }
}
```

Option B is a user-level setting and cannot be verified or set from within the repo. If a `GEMINI.md` redirect file is the team's chosen approach, verify it exists:

```bash
test -f GEMINI.md && echo "OK" || echo "MISSING: echo '@AGENTS.md' > GEMINI.md"
```

## 4. Context file redirects

Verify the redirect files point to AGENTS.md:

```bash
# CLAUDE.md should import AGENTS.md
grep -q '@AGENTS.md' CLAUDE.md 2>/dev/null && echo "OK" || echo "MISSING or incorrect: CLAUDE.md should contain @AGENTS.md"
```

## 5. Beads stealth-mode remediation

If the project uses `bd` (beads) and `.beads/` is **not** tracked by git, it was likely initialized with the now-deprecated `bd init --stealth` flag. Stealth mode adds `.beads/` to `.git/info/exclude` (and possibly `~/.config/git/ignore`), which means issue data, hooks, and config are invisible to version control.

To switch to tracked mode:

```bash
# 1. Check if .beads/ is tracked
git ls-files --error-unmatch .beads/ 2>/dev/null && echo "Already tracked" && exit 0

# 2. Remove from local excludes
sed -i.bak '/.beads/d' .git/info/exclude 2>/dev/null && rm -f .git/info/exclude.bak

# 3. Stage and commit
git add .beads/
git commit -m 'chore: track .beads/ directory (stealth-mode remediation)'
```

If `.beads/` is also in `~/.config/git/ignore`, the user must remove that entry manually (it is a global user-level setting).

## 6. Cleanup

After all checks pass:

1. Remove the line `@.agents/AGENTS-SETUP.md` from `AGENTS.md`.
2. Do **not** commit the removal -- the reference should stay in the committed version so that fresh clones and new contributors get verified automatically.

If any check failed, fix it first, then re-run the checks before removing the reference.
