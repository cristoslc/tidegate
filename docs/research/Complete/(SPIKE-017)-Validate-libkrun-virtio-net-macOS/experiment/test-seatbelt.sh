#!/bin/sh
## SPIKE-017 — Seatbelt profile validation
## Tests that the gvproxy-egress.sb profile allows gateway/proxy
## traffic while blocking everything else.
##
## Prerequisites: Docker services running (docker compose up -d)
## Usage: sh test-seatbelt.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROFILE="$SCRIPT_DIR/gvproxy-egress.sb"
PASS=0
FAIL=0

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1"; }
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

## ── Preflight ──
log "Profile: $PROFILE"

if ! docker compose -f "$SCRIPT_DIR/docker-compose.yaml" ps --status running 2>/dev/null | grep -q gateway; then
    log "Starting Docker mock services..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yaml" up -d --wait 2>/dev/null
fi

# Verify services are reachable unsandboxed (baseline)
if ! curl -sf http://localhost:4100/health >/dev/null 2>&1; then
    log "ERROR: gateway not reachable on localhost:4100 — start Docker services first"
    exit 1
fi
log "Baseline: gateway and proxy reachable"

## ── Test 1: Allowed — gateway:4100 ──
log "Test 1: sandbox-exec curl → localhost:4100 (should PASS)"
RESP=$(sandbox-exec -f "$PROFILE" curl -sf --max-time 5 http://localhost:4100/health 2>&1) || true
if printf '%s' "$RESP" | grep -q '"status"'; then
    pass "gateway:4100 — got: $RESP"
else
    fail "gateway:4100 — got: $RESP"
fi

## ── Test 2: Allowed — gateway:4100/mcp ──
log "Test 2: sandbox-exec curl → localhost:4100/mcp (should PASS)"
RESP=$(sandbox-exec -f "$PROFILE" curl -sf --max-time 5 http://localhost:4100/mcp 2>&1) || true
if printf '%s' "$RESP" | grep -q '"jsonrpc"'; then
    pass "gateway:4100/mcp — got valid JSON-RPC"
else
    fail "gateway:4100/mcp — got: $RESP"
fi

## ── Test 3: Allowed — egress proxy:3128 ──
log "Test 3: sandbox-exec curl → localhost:3128 (should PASS)"
RESP=$(sandbox-exec -f "$PROFILE" curl -sf --max-time 5 http://localhost:3128/ 2>&1) || true
if printf '%s' "$RESP" | grep -q '"service"\|"status"'; then
    pass "proxy:3128 — got: $RESP"
else
    fail "proxy:3128 — got: $RESP"
fi

## ── Test 4: Denied — external HTTP ──
log "Test 4: sandbox-exec curl → http://example.com (should FAIL)"
RESP=$(sandbox-exec -f "$PROFILE" curl -sf --max-time 5 http://example.com 2>&1) || true
if [ -z "$RESP" ] || printf '%s' "$RESP" | grep -qi 'denied\|not permitted\|could not resolve\|failed to connect'; then
    pass "example.com blocked (no response or error)"
else
    fail "example.com NOT blocked — got: $(printf '%s' "$RESP" | head -c 120)"
fi

## ── Test 5: Denied — external HTTPS ──
log "Test 5: sandbox-exec curl → https://ifconfig.me (should FAIL)"
RESP=$(sandbox-exec -f "$PROFILE" curl -sf --max-time 5 https://ifconfig.me 2>&1) || true
if [ -z "$RESP" ] || printf '%s' "$RESP" | grep -qi 'denied\|not permitted\|could not resolve\|failed to connect'; then
    pass "ifconfig.me blocked (no response or error)"
else
    fail "ifconfig.me NOT blocked — got: $(printf '%s' "$RESP" | head -c 120)"
fi

## ── Test 6: Denied — external TCP (raw) ──
log "Test 6: sandbox-exec nc → 1.1.1.1:53 (should FAIL)"
if sandbox-exec -f "$PROFILE" nc -z -w 3 1.1.1.1 53 2>/dev/null; then
    fail "1.1.1.1:53 NOT blocked — TCP connected"
else
    pass "1.1.1.1:53 blocked"
fi

## ── Test 7: Denied — DNS resolution itself ──
log "Test 7: sandbox-exec — DNS resolution (should FAIL or be irrelevant)"
RESP=$(sandbox-exec -f "$PROFILE" curl -sf --max-time 5 http://httpbin.org/get 2>&1) || true
if [ -z "$RESP" ] || printf '%s' "$RESP" | grep -qi 'denied\|not permitted\|could not resolve\|failed to connect'; then
    pass "httpbin.org blocked"
else
    fail "httpbin.org NOT blocked — got: $(printf '%s' "$RESP" | head -c 120)"
fi

## ── Test 8: Denied — localhost on wrong port ──
log "Test 8: sandbox-exec curl → localhost:8080 (should FAIL — port not allowlisted)"
RESP=$(sandbox-exec -f "$PROFILE" curl -sf --max-time 3 http://localhost:8080/ 2>&1) || true
if [ -z "$RESP" ] || printf '%s' "$RESP" | grep -qi 'denied\|not permitted\|refused\|failed to connect'; then
    pass "localhost:8080 blocked or refused"
else
    fail "localhost:8080 NOT blocked — got: $(printf '%s' "$RESP" | head -c 120)"
fi

## ── Summary ──
echo ""
log "Results: $PASS passed, $FAIL failed ($(( PASS + FAIL )) total)"

if [ "$FAIL" -gt 0 ]; then
    log "VERDICT: FAIL — profile has gaps"
    exit 1
else
    log "VERDICT: PASS — profile correctly allows gateway/proxy, blocks everything else"
fi
