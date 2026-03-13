#!/bin/sh
# Test that the Seatbelt profile generator produces correct profiles
# with custom port numbers.

set -e

GENERATOR="src/vm-launcher/generate-seatbelt-profile.sh"
PASS=0
FAIL=0
TOTAL=0
TMPDIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMPDIR"
    [ -n "$LISTENER1_PID" ] && kill "$LISTENER1_PID" 2>/dev/null || true
    [ -n "$LISTENER2_PID" ] && kill "$LISTENER2_PID" 2>/dev/null || true
}
trap cleanup EXIT

assert_ok() {
    desc="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf "  PASS: %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s\n" "$desc"
    fi
}

assert_fail() {
    desc="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s (expected: failure, got: success)\n" "$desc"
    else
        PASS=$((PASS + 1))
        printf "  PASS: %s\n" "$desc"
    fi
}

assert_contains() {
    desc="$1"
    file="$2"
    pattern="$3"
    TOTAL=$((TOTAL + 1))
    if grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        printf "  PASS: %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s (pattern '%s' not found)\n" "$desc" "$pattern"
    fi
}

if [ "$(uname)" != "Darwin" ]; then
    echo "SKIP: Seatbelt tests require macOS"
    exit 0
fi

echo "Testing Seatbelt profile generation"
echo ""

# Test 1: Generate profile with custom ports
echo "--- Profile content ---"
PROFILE="$TMPDIR/custom.sb"
assert_ok "Generate profile with ports 5100/4128" \
    sh "$GENERATOR" 5100 4128 "$PROFILE"

assert_contains "Profile has gateway port 5100" "$PROFILE" "localhost:5100"
assert_contains "Profile has proxy port 4128" "$PROFILE" "localhost:4128"
assert_contains "Profile denies by default" "$PROFILE" "(deny default)"

# Test 2: Generate with default ports (matching the static profile)
PROFILE2="$TMPDIR/default.sb"
sh "$GENERATOR" 4100 3128 "$PROFILE2"
assert_contains "Default ports: gateway 4100" "$PROFILE2" "localhost:4100"
assert_contains "Default ports: proxy 3128" "$PROFILE2" "localhost:3128"

# Test 3: Invalid inputs
echo ""
echo "--- Input validation ---"
assert_fail "Reject non-numeric gateway port" sh "$GENERATOR" abc 3128 "$TMPDIR/bad.sb"
assert_fail "Reject non-numeric proxy port" sh "$GENERATOR" 4100 xyz "$TMPDIR/bad.sb"
assert_fail "Reject missing arguments" sh "$GENERATOR"

# Test 4: Generated profile actually works with sandbox-exec
echo ""
echo "--- Functional validation with custom ports ---"
PROFILE3="$TMPDIR/func.sb"
sh "$GENERATOR" 4100 3128 "$PROFILE3"

# Start listeners
nc -l 4100 </dev/null &
LISTENER1_PID=$!
sleep 0.1

assert_ok "Generated profile allows gateway:4100" \
    sandbox-exec -f "$PROFILE3" nc -z -w 2 localhost 4100

assert_fail "Generated profile blocks external host" \
    sandbox-exec -f "$PROFILE3" nc -z -w 2 1.1.1.1 443

echo ""
echo "--- Results ---"
echo "$PASS/$TOTAL passed, $FAIL failed"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
