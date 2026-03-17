---
title: "Seatbelt Egress Enforcement"
artifact: SPEC-002
status: Abandoned
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
type: feature
parent-epic: EPIC-001
linked-research:
  - SPIKE-017
linked-adrs:
  - ADR-005
  - ADR-008
  - ADR-009
depends-on:
  - SPEC-001
addresses:
  - JOURNEY-001.PP-01
trove: ""
source-issue: ""
swain-do: required
linked-artifacts:
  - ADR-005
  - ADR-008
  - JOURNEY-001
  - SPEC-001
  - SPEC-005
---
# SPEC-002: Seatbelt Egress Enforcement

## Problem Statement

SPIKE-017 validated that gvproxy provides VM networking on macOS but has zero built-in filtering — all VM outbound traffic is NAT'd to the host network without restriction. A compromised agent in the VM can reach any internet destination, bypassing the egress proxy entirely. Egress enforcement must live outside the VM's trust boundary.

SPIKE-017 validated macOS `sandbox-exec` (Seatbelt) as the primary enforcement mechanism: kernel-enforced, zero code changes, same pattern Anthropic uses for Claude Code's `sandbox-runtime`.

## External Behavior

**Artifacts produced:**
- `src/vm-launcher/gvproxy-egress.sb` — Seatbelt profile that restricts gvproxy's outbound connections to gateway:4100 and proxy:3128 only
- Integration with `tidegate vm start` (SPEC-001) — gvproxy is launched wrapped in `sandbox-exec -f gvproxy-egress.sb`

**Enforcement guarantees:**
- From inside the VM, TCP connections to gateway:4100 succeed
- From inside the VM, TCP connections to proxy:3128 succeed
- From inside the VM, TCP connections to any other destination are blocked with "Operation not permitted"
- From inside the VM, UDP outbound (including DNS to external resolvers) is blocked
- Enforcement is kernel-level (macOS sandbox), outside the VM trust boundary

## Acceptance Criteria

1. **Given** gvproxy running under the Seatbelt profile, **when** the VM sends a TCP connection to gateway:4100, **then** the connection succeeds.
2. **Given** gvproxy running under the Seatbelt profile, **when** the VM sends a TCP connection to proxy:3128, **then** the connection succeeds.
3. **Given** gvproxy running under the Seatbelt profile, **when** the VM sends a TCP connection to any external host (e.g., example.com:80), **then** the connection fails with "Operation not permitted".
4. **Given** gvproxy running under the Seatbelt profile, **when** the VM sends a UDP packet to an external DNS resolver (e.g., 1.1.1.1:53), **then** the packet is dropped.
5. **Given** gvproxy running under the Seatbelt profile, **when** the VM sends a TCP connection to a non-allowlisted localhost port (e.g., localhost:8080), **then** the connection fails.
6. **Given** a `tidegate.yaml` with custom gateway/proxy ports, **when** `tidegate vm start` generates the Seatbelt profile, **then** the profile reflects the configured ports.

## Verification

| Criterion | Evidence | Result |
|-----------|----------|--------|

## Scope & Constraints

- macOS only. Linux enforcement uses Docker network isolation (separate concern, not in this spec).
- The Seatbelt profile is the primary layer. Defense-in-depth (gvproxy fork with allowlist, pf rules) are future enhancements, not in this spec.
- `sandbox-exec` is deprecated by Apple but still functional on macOS 26.3. If Apple removes it, the fallback is a Network Extension or pf rules.

## Implementation Approach

1. **Test**: Write test script that launches `sandbox-exec -f profile.sb curl <target>` and asserts allow/deny behavior for each criterion.
2. **Implement**: Create `gvproxy-egress.sb` Seatbelt profile based on SPIKE-017's validated profile.
3. **Test**: Run the 8-case test suite from SPIKE-017 (gateway allowed, proxy allowed, MCP JSON-RPC allowed, example.com blocked, ifconfig.me blocked, 1.1.1.1:53 blocked, httpbin.org blocked, non-allowlisted port blocked).
4. **Implement**: Template generation — `tidegate vm start` reads gateway/proxy ports from config and generates the .sb profile with correct port numbers.
5. **Test**: Integration test with custom ports.

## Related

- [ADR-005](../../../adr/Accepted/(ADR-005)-Composable-VM-Isolation.md) — Architectural decision establishing VM isolation approach
- [ADR-008](../../../adr/Superseded/(ADR-008)-libkrun-Single-VMM-for-Agent-Isolation.md) — Selected libkrun VMM whose gvproxy networking this spec enforces
- [JOURNEY-001](../../../journey/Validated/(JOURNEY-001)-Securing-an-AI-Assistant/(JOURNEY-001)-Securing-an-AI-Assistant.md) — User journey requiring egress enforcement (PP-01)

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Approved | 2026-03-13 | b530c62 | Decomposed from EPIC-001; validated in SPIKE-017 (8/8 tests pass) |
| Abandoned | 2026-03-13 | e6a1bcb | Superseded by SPEC-005; ADR-009 moved primary egress to gvproxy allowlist; Seatbelt demoted to defense-in-depth |
