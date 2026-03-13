---
title: "gvproxy Egress Allowlist"
artifact: SPEC-005
status: Approved
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
type: feature
parent-epic: EPIC-002
linked-research:
  - SPIKE-017
  - SPIKE-020
  - SPIKE-022
linked-adrs:
  - ADR-008
  - ADR-009
depends-on: []
addresses:
  - JOURNEY-001.PP-01
evidence-pool: ""
source-issue: ""
swain-do: required
---

# SPEC-005: gvproxy Egress Allowlist

## Problem Statement

gvproxy provides the VM's only network path — all guest traffic flows through its userspace TCP/UDP forwarders before reaching the host network. Stock gvproxy has zero destination filtering: it NATs all VM-initiated connections to the host network without restriction. A compromised agent can reach any internet destination, bypassing the egress proxy.

Per ADR-009, egress enforcement must be infrastructure-embedded — in gvproxy itself, not in host OS sandboxes. SPIKE-022 identified the interception point: gvproxy's `pkg/services/forwarder/tcp.go` and `udp.go`, where VM connections become host `net.Dial()` calls. An IP:port allowlist at this point blocks unauthorized connections before they leave gvproxy.

Upstream gvproxy has an open PR (#609) adding `blockAllOutbound` + domain-based filtering. Our requirement is simpler: IP:port allowlisting (~90 LOC).

## External Behavior

**Artifacts produced:**
- Forked `gvisor-tap-vsock` repository with IP:port allowlist patch
- Configuration schema addition to gvproxy's `pkg/types/configuration.go`:
  ```yaml
  egressAllowlist:
    - ip: "172.20.0.2"
      port: 4100
    - ip: "172.20.0.3"
      port: 3128
  ```
- Allowlist is populated from `tidegate.yaml` at launch time by `tidegate vm start` (SPEC-004)

**Enforcement guarantees:**
- From inside the VM, TCP connections to allowlisted IP:port pairs succeed
- From inside the VM, TCP connections to any non-allowlisted destination fail (connection refused or timeout)
- From inside the VM, UDP to non-allowlisted destinations is dropped
- Localhost/loopback traffic (gvproxy internal) is always permitted
- Host-to-guest port forwards (separate code path) are unaffected
- Enforcement is active on both macOS and Linux (same Go binary)

## Acceptance Criteria

1. **Given** gvproxy running with the allowlist configured for gateway:4100, **when** the VM sends a TCP connection to gateway:4100, **then** the connection succeeds.
2. **Given** gvproxy running with the allowlist configured for proxy:3128, **when** the VM sends a TCP connection to proxy:3128, **then** the connection succeeds.
3. **Given** gvproxy running with the allowlist, **when** the VM sends a TCP connection to any external host (e.g., example.com:80), **then** the connection fails.
4. **Given** gvproxy running with the allowlist, **when** the VM sends a UDP packet to an external DNS resolver (e.g., 1.1.1.1:53), **then** the packet is dropped.
5. **Given** gvproxy running with the allowlist, **when** the VM sends a TCP connection to a non-allowlisted port on an allowlisted IP (e.g., gateway:22), **then** the connection fails.
6. **Given** a `tidegate.yaml` with custom gateway/proxy addresses, **when** `tidegate vm start` launches gvproxy, **then** the allowlist reflects the configured addresses.
7. **Given** gvproxy running with the allowlist on macOS, **when** acceptance criteria 1-5 are tested, **then** results match Linux behavior exactly.
8. **Given** an empty allowlist, **when** the VM sends any outbound connection, **then** all connections fail (default-deny).

## Verification

| Criterion | Evidence | Result |
|-----------|----------|--------|

## Scope & Constraints

- Cross-platform: macOS and Linux. Same gvproxy binary, same patch.
- The patch targets `pkg/services/forwarder/tcp.go` and `pkg/services/forwarder/udp.go` — the interception point before `net.Dial()`.
- Defense-in-depth layers (Seatbelt on macOS, network namespace on Linux, TSI scope) are NOT in this spec — they are optional hardening documented in the launcher (SPEC-004).
- Upstream contribution is a goal but not a gate. We maintain a fork until the patch is accepted.
- The allowlist is static per gvproxy launch — no runtime modification. Changing allowed destinations requires restarting gvproxy.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Approved | 2026-03-13 | e6a1bcb | Supersedes SPEC-002 (Seatbelt); per ADR-009 infrastructure-embedded enforcement |
