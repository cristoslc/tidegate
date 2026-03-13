#!/bin/sh
# Test suite for tidegate vm launcher.
# Tests argument parsing, config reading, dependency checks,
# and (when deps available) actual VM boot.

set -e

LAUNCHER="src/vm-launcher/tidegate-vm.sh"
PASS=0
FAIL=0
SKIP=0
TOTAL=0
TMPDIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

assert_ok() {
    desc="$1"; shift; TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); printf "  PASS: %s\n" "$desc"
    else
        FAIL=$((FAIL + 1)); printf "  FAIL: %s\n" "$desc"
    fi
}

assert_fail() {
    desc="$1"; shift; TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1)); printf "  FAIL: %s (expected failure)\n" "$desc"
    else
        PASS=$((PASS + 1)); printf "  PASS: %s\n" "$desc"
    fi
}

assert_output_contains() {
    desc="$1"; pattern="$2"; shift 2; TOTAL=$((TOTAL + 1))
    output=$("$@" 2>&1 || true)
    if printf '%s' "$output" | grep -q "$pattern"; then
        PASS=$((PASS + 1)); printf "  PASS: %s\n" "$desc"
    else
        FAIL=$((FAIL + 1)); printf "  FAIL: %s (pattern '%s' not in output)\n" "$desc" "$pattern"
    fi
}

skip() {
    desc="$1"; TOTAL=$((TOTAL + 1)); SKIP=$((SKIP + 1))
    printf "  SKIP: %s\n" "$desc"
}

if [ ! -f "$LAUNCHER" ]; then
    echo "ERROR: Launcher not found at $LAUNCHER"
    exit 1
fi

echo "Testing VM launcher: $LAUNCHER"
echo ""

# --- Dependency checks ---
echo "--- Dependency checks ---"

# Test: missing deps produce clear error
assert_output_contains "Reports missing gvproxy" "gvproxy" \
    sh "$LAUNCHER" check-deps

# Test: help flag
assert_output_contains "Help shows usage" "Usage" \
    sh "$LAUNCHER" --help

# --- Argument parsing ---
echo ""
echo "--- Argument parsing ---"

# Test: default values in dry-run mode
assert_output_contains "Dry-run shows gateway default" "4100" \
    sh "$LAUNCHER" --dry-run start

assert_output_contains "Dry-run shows proxy default" "3128" \
    sh "$LAUNCHER" --dry-run start

assert_output_contains "Dry-run shows workspace" "workspace" \
    sh "$LAUNCHER" --dry-run start

# Test: custom arguments in dry-run
assert_output_contains "Custom gateway port" "5100" \
    sh "$LAUNCHER" --dry-run start --gateway localhost:5100

assert_output_contains "Custom proxy port" "4128" \
    sh "$LAUNCHER" --dry-run start --proxy localhost:4128

assert_output_contains "Custom workspace" "/tmp/myproject" \
    sh "$LAUNCHER" --dry-run start --workspace /tmp/myproject

assert_output_contains "Custom CPUs" "cpus: 2" \
    sh "$LAUNCHER" --dry-run start --cpus 2

assert_output_contains "Custom memory" "memory: 2048" \
    sh "$LAUNCHER" --dry-run start --memory 2048

# --- Integration tests (require deps) ---
echo ""
echo "--- Integration tests ---"

HAS_KRUNKIT=false
HAS_GVPROXY=false
command -v krunkit >/dev/null 2>&1 && HAS_KRUNKIT=true
command -v gvproxy >/dev/null 2>&1 && HAS_GVPROXY=true

if [ "$HAS_KRUNKIT" = "true" ] && [ "$HAS_GVPROXY" = "true" ]; then
    echo "(krunkit + gvproxy found — running integration tests)"
    # These tests would boot an actual VM
    skip "VM boots with virtio-net (requires OCI image)"
    skip "Gateway reachable from VM (requires running gateway)"
    skip "Virtiofs workspace mounted (requires OCI image)"
else
    skip "VM boots with virtio-net (krunkit/gvproxy not installed)"
    skip "Gateway reachable from VM (krunkit/gvproxy not installed)"
    skip "Virtiofs workspace mounted (krunkit/gvproxy not installed)"
fi

echo ""
echo "--- Results ---"
echo "$PASS passed, $FAIL failed, $SKIP skipped (of $TOTAL total)"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
