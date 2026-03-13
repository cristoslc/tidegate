---
title: "VM Launcher CLI"
artifact: SPEC-001
status: Abandoned
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
  - SPIKE-020
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

EPIC-001 requires a way to boot an agent inside a libkrun VM with virtio-net networking and virtiofs workspace mounting. Research spikes (SPIKE-015 through SPIKE-020) evaluated the landscape and found:

- **macOS:** Lima v2.0 with `vmType: krunkit` provides VM lifecycle, provisioning, and virtiofs orchestration. A thin `tidegate vm` wrapper generates Lima YAML from `tidegate.yaml` and invokes `limactl` (SPIKE-018).
- **Linux:** No equivalent orchestrator exists. microsandbox wraps libkrun with SDKs but uses TSI-only networking (SPIKE-019). A thin custom wrapper around libkrun's C/Rust API (~200 LOC) is needed (SPIKE-019).
- **Both platforms:** libkrun is the VMM. TSI scope provides defense-in-depth but is insufficient as sole egress enforcement (SPIKE-020). Primary egress enforcement is platform-specific (SPEC-002 for macOS, TBD for Linux).

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
  - virtio-net via gvproxy (not TSI) for network-controlled operation
  - TSI scope=Group as defense-in-depth (narrow subnet: gateway + proxy IPs only)
  - virtiofs mount of workspace at `/workspace`
  - Guest env vars: `HTTP_PROXY`, `HTTPS_PROXY`, `TIDEGATE_GATEWAY`
  - Guest `/etc/resolv.conf` configured to route DNS through proxy or controlled resolver
- Prints VM IP and connection info to stdout
- Returns exit code 0 on successful boot, 1 on failure

**Platform-specific orchestration:**

| | macOS (Apple Silicon) | Linux (KVM) |
|---|---|---|
| **Orchestration** | Lima v2.0 (`vmType: krunkit`) | Thin libkrun C/Rust wrapper |
| **VM config** | Lima YAML template generated from `tidegate.yaml` | Direct libkrun API calls |
| **VM lifecycle** | `limactl start/stop/shell` | Custom start/stop via libkrun API |
| **Provisioning** | Lima cloud-init + `PARAM_*` env vars | virtiofs-shared config file + `krun_set_env()` |
| **Networking** | gvproxy via krunkit | gvproxy via `krun_add_net_unixgram()` or passt via `krun_add_net_unixstream()` |
| **Egress enforcement** | Seatbelt on gvproxy (SPEC-002) | TBD — nftables, gvproxy-in-container, or network namespace (pending spike) |

**Preconditions:**
- macOS: Lima v2.0 + krunkit + gvproxy installed
- Linux: libkrun shared library + gvproxy (or passt) installed

## Acceptance Criteria

1. **Given** a valid OCI image and workspace path on macOS, **when** `tidegate vm start` is run, **then** a libkrun VM boots via Lima with virtio-net networking and virtiofs workspace mount within 5 seconds.
2. **Given** a valid OCI image and workspace path on Linux, **when** `tidegate vm start` is run, **then** a libkrun VM boots with virtio-net networking and virtiofs workspace mount within 2 seconds.
3. **Given** a running VM on either platform, **when** `curl http://<gateway-ip>:4100/mcp` is executed inside the VM, **then** the gateway responds with a valid JSON-RPC response.
4. **Given** a running VM, **when** an outbound HTTP request is attempted, **then** it routes through the configured egress proxy.
5. **Given** `--workspace /path/to/project`, **when** the VM boots, **then** `/workspace` inside the VM contains the host directory contents via virtiofs.
6. **Given** missing dependencies (Lima/libkrun/gvproxy), **when** `tidegate vm start` is run, **then** it fails with a clear error message listing what's missing and how to install it.

## Verification

| Criterion | Evidence | Result |
|-----------|----------|--------|

## Scope & Constraints

- macOS (Apple Silicon, HVF) and Linux (KVM, x86_64/aarch64) are both targets.
- The launcher does NOT manage the OCI image build — that is SPEC-003's responsibility.
- The launcher does NOT implement egress enforcement — that is SPEC-002's responsibility (macOS) and a pending spec (Linux).
- macOS path: Lima YAML template + thin `tidegate vm` CLI wrapper.
- Linux path: Rust or Python wrapper using libkrun C API.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Approved | 2026-03-13 | b530c62 | Decomposed from EPIC-001; backed by SPIKE-015 + SPIKE-017 |
| Abandoned | 2026-03-13 | — | Superseded by SPEC-004 under EPIC-002; egress model revised per ADR-009 |
