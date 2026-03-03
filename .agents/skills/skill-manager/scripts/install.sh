#!/usr/bin/env bash
# install.sh — Install a skill with safety-gated activation
#
# Backend selection:
#   - npx path: `npx skills add <repo>@<ref> --skill <name> --agent <agent> --yes`
#   - POSIX path: delegates to fetch-remote-skill.sh
#
# After install:
#   - Stamps .source.yml (npx path reads skills-lock.json + git metadata)
#   - Runs audit.sh, rolls back on critical findings (exit 2)
#
# Usage:
#   install.sh <repo-url> <skill-path> [ref] [target-dir] [--agent <agent>]
#
# Exit codes:
#   0 — installed, audit clean
#   1 — installed, audit warnings
#   2 — rolled back due to critical audit findings

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FETCH_SCRIPT="$SCRIPT_DIR/fetch-remote-skill.sh"
AUDIT_SCRIPT="$SCRIPT_DIR/audit.sh"

# --- Parse arguments ---
REPO_URL="${1:?Usage: install.sh <repo-url> <skill-path> [ref] [target-dir] [--agent <agent>]}"
SKILL_PATH="${2:?Usage: install.sh <repo-url> <skill-path> [ref] [target-dir] [--agent <agent>]}"
REF="${3:-HEAD}"
TARGET_DIR="${4:-.agents/skills}"
AGENT=""

# Parse optional --agent flag from remaining args
shift 4 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --agent) AGENT="${2:?--agent requires a value}"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

SKILL_NAME="$(basename "$SKILL_PATH")"
DEST="$TARGET_DIR/$SKILL_NAME"

# --- Backend selection ---
use_npx() {
  command -v npx >/dev/null 2>&1
}

# --- Backup for rollback ---
BACKUP_DIR=""
prepare_rollback() {
  if [ -d "$DEST" ]; then
    BACKUP_DIR="$(mktemp -d)"
    cp -R "$DEST" "$BACKUP_DIR/skill-backup"
  fi
}

rollback() {
  echo "Rolling back installation of '$SKILL_NAME'..." >&2
  rm -rf "$DEST"
  if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR/skill-backup" ]; then
    mkdir -p "$(dirname "$DEST")"
    mv "$BACKUP_DIR/skill-backup" "$DEST"
    echo "Restored previous version." >&2
  else
    echo "No previous version to restore — skill directory removed." >&2
  fi
}

cleanup_backup() {
  if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
  fi
}
trap cleanup_backup EXIT

# --- Install ---
echo "Installing skill '$SKILL_NAME'..."

prepare_rollback

if use_npx; then
  echo "Backend: npx skills"

  # Build npx command
  NPX_REF="$REPO_URL"
  if [ "$REF" != "HEAD" ]; then
    NPX_REF="${REPO_URL}@${REF}"
  fi

  NPX_CMD="npx skills add $NPX_REF --skill $SKILL_NAME --yes"
  if [ -n "$AGENT" ]; then
    NPX_CMD="$NPX_CMD --agent $AGENT"
  fi

  echo "Running: $NPX_CMD"
  if ! eval "$NPX_CMD"; then
    echo "WARN: npx skills add failed, falling back to POSIX path" >&2
    bash "$FETCH_SCRIPT" "$REPO_URL" "$SKILL_PATH" "$REF" "$TARGET_DIR"
  else
    # npx path: stamp .source.yml if not already present
    if [ ! -f "$DEST/.source.yml" ]; then
      echo "Stamping .source.yml for npx-installed skill..."
      bash "$FETCH_SCRIPT" "$REPO_URL" "$SKILL_PATH" "$REF" "$TARGET_DIR"
    fi
  fi
else
  echo "Backend: POSIX (fetch-remote-skill.sh)"
  bash "$FETCH_SCRIPT" "$REPO_URL" "$SKILL_PATH" "$REF" "$TARGET_DIR"
fi

# --- Verify installation ---
if [ ! -d "$DEST" ] || [ ! -f "$DEST/SKILL.md" ]; then
  echo "ERROR: Installation failed — skill directory or SKILL.md missing" >&2
  rollback
  exit 2
fi

# --- Safety audit ---
echo ""
AUDIT_EXIT=0
bash "$AUDIT_SCRIPT" "$DEST" || AUDIT_EXIT=$?

if [ "$AUDIT_EXIT" -eq 2 ]; then
  echo ""
  echo "CRITICAL findings — rolling back installation" >&2
  rollback
  exit 2
elif [ "$AUDIT_EXIT" -eq 1 ]; then
  echo ""
  echo "Warnings found — skill installed but review recommended"
  exit 1
else
  echo ""
  echo "OK: Skill '$SKILL_NAME' installed and audit clean"
  exit 0
fi
