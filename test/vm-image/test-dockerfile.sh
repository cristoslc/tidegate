#!/bin/sh
# Validates Dockerfile structure against project conventions and SPEC-006.
set -e

DOCKERFILE="${1:-src/vm-image/Dockerfile}"
PASS=0
FAIL=0
TOTAL=0

assert_contains() {
    desc="$1"; pattern="$2"
    TOTAL=$((TOTAL + 1))
    if grep -q "$pattern" "$DOCKERFILE"; then
        PASS=$((PASS + 1))
        printf "  PASS: %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s (pattern '%s' not found)\n" "$desc" "$pattern"
    fi
}

if [ ! -f "$DOCKERFILE" ]; then
    echo "ERROR: Dockerfile not found: $DOCKERFILE"
    exit 1
fi

echo "Validating Dockerfile: $DOCKERFILE"
echo ""

# --- Convention compliance (AGENTS.md) ---
echo "--- Conventions ---"
assert_contains "Base image is pinned (alpine:3.x)" 'FROM alpine:3\.[0-9]'
assert_contains "Has HEALTHCHECK" 'HEALTHCHECK'
assert_contains "Non-root user created" 'adduser'
assert_contains "Has ENTRYPOINT" 'ENTRYPOINT'

# --- Required packages (SPEC-006) ---
echo ""
echo "--- Required packages ---"
assert_contains "Installs nodejs" 'nodejs'
assert_contains "Installs python3" 'python3'
assert_contains "Installs git" '[^#]*git'
assert_contains "Installs ca-certificates" 'ca-certificates'

# --- Init script ---
echo ""
echo "--- Init script ---"
assert_contains "Copies init.sh" 'COPY init.sh'
assert_contains "init.sh is set executable" 'chmod.*init.sh'

# --- Workspace mount point ---
echo ""
echo "--- Workspace ---"
assert_contains "Creates /workspace directory" 'mkdir.*workspace'

# --- Image minimization ---
echo ""
echo "--- Minimization ---"
assert_contains "Removes man pages" '/usr/share/man'
assert_contains "Removes docs" '/usr/share/doc'
assert_contains "Uses --no-cache for apk" 'apk add --no-cache'

echo ""
echo "--- Results ---"
RESULT_TOTAL=$((PASS + FAIL))
echo "$PASS passed, $FAIL failed (of $RESULT_TOTAL total)"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
