---
title: "Infrastructure-Embedded Egress Enforcement"
artifact: ADR-009
status: Accepted
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
linked-epics:
  - EPIC-002
linked-specs:
  - SPEC-002
depends-on:
  - ADR-010
trove: ""
affected-artifacts:
  - SPIKE-021
  - SPIKE-022
---
# ADR-009: Infrastructure-Embedded Egress Enforcement

## Context

Tidegate runs AI agents inside libkrun VMs. The VM's only network path is gvproxy — a userspace NAT that receives packets from the guest via Unix socket and makes host-side `connect()` calls. The VM must only reach the Tidegate gateway (port 4100) and egress proxy (port 3128); all other internet access must be blocked.

SPIKE-021 recommended host OS sandbox mechanisms: Seatbelt (`sandbox-exec`) on macOS and cgroup/eBPF (`BPF_CGROUP_INET4_CONNECT`) on Linux. Both intercept gvproxy's `connect()` syscall at the kernel level and are technically sound.

However, these are **device-level enforcement mechanisms** — they depend on the host OS having specific sandbox capabilities. Seatbelt requires macOS. cgroup/eBPF requires `CAP_BPF` and a modern Linux kernel. We cannot guarantee that the host device where Tidegate runs has these capabilities correctly configured. Device-level firewalls violate trust zone requirements: if the enforcement can be absent, misconfigured, or disabled on the host, it is not a reliable security boundary.

SPIKE-022 investigated alternatives and found that gvproxy itself is the right enforcement point. gvproxy's TCP/UDP forwarders (`pkg/services/forwarder/tcp.go`, `udp.go`) are where VM-initiated connections become host `net.Dial()` calls. An IP:port allowlist at this point provides enforcement that is:
- Guaranteed by construction (no path exists if gvproxy doesn't forward it)
- Cross-platform (same Go binary on macOS and Linux)
- Independent of host OS capabilities

Upstream gvproxy already has an open PR (#609) adding `blockAllOutbound` + domain-based filtering, confirming community interest in this capability.

## Decision

**Egress enforcement must be embedded in the VM networking infrastructure — specifically in gvproxy's connection handling — not in host OS sandbox mechanisms.**

Primary enforcement is an IP:port destination allowlist in gvproxy's TCP/UDP forwarders (~90 LOC patch). gvproxy blocks all VM-initiated outbound connections except those to explicitly allowlisted IP:port pairs (gateway:4100, proxy:3128).

Host OS mechanisms (Seatbelt, cgroup/eBPF, Landlock, network namespaces) are defense-in-depth layers, not primary enforcement. They provide kernel-level hardening against bugs in the primary layer but are not required for the security guarantee to hold.

**Enforcement hierarchy:**

| Layer | Mechanism | Role | Platform |
|-------|-----------|------|----------|
| 1 (primary) | gvproxy IP:port allowlist | Infrastructure guarantee | Both |
| 2 (defense-in-depth) | Seatbelt on gvproxy | Kernel sandbox on connect() | macOS |
| 2 (defense-in-depth) | Network namespace / eBPF | Kernel enforcement | Linux |
| 3 (defense-in-depth) | TSI scope=Group | IP range inside VM | Both |

## Alternatives Considered

### 1. Seatbelt (macOS) + cgroup/eBPF (Linux) as primary

SPIKE-021's recommendation. Kernel-enforced, process-scoped, full IP+port filtering.

**Rejected because:** Device-level. Depends on host OS capabilities that may not be present or correctly configured. Platform-specific — two different enforcement mechanisms to maintain. Violates trust zone requirements.

### 2. Docker `--internal` network isolation

Run gvproxy in a Docker container on a restricted bridge network. Infrastructure-level, cross-platform, no patching.

**Not chosen as primary because:** Makes Docker a hard runtime dependency for the VM launcher. Unix socket performance through Docker Desktop's file sharing layer on macOS is unvalidated. Acceptable as a fallback deployment mode.

### 3. Network namespace topology (Linux)

Place gvproxy in a netns where only gateway and proxy are routable. Kernel-enforced, infrastructure-level.

**Not chosen as primary because:** Linux-only. No macOS equivalent. Useful as defense-in-depth.

### 4. passt destination filtering

passt has no destination filtering capability. `--no-tcp --no-udp` blocks everything with no allowlisting. Disqualified.

## Consequences

**Positive:**
- Single enforcement mechanism across macOS and Linux (gvproxy is the same Go binary)
- Enforcement is guaranteed by the VM infrastructure — if gvproxy is running, enforcement is active
- No host OS feature dependencies — works on any system that can run gvproxy
- Eliminates platform-specific egress specs (SPEC-002 Seatbelt is superseded)
- Defense-in-depth layers are additive, not required

**Negative:**
- Requires patching gvproxy (~90 LOC) — either a fork or upstream contribution
- Enforcement is application-level (userspace), not kernel-level — a bug in gvproxy could theoretically bypass it
- Fork maintenance burden until upstream accepts the patch
- Defense-in-depth layers (Seatbelt, eBPF) are still recommended but are now optional complexity

**Constraints on future work:**
- Any new egress spec must use gvproxy-level enforcement as primary, not OS sandboxes
- SPEC-002 (Seatbelt) is superseded by this decision — Seatbelt is defense-in-depth
- The gvproxy fork/patch is a new dependency that must be maintained

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Accepted | 2026-03-13 | e6a1bcb | Based on SPIKE-022 findings; supersedes SPIKE-021 device-level approach |
