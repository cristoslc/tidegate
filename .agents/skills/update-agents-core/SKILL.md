---
name: update-agents-core
description: Pull the latest agents-standalone scaffolding from upstream into the current project. Use when the user wants to update their .agents/ directory, AGENTS.md, or other scaffolding files from the shared upstream repository.
license: UNLICENSED
allowed-tools: Bash, Read, Grep, Glob
metadata:
  short-description: Update agents scaffolding from upstream
---

# Update Agents Core

Pull the latest agents-standalone scaffolding from the upstream repository into the current project.

## Prerequisites

This skill assumes the project was originally set up via the `import-agents-standalone.sh` script, which configures a git remote named `agents-upstream` pointing at the source repository.

## Workflow

### 1. Preflight checks

1. Confirm the working tree is clean (`git status`). If there are uncommitted changes, stop and ask the user to commit or stash first — the merge may produce conflicts that are easier to resolve on a clean tree.
2. Verify the `agents-upstream` remote exists:
   ```bash
   git remote get-url agents-upstream
   ```
   If it does not exist, tell the user the remote is missing and show them how to add it:
   ```
   git remote add agents-upstream https://github.com/cristoslc/LLM-personal-agent-patterns.git
   ```
   Then ask them to re-invoke the skill after adding it.

### 2. Fetch latest

```bash
git fetch agents-upstream l3-standalone
```

### 3. Check for changes

Compare the fetched ref to what was last merged. Show the user a summary of what changed upstream:

```bash
git diff HEAD...agents-upstream/l3-standalone --stat
```

If the diff is empty, tell the user they are already up to date and stop.

### 4. Merge

```bash
git merge agents-upstream/l3-standalone --allow-unrelated-histories --squash
```

The `--allow-unrelated-histories` flag is always required because the initial import used `--squash`, which does not record a merge base.

### 5. Review

Show the user what was staged:

```bash
git diff --cached --stat
```

If there are conflicts, help the user resolve them. Scaffolding files (AGENTS.md, SKILL.md files) may have been customized locally — prefer the user's version for content changes and the upstream version for structural additions.

### 6. Commit

Ask the user to confirm, then commit:

```bash
git commit -m 'chore: update agents-core scaffolding from upstream'
```
