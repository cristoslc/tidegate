#!/usr/bin/env bash
# smoke-test.sh — End-to-end verification of the remote-skills-reference pattern
#
# Exercises acceptance criteria AC-1 through AC-5 from ADR-002.
# Uses THIS repository's spec-management skill as the fetch target
# (self-referential test — no external dependency required).
#
# Usage:
#   bash scripts/smoke-test.sh [repo-url]
#
# Arguments:
#   repo-url — Git remote URL to fetch from (default: this repo's origin)
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FETCH_SCRIPT="$SCRIPT_DIR/fetch-remote-skill.sh"

# --- Configuration ---
# Default: fetch from this repo's own origin
REPO_URL="${1:-$(git remote get-url origin 2>/dev/null || echo "https://github.com/cristoslc/LLM-personal-agent-patterns")}"
SKILL_PATH="L3-agents-standalone/.agents/skills/spec-management"
SKILL_NAME="spec-management"

# --- Test workspace ---
WORK_DIR="$(mktemp -d)"
TARGET_DIR="$WORK_DIR/skills"
mkdir -p "$TARGET_DIR"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

PASS=0
FAIL=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

check_not() {
  local label="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    FAIL=$((FAIL + 1))
  fi
}

# --- Portable sha256 (matches fetch script) ---
sha256_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    echo "ERROR: Neither sha256sum nor shasum found" >&2
    exit 1
  fi
}

# --- Portable YAML field extractor (no yq dependency) ---
yaml_field() {
  local file="$1" field="$2"
  grep "  *${field}:" "$file" | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' '
}

echo "=== ADR-002 Smoke Test ==="
echo "Repo:       $REPO_URL"
echo "Skill path: $SKILL_PATH"
echo "Target:     $TARGET_DIR"
echo ""

# ============================================================
# AC-1: Fetch clones a public repo, extracts a skill directory,
#        and writes it to the target skills path.
# ============================================================
echo "--- AC-1: Fetch and extract ---"

bash "$FETCH_SCRIPT" "$REPO_URL" "$SKILL_PATH" HEAD "$TARGET_DIR"
FETCH_EXIT=$?

check "fetch script exits 0" test "$FETCH_EXIT" -eq 0
check "skill directory created" test -d "$TARGET_DIR/$SKILL_NAME"
check "SKILL.md present" test -f "$TARGET_DIR/$SKILL_NAME/SKILL.md"

# ============================================================
# AC-2: A valid .source.yml is generated alongside the skill.
# ============================================================
echo ""
echo "--- AC-2: .source.yml exists and is valid YAML ---"

SOURCE_YML="$TARGET_DIR/$SKILL_NAME/.source.yml"

check ".source.yml exists" test -f "$SOURCE_YML"
# Basic YAML validity: no tabs, has expected top-level keys
check ".source.yml contains source: key" grep -q "^source:" "$SOURCE_YML"
check ".source.yml contains skill: key" grep -q "^skill:" "$SOURCE_YML"
check ".source.yml contains fetched: key" grep -q "^fetched:" "$SOURCE_YML"
check ".source.yml contains integrity: key" grep -q "^integrity:" "$SOURCE_YML"

# ============================================================
# AC-3: All required fields are populated and non-empty.
# ============================================================
echo ""
echo "--- AC-3: Required fields populated ---"

for field in repository ref commit path; do
  val="$(yaml_field "$SOURCE_YML" "$field")"
  check "source.$field is non-empty ($val)" test -n "$val"
done

name_val="$(yaml_field "$SOURCE_YML" "name")"
check "skill.name is non-empty ($name_val)" test -n "$name_val"
check "skill.name matches directory ($name_val == $SKILL_NAME)" test "$name_val" = "$SKILL_NAME"

at_val="$(yaml_field "$SOURCE_YML" "at")"
check "fetched.at is non-empty ($at_val)" test -n "$at_val"

by_val="$(yaml_field "$SOURCE_YML" "by")"
check "fetched.by is non-empty ($by_val)" test -n "$by_val"

algo_val="$(yaml_field "$SOURCE_YML" "algorithm")"
check "integrity.algorithm is sha256 ($algo_val)" test "$algo_val" = "sha256"

digest_val="$(yaml_field "$SOURCE_YML" "digest")"
check "integrity.digest is non-empty" test -n "$digest_val"
check "integrity.digest is 64 hex chars" echo "$digest_val" | grep -qE '^[0-9a-f]{64}$'

# ============================================================
# AC-4: Integrity digest matches a fresh computation.
# ============================================================
echo ""
echo "--- AC-4: Integrity digest verification ---"

FRESH_DIGEST="$(tar cf - --exclude='.source.yml' -C "$TARGET_DIR" "$SKILL_NAME" 2>/dev/null | sha256_hash)"
check "fresh digest matches recorded ($FRESH_DIGEST)" test "$FRESH_DIGEST" = "$digest_val"

# ============================================================
# AC-5: Re-running updates fetched.at and source.commit.
# ============================================================
echo ""
echo "--- AC-5: Idempotent re-fetch ---"

FIRST_AT="$at_val"
FIRST_COMMIT="$(yaml_field "$SOURCE_YML" "commit")"

# Small delay to ensure timestamp differs
sleep 2

bash "$FETCH_SCRIPT" "$REPO_URL" "$SKILL_PATH" HEAD "$TARGET_DIR" >/dev/null 2>&1

SECOND_AT="$(yaml_field "$SOURCE_YML" "at")"
SECOND_COMMIT="$(yaml_field "$SOURCE_YML" "commit")"

check "fetched.at changed after re-fetch" test "$FIRST_AT" != "$SECOND_AT"
check "source.commit is a valid SHA ($SECOND_COMMIT)" echo "$SECOND_COMMIT" | grep -qE '^[0-9a-f]{40}$'
check "SKILL.md still present after re-fetch" test -f "$TARGET_DIR/$SKILL_NAME/SKILL.md"

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  echo "SMOKE TEST FAILED"
  exit 1
else
  echo "SMOKE TEST PASSED"
  exit 0
fi
