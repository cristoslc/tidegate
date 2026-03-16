---
title: "VM Launcher CLI"
artifact: SPEC-004
status: Approved
author: cristos
created: 2026-03-13
last-updated: 2026-03-14
type: feature
parent-epic: EPIC-002
linked-research:
  - SPIKE-015
  - SPIKE-017
  - SPIKE-018
  - SPIKE-019
  - SPIKE-020
  - SPIKE-022
linked-adrs:
  - ADR-002
  - ADR-005
  - ADR-009
  - ADR-010
depends-on:
  - SPEC-005
  - SPEC-006
  - SPEC-007
addresses:
  - JOURNEY-001.PP-01
trove: ""
source-issue: ""
swain-do: required
linked-artifacts:
  - SPEC-001
  - SPEC-005
  - SPEC-006
  - SPEC-007
---
# SPEC-004: VM Launcher CLI

## Problem Statement

EPIC-002 requires a CLI to boot an agent inside a libkrun VM with virtio-net networking, virtiofs workspace mounting, and infrastructure-embedded egress enforcement. Research spikes found:

- **macOS:** Lima v2.0 with `vmType: krunkit` provides VM lifecycle, provisioning, and virtiofs orchestration. A thin `tidegate vm` wrapper generates Lima YAML from `tidegate.yaml` and invokes `limactl` (SPIKE-018).
- **Linux:** No equivalent orchestrator exists. A thin custom wrapper around libkrun's C/Rust API (~200 LOC) is needed (SPIKE-019).
- **Both platforms:** libkrun is the VMM (ADR-010). Egress enforcement is gvproxy IP:port allowlist (ADR-009, SPEC-005). TSI scope provides defense-in-depth (SPIKE-020).

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
  - virtio-net via gvproxy (patched with IP:port allowlist per SPEC-005)
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
| **Networking** | gvproxy via krunkit | gvproxy via `krun_add_net_unixgram()` |
| **Egress enforcement** | gvproxy IP:port allowlist (SPEC-005) | gvproxy IP:port allowlist (SPEC-005) |
| **Defense-in-depth** | Seatbelt on gvproxy + TSI scope | Network namespace + TSI scope |

**Preconditions:**
- macOS: Lima v2.0 + krunkit + gvproxy (patched) installed
- Linux: libkrun shared library + gvproxy (patched) installed

## Acceptance Criteria

1. **Given** a valid OCI image and workspace path on macOS, **when** `tidegate vm start` is run, **then** a libkrun VM boots via Lima with virtio-net networking and virtiofs workspace mount within 5 seconds.
2. **Given** a valid OCI image and workspace path on Linux, **when** `tidegate vm start` is run, **then** a libkrun VM boots with virtio-net networking and virtiofs workspace mount within 2 seconds.
3. **Given** a running VM on either platform, **when** `curl http://<gateway-ip>:4100/mcp` is executed inside the VM, **then** the gateway responds with a valid JSON-RPC response.
4. **Given** a running VM, **when** an outbound HTTP request is attempted, **then** it routes through the configured egress proxy.
5. **Given** `--workspace /path/to/project`, **when** the VM boots, **then** `/workspace` inside the VM contains the host directory contents via virtiofs.
6. **Given** missing dependencies (Lima/libkrun/gvproxy), **when** `tidegate vm start` is run, **then** it fails with a clear error message listing what's missing and how to install it.
7. **Given** a running VM, **when** the VM attempts to connect to a non-allowlisted destination, **then** the connection is blocked by gvproxy's allowlist (SPEC-005).

## Verification

| Criterion | Evidence | Result |
|-----------|----------|--------|

## Scope & Constraints

- macOS (Apple Silicon, HVF) and Linux (KVM, x86_64/aarch64) are both targets.
- The launcher orchestrates the full topology: Docker Compose services (gateway, egress proxy, MCP servers) + VM. `tidegate vm start` brings up compose services first, then boots the VM with gvproxy pointed at the gateway and proxy IPs.
- The egress proxy is a CONNECT-only proxy (Squid or equivalent) allowlisted to LLM API domains. It is deployed as a Docker container via the compose topology — not custom code, just configuration.
- The launcher does NOT manage the OCI image build — that is SPEC-006's responsibility.
- The launcher does NOT implement egress enforcement — that is SPEC-005's responsibility. The launcher starts gvproxy with the allowlist configured.
- The launcher does NOT implement MCP scanning — that is SPEC-007's responsibility. The launcher starts the gateway container and points gvproxy's allowlist at its IP.
- macOS path: Lima YAML template + thin `tidegate vm` CLI wrapper.
- Linux path: Rust or Python wrapper using libkrun C API.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Approved | 2026-03-13 | e6a1bcb | Supersedes SPEC-001; incorporates SPIKE-018/019 and ADR-009 |
