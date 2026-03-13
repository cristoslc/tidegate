---
title: "VM Guest Image"
artifact: SPEC-006
status: Approved
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
type: feature
parent-epic: EPIC-002
linked-research:
  - SPIKE-015
linked-adrs:
  - ADR-002
  - ADR-005
  - ADR-008
depends-on: []
addresses: []
evidence-pool: ""
source-issue: ""
swain-do: required
---

# SPEC-006: VM Guest Image

## Problem Statement

The libkrun VM needs a minimal Linux guest image containing the agent runtime (Node.js 18+, Python 3.11+, git, Claude Code CLI) and a custom init system. SPIKE-015 determined that a stripped kernel (~10-15MB) with eBPF support can run the full agentic runtime. The image must boot in <2 seconds with a custom init (no systemd).

## External Behavior

**Artifacts produced:**
- `src/vm-image/Dockerfile` — Multi-stage build producing a minimal rootfs tarball
- `src/vm-image/init.sh` — Custom init script (POSIX sh) that starts required daemons
- `src/vm-image/kernel-config` — Minimal kernel config with eBPF, virtio drivers, ext4, and required subsystems

**Guest runtime contents:**
- Alpine Linux base (musl)
- Node.js 18+ (musl build)
- Python 3.11+
- git
- virtiofs mount support (kernel module)
- eBPF-capable kernel (CONFIG_BPF=y, CONFIG_BPF_SYSCALL=y, CONFIG_BPF_JIT=y)

**Boot sequence:**
1. Kernel boots (direct boot, no bootloader)
2. `init.sh` mounts proc, sysfs, devtmpfs, virtiofs workspace
3. `init.sh` configures networking (IP from DHCP or static via kernel cmdline)
4. `init.sh` sets environment (HTTP_PROXY, HTTPS_PROXY, TIDEGATE_GATEWAY)
5. Agent process starts

## Acceptance Criteria

1. **Given** the built image, **when** booted in libkrun, **then** the guest reaches a shell prompt within 2 seconds.
2. **Given** the running guest, **when** `node --version` is executed, **then** it reports Node.js 18+.
3. **Given** the running guest, **when** `python3 --version` is executed, **then** it reports Python 3.11+.
4. **Given** the running guest, **when** `git --version` is executed, **then** git is available.
5. **Given** the running guest, **when** the virtiofs workspace is mounted, **then** host files are visible at `/workspace`.
6. **Given** the kernel config, **when** `cat /proc/config.gz | gunzip | grep CONFIG_BPF` is run, **then** BPF, BPF_SYSCALL, and BPF_JIT are all set to `y`.
7. **Given** the image, **when** its compressed size is measured, **then** it is under 200MB.

## Verification

| Criterion | Evidence | Result |
|-----------|----------|--------|

## Scope & Constraints

- Alpine Linux (musl) only — no glibc. Claude Code CLI is pure JS; tg-scanner is pure Python. Both work with musl.
- No systemd. Custom init only.
- Kernel compilation is required (stock Alpine kernel may lack eBPF or virtiofs). This is the most complex part of the spec.
- The image does NOT include Claude Code or agent-specific configuration — those are mounted or injected at runtime.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Approved | 2026-03-13 | — | Supersedes SPEC-003; same requirements, new parent epic |
