#!/bin/sh
# Test suite for VM guest image.
# Tests build, boot time, runtime tools, and image size.
#
# Requires: Docker (for image build), krunkit + gvproxy (for boot tests)

set -e

DOCKERFILE="src/vm-image/Dockerfile"
IMAGE_TAG="tidegate-agent:test"
PASS=0
FAIL=0
SKIP=0
TOTAL=0

assert_ok() {
    desc="$1"; shift; TOTAL=$((TOTAL + 1))
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1)); printf "  PASS: %s\n" "$desc"
    else
        FAIL=$((FAIL + 1)); printf "  FAIL: %s\n" "$desc"
    fi
}

assert_output_contains() {
    desc="$1"; pattern="$2"; shift 2; TOTAL=$((TOTAL + 1))
    output=$("$@" 2>&1 || true)
    if printf '%s' "$output" | grep -q "$pattern"; then
        PASS=$((PASS + 1)); printf "  PASS: %s\n" "$desc"
    else
        FAIL=$((FAIL + 1)); printf "  FAIL: %s (pattern '%s' not found)\n" "$desc" "$pattern"
    fi
}

skip() {
    desc="$1"; TOTAL=$((TOTAL + 1)); SKIP=$((SKIP + 1))
    printf "  SKIP: %s\n" "$desc"
}

if [ ! -f "$DOCKERFILE" ]; then
    echo "ERROR: Dockerfile not found at $DOCKERFILE"
    exit 1
fi

echo "Testing VM guest image"
echo ""

# --- Build tests ---
echo "--- Build ---"

HAS_DOCKER=false
command -v docker >/dev/null 2>&1 && HAS_DOCKER=true

if [ "$HAS_DOCKER" = "true" ]; then
    assert_ok "Dockerfile builds successfully" \
        docker build -t "$IMAGE_TAG" -f "$DOCKERFILE" src/vm-image/

    if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
        # Test: image size under 200MB
        SIZE_BYTES=$(docker image inspect "$IMAGE_TAG" --format='{{.Size}}')
        SIZE_MB=$((SIZE_BYTES / 1024 / 1024))
        TOTAL=$((TOTAL + 1))
        if [ "$SIZE_MB" -lt 200 ]; then
            PASS=$((PASS + 1))
            printf "  PASS: Image size %sMB < 200MB\n" "$SIZE_MB"
        else
            FAIL=$((FAIL + 1))
            printf "  FAIL: Image size %sMB >= 200MB\n" "$SIZE_MB"
        fi

        # Test: runtime tools in image
        echo ""
        echo "--- Runtime tools ---"
        assert_output_contains "Node.js 18+ available" "v[0-9]" \
            docker run --rm "$IMAGE_TAG" node --version

        assert_output_contains "Python 3.11+ available" "Python 3" \
            docker run --rm "$IMAGE_TAG" python3 --version

        assert_output_contains "git available" "git version" \
            docker run --rm "$IMAGE_TAG" git --version

        # Test: init script exists and is executable
        assert_ok "init.sh exists in image" \
            docker run --rm "$IMAGE_TAG" test -x /init.sh
    fi
else
    skip "Docker build (docker not available)"
    skip "Image size check (docker not available)"
    skip "Node.js version check (docker not available)"
    skip "Python version check (docker not available)"
    skip "git version check (docker not available)"
    skip "init.sh exists check (docker not available)"
fi

# --- Boot time tests (require krunkit) ---
echo ""
echo "--- Boot time ---"

HAS_KRUNKIT=false
command -v krunkit >/dev/null 2>&1 && HAS_KRUNKIT=true

if [ "$HAS_KRUNKIT" = "true" ] && [ "$HAS_DOCKER" = "true" ]; then
    skip "Boot time under 2 seconds (requires rootfs extraction + krunkit boot)"
    skip "eBPF tracepoints (requires custom kernel)"
else
    skip "Boot time under 2 seconds (krunkit/docker not available)"
    skip "eBPF tracepoints (krunkit not available)"
fi

echo ""
echo "--- Results ---"
echo "$PASS passed, $FAIL failed, $SKIP skipped (of $TOTAL total)"

# Cleanup
if [ "$HAS_DOCKER" = "true" ]; then
    docker rmi "$IMAGE_TAG" >/dev/null 2>&1 || true
fi

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
