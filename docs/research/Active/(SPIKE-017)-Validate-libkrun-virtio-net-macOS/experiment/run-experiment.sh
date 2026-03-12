#!/bin/sh
## SPIKE-017 Experiment Runner
## Tests libkrun VM connectivity to Docker services on macOS
##
## Prerequisites:
##   brew install slp/krun/krunvm slp/krun/gvproxy
##   Case-sensitive APFS volume for krunvm
##   Docker Desktop running
##
## Usage: sh run-experiment.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_FILE="$SCRIPT_DIR/results.md"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1"; }
pass() { printf '  ✓ %s\n' "$1"; echo "| $1 | PASS | |" >> "$RESULTS_FILE"; }
fail() { printf '  ✗ %s\n' "$1"; echo "| $1 | FAIL | $2 |" >> "$RESULTS_FILE"; }
skip() { printf '  - %s (skipped: %s)\n' "$1" "$2"; echo "| $1 | SKIP | $2 |" >> "$RESULTS_FILE"; }

# Initialize results
cat > "$RESULTS_FILE" <<'HEADER'
# SPIKE-017 Experiment Results

| Test | Result | Notes |
|------|--------|-------|
HEADER

## ─── Phase 0: Prerequisites ───
log "Phase 0: Checking prerequisites"

if ! command -v docker >/dev/null 2>&1; then
    fail "Docker available" "docker not found"
    exit 1
fi
pass "Docker available"

if ! docker info >/dev/null 2>&1; then
    fail "Docker running" "docker daemon not responding"
    exit 1
fi
pass "Docker running"

if command -v krunvm >/dev/null 2>&1; then
    pass "krunvm installed ($(krunvm --version 2>/dev/null || echo 'unknown version'))"
    HAVE_KRUNVM=1
else
    skip "krunvm installed" "not found"
    HAVE_KRUNVM=0
fi

if command -v gvproxy >/dev/null 2>&1; then
    pass "gvproxy installed"
    HAVE_GVPROXY=1
else
    skip "gvproxy installed" "not found"
    HAVE_GVPROXY=0
fi

## ─── Phase 1: Docker mock gateway ───
log "Phase 1: Starting Docker mock gateway"

cd "$SCRIPT_DIR"
docker compose -f "$COMPOSE_FILE" up -d --wait 2>/dev/null

# Test from host
HOST_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:4100/health 2>/dev/null || echo "000")
if [ "$HOST_RESPONSE" = "200" ]; then
    pass "Gateway reachable from host (localhost:4100)"
else
    fail "Gateway reachable from host" "HTTP $HOST_RESPONSE"
fi

MCP_RESPONSE=$(curl -s http://localhost:4100/mcp 2>/dev/null)
if echo "$MCP_RESPONSE" | grep -q '"jsonrpc"'; then
    pass "Gateway returns MCP response"
else
    fail "Gateway returns MCP response" "unexpected response"
fi

PROXY_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3128/ 2>/dev/null || echo "000")
if [ "$PROXY_RESPONSE" != "000" ]; then
    pass "Egress proxy reachable from host (localhost:3128)"
else
    fail "Egress proxy reachable from host" "HTTP $PROXY_RESPONSE"
fi

## ─── Phase 2: krunvm TSI baseline ───
if [ "$HAVE_KRUNVM" = "1" ]; then
    log "Phase 2: krunvm TSI baseline test"

    # Check for case-sensitive volume
    if mount | grep -q "case-sensitive"; then
        pass "Case-sensitive APFS volume mounted"
    else
        skip "krunvm TSI test" "case-sensitive APFS volume not found — run: diskutil apfs addVolume disk3 'Case-sensitive APFS' krunvm"
        HAVE_KRUNVM=0
    fi
fi

if [ "$HAVE_KRUNVM" = "1" ]; then
    # Clean up any previous test VM
    krunvm delete spike017-test 2>/dev/null || true

    log "Creating krunvm Alpine VM..."
    if krunvm create docker.io/library/alpine:3.21 --name spike017-test --cpus 2 --mem 512 2>&1; then
        pass "krunvm create Alpine VM"
    else
        fail "krunvm create Alpine VM" "create failed"
        HAVE_KRUNVM=0
    fi
fi

if [ "$HAVE_KRUNVM" = "1" ]; then
    log "Testing connectivity from VM via TSI..."

    # Get host IP for reaching published Docker ports
    # With TSI, the VM can reach host localhost directly
    VM_GATEWAY_RESULT=$(krunvm start spike017-test /bin/sh -- -c \
        "wget -q -O- -T 5 http://host.docker.internal:4100/health 2>/dev/null || wget -q -O- -T 5 http://192.168.127.1:4100/health 2>/dev/null || wget -q -O- -T 5 http://localhost:4100/health 2>/dev/null || echo FAIL" \
        2>/dev/null || echo "VM_START_FAIL")

    if echo "$VM_GATEWAY_RESULT" | grep -q '"status"'; then
        pass "VM (TSI) reaches gateway:4100 — response: $VM_GATEWAY_RESULT"
    elif echo "$VM_GATEWAY_RESULT" | grep -q "VM_START_FAIL"; then
        fail "VM (TSI) reaches gateway:4100" "VM failed to start"
    else
        fail "VM (TSI) reaches gateway:4100" "response: $VM_GATEWAY_RESULT"
    fi

    VM_MCP_RESULT=$(krunvm start spike017-test /bin/sh -- -c \
        "wget -q -O- -T 5 http://localhost:4100/mcp 2>/dev/null || echo FAIL" \
        2>/dev/null || echo "VM_START_FAIL")

    if echo "$VM_MCP_RESULT" | grep -q '"jsonrpc"'; then
        pass "VM (TSI) gets MCP response from gateway"
    else
        fail "VM (TSI) gets MCP response" "response: $VM_MCP_RESULT"
    fi

    # Test egress proxy
    VM_PROXY_RESULT=$(krunvm start spike017-test /bin/sh -- -c \
        "wget -q -O- -T 5 http://localhost:3128/ 2>/dev/null || echo FAIL" \
        2>/dev/null || echo "VM_START_FAIL")

    if echo "$VM_PROXY_RESULT" | grep -q "FAIL\|VM_START_FAIL"; then
        fail "VM (TSI) reaches egress proxy:3128" "response: $VM_PROXY_RESULT"
    else
        pass "VM (TSI) reaches egress proxy:3128"
    fi

    # Latency test
    log "Measuring round-trip latency..."
    LATENCY_HOST=$(curl -s -o /dev/null -w "%{time_total}" http://localhost:4100/mcp 2>/dev/null || echo "N/A")
    echo "| Host curl latency (localhost:4100/mcp) | INFO | ${LATENCY_HOST}s |" >> "$RESULTS_FILE"
    log "  Host latency: ${LATENCY_HOST}s"

    VM_LATENCY=$(krunvm start spike017-test /bin/sh -- -c \
        "TIME_START=\$(date +%s%N 2>/dev/null || date +%s); wget -q -O /dev/null -T 5 http://localhost:4100/mcp 2>/dev/null; TIME_END=\$(date +%s%N 2>/dev/null || date +%s); echo \$((TIME_END - TIME_START))" \
        2>/dev/null || echo "N/A")
    echo "| VM (TSI) wget latency (localhost:4100/mcp) | INFO | ${VM_LATENCY}ns |" >> "$RESULTS_FILE"
    log "  VM latency: ${VM_LATENCY}ns"

    # Network interface check (TSI should show no interfaces)
    VM_IFACES=$(krunvm start spike017-test /bin/sh -- -c \
        "ip addr 2>/dev/null || ifconfig 2>/dev/null || echo NO_IFACE_CMD" \
        2>/dev/null || echo "VM_FAIL")
    if echo "$VM_IFACES" | grep -q "eth0"; then
        echo "| VM (TSI) has eth0 interface | INFO | unexpected — TSI should not create eth0 |" >> "$RESULTS_FILE"
        log "  TSI has eth0 (unexpected)"
    else
        echo "| VM (TSI) has no eth0 (confirms TSI mode) | INFO | expected — TSI uses vsock, no virtual NIC |" >> "$RESULTS_FILE"
        log "  TSI confirmed: no eth0 interface"
    fi

    # Clean up
    krunvm delete spike017-test 2>/dev/null || true
fi

## ─── Phase 3: gvproxy + virtio-net ───
if [ "$HAVE_GVPROXY" = "1" ]; then
    log "Phase 3: gvproxy virtio-net test"
    log "NOTE: krunvm does not support virtio-net. This test requires krunkit or a custom launcher."
    log "Checking for krunkit..."

    if command -v krunkit >/dev/null 2>&1; then
        pass "krunkit available"
        echo "| krunkit + gvproxy test | TODO | requires rootfs extraction and krunkit launch sequence |" >> "$RESULTS_FILE"
    else
        skip "krunkit + gvproxy test" "krunkit not installed (not in slp/krun tap; needs separate build)"
        echo "| gvproxy virtio-net test | SKIP | krunvm only supports TSI; krunkit or custom launcher needed |" >> "$RESULTS_FILE"
    fi
else
    skip "gvproxy virtio-net test" "gvproxy not installed"
fi

## ─── Cleanup ───
log "Cleaning up Docker services..."
docker compose -f "$COMPOSE_FILE" down 2>/dev/null

log "Done. Results written to: $RESULTS_FILE"
cat "$RESULTS_FILE"
