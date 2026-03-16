---
title: "VM Infrastructure Egress Enforcement"
artifact: SPIKE-022
status: Complete
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
question: "How should egress enforcement be embedded in the VM networking infrastructure (gvproxy) so that it does not depend on host OS sandbox mechanisms?"
parent-epic: EPIC-001
gate: Pre-egress enforcement spec
risks-addressed:
  - Device-level enforcement (Seatbelt, eBPF) depends on host OS capabilities that violate trust zone requirements
  - Platform-specific enforcement mechanisms prevent a unified egress architecture
  - gvproxy is the VM's sole network path but currently has no built-in destination filtering
supersedes:
  - SPIKE-021
depends-on:
  - SPIKE-017
  - SPIKE-019
  - SPIKE-020
blocks:
  - Cross-platform egress enforcement spec
evidence-pool: ""
linked-artifacts:
  - SPEC-001
  - SPEC-002
  - SPIKE-017
  - SPIKE-020
  - SPIKE-021
---
# SPIKE-022: VM Infrastructure Egress Enforcement

## Question

SPIKE-021 recommended device-level OS mechanisms for egress enforcement — Seatbelt on macOS, cgroup/eBPF on Linux. Both are host OS sandboxes applied to gvproxy. **This violates trust zone requirements**: we cannot count on the host device having the right sandbox capabilities or configuration.

gvproxy IS the VM's only network path. All VM traffic flows: guest → virtio-net → gvproxy (Unix socket) → host network. If enforcement is embedded in this pipeline — in gvproxy itself or in the network topology gvproxy operates within — it becomes infrastructure, not a device firewall.

**How do we embed egress enforcement in the VM networking infrastructure so it's guaranteed by construction, not by host OS policy?**

The enforcement must:
- Block all VM traffic to destinations other than gateway:4100 and proxy:3128
- Be guaranteed by the VM infrastructure itself (not dependent on host OS sandbox features)
- Be outside the VM's trust boundary (root in the VM cannot disable it)
- Work cross-platform (gvproxy is the same Go binary on macOS and Linux)
- Be templateable from `tidegate.yaml`

## Candidates Evaluated

### 1. gvproxy destination allowlist (patch gvproxy) — RECOMMENDED

#### Source code architecture

gvproxy's outbound connection path:
1. VM sends packets via Unix socket (libkrun `krun_add_net_unixgram()`) to gvproxy
2. gvproxy's gVisor userspace TCP/IP stack processes packets
3. TCP connections hit `tcp.NewForwarder()` callback in `pkg/services/forwarder/tcp.go`
4. UDP connections hit `udp.NewForwarder()` callback in `pkg/services/forwarder/udp.go`
5. Both call `net.Dial("tcp"|"udp", ...)` to make the actual host-side connection
6. A `tcpproxy.DialProxy` bridges the gVisor endpoint and the outbound host connection

The interception point is between steps 3/4 and 5 — before `net.Dial()` is called. There is currently no destination filtering at this point in mainline.

#### Upstream activity (critical finding)

Three PRs by `clemlesne` target exactly this capability:

**[PR #609](https://github.com/containers/gvisor-tap-vsock/pull/609) (OPEN)** — "feat: add outbound filtering with SNI-based allowlist and security hardening"
- Status: Open, all CI passing, blocked only by DCO sign-off. No maintainer reviews yet.
- Created 2026-02-12, last updated 2026-02-17. +4632/-51 lines across 10 files.
- Supersedes [#599](https://github.com/containers/gvisor-tap-vsock/pull/599) (DNS allowlist) and [#600](https://github.com/containers/gvisor-tap-vsock/pull/600) (blockAllOutbound).

What PR #609 adds to `pkg/types/configuration.go`:
```yaml
blockAllOutbound: true       # Kill all guest-initiated TCP/UDP
outboundAllow:               # Regex allowlist for domains
  - "^(.*\\.)?gateway\\.local$"
  - "^(.*\\.)?proxy\\.local$"
```

PR #609 enforcement layers:

| Traffic Type | Behavior |
|---|---|
| DNS queries | Checked against allowlist; blocked domains get NXDOMAIN |
| TCP port 443 | TLS ClientHello peeked, SNI extracted, checked against allowlist + DNS cross-check |
| TCP non-443 | Blocked (no SNI available) |
| UDP | Only gateway-bound allowed |
| Gateway (192.168.127.1) | Always exempt |
| Host-to-guest forwards | Unaffected (separate code path) |

Security hardening: IP literals in SNI rejected, case normalization, SNI spoofing detection via DNS cross-check, TLS record fragmentation reassembly, ECH GREASE allowed per RFC 9849.

#### Gap for Tidegate

PR #609 filters by **domain name** (DNS + SNI), not by IP:port. Tidegate needs the VM to reach `gateway_ip:4100` and `proxy_ip:3128` by IP address. `blockAllOutbound: true` blocks everything including those. The gateway exemption only covers gvproxy's internal gateway IP (192.168.127.1), not external services.

**What Tidegate needs:** An IP:port allowlist in the TCP/UDP forwarders. This is a simpler patch than PR #609 — check destination IP and port against an allowlist before `net.Dial()`.

**Patch estimate:** ~50 LOC in `tcp.go`, ~30 LOC in `udp.go`, ~10 LOC in `configuration.go`. Total ~90 LOC.

**Upstream acceptance:** Moderate-to-good. PR #609 shows active contributor interest in this area. An IP:port allowlist complements domain-based filtering.

#### Assessment

| Criterion | Met? |
|---|---|
| Infrastructure-level enforcement | Yes — filtering is in gvproxy's connection handling |
| Cross-platform | **Yes** — same Go binary on macOS and Linux |
| Outside VM trust boundary | Yes — gvproxy runs on host, not in VM |
| No host OS sandbox dependency | **Yes** — no Seatbelt, no eBPF, no capabilities |
| No root required | **Yes** |
| Templateable | Yes — allowlist from config file or CLI flags |

**Verdict: Strongest candidate.** Two implementation paths:
- **Path A (immediate):** Fork gvproxy, add IP:port allowlist (~90 LOC), submit upstream, use fork until merged.
- **Path B (medium-term):** Monitor PR #609. If merged, use `blockAllOutbound: true` and route gateway/proxy traffic through gvproxy's internal NAT (VM routes to 192.168.127.1, gvproxy forwards to gateway:4100 and proxy:3128 via its existing port-forward mechanism).

### 2. Network namespace topology — LINUX DEFENSE-IN-DEPTH

gvproxy receives packets from libkrun via Unix socket (file descriptor, not network stack), but makes outbound connections via the host's `net.Dial()`. If gvproxy runs in a network namespace with only routes to gateway and proxy, `net.Dial()` to any other destination fails at the kernel routing level — no route exists.

**Unix socket compatibility:** Confirmed. Unix sockets are file-descriptor-based and work regardless of network namespace. A socket created before entering the namespace (or shared via bind mount) works fine. Only TCP/UDP use the namespace's routing table.

**macOS equivalent:** None. macOS has no network namespaces. Apple's Container framework uses per-container lightweight VMs, but this is proprietary and not a general-purpose mechanism.

| Criterion | Met? |
|---|---|
| Infrastructure-level enforcement | Yes (kernel routing table) |
| Cross-platform | **No** (Linux only) |
| Outside VM trust boundary | Yes |
| Implementation complexity | ~40 lines shell (create netns, veth pair, routes) |

**Verdict:** Viable on Linux only. Useful as defense-in-depth layer alongside gvproxy allowlist.

### 3. gvproxy-in-container (Docker `--internal` network) — FALLBACK

Docker's `--internal` flag creates a network where containers can communicate but have **no route to the internet** — Docker does not create masquerade/NAT rules for internal networks. Run gvproxy, gateway, and proxy as containers on `agent-net --internal`.

**Unix socket sharing:** Works via Docker volume mount. gvproxy binds its socket inside the container at a mounted path; libkrun on the host accesses the same path. Standard pattern (same as Docker daemon socket).

**macOS caveat:** Docker Desktop on macOS runs containers inside a Linux VM (Moby VM). Unix socket sharing goes through Docker Desktop's file sharing layer. Generally works for bind mounts but adds latency and has had historical bugs. Needs validation.

**Boot latency:** Container startup adds ~100-300ms. Negligible vs VM boot (500ms-2s).

| Criterion | Met? |
|---|---|
| Infrastructure-level enforcement | Yes (Docker network topology) |
| Cross-platform | **Yes** (Docker on macOS and Linux) |
| Outside VM trust boundary | Yes |
| Implementation complexity | Docker Compose config + socket volume mount |

**Caveats:**
- Docker becomes a hard runtime dependency
- Unix socket performance through Docker Desktop on macOS needs validation
- Container-in-container complexity if VM launcher is itself containerized
- Relies on Docker's iptables rules (reliable but not as tight as app-level filtering)

**Verdict:** Strong cross-platform fallback. No patching needed. Docker dependency may be acceptable since Tidegate already uses Docker.

### 4. passt — DISQUALIFIED

passt has **no destination filtering capability**. CLI flags (`-t`/`--tcp-ports`, `-u`/`--udp-ports`) control **inbound** port forwarding only. `--no-tcp --no-udp --no-icmp` blocks everything with no allowlisting. passt is also Linux-only.

### 5. gvproxy `--forward-*` flags — DISQUALIFIED

These flags configure **SSH port forwarding tunnels** for host-to-guest access. They do not affect the TCP/UDP forwarder that handles VM-initiated outbound connections. There is no "default deny" mode.

### 6. Custom filtering proxy — OVER-ENGINEERED

Replacing gvproxy reimplements a complex userspace network stack. gvproxy works — the question is how to constrain it, not replace it.

## Comparison Matrix

| Criterion | gvproxy patch | Network NS | Docker container | passt | Forward flags |
|---|---|---|---|---|---|
| Infrastructure-level | Yes (app-level) | Yes (kernel routing) | Yes (Docker network) | No | No |
| Cross-platform | **Yes** | No (Linux only) | **Yes** | No | N/A |
| Outside VM trust boundary | **Yes** | **Yes** | **Yes** | N/A | N/A |
| No host OS sandbox | **Yes** | **Yes** | **Yes** | N/A | N/A |
| No gvproxy patching | No | **Yes** | **Yes** | N/A | N/A |
| No root required | **Yes** | No (CAP_NET_ADMIN) | **Yes** (Docker manages) | N/A | N/A |
| Complexity | ~90 LOC | ~40 LOC shell | Compose config | N/A | N/A |

## Go / No-Go Criteria

**Go:** At least one mechanism can:
1. Guarantee VM traffic can only reach gateway:4100 and proxy:3128 — by infrastructure construction, not host OS policy
2. Work cross-platform (or have a clear per-platform variant that's still infrastructure-level)
3. Not require host OS sandbox features (Seatbelt, eBPF, AppArmor)
4. Be outside the VM trust boundary
5. Be templateable from `tidegate.yaml`

## Findings

### Verdict: GO

**Primary mechanism: gvproxy IP:port destination allowlist**

A ~90 LOC patch to gvproxy's TCP/UDP forwarders (`pkg/services/forwarder/tcp.go`, `udp.go`) adds destination filtering at the exact point where VM-initiated connections become host `net.Dial()` calls. This is:
- **Infrastructure-embedded** — enforcement is in the VM's network stack, not an external sandbox
- **Cross-platform** — same Go code on macOS and Linux
- **Outside VM trust boundary** — gvproxy runs on host
- **No host OS dependencies** — no Seatbelt, no eBPF, no capabilities, no root
- **Templateable** — allowlist generated from `tidegate.yaml` at launch

Upstream gvproxy already has an open PR (#609) adding `blockAllOutbound` + domain-based filtering. Our IP:port allowlist is complementary and a simpler variant of the same interception.

### Implementation paths

| Path | Approach | Timeline | Risk |
|---|---|---|---|
| A (recommended) | Fork gvproxy, add IP:port allowlist, submit upstream | Immediate | Fork maintenance until merge |
| B (alternative) | Use PR #609's `blockAllOutbound` + gvproxy internal NAT forwarding | When #609 merges | Depends on upstream review |
| C (fallback) | gvproxy-in-container on Docker `--internal` network | Immediate | Docker dependency, macOS socket perf |

### Recommended layered enforcement

| Layer | Mechanism | Scope | Platform |
|---|---|---|---|
| 1 (primary) | gvproxy IP:port allowlist | Application-level, in network stack | Both |
| 2 (defense-in-depth) | Network namespace | Kernel routing table | Linux |
| 2 (defense-in-depth) | Seatbelt on gvproxy | Kernel sandbox on connect() | macOS |
| 3 (defense-in-depth) | TSI scope=Group | IP range inside VM | Both |

Layer 1 is the architectural guarantee. Layers 2-3 are hardening that assume a bug in layer 1.

### Implications for existing specs

- **SPEC-002 (Seatbelt Egress Enforcement):** Seatbelt becomes defense-in-depth layer 2, not primary enforcement. SPEC-002 may need revision or a cross-platform egress spec may supersede it.
- **SPEC-001 (VM Launcher CLI):** Egress enforcement table should be updated — primary enforcement is gvproxy allowlist on both platforms.

## Pivot Recommendation

If gvproxy patching proves impractical (upstream rejection, maintenance burden), fall back to gvproxy-in-container (Docker `--internal` network). This requires no code changes and works cross-platform, at the cost of a Docker runtime dependency.

## References

- [gvproxy PR #609: outbound filtering](https://github.com/containers/gvisor-tap-vsock/pull/609) — upstream `blockAllOutbound` + domain allowlist
- [gvproxy PR #600: blockAllOutbound](https://github.com/containers/gvisor-tap-vsock/pull/600) — superseded by #609
- [gvproxy PR #599: DNS allowlist](https://github.com/containers/gvisor-tap-vsock/pull/599) — superseded by #609
- [gvproxy TCP forwarder](https://github.com/containers/gvisor-tap-vsock/blob/main/pkg/services/forwarder/tcp.go) — outbound TCP interception point
- [gvproxy UDP forwarder](https://github.com/containers/gvisor-tap-vsock/blob/main/pkg/services/forwarder/udp.go) — outbound UDP interception point
- [gvproxy config struct](https://github.com/containers/gvisor-tap-vsock/blob/main/pkg/types/configuration.go) — configuration schema
- [Docker --internal networks](https://docs.docker.com/reference/cli/docker/network/create/) — network isolation
- [passt man page](https://passt.top/builds/latest/web/passt.1.html) — no destination filtering
- SPIKE-021: Linux Egress Enforcement (abandoned — device-level mechanisms catalog)
- SPIKE-020: TSI Scope Egress Sufficiency (NO-GO for sole enforcement)
- SPIKE-017: Validate libkrun virtio-net macOS (gvproxy architecture analysis)
- SPEC-002: Seatbelt Egress Enforcement (becomes defense-in-depth)

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-03-13 | 2779ae9 | Investigate infrastructure-embedded egress enforcement; supersedes SPIKE-021 |
| Complete | 2026-03-13 | 2779ae9 | GO: gvproxy IP:port allowlist (~90 LOC patch) is cross-platform infrastructure enforcement |
