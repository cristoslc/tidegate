#!/usr/bin/env bash
# update.sh — Update a skill using .source.yml coordinates
#
# Reads .source.yml for repository and ref, then re-runs install.sh
# with the same coordinates. Reports whether anything changed by
# comparing the old and new integrity digests.
#
# Workaround for npx skills update #337 (project-scoped updates broken).
#
# Usage:
#   update.sh <skill-dir> [target-dir]
#
# Arguments:
#   skill-dir  — Path to the installed skill (must contain .source.yml)
#   target-dir — Parent directory for skills (default: dirname of skill-dir)
#
# Exit codes:
#   0 — up to date or updated, audit clean
#   1 — updated, audit warnings
#   2 — rolled back due to critical audit findings

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"

SKILL_DIR="${1:?Usage: update.sh <skill-dir> [target-dir]}"
TARGET_DIR="${2:-$(dirname "$SKILL_DIR")}"

SOURCE_YML="$SKILL_DIR/.source.yml"

if [ ! -f "$SOURCE_YML" ]; then
  echo "ERROR: No .source.yml found in $SKILL_DIR — cannot update a local-only skill" >&2
  exit 2
fi

# --- Portable YAML field extractor (no yq dependency) ---
yaml_field() {
  local file="$1" field="$2"
  grep "  *${field}:" "$file" | head -1 | sed "s/.*${field}: *//" | sed 's/^"\(.*\)"$/\1/' | tr -d ' '
}

# --- Read coordinates from .source.yml ---
REPO_URL="$(yaml_field "$SOURCE_YML" "repository")"
REF="$(yaml_field "$SOURCE_YML" "ref")"
SKILL_PATH="$(yaml_field "$SOURCE_YML" "path")"
OLD_DIGEST="$(yaml_field "$SOURCE_YML" "digest")"

if [ -z "$REPO_URL" ] || [ -z "$SKILL_PATH" ]; then
  echo "ERROR: .source.yml missing required fields (repository, path)" >&2
  exit 2
fi

SKILL_NAME="$(basename "$SKILL_DIR")"

echo "Updating skill '$SKILL_NAME'..."
echo "  Repository: $REPO_URL"
echo "  Ref:        $REF"
echo "  Path:       $SKILL_PATH"
echo "  Old digest: $OLD_DIGEST"
echo ""

# --- Re-install ---
INSTALL_EXIT=0
bash "$INSTALL_SCRIPT" "$REPO_URL" "$SKILL_PATH" "$REF" "$TARGET_DIR" || INSTALL_EXIT=$?

if [ "$INSTALL_EXIT" -eq 2 ]; then
  echo "Update failed — rolled back due to critical audit findings" >&2
  exit 2
fi

# --- Compare digests ---
NEW_DIGEST="$(yaml_field "$SKILL_DIR/.source.yml" "digest")"

echo ""
if [ "$OLD_DIGEST" = "$NEW_DIGEST" ]; then
  echo "Skill '$SKILL_NAME' is already up to date (digest unchanged)"
else
  echo "Skill '$SKILL_NAME' updated"
  echo "  Old digest: $OLD_DIGEST"
  echo "  New digest: $NEW_DIGEST"
fi

exit "$INSTALL_EXIT"
