---
title: "Linux Egress Enforcement"
artifact: SPIKE-021
status: Active
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
question: "What is the best mechanism for enforcing egress control on a libkrun VM on Linux, equivalent to macOS Seatbelt on gvproxy (SPEC-002)?"
parent-epic: EPIC-001
gate: Pre-Linux egress spec
risks-addressed:
  - No validated Linux egress enforcement mechanism exists for the libkrun VM
  - Different enforcement approaches have different security boundaries and operational complexity
depends-on:
  - SPIKE-019
  - SPIKE-020
blocks:
  - Linux egress enforcement spec
evidence-pool: ""
---

# SPIKE-021: Linux Egress Enforcement

## Question

SPEC-002 solves macOS egress enforcement with Seatbelt on gvproxy — kernel-enforced, zero code changes, outside the VM trust boundary. SPIKE-020 ruled out TSI scope as a sole enforcement mechanism. **What is the Linux equivalent?**

The enforcement must:
- Block all direct internet access from the VM
- Allow only gateway:4100 and proxy:3128
- Be outside the VM's trust boundary (a root attacker in the VM cannot disable it)
- Work with libkrun's gvproxy or passt networking

## Candidates

### 1. nftables on host TAP interface

If using virtio-net with a TAP, apply FORWARD chain rules:
```sh
nft add rule inet filter forward iifname "tap-agent" drop
nft add rule inet filter forward iifname "tap-agent" ip daddr <gateway-ip> tcp dport 4100 accept
nft add rule inet filter forward iifname "tap-agent" ip daddr <proxy-ip> tcp dport 3128 accept
```

**Pros:** Kernel-enforced, standard Linux tooling, per-port granularity, outside VM trust boundary.
**Cons:** Requires TAP interface (not gvproxy's default mode). Requires CAP_NET_ADMIN or root.

### 2. gvproxy-in-container on restricted Docker network

Run gvproxy inside a Docker container connected only to `agent-net`. Docker bridge isolation prevents external access.

**Pros:** No root needed (Docker manages networking). Works with existing Docker infrastructure.
**Cons:** Adds Docker dependency to the VM launcher. gvproxy's Unix socket must be shared between container and host.

### 3. Network namespace isolation

Place gvproxy in a dedicated network namespace with restricted routing:
```sh
ip netns add gvproxy-ns
# Only add routes for gateway and proxy IPs
ip netns exec gvproxy-ns ip route add <gateway-ip>/32 via ...
ip netns exec gvproxy-ns ip route add <proxy-ip>/32 via ...
```

**Pros:** Kernel-enforced, fine-grained, standard tooling.
**Cons:** More complex setup than nftables. Requires CAP_NET_ADMIN.

### 4. eBPF/XDP on TAP or gvproxy socket

Attach eBPF programs for programmable packet filtering.

**Pros:** Dynamic policy, high performance, programmable.
**Cons:** Higher complexity. Requires BPF capabilities. Harder to audit.

### 5. seccomp-bpf on gvproxy

Restrict gvproxy's syscalls — specifically `connect()` destinations.

**Pros:** Process-level, no root needed.
**Cons:** seccomp cannot inspect `connect()` address arguments (only syscall number). Would need seccomp-notify + userspace filter, which is complex.

### 6. Linux Landlock on gvproxy

Landlock LSM can restrict filesystem and (since 5.18) network access.

**Pros:** Unprivileged (no root). Process-level. Kernel-enforced.
**Cons:** Network filtering added in kernel 6.8+ only. Limited to bind/connect port restrictions, not destination IP filtering (as of kernel 6.x). May not support destination IP + port combinations.

### 7. AppArmor profile on gvproxy

AppArmor can restrict network access by process.

**Pros:** Kernel-enforced, standard on Ubuntu/Debian. Process-level.
**Cons:** AppArmor network rules are coarse (allow/deny protocol, not destination). Cannot restrict to specific IPs or ports in standard profiles. Needs net_raw mediation or custom patches.

## Sub-questions

1. Does gvproxy use a TAP interface on Linux, or a different mechanism? (This determines if nftables on TAP is applicable.)
2. Can Linux Landlock restrict `connect()` to specific destination IPs + ports? (Kernel version dependent.)
3. Does AppArmor support per-destination network filtering in any recent version?
4. What is the operational complexity of each approach for end users? (Setup, teardown, debugging.)
5. Which approach most closely mirrors the macOS Seatbelt model (process-level, kernel-enforced, no root)?

## Go / No-Go Criteria

**Go:** At least one mechanism can:
1. Block gvproxy from connecting to any destination except gateway:4100 and proxy:3128
2. Enforcement is kernel-level and outside the VM trust boundary
3. Does not require root (preferred) or requires only initial setup as root
4. Can be templated from `tidegate.yaml` like SPEC-002's Seatbelt profile

## Pivot Recommendation

If no clean mechanism exists, accept nftables (requires root) as the Linux enforcement and document the elevated privilege requirement.

## References

- SPEC-002: Seatbelt Egress Enforcement (macOS equivalent)
- SPIKE-017: Validate libkrun virtio-net macOS (gvproxy egress analysis)
- SPIKE-020: TSI Scope Egress Sufficiency (NO-GO for sole enforcement)
- [nftables](https://wiki.archlinux.org/title/Nftables)
- [Linux Landlock](https://landlock.io/)
- [AppArmor network mediation](https://gitlab.com/apparmor/apparmor/-/wikis/Networking)
- [gvproxy / gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock)

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-03-13 | 11e46d3 | Evaluate Linux egress enforcement mechanisms |
