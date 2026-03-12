---
artifact: SPIKE-017
title: "Validate libkrun virtio-net on macOS with Docker Bridge Routing"
status: Active
author: cristos
created: 2026-03-12
last-updated: 2026-03-12
question: "Can libkrun's virtio-net mode route agent traffic through Tidegate's Docker bridge topology on macOS?"
parent-epic: EPIC-001
gate: Pre-EPIC-001 implementation
risks-addressed:
  - libkrun TSI bypasses Tidegate network control plane; virtio-net is the only viable mode
  - macOS networking (vmnet/passt/gvproxy) may not bridge to Docker networks
depends-on:
  - ADR-008
blocks:
  - EPIC-001 implementation work
  - ADR-008 adoption (validation gate)
---

# Validate libkrun virtio-net on macOS with Docker Bridge Routing

## Question

ADR-008 proposes libkrun as the single VMM for agent isolation. TSI (Transparent Socket Impersonation) is incompatible with Tidegate's proxy routing — it maps guest sockets directly to host sockets, bypassing the gateway and egress proxy entirely. libkrun also supports conventional virtio-net via passt or gvproxy, but this mode has not been validated end-to-end on macOS with Docker bridge routing.

The critical path: can a libkrun VM on macOS, using virtio-net (not TSI), route all traffic through Docker's `agent-net` bridge to reach the gateway at port 4100 and the egress proxy?

## Go / No-Go Criteria

**Go (all must pass):**

1. A libkrun VM on macOS (Apple Silicon, HVF) boots with virtio-net networking (TSI disabled).
2. The VM obtains an IP on the same subnet as Docker's `agent-net` bridge, or can reach services on that bridge via routing.
3. From inside the VM: `curl http://gateway:4100/mcp` (or equivalent IP) reaches the Tidegate gateway and returns a valid MCP response.
4. From inside the VM: all outbound TCP connections route through the egress proxy (no direct internet access bypassing the proxy).
5. virtiofs workspace mount functions correctly alongside virtio-net (both active simultaneously).
6. Round-trip latency for an MCP tool call through the gateway adds <10ms compared to Docker container baseline.

**No-go threshold:** If any of criteria 1-4 fail, networking is broken and ADR-008 cannot be adopted as-is.

## Pivot Recommendation

If virtio-net on macOS cannot route through Docker's bridge:

1. **Try passt with port forwarding**: passt can forward specific ports rather than bridging. If the gateway is reachable at `host.docker.internal:4100`, the VM could target that instead of the Docker bridge IP. Less clean but functional.
2. **Try gvproxy**: Podman's network proxy. May offer different routing semantics than passt.
3. **Fall back to dual-path**: Accept Cloud Hypervisor on Linux (where TAP-to-Docker-bridge is well-proven) and Docker containers on macOS (accepted risk per ADR-005). Amend ADR-008 to Linux-only libkrun.
4. **Investigate macOS vmnet.framework**: Direct bridging via vmnet may work where passt/gvproxy don't.

## Sub-questions

1. **passt vs gvproxy on macOS**: Which networking backend does libkrun use on macOS? Can the user choose? What are the routing semantics of each?
2. **Docker bridge visibility on macOS**: Docker Desktop on macOS runs Docker inside a Linux VM (LinuxKit). The `agent-net` bridge exists inside that VM, not on the macOS host. Can a libkrun VM on the macOS host reach a bridge inside Docker's VM? This may require `host.docker.internal` routing or a shared network namespace.
3. **OrbStack alternative**: OrbStack (popular Docker Desktop alternative on macOS) exposes container IPs directly on the host network. Does this change the routing picture?
4. **Colima/Lima alternative**: Lima-based Docker runtimes may offer different networking models that expose bridges differently.
5. **virtiofs + virtio-net coexistence**: Any conflicts between virtiofsd and passt/gvproxy running simultaneously? Resource contention?
6. **DNS resolution**: Can the VM resolve Docker service names (`gateway`, `egress-proxy`) or must it use IPs?

## Key Experiments

1. **Basic connectivity**: Install krunvm on macOS. Create a minimal Alpine VM with virtio-net. Verify it gets network connectivity and can reach the host.
2. **Docker bridge routing**: Start `docker compose up` (gateway + egress proxy on `agent-net`). From the krunvm VM, attempt to reach the gateway. Document what works and what doesn't.
3. **Proxy enforcement**: Configure the VM's default route to go through the egress proxy. Verify that direct internet access is blocked.
4. **virtiofs + virtio-net**: Add virtiofs workspace mount alongside virtio-net. Verify both work simultaneously.
5. **Latency measurement**: Time an MCP tool call from inside the VM vs from a Docker container. Measure the overhead.

## Why it matters

ADR-008's entire value proposition is "one VMM, all platforms." If virtio-net doesn't work on macOS with Docker bridge routing, macOS falls back to Docker containers — and the simplification argument collapses. This spike is the validation gate for ADR-008 adoption.

## Context at time of writing

libkrun is used by Podman 5.0+ on macOS, but Podman uses gvproxy for its own networking needs (port mapping between host and VM), not for bridging to external Docker networks. The specific configuration Tidegate needs — libkrun VM talking to services on a Docker-managed bridge — is novel and untested.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-03-12 | 9ea534f | Validation gate for ADR-008; blocks EPIC-001 |
