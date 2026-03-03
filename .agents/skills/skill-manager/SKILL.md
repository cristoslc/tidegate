---
name: skill-manager
description: Full-lifecycle skill management — discover, install, audit, update, and detect drift for agent skills. Wraps `npx skills` when available, falls back to POSIX tooling. Use when installing shared skills, checking for upstream changes, auditing skill safety, or managing skills across projects.
license: UNLICENSED
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
metadata:
  short-description: Discover, install, audit, update, and drift-detect agent skills
  related-adr: ADR-002-Remote-Skills-Reference-Pattern, ADR-003-Skill-Manager-Wraps-npx-Skills
  version: 2.1.0
  author: cristos
---

# Skill Manager

Full-lifecycle skill management for agent skills per ADR-002 and ADR-003. Wraps `npx skills` when available, falls back to POSIX tooling.

## Quick reference

| Operation | Command |
|---|---|
| Discover skills | `npx skills find <query>` or GitHub/skills.sh search |
| Install a skill | `scripts/install.sh <repo-url> <skill-path> [ref] [target-dir]` |
| Audit a skill | `scripts/audit.sh <skill-dir>` |
| Fetch (low-level) | `scripts/fetch-remote-skill.sh <repo-url> <skill-path> [ref] [target-dir]` |
| Check drift | `scripts/drift.sh <skill-dir>` or `scripts/drift.sh --all` |
| Update a skill | `scripts/update.sh <skill-dir> [target-dir]` |
| Verify setup | `scripts/smoke-test.sh` |

## Concepts

### `.source.yml` provenance manifest

Every skill fetched from a remote repo gets a `.source.yml` file written alongside its `SKILL.md`. This manifest records:

- **Where** the skill came from (repository, ref, path, pinned commit)
- **When** it was fetched and by whom
- **Integrity** hash for drift detection

The schema is defined in ADR-002 and formalized as:
- JSON Schema: `references/source-yml-schema.json`
- Jinja template: `references/source-yml.template.j2`

Local-only skills (authored in this repo) do NOT have `.source.yml`. Its absence is the signal that a skill is locally maintained.

### Drift detection

A fetched skill is **in sync** when:

```
sha256(file paths + file content hashes, excluding .source.yml) == .source.yml → integrity.digest
```

Drift means either upstream changed (re-fetch to update) or the local copy was modified (document customizations or fork to local-only by removing `.source.yml`).

## Discovery

### Ecosystem search (npx skills)

When Node.js is available:

```bash
npx skills find "code review"
```

This queries the skills.sh index and returns matching skills with names, descriptions, and install commands.

### Skills.sh web search

Browse the skills directory at `https://skills.sh`. Search by category, keyword, or browse featured skills. Each listing includes the `npx skills add` command.

### GitHub search fallback

When ecosystem tooling is unavailable, search GitHub directly:

```bash
# Search for repos containing SKILL.md (Agent Skills convention)
# GitHub web: search for "path:.agents/skills SKILL.md" + your query
```

Look for repositories that follow the Agent Skills convention (`.agents/skills/*/SKILL.md`).

### Project-context recommendations

When helping a user find relevant skills, examine their project for context:

1. **Check AGENTS.md** — what skills are already referenced in routing rules?
2. **List installed skills** — `ls .agents/skills/` or `.claude/skills/`
3. **Identify gaps** — compare installed capabilities against common needs:
   - Code review / PR review
   - Testing and test generation
   - Documentation generation
   - Security scanning
   - Deployment and CI/CD
   - Database management
4. **Suggest based on tech stack** — examine `package.json`, `Cargo.toml`, `go.mod`, etc. to recommend stack-specific skills

## Installation

### Installation interview

Before running the install script, interview the user to determine scope, git tracking, and version. Gather answers via the decision table below, then map them to `install.sh` arguments.

#### Decision table

| # | Decision | Options | Default |
|---|----------|---------|---------|
| 1 | **Scope** — Where to install? | Project (`.agents/skills/`), User-global (`~/.claude/skills/`) | Project |
| 2 | **Git tracking** — Track in version control? *(only when scope = project)* | Commit with repo, Gitignore, Decide later | Commit |
| 3 | **Version** — Which ref to install? | Latest (HEAD), Specific tag/branch, Specific commit SHA | Latest |

Q2 is **conditional** — skip it when scope = user-global (the install target is outside the repo).

#### Claude Code structured prompts

When `AskUserQuestion` is available, use two rounds of structured prompts.

**Round 1 — scope + version** (ask together):

```yaml
AskUserQuestion:
  questions:
    - question: "Where should this skill be installed?"
      header: "Scope"
      options:
        - label: "Project (Recommended)"
          description: "Install to .agents/skills/ — shared with team via version control"
        - label: "User-global"
          description: "Install to ~/.claude/skills/ — available across all your projects, not committed"
      multiSelect: false
    - question: "Which version should be installed?"
      header: "Version"
      options:
        - label: "Latest (Recommended)"
          description: "Fetch the default branch tip (HEAD)"
        - label: "Specific tag or branch"
          description: "You'll be asked for the exact ref name next"
        - label: "Specific commit SHA"
          description: "You'll be asked for the full 40-character hash next"
      multiSelect: false
```

**Round 2 — git tracking** (only if scope = project):

```yaml
AskUserQuestion:
  questions:
    - question: "Should this skill be tracked in git?"
      header: "Git tracking"
      options:
        - label: "Commit with repo (Recommended)"
          description: "Stage the skill files — team members get it when they pull"
        - label: "Gitignore"
          description: "Add to .gitignore — stays local to your machine"
        - label: "Decide later"
          description: "Install without touching git configuration"
      multiSelect: false
```

If version = "Specific tag or branch" or "Specific commit SHA", ask a conversational follow-up for the ref value (free-text input — no structured prompt needed).

#### Fallback for non-Claude runtimes

If structured prompts are not available, ask the same questions conversationally and accept free-text answers. Use the defaults (project scope, commit, latest) if the user says "just install it" or similar.

#### Mapping answers to install.sh arguments

| Answer | install.sh argument |
|--------|---------------------|
| Scope = Project | `target-dir` = `.agents/skills` |
| Scope = User-global | `target-dir` = `~/.claude/skills` |
| Version = Latest | `ref` = `HEAD` |
| Version = specific | `ref` = user-provided value |

#### Post-install actions

After `install.sh` succeeds (exit 0 or 1), apply git actions based on the interview answers:

| Answer | Post-install action |
|--------|---------------------|
| Git tracking = Commit | `git add <skill-dir>` — inform user files are staged, do **not** commit |
| Git tracking = Gitignore | Append the skill directory path to `.gitignore` |
| Git tracking = Decide later | No git action |
| Scope = User-global | No git action (regardless of Q2) |

### Install with safety gate

Called by the interview procedure above. Wraps the fetch-and-stamp workflow with a post-install safety audit and automatic rollback on critical findings.

```bash
bash scripts/install.sh \
  https://github.com/acme/shared-skills \
  .agents/skills/code-review \
  v2.1.0 \
  ../../.agents/skills
```

**Backend selection:** When `npx` is available, `install.sh` attempts `npx skills add` first. If `npx` is unavailable or the command fails, it falls back to `fetch-remote-skill.sh` (POSIX path).

**After install:**
1. Stamps `.source.yml` provenance manifest
2. Runs `audit.sh` on the installed skill
3. If audit finds **critical** issues (exit 2): rolls back the installation
4. If audit finds **warnings** (exit 1): skill installed, review recommended
5. If audit is **clean** (exit 0): skill installed and ready

**Exit codes:**
- `0` — installed, audit clean
- `1` — installed, audit warnings
- `2` — rolled back due to critical audit findings

### Optional: `--agent` flag

When using the npx backend, pass `--agent <name>` to scope the installation:

```bash
bash scripts/install.sh \
  https://github.com/acme/shared-skills \
  .agents/skills/code-review \
  v2.1.0 \
  .agents/skills \
  --agent claude
```

## Safety review

### Automated audit

Run `audit.sh` on any skill directory to scan for security patterns:

```bash
bash scripts/audit.sh .agents/skills/code-review
```

The audit checks for:

| Category | Severity | What it detects |
|---|---|---|
| Exfiltration | Critical | `curl --data`, `wget --post`, outbound POST |
| Env harvesting | Critical/Warning | `printenv`, references to KEY/TOKEN/SECRET vars |
| Credential access | Critical | SSH keys, AWS creds, `.env`, service accounts |
| Obfuscation | Critical/Warning | `base64 -d`, `eval $var` |
| Reverse shells | Critical | `/dev/tcp`, netcat listeners, bash reverse shells |
| Curl-pipe-shell | Critical | `curl ... \| bash`, `wget ... \| sh` |
| Prompt injection | Warning | "ignore previous instructions", role hijacking |
| Known malicious | Critical | `rm -rf /`, `chmod 777`, fifo+netcat |

**Interpreting results:**
- **Exit 0 (clean):** No findings. Skill is safe to activate.
- **Exit 1 (warnings):** Review the flagged patterns. Most are false positives in legitimate skills. Check context before activating.
- **Exit 2 (critical):** Do not activate. Review the findings file:line references. If using `install.sh`, the skill was already rolled back.

## Fetching a skill (low-level)

### Prerequisites

- `git` available on PATH
- POSIX tools: `tar`, `sha256sum` or `shasum`, `date`

### Workflow

1. Run the fetch script:
   ```bash
   bash scripts/fetch-remote-skill.sh \
     https://github.com/acme/shared-skills \
     .agents/skills/code-review \
     v2.1.0 \
     ../../.agents/skills
   ```

2. The script will:
   - Shallow-clone the repository at the specified ref
   - Extract the skill directory from the clone
   - Copy it to the target skills directory
   - Compute an integrity hash of the fetched files
   - Generate `.source.yml` from the Jinja template
   - Clean up the temporary clone

3. Verify the result:
   ```bash
   cat .agents/skills/code-review/.source.yml
   ```

### Arguments

| Position | Name | Required | Default | Description |
|---|---|---|---|---|
| 1 | `repo-url` | Yes | — | Git remote URL (HTTPS or SSH) |
| 2 | `skill-path` | Yes | — | Path to skill directory within the source repo |
| 3 | `ref` | No | `HEAD` | Branch, tag, or commit to fetch |
| 4 | `target-dir` | No | `.agents/skills` | Local directory to install the skill into |

## Updates

Use `update.sh` to update skills using their `.source.yml` coordinates. This is the workaround for [npx skills update #337](https://github.com/vercel-labs/skills/issues/337) (project-scoped updates broken).

```bash
bash scripts/update.sh .agents/skills/code-review
```

The script:
1. Reads `repository`, `ref`, and `path` from `.source.yml`
2. Re-runs `install.sh` with the same coordinates (including safety audit)
3. Compares old vs new integrity digest
4. Reports "up to date" (digest unchanged) or "updated" (digest changed)

**Exit codes** mirror `install.sh`: 0=clean, 1=warnings, 2=rolled back.

To update to a different ref, edit `.source.yml` first or re-install directly:

```bash
bash scripts/install.sh \
  https://github.com/acme/shared-skills \
  .agents/skills/code-review \
  v3.0.0
```

## Drift detection

### Single skill

```bash
bash scripts/drift.sh .agents/skills/code-review
```

### All skills in a directory

```bash
bash scripts/drift.sh --all .agents/skills
```

Scans all subdirectories containing `.source.yml`. Local-only skills (no `.source.yml`) are skipped.

### Cross-project comparison

```bash
bash scripts/drift.sh --cross /project-a/.agents/skills /project-b/.agents/skills
```

Compares skill versions across two projects by `.source.yml` digest and ref. Reports skills that differ, are missing from one project, or are identical.

**Exit codes:** `0` = all in sync, `1` = drift detected.

## Removing a fetched skill

Delete the skill directory (including `.source.yml`). No other cleanup is required:

```bash
rm -rf .agents/skills/code-review
```

## Converting a fetched skill to local-only

If you have customized a fetched skill and want to take ownership of it locally:

```bash
rm .agents/skills/code-review/.source.yml
```

The skill is now treated as locally-authored. Drift detection no longer applies.

## Verification

Run the smoke test to validate all operations end-to-end:

```bash
bash scripts/smoke-test.sh
```

The smoke test exercises:
- **AC-1..AC-5:** Fetch, provenance, field validation, integrity, idempotency (ADR-002)
- **AC-6..AC-9:** Install via POSIX path, audit clean skill, audit detects bad patterns, rollback on critical (STORY-005)
- **AC-10..AC-11:** Update with changes, update no-op (STORY-006)
- **AC-12..AC-13:** Drift detection clean, drift detection modified (STORY-007)

## Skill references

| File | Purpose |
|---|---|
| `references/source-yml-schema.json` | JSON Schema for `.source.yml` validation |
| `references/source-yml.template.j2` | Jinja2 template for `.source.yml` generation |
| `scripts/install.sh` | Install with safety-gated activation |
| `scripts/audit.sh` | Security pattern scanner |
| `scripts/update.sh` | Update using .source.yml coordinates |
| `scripts/drift.sh` | Drift detection (single, all, cross-project) |
| `scripts/fetch-remote-skill.sh` | Low-level fetch-and-stamp (POSIX fallback) |
| `scripts/smoke-test.sh` | End-to-end verification |
