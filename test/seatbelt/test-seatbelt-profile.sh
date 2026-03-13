#!/bin/sh
# Test suite for gvproxy Seatbelt egress enforcement profile.
# Validates that the sandbox-exec profile correctly allows/denies connections.
#
# Requirements: macOS with sandbox-exec, nc, curl
# Usage: sh test/seatbelt/test-seatbelt-profile.sh [profile-path]

set -e

PROFILE="${1:-src/vm-launcher/gvproxy-egress.sb}"
PASS=0
FAIL=0
TOTAL=0

cleanup() {
    # Kill background listeners
    [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null || true
    [ -n "$DECOY_PID" ] && kill "$DECOY_PID" 2>/dev/null || true
}
trap cleanup EXIT

assert_allowed() {
    desc="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf "  PASS: %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s (expected: allowed, got: blocked)\n" "$desc"
    fi
}

assert_blocked() {
    desc="$1"
    shift
    TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s (expected: blocked, got: allowed)\n" "$desc"
    else
        PASS=$((PASS + 1))
        printf "  PASS: %s\n" "$desc"
    fi
}

if [ "$(uname)" != "Darwin" ]; then
    echo "SKIP: Seatbelt tests require macOS"
    exit 0
fi

if ! command -v sandbox-exec >/dev/null 2>&1; then
    echo "SKIP: sandbox-exec not found"
    exit 0
fi

if [ ! -f "$PROFILE" ]; then
    echo "ERROR: Seatbelt profile not found at $PROFILE"
    exit 1
fi

echo "Testing Seatbelt profile: $PROFILE"
echo ""

# Start local listeners to simulate gateway and proxy
nc -l 4100 </dev/null &
GW_PID=$!

nc -l 3128 </dev/null &
PROXY_PID=$!

# Decoy on non-allowlisted port
nc -l 8080 </dev/null &
DECOY_PID=$!

# Brief pause for listeners to start
sleep 0.2

echo "--- Allowed connections ---"

# Test 1: TCP to gateway port 4100
assert_allowed "TCP to localhost:4100 (gateway)" \
    sandbox-exec -f "$PROFILE" nc -z -w 2 localhost 4100

# Restart listener (nc -l exits after one connection)
nc -l 4100 </dev/null &
GW_PID=$!
sleep 0.1

# Test 2: TCP to proxy port 3128
assert_allowed "TCP to localhost:3128 (proxy)" \
    sandbox-exec -f "$PROFILE" nc -z -w 2 localhost 3128

echo ""
echo "--- Blocked connections ---"

# Test 3: TCP to external host (example.com)
assert_blocked "TCP to example.com:80 (external)" \
    sandbox-exec -f "$PROFILE" nc -z -w 2 example.com 80

# Test 4: TCP to external host (ifconfig.me)
assert_blocked "TCP to ifconfig.me:443 (external)" \
    sandbox-exec -f "$PROFILE" nc -z -w 2 ifconfig.me 443

# Test 5: UDP to external DNS (1.1.1.1:53)
assert_blocked "UDP to 1.1.1.1:53 (external DNS)" \
    sandbox-exec -f "$PROFILE" nc -z -u -w 2 1.1.1.1 53

# Test 6: TCP to httpbin.org
assert_blocked "TCP to httpbin.org:80 (external)" \
    sandbox-exec -f "$PROFILE" nc -z -w 2 httpbin.org 80

# Test 7: TCP to non-allowlisted localhost port
assert_blocked "TCP to localhost:8080 (non-allowlisted port)" \
    sandbox-exec -f "$PROFILE" nc -z -w 2 localhost 8080

# Test 8: TCP to arbitrary high port on external host
assert_blocked "TCP to 1.1.1.1:443 (external)" \
    sandbox-exec -f "$PROFILE" nc -z -w 2 1.1.1.1 443

echo ""
echo "--- Results ---"
echo "$PASS/$TOTAL passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
