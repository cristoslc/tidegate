---
name: update-agents-core
description: Pull the latest agents-core scaffolding from upstream into the current project. Use when the user wants to update their .agents/ directory, AGENTS.md, or other scaffolding files from the shared upstream repository.
license: UNLICENSED
allowed-tools: Bash, Read, Grep, Glob
metadata:
  short-description: Update agents scaffolding from upstream
  version: 1.2.0
  author: cristos
---

# Update Agents Core

Pull the latest agents-core scaffolding from the upstream repository into the current project.

## Prerequisites

- The working tree must be clean before starting.
- `npx` is the preferred update path for skills. If unavailable, the skill falls back to pure git.
- The `agents-upstream` git remote is required for updating `AGENTS.md` and other non-skill scaffolding. If it is missing, the skill will prompt the user to add it.

## Quick check mode

If the user just wants to know whether updates are available (without applying them), run steps 1–3c of the workflow below and stop after reporting the diff. Tell the user what changed and how to run the full update when ready.

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

Fetch the upstream branch. A regular fetch (not shallow) is needed so git can compute a proper merge base for incremental merges:

```bash
git fetch agents-upstream l3-agents-core
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
  git diff HEAD..agents-upstream/l3-agents-core --stat -- .agents/ AGENTS.md import-agents-standalone.sh
  ```

If the diff is empty, tell the user they are already up to date and stop.

#### 3d. Merge

```bash
git merge agents-upstream/l3-agents-core --allow-unrelated-histories --no-edit
```

**Why `--allow-unrelated-histories`**: The initial import into most projects used `--squash`, which did not record a merge base. The flag is harmless on subsequent merges where a base already exists — git ignores it when histories are already related.

**Why no `--squash`**: A real merge commit records the merge base. This means future updates only diff the delta since the last update — not the entire upstream history. This is what makes subsequent merges fast and keeps conflicts scoped to what actually changed.

> **Migration note**: Projects that previously used the squash-based v1.1 workflow will experience one last full-scope merge on their first v1.2 update (because no merge base exists yet). Every update after that will be incremental.

#### 3e. Abort if needed

If the merge goes badly and you want to start over:

```bash
git merge --abort
```

This restores the working tree to the pre-merge state. Safe to run at any point before committing.

#### 3f. Resolve conflicts

After the merge, two categories of files need different treatment:

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

If the merge completed without conflicts, git already created the merge commit automatically (via `--no-edit`). Skip this step.

If there were conflicts that required manual resolution, the merge commit is still pending. After resolving and staging all conflicts, ask the user to confirm, then commit:

```bash
git commit -m 'chore: update agents-core scaffolding from upstream'
```
