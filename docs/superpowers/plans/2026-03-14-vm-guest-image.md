# VM Guest Image Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan.

**Goal:** Produce a structurally correct, tested set of VM guest image artifacts (Dockerfile, init.sh, kernel-config, build script) for SPEC-006.
**Architecture:** Multi-stage Alpine Dockerfile builds a minimal rootfs with Node.js 18+, Python 3.11+, and git. A POSIX sh init script boots as PID 1 (no systemd), mounting filesystems, configuring networking, and starting the agent. A kernel config fragment enables eBPF, virtio, and virtiofs. A Makefile ties build, export, and test together.
**Tech Stack:** Alpine Linux 3.21, POSIX sh, Docker multi-stage builds, shellcheck, kernel kconfig fragments

---

## Chunk 1: Test Infrastructure and Validation Scripts

### Task 1: Create kernel-config validation script

**Files:**
- Create: `test/vm-image/test-kernel-config.sh`

- [ ] **Step 1: Write validation script that checks all required kernel options**

Create `test/vm-image/test-kernel-config.sh`:

```sh
#!/bin/sh
# Validates that the kernel config fragment contains all required options.
set -e

CONFIG_FILE="${1:-src/vm-image/kernel-config.fragment}"
PASS=0
FAIL=0

check_option() {
    option="$1"
    value="$2"
    if grep -q "^${option}=${value}$" "$CONFIG_FILE"; then
        PASS=$((PASS + 1))
        printf "  PASS: %s=%s\n" "$option" "$value"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s=%s not found\n" "$option" "$value"
    fi
}

check_disabled() {
    option="$1"
    if grep -q "^# ${option} is not set$" "$CONFIG_FILE"; then
        PASS=$((PASS + 1))
        printf "  PASS: %s is disabled\n" "$option"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s should be disabled\n" "$option"
    fi
}

echo "Validating kernel config: $CONFIG_FILE"
echo ""

# eBPF (acceptance criterion 6)
echo "--- eBPF ---"
check_option CONFIG_BPF y
check_option CONFIG_BPF_SYSCALL y
check_option CONFIG_BPF_JIT y
check_option CONFIG_BPF_JIT_ALWAYS_ON y
check_option CONFIG_CGROUP_BPF y

# Virtio (required for libkrun)
echo ""
echo "--- Virtio ---"
check_option CONFIG_VIRTIO y
check_option CONFIG_VIRTIO_PCI y
check_option CONFIG_VIRTIO_MMIO y
check_option CONFIG_VIRTIO_NET y
check_option CONFIG_VIRTIO_BLK y
check_option CONFIG_VIRTIO_CONSOLE y

# Virtiofs (acceptance criterion 5)
echo ""
echo "--- Virtiofs ---"
check_option CONFIG_FUSE_FS y
check_option CONFIG_VIRTIO_FS y

# Filesystems
echo ""
echo "--- Filesystems ---"
check_option CONFIG_EXT4_FS y
check_option CONFIG_TMPFS y
check_option CONFIG_PROC_FS y
check_option CONFIG_SYSFS y
check_option CONFIG_DEVTMPFS y
check_option CONFIG_DEVTMPFS_MOUNT y

# Networking
echo ""
echo "--- Networking ---"
check_option CONFIG_NET y
check_option CONFIG_INET y

# Security
echo ""
echo "--- Security ---"
check_option CONFIG_SECCOMP y
check_option CONFIG_SECCOMP_FILTER y

# Disabled subsystems (minimize attack surface)
echo ""
echo "--- Disabled ---"
check_disabled CONFIG_SOUND
check_disabled CONFIG_DRM
check_disabled CONFIG_USB_SUPPORT
check_disabled CONFIG_BLUETOOTH
check_disabled CONFIG_WIRELESS
check_disabled CONFIG_MODULES

echo ""
echo "--- Results ---"
TOTAL=$((PASS + FAIL))
echo "$PASS passed, $FAIL failed (of $TOTAL total)"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
```

- [ ] **Step 2: Run validation against existing kernel config**

```sh
chmod +x test/vm-image/test-kernel-config.sh
sh test/vm-image/test-kernel-config.sh
```

### Task 2: Create init.sh unit tests

**Files:**
- Create: `test/vm-image/test-init-functions.sh`

- [ ] **Step 1: Write tests for init.sh parsing and environment logic**

Create `test/vm-image/test-init-functions.sh`:

```sh
#!/bin/sh
# Unit tests for init.sh logic.
# Tests parsing functions and environment setup without requiring VM boot.
set -e

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
    desc="$1"; expected="$2"; actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf "  PASS: %s\n" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s (expected '%s', got '%s')\n" "$desc" "$expected" "$actual"
    fi
}

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
        FAIL=$((FAIL + 1)); printf "  FAIL: %s (should have failed)\n" "$desc"
    else
        PASS=$((PASS + 1)); printf "  PASS: %s\n" "$desc"
    fi
}

echo "Testing init.sh"
echo ""

INIT_SH="src/vm-image/init.sh"

# --- Static analysis ---
echo "--- Static analysis ---"

assert_ok "init.sh exists" test -f "$INIT_SH"
assert_ok "init.sh is executable" test -x "$INIT_SH"
assert_ok "init.sh starts with #!/bin/sh" head -1 "$INIT_SH" | grep -q '^#!/bin/sh'
assert_ok "init.sh uses set -e" grep -q '^set -e' "$INIT_SH"
assert_ok "init.sh mounts proc" grep -q 'mount.*proc' "$INIT_SH"
assert_ok "init.sh mounts sysfs" grep -q 'mount.*sysfs' "$INIT_SH"
assert_ok "init.sh mounts devtmpfs" grep -q 'mount.*devtmpfs' "$INIT_SH"
assert_ok "init.sh mounts virtiofs" grep -q 'mount.*virtiofs.*workspace.*/workspace' "$INIT_SH"
assert_ok "init.sh sets HTTP_PROXY" grep -q 'HTTP_PROXY' "$INIT_SH"
assert_ok "init.sh sets HTTPS_PROXY" grep -q 'HTTPS_PROXY' "$INIT_SH"
assert_ok "init.sh sets TIDEGATE_GATEWAY" grep -q 'TIDEGATE_GATEWAY' "$INIT_SH"
assert_ok "init.sh signals readiness" grep -q 'touch.*/tmp/healthy' "$INIT_SH"

# --- PID 1 guard ---
echo ""
echo "--- PID 1 guard ---"
assert_ok "init.sh checks PID 1 for mount operations" grep -q '"\$\$".*1\|$$.*-eq.*1' "$INIT_SH"

# --- Fail-closed behavior ---
echo ""
echo "--- Fail-closed ---"
assert_ok "init.sh networking falls back to DHCP" grep -q 'udhcpc' "$INIT_SH"

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
```

- [ ] **Step 2: Run init tests**

```sh
chmod +x test/vm-image/test-init-functions.sh
sh test/vm-image/test-init-functions.sh
```

### Task 3: Create Dockerfile validation tests

**Files:**
- Create: `test/vm-image/test-dockerfile.sh`

- [ ] **Step 1: Write structural validation for Dockerfile**

Create `test/vm-image/test-dockerfile.sh`:

```sh
#!/bin/sh
# Validates Dockerfile structure against project conventions.
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

assert_not_contains() {
    desc="$1"; pattern="$2"
    TOTAL=$((TOTAL + 1))
    if grep -q "$pattern" "$DOCKERFILE"; then
        FAIL=$((FAIL + 1))
        printf "  FAIL: %s (pattern '%s' found but should not be)\n" "$desc" "$pattern"
    else
        PASS=$((PASS + 1))
        printf "  PASS: %s\n" "$desc"
    fi
}

echo "Validating Dockerfile: $DOCKERFILE"
echo ""

# --- Convention compliance ---
echo "--- Conventions ---"
assert_contains "Base image is pinned (alpine:3.x)" 'FROM alpine:3\.[0-9]'
assert_contains "Has HEALTHCHECK" 'HEALTHCHECK'
assert_contains "Non-root user created" 'adduser'
assert_contains "Has ENTRYPOINT" 'ENTRYPOINT'

# --- Required packages ---
echo ""
echo "--- Required packages ---"
assert_contains "Installs nodejs" 'nodejs'
assert_contains "Installs python3" 'python3'
assert_contains "Installs git" 'git'
assert_contains "Installs ca-certificates" 'ca-certificates'

# --- Init script ---
echo ""
echo "--- Init script ---"
assert_contains "Copies init.sh" 'COPY init.sh'
assert_contains "init.sh is executable" 'chmod.*init.sh'

# --- Workspace ---
echo ""
echo "--- Workspace ---"
assert_contains "Creates /workspace" 'mkdir.*workspace'

# --- Minimization ---
echo ""
echo "--- Minimization ---"
assert_contains "Removes man pages" 'rm.*share/man'
assert_contains "Removes docs" 'rm.*share/doc'
assert_contains "Uses --no-cache for apk" 'apk add --no-cache'

echo ""
echo "--- Results ---"
TOTAL_COUNT=$((PASS + FAIL))
echo "$PASS passed, $FAIL failed (of $TOTAL_COUNT total)"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
```

- [ ] **Step 2: Run Dockerfile validation**

```sh
chmod +x test/vm-image/test-dockerfile.sh
sh test/vm-image/test-dockerfile.sh
```

## Chunk 2: Fix Issues Found by Tests

### Task 4: Fix init.sh shellcheck issues

**Files:**
- Modify: `src/vm-image/init.sh`

- [ ] **Step 1: Run shellcheck and fix all warnings**

```sh
shellcheck -s sh src/vm-image/init.sh
```

Fix any issues found (likely `$$` quoting, useless use of cat, etc.)

- [ ] **Step 2: Re-run all init tests to confirm green**

```sh
sh test/vm-image/test-init-functions.sh
```

### Task 5: Enhance Dockerfile for production readiness

**Files:**
- Modify: `src/vm-image/Dockerfile`

- [ ] **Step 1: Add multi-stage build with rootfs export stage**

The Dockerfile should have a builder stage and a final minimal stage. Add `LABEL` metadata and ensure the non-root user setup is complete.

- [ ] **Step 2: Re-run Dockerfile validation**

```sh
sh test/vm-image/test-dockerfile.sh
```

## Chunk 3: Build Script and Integration

### Task 6: Create Makefile for build workflow

**Files:**
- Create: `src/vm-image/Makefile`

- [ ] **Step 1: Write Makefile with build, export, test, and clean targets**

```makefile
.POSIX:
SHELL = /bin/sh

IMAGE_TAG = tidegate-agent:latest
ROOTFS_DIR = rootfs
ROOTFS_TAR = rootfs.tar

.PHONY: build export test clean lint

build:
	docker build -t $(IMAGE_TAG) -f Dockerfile .

export: build
	@rm -rf $(ROOTFS_DIR) $(ROOTFS_TAR)
	@CID=$$(docker create $(IMAGE_TAG)) && \
		docker export "$$CID" > $(ROOTFS_TAR) && \
		docker rm "$$CID" >/dev/null
	@echo "Exported rootfs to $(ROOTFS_TAR)"

test:
	@cd ../.. && sh test/vm-image/test-kernel-config.sh
	@cd ../.. && sh test/vm-image/test-init-functions.sh
	@cd ../.. && sh test/vm-image/test-dockerfile.sh
	@cd ../.. && sh test/vm-image/test-guest-image.sh

lint:
	shellcheck init.sh
	@echo "Lint passed"

clean:
	rm -rf $(ROOTFS_DIR) $(ROOTFS_TAR)
	docker rmi $(IMAGE_TAG) 2>/dev/null || true
```

### Task 7: Run all tests and verify green

- [ ] **Step 1: Run all validation tests**

```sh
sh test/vm-image/test-kernel-config.sh
sh test/vm-image/test-init-functions.sh
sh test/vm-image/test-dockerfile.sh
shellcheck src/vm-image/init.sh
```

- [ ] **Step 2: Commit all work**

```sh
git add src/vm-image/ test/vm-image/ docs/superpowers/plans/
git commit -m "feat(vm-image): implement SPEC-006 VM guest image artifacts

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```
