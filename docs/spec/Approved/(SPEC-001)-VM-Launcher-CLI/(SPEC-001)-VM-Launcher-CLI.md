---
title: "VM Launcher CLI"
artifact: SPEC-001
status: Approved
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
type: feature
parent-epic: EPIC-001
linked-research:
  - SPIKE-015
  - SPIKE-017
  - SPIKE-018
  - SPIKE-019
linked-adrs:
  - ADR-005
  - ADR-008
depends-on: []
addresses:
  - JOURNEY-001.PP-01
evidence-pool: ""
source-issue: ""
swain-do: required
---

# SPEC-001: VM Launcher CLI

## Problem Statement

EPIC-001 requires a way to boot an agent inside a libkrun VM with virtio-net networking and virtiofs workspace mounting. Neither krunvm (TSI-only, no virtio-net) nor krunkit (no OCI handling) provides a complete solution. Tidegate needs a custom launcher that combines OCI image handling with virtio-net + virtiofs configuration.

## External Behavior

**Command:** `tidegate vm start [options]`

**Inputs:**
- `--image <oci-ref>` — OCI image reference for the guest (default: `tidegate-agent:latest`)
- `--workspace <path>` — Host path to mount via virtiofs (default: current directory)
- `--gateway <host:port>` — Gateway address (default: `localhost:4100`)
- `--proxy <host:port>` — Egress proxy address (default: `localhost:3128`)
- `--cpus <n>` — vCPU count (default: 4)
- `--memory <mb>` — RAM in MB (default: 4096)

**Outputs:**
- Boots a libkrun VM with:
  - virtio-net via gvproxy (not TSI)
  - virtiofs mount of workspace at `/workspace`
  - `/etc/hosts` injected with gateway and proxy addresses
  - Guest env vars: `HTTP_PROXY`, `HTTPS_PROXY`, `TIDEGATE_GATEWAY`
- Prints VM IP and connection info to stdout
- Returns exit code 0 on successful boot, 1 on failure

**Preconditions:**
- libkrun shared library installed on host
- gvproxy binary available on PATH

## Acceptance Criteria

1. **Given** a valid OCI image and workspace path, **when** `tidegate vm start` is run, **then** a libkrun VM boots with virtio-net networking and virtiofs workspace mount within 5 seconds.
2. **Given** a running VM, **when** `curl http://<gateway-ip>:4100/mcp` is executed inside the VM, **then** the gateway responds with a valid JSON-RPC response.
3. **Given** a running VM, **when** an outbound HTTP request is attempted, **then** it routes through the configured egress proxy.
4. **Given** `--workspace /path/to/project`, **when** the VM boots, **then** `/workspace` inside the VM contains the host directory contents via virtiofs.
5. **Given** missing libkrun or gvproxy, **when** `tidegate vm start` is run, **then** it fails with a clear error message listing missing dependencies.

## Verification

| Criterion | Evidence | Result |
|-----------|----------|--------|

## Scope & Constraints

- macOS (Apple Silicon, HVF) is the primary target. Linux (KVM) support is a future goal.
- The launcher does NOT manage the OCI image build — that is SPEC-003's responsibility.
- The launcher does NOT implement egress enforcement — that is SPEC-002's responsibility.
- Written in Rust (libkrun has Rust bindings) or as a shell wrapper around krunkit.

## Implementation Approach

1. **Test**: Verify gvproxy + krunkit can boot a VM with virtio-net from a script.
2. **Implement**: Create `src/vm-launcher/` with CLI argument parsing, libkrun configuration, gvproxy lifecycle management, and virtiofs setup.
3. **Test**: Integration test: boot VM, verify gateway reachability, verify workspace mount.
4. **Refactor**: Extract common config (gateway/proxy addresses) into `tidegate.yaml`.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Approved | 2026-03-13 | b530c62 | Decomposed from EPIC-001; backed by SPIKE-015 + SPIKE-017 |
