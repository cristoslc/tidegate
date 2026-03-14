#!/bin/sh
# Unit tests for init.sh logic.
# Tests parsing functions, environment setup, and structural correctness
# without requiring VM boot.
set -e

PASS=0
FAIL=0
TOTAL=0

assert_ok() {
    desc="$1"; shift; TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); printf "  PASS: %s\n" "$desc"
    else
        FAIL=$((FAIL + 1)); printf "  FAIL: %s\n" "$desc"
    fi
}

echo "Testing init.sh"
echo ""

INIT_SH="src/vm-image/init.sh"

# --- Static analysis ---
echo "--- Static analysis ---"

assert_ok "init.sh exists" test -f "$INIT_SH"
assert_ok "init.sh is executable" test -x "$INIT_SH"
assert_ok "init.sh starts with #!/bin/sh" sh -c "head -1 '$INIT_SH' | grep -q '^#!/bin/sh'"
assert_ok "init.sh uses set -e" grep -q '^set -e' "$INIT_SH"

# --- Boot sequence (SPEC-006 step 2): mount filesystems ---
echo ""
echo "--- Boot sequence: mount filesystems ---"
assert_ok "mounts proc" grep -q 'mount.*proc' "$INIT_SH"
assert_ok "mounts sysfs" grep -q 'mount.*sysfs' "$INIT_SH"
assert_ok "mounts devtmpfs" grep -q 'mount.*devtmpfs' "$INIT_SH"
assert_ok "mounts tmpfs on /tmp" grep -q 'mount.*tmpfs.*/tmp' "$INIT_SH"
assert_ok "mounts virtiofs at /workspace" grep -q 'virtiofs.*workspace.*/workspace' "$INIT_SH"

# --- Boot sequence (SPEC-006 step 3): networking ---
echo ""
echo "--- Boot sequence: networking ---"
assert_ok "parses kernel cmdline for ip=" grep -q 'proc/cmdline' "$INIT_SH"
assert_ok "configures IP address" grep -q 'ip addr add' "$INIT_SH"
assert_ok "sets default route" grep -q 'ip route add default' "$INIT_SH"
assert_ok "falls back to DHCP" grep -q 'udhcpc' "$INIT_SH"

# --- Boot sequence (SPEC-006 step 4): environment ---
echo ""
echo "--- Boot sequence: environment ---"
assert_ok "exports HTTP_PROXY" grep -q 'export HTTP_PROXY' "$INIT_SH"
assert_ok "exports HTTPS_PROXY" grep -q 'export HTTPS_PROXY' "$INIT_SH"
assert_ok "exports TIDEGATE_GATEWAY" grep -q 'export TIDEGATE_GATEWAY' "$INIT_SH"

# --- PID 1 guard ---
echo ""
echo "--- PID 1 guard ---"
assert_ok "checks PID for mount operations" grep -q '"\$\$"' "$INIT_SH"

# --- Readiness signal ---
echo ""
echo "--- Readiness ---"
assert_ok "signals readiness via /tmp/healthy" grep -q 'touch.*/tmp/healthy' "$INIT_SH"
assert_ok "prints ready message" grep -q 'tidegate-agent ready' "$INIT_SH"

# --- Fail-closed: exec replaces shell ---
echo ""
echo "--- Exec behavior ---"
assert_ok "uses exec for command dispatch" grep -q 'exec.*"$@"' "$INIT_SH"
assert_ok "uses exec for shell fallback" grep -q 'exec sh' "$INIT_SH"

# --- shellcheck ---
echo ""
echo "--- shellcheck ---"
if command -v shellcheck >/dev/null 2>&1; then
    assert_ok "init.sh passes shellcheck" shellcheck -s sh "$INIT_SH"
else
    TOTAL=$((TOTAL + 1))
    printf "  SKIP: shellcheck not available\n"
fi

echo ""
echo "--- Results ---"
echo "$PASS passed, $FAIL failed (of $TOTAL total)"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
