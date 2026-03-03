---
name: update-agents-core
description: Pull the latest agents-core scaffolding from upstream into the current project. Use when the user wants to update their .agents/ directory, AGENTS.md, or other scaffolding files from the shared upstream repository.
license: UNLICENSED
allowed-tools: Bash, Read, Grep, Glob
metadata:
  short-description: Update agents scaffolding from upstream
  version: 1.1.0
  author: cristos
---

# Update Agents Core

Pull the latest agents-core scaffolding from the upstream repository into the current project.

## Prerequisites

- The working tree must be clean before starting.
- `npx` is the preferred update path for skills. If unavailable, the skill falls back to pure git.
- The `agents-upstream` git remote is required for updating `AGENTS.md` and other non-skill scaffolding. If it is missing, the skill will prompt the user to add it.

## Workflow

### 1. Preflight checks

Confirm the working tree is clean (`git status`). If there are uncommitted changes, stop and ask the user to commit or stash first — the merge may produce conflicts that are easier to resolve on a clean tree.

### 2. Update skills via npx (preferred)

Check whether `npx` is available:

```bash
command -v npx >/dev/null 2>&1
```

If available, run:

```bash
npx skills add https://github.com/cristoslc/LLM-personal-agent-patterns@l3-agents-core --yes
```

Track the outcome:
- **npx succeeded** — skills are updated. Proceed to step 3 to update `AGENTS.md` and other non-skill scaffolding via git.
- **npx failed or unavailable** — proceed to step 3, which will handle updating everything (skills included) via git.

### 3. Git procedure — AGENTS.md and scaffolding (and full fallback)

#### 3a. Verify remote

Verify the `agents-upstream` remote exists:

```bash
git remote get-url agents-upstream
```

If it does not exist, tell the user the remote is missing and show them how to add it:

```
git remote add agents-upstream https://github.com/cristoslc/LLM-personal-agent-patterns.git
```

Then ask them to re-invoke the skill after adding it.

#### 3b. Fetch latest

Use a shallow fetch — only the tip commit is needed because the merge always squashes (no merge base is recorded between the two histories):

```bash
git fetch --depth=1 agents-upstream l3-agents-core
```

#### 3c. Check for changes

Compare the current HEAD to the fetched upstream. Use a two-dot diff (three-dot is unreliable with unrelated histories).

The diff scope depends on whether npx already updated the skills:

- **If npx succeeded** — narrow scope (only non-skill scaffolding):
  ```bash
  git diff HEAD..agents-upstream/l3-agents-core --stat -- AGENTS.md .agents/README.md .agents/AGENTS-SETUP.md import-agents-standalone.sh
  ```
- **If npx failed or was unavailable** — full scope:
  ```bash
  git diff HEAD..agents-upstream/l3-agents-core --stat -- .agents/ AGENTS.md
  ```

If the diff is empty, tell the user they are already up to date and stop.

#### 3d. Merge

```bash
git merge agents-upstream/l3-agents-core --allow-unrelated-histories --squash
```

The `--allow-unrelated-histories` flag is always required because the initial import used `--squash`, which does not record a merge base.

#### 3e. Resolve conflicts

After the squash merge, two categories of files need different treatment:

**Skills and scaffolding — remote wins**

All files under `.agents/` (skills, README, AGENTS-SETUP.md, etc.) and the `import-agents-standalone.sh` script are **upstream-owned**. If there are conflicts on any of these files, accept the upstream version unconditionally:

```bash
# For each conflicted file under .agents/ or import-agents-standalone.sh:
git checkout --theirs <file>
git add <file>
```

Local projects should not modify files inside `.agents/skills/` directly. Project-specific customizations belong in `AGENTS.md` or in separate skill directories that upstream does not ship.

**AGENTS.md — reconcile**

`AGENTS.md` is the one file that lives at the boundary between upstream scaffolding and local project configuration. Upstream may add new routing rules, artifact types, or structural sections, while the local project may have added its own routing rules, custom artifact types, or project-specific workflow notes.

When `AGENTS.md` has conflicts:

1. Show the user the conflict hunks (`git diff AGENTS.md` or read the file to see conflict markers).
2. **Preserve local additions** — any routing rules, artifact types, or sections the project added that do not exist upstream.
3. **Accept upstream changes** — new or modified sections from upstream take priority over local edits to the *same* section. If upstream restructured a section the project also edited, adopt the upstream structure and re-apply the local additions on top.
4. **Delete stale local overrides** — if the local project modified an upstream-owned section (e.g., changed the artifact-types table or hierarchy diagram) and upstream has a newer version of that same section, the upstream version wins. Local projects should extend via new sections, not by editing upstream sections in place.
5. Stage the resolved file: `git add AGENTS.md`

If there are no conflicts (clean merge), no manual reconciliation is needed.

### 4. Review

Show the user what was staged:

```bash
git diff --cached --stat
```

Walk through the changes briefly so the user understands what upstream updated.

### 5. Commit

Ask the user to confirm, then commit:

```bash
git commit -m 'chore: update agents-core scaffolding from upstream'
```
