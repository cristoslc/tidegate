---
name: remote-skill-manager
description: Fetch skills from remote Git repositories, generate `.source.yml` provenance manifests, detect drift, and update fetched skills. Use when installing shared skills from external repos, checking for upstream changes, or auditing skill provenance.
license: UNLICENSED
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
metadata:
  short-description: Fetch, track, and update remote skills
  related-adr: ADR-002-Remote-Skills-Reference-Pattern
  version: 1.0.0
  author: cristos
---

# Remote Skill Manager

Fetch skills from remote Git repositories into the local `.agents/skills/` directory and maintain `.source.yml` provenance manifests per ADR-002.

## Quick reference

| Operation | Command |
|---|---|
| Fetch a skill | `scripts/fetch-remote-skill.sh <repo-url> <skill-path> [ref] [target-dir]` |
| Check drift | Compare `integrity.digest` in `.source.yml` to a fresh hash of local files |
| Update a skill | Re-run the fetch script — it overwrites and re-stamps |
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
sha256(tar of skill files, excluding .source.yml) == .source.yml → integrity.digest
```

Drift means either upstream changed (re-fetch to update) or the local copy was modified (document customizations or fork to local-only by removing `.source.yml`).

## Fetching a skill

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

## Updating a skill

Re-run the fetch script with the same arguments. The script is idempotent:

- Overwrites local skill files with the latest upstream version
- Generates a fresh `.source.yml` with updated `fetched.at`, `source.commit`, and `integrity.digest`

To update to a new version:

```bash
bash scripts/fetch-remote-skill.sh \
  https://github.com/acme/shared-skills \
  .agents/skills/code-review \
  v3.0.0
```

## Checking drift

To manually check if a fetched skill has drifted from its recorded state:

```bash
# Compute current hash (excluding .source.yml)
CURRENT=$(tar cf - --exclude='.source.yml' -C .agents/skills code-review | sha256sum | cut -d' ' -f1)

# Compare to recorded hash
RECORDED=$(grep 'digest:' .agents/skills/code-review/.source.yml | awk '{print $2}')

[ "$CURRENT" = "$RECORDED" ] && echo "In sync" || echo "Drift detected"
```

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

Run the smoke test to validate the fetch-and-stamp workflow end-to-end:

```bash
bash scripts/smoke-test.sh
```

The smoke test exercises acceptance criteria AC-1 through AC-5 from ADR-002. See `scripts/smoke-test.sh` for details.

## Skill references

| File | Purpose |
|---|---|
| `references/source-yml-schema.json` | JSON Schema for `.source.yml` validation |
| `references/source-yml.template.j2` | Jinja2 template for `.source.yml` generation |
| `scripts/fetch-remote-skill.sh` | Fetch-and-stamp automation script |
| `scripts/smoke-test.sh` | End-to-end verification of the pattern |
