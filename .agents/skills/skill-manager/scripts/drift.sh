#!/usr/bin/env bash
# drift.sh — Detect drift between installed skills and their recorded state
#
# Modes:
#   drift.sh <skill-dir>            — Single skill: compare .source.yml digest to fresh hash
#   drift.sh --all [skills-dir]     — Scan all skills with .source.yml in a directory
#   drift.sh --cross <dir1> <dir2>  — Compare skill versions across two projects
#
# Exit codes:
#   0 — all in sync
#   1 — drift detected

set -euo pipefail

# --- Portable sha256 ---
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
  grep "  *${field}:" "$file" | head -1 | sed "s/.*${field}: *//" | sed 's/^"\(.*\)"$/\1/' | tr -d ' '
}

# --- Check single skill ---
check_drift() {
  local skill_dir="$1"
  local skill_name
  skill_name="$(basename "$skill_dir")"
  local source_yml="$skill_dir/.source.yml"

  if [ ! -f "$source_yml" ]; then
    echo "  SKIP: $skill_name (no .source.yml — local-only skill)"
    return 0
  fi

  local recorded_digest
  recorded_digest="$(yaml_field "$source_yml" "digest")"

  if [ -z "$recorded_digest" ]; then
    echo "  ERROR: $skill_name — .source.yml missing digest field"
    return 1
  fi

  local parent_dir
  parent_dir="$(dirname "$skill_dir")"
  local fresh_digest
  fresh_digest="$(cd "$parent_dir" && find "$skill_name" -type f ! -name '.source.yml' | LC_ALL=C sort | while IFS= read -r f; do printf '%s\n' "$f"; sha256_hash < "$f"; done | sha256_hash)"

  if [ "$recorded_digest" = "$fresh_digest" ]; then
    echo "  OK: $skill_name (in sync)"
    return 0
  else
    echo "  DRIFT: $skill_name"
    echo "    Recorded: $recorded_digest"
    echo "    Current:  $fresh_digest"
    return 1
  fi
}

# --- Cross-project comparison ---
cross_compare() {
  local dir1="$1" dir2="$2"
  local drift_found=0

  echo "=== Cross-Project Drift Comparison ==="
  echo "Project A: $dir1"
  echo "Project B: $dir2"
  echo ""

  # Find all skills in dir1 that have .source.yml
  for source_yml in "$dir1"/*/.source.yml; do
    [ -f "$source_yml" ] || continue
    local skill_name
    skill_name="$(basename "$(dirname "$source_yml")")"

    local digest_a
    digest_a="$(yaml_field "$source_yml" "digest")"
    local ref_a
    ref_a="$(yaml_field "$source_yml" "ref")"

    # Check if same skill exists in dir2
    local source_yml_b="$dir2/$skill_name/.source.yml"
    if [ ! -f "$source_yml_b" ]; then
      echo "  MISSING: $skill_name — present in A but not in B"
      drift_found=1
      continue
    fi

    local digest_b
    digest_b="$(yaml_field "$source_yml_b" "digest")"
    local ref_b
    ref_b="$(yaml_field "$source_yml_b" "ref")"

    if [ "$digest_a" = "$digest_b" ]; then
      echo "  OK: $skill_name (same version)"
    else
      echo "  DIFF: $skill_name"
      echo "    A: ref=$ref_a digest=$digest_a"
      echo "    B: ref=$ref_b digest=$digest_b"
      drift_found=1
    fi
  done

  # Check for skills in dir2 not in dir1
  for source_yml in "$dir2"/*/.source.yml; do
    [ -f "$source_yml" ] || continue
    local skill_name
    skill_name="$(basename "$(dirname "$source_yml")")"
    if [ ! -f "$dir1/$skill_name/.source.yml" ]; then
      echo "  MISSING: $skill_name — present in B but not in A"
      drift_found=1
    fi
  done

  return "$drift_found"
}

# --- Main ---
MODE="single"
case "${1:-}" in
  --all)
    MODE="all"
    SKILLS_DIR="${2:-.agents/skills}"
    ;;
  --cross)
    MODE="cross"
    DIR1="${2:?Usage: drift.sh --cross <dir1> <dir2>}"
    DIR2="${3:?Usage: drift.sh --cross <dir1> <dir2>}"
    ;;
  --help|-h)
    echo "Usage:"
    echo "  drift.sh <skill-dir>            — Check single skill"
    echo "  drift.sh --all [skills-dir]     — Check all skills"
    echo "  drift.sh --cross <dir1> <dir2>  — Compare across projects"
    exit 0
    ;;
  "")
    echo "ERROR: No arguments provided" >&2
    echo "Usage: drift.sh <skill-dir> | --all [skills-dir] | --cross <dir1> <dir2>" >&2
    exit 1
    ;;
  *)
    MODE="single"
    SKILL_DIR="$1"
    ;;
esac

DRIFT_FOUND=0

case "$MODE" in
  single)
    echo "=== Drift Detection ==="
    check_drift "$SKILL_DIR" || DRIFT_FOUND=1
    ;;
  all)
    echo "=== Drift Detection (all skills in $SKILLS_DIR) ==="
    if [ ! -d "$SKILLS_DIR" ]; then
      echo "ERROR: Directory not found: $SKILLS_DIR" >&2
      exit 1
    fi
    for skill_dir in "$SKILLS_DIR"/*/; do
      [ -d "$skill_dir" ] || continue
      check_drift "${skill_dir%/}" || DRIFT_FOUND=1
    done
    ;;
  cross)
    cross_compare "$DIR1" "$DIR2" || DRIFT_FOUND=1
    ;;
esac

echo ""
if [ "$DRIFT_FOUND" -eq 0 ]; then
  echo "All in sync."
  exit 0
else
  echo "Drift detected."
  exit 1
fi
