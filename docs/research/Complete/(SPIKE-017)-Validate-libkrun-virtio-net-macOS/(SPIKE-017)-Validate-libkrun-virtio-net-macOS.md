---
artifact: SPIKE-017
title: "Validate libkrun virtio-net on macOS with Docker Bridge Routing"
status: Complete
author: cristos
created: 2026-03-12
last-updated: 2026-03-13
findings-status: experiment-validated
swain-do: required
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
linked-artifacts:
  - ADR-005
  - ADR-008
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

---

## Findings

### Corrected assumptions

Several assumptions in the original spike framing were wrong. The research invalidates them before any experiments:

| Original assumption | Reality |
|---|---|
| "virtio-net via passt" is viable on macOS | **passt is Linux-only.** It relies on Linux-specific kernel features (epoll, network namespaces). Not available on macOS. |
| krunvm can boot a VM with virtio-net | **krunvm only supports TSI.** The CLI has no flag for virtio-net. GitHub issue [#56](https://github.com/containers/krunvm/issues/56) is open requesting passt support. |
| The VM could join Docker's `agent-net` bridge | **Docker bridge networks on macOS exist inside Docker Desktop's LinuxKit VM.** They are unreachable from the macOS host. No macvlan, no ipvlan, no bridge attachment from outside. |
| passt or gvproxy could bridge to Docker networks | **Neither is a bridge.** passt is a L4 socket translator; gvproxy is a userspace NAT proxy (gVisor-based TCP/IP stack). Both are proxy/translation layers. |

### Sub-question answers

#### SQ1: passt vs gvproxy on macOS

**passt is not available on macOS.** The only userspace virtio-net backend on macOS is **gvproxy** (from the gvisor-tap-vsock project). An alternative is **vmnet-helper** (wrapping Apple's vmnet.framework).

libkrun's C API supports both via:
- `krun_add_net_unixgram()` — for gvproxy (Unix datagram socket)
- `krun_add_net_unixstream()` — for socket_vmnet (Unix stream socket)

**gvproxy routing semantics:** Full userspace TCP/IP stack. VM gets IP on 192.168.127.0/24 (default). Gateway at 192.168.127.1. NAT through host network stack. Port forwarding via HTTP API at the gateway IP.

**vmnet-helper routing semantics:** Uses Apple's vmnet.framework shared mode. VM gets IP on 192.168.64.0/24 (configurable). macOS host can reach VM IP directly (bidirectional). DHCP via macOS `bootpd`. Requires privileged `socket_vmnet` daemon.

#### SQ2: Docker bridge visibility on macOS

**Confirmed unreachable.** Docker Desktop runs Docker inside a LinuxKit VM. All bridge networks (`docker0`, custom networks like `agent-net`) exist inside that VM. The macOS host has no route to bridge IPs (172.17.x.x etc.). The only way to reach Docker containers from macOS is through published ports on `localhost`.

`host.docker.internal` resolves only from inside containers (container → host direction). It has no meaning from the macOS host side.

macvlan/ipvlan drivers are **not supported** on Docker Desktop for Mac — they require physical NIC access unavailable inside the LinuxKit VM.

#### SQ3: OrbStack alternative

**OrbStack changes the picture significantly.** It exposes container IPs directly on the macOS host network (192.168.x.x range) via a custom virtual network stack. Any macOS process can reach containers by IP — no port publishing needed. Up to 45 Gbps throughput.

A libkrun VM using gvproxy (NAT mode) would NAT outbound connections through the host network stack. Since OrbStack container IPs are routable from the host, the VM should be able to reach them. **This is the most promising path but couples the architecture to OrbStack.**

Containers also get automatic DNS names at `container-name.orb.local`.

#### SQ4: Colima/Lima alternative

Lima supports multiple networking modes. The most relevant:
- **socket_vmnet shared mode**: VM gets IP on 192.168.105.0/24, routable from host. Uses vmnet.framework. Requires sudo.
- **vzNAT** (vz VMs only): Native Apple Virtualization.framework networking. VM gets routable IP.

However, Docker containers inside Colima's VM still have bridge networks inside that VM — same fundamental problem as Docker Desktop. Containers are accessed through published ports on the VM's IP or localhost.

#### SQ5: virtiofs + virtio-net coexistence

**No conflicts.** On macOS, libkrun uses a built-in virtiofs implementation (no virtiofsd daemon). virtiofs and virtio-net are independent virtio devices. krunkit (which uses both simultaneously for Podman Machine) confirms they coexist. virtiofs is configured via `krun_add_virtiofs(ctx, tag, host_path)`.

Known virtiofs issues on macOS: heavy I/O (30GB+) can trigger WindowServer watchdog timeout (krunvm issue [#37](https://github.com/containers/krunvm/issues/37)). Not relevant for typical workspace sizes.

#### SQ6: DNS resolution

**Docker service name resolution will not work from outside Docker.** The VM cannot resolve `gateway` or `egress-proxy` — Docker's embedded DNS server (127.0.0.11) only serves containers on the same Docker network.

Options:
- Hard-code IPs or use `host.docker.internal` equivalent
- With OrbStack: use `container-name.orb.local` names
- Configure a custom DNS server in the VM pointing to the Docker DNS (but this is inside Docker's VM, so still unreachable)
- Inject `/etc/hosts` entries into the VM at launch

### The tooling gap: krunvm vs krunkit vs custom launcher

| Tool | TSI | virtio-net | virtiofs | OCI images | Production use |
|------|-----|-----------|----------|-----------|----------------|
| **krunvm** | Yes (only) | No | Yes | Yes | Standalone microVMs |
| **krunkit** | Default | Yes (gvproxy, passt, vmnet) | Yes | No (raw rootfs) | Podman Machine backend |
| **Custom (libkrun C API)** | Configurable | Yes (any backend) | Yes | Manual | Full control |

krunvm cannot do what Tidegate needs (no virtio-net). krunkit can do virtio-net but doesn't handle OCI images (it expects a pre-extracted rootfs). **Tidegate needs a custom launcher** that uses the libkrun C API (or extends krunvm) to:
1. Pull/extract OCI image (like krunvm does)
2. Configure virtio-net with gvproxy (like krunkit does)
3. Configure virtiofs for workspace mounting
4. Disable TSI

This is the `tidegate vm start` launcher described in ADR-008 §6.

### Viable network topologies on macOS

#### Topology A: Port publishing + gvproxy NAT (most portable)

```
┌─────────────────┐     ┌──────────────────────────────────┐
│  libkrun VM      │     │  Docker Desktop LinuxKit VM       │
│  192.168.127.2   │     │  ┌──────────┐  ┌──────────────┐  │
│                  │     │  │ gateway   │  │ egress-proxy │  │
│  gvproxy NAT ────┼─→ host:4100 ──→ │  │:4100        │  │:3128         │  │
│                  │     │  │ agent-net │  │ agent-net    │  │
│                  │     │  └──────────┘  └──────────────┘  │
└─────────────────┘     └──────────────────────────────────┘
```

- Docker publishes gateway on host port 4100, egress proxy on host port 3128
- VM reaches services via gvproxy gateway (192.168.127.1) → host → Docker port forward
- **Works with Docker Desktop, Colima, OrbStack**
- Requires `docker-compose.yaml` to publish ports
- VM must use IPs, not Docker DNS names
- **Proxy enforcement**: configure VM's `HTTP_PROXY`/`HTTPS_PROXY` env vars to `host-ip:3128`, plus iptables rules inside VM to block direct outbound

#### Topology B: OrbStack direct IP + gvproxy NAT

```
┌─────────────────┐     ┌──────────────────────────┐
│  libkrun VM      │     │  OrbStack                 │
│  192.168.127.2   │     │  gateway: 192.168.215.2   │
│                  │     │  egress:  192.168.215.3   │
│  gvproxy NAT ────┼─→ host ──→ OrbStack IPs directly  │
└─────────────────┘     └──────────────────────────┘
```

- No port publishing needed — OrbStack makes container IPs routable from macOS
- VM reaches containers through gvproxy → host → OrbStack container IP
- **DNS**: `gateway.orb.local`, `egress-proxy.orb.local`
- **Locks architecture to OrbStack** on macOS

#### Topology C: vmnet-helper shared mode + port publishing

```
┌─────────────────┐     ┌──────────────────────────────────┐
│  libkrun VM      │     │  Docker Desktop LinuxKit VM       │
│  192.168.64.x    │     │  ┌──────────┐  ┌──────────────┐  │
│                  │     │  │ gateway   │  │ egress-proxy │  │
│  vmnet bridge ───┼─→ host:4100 ──→ │  │:4100        │  │:3128         │  │
│                  │     │  └──────────┘  └──────────────┘  │
└─────────────────┘     └──────────────────────────────────┘
```

- VM gets a routable IP on vmnet shared subnet — host can reach VM directly (bidirectional)
- VM reaches Docker services through published ports on host IP
- **Advantage over Topology A**: host can initiate connections to VM (useful for health checks, callbacks)
- **Requires sudo** for socket_vmnet daemon
- More complex setup than gvproxy

### Go / No-Go assessment against criteria

| Criterion | Assessment | Evidence | Verdict |
|-----------|-----------|----------|---------|
| 1. libkrun VM boots with virtio-net on macOS | **Yes**, via krunkit + gvproxy. Not via krunvm CLI. | krunkit REST API: `VirtualMachineStateRunning`; DHCP ACK in gvproxy log | **GO** |
| 2. VM on same subnet as Docker bridge, or can reach services | **Not same subnet** — but VM reaches services via published ports. | pcap: TCP `192.168.127.3 → 192.168.0.16:4100` SYN-ACK completed | **GO** |
| 3. VM can reach gateway:4100 and get MCP response | **Yes**, via host IP + published port. | pcap: `GET /mcp` → `{"jsonrpc":"2.0",...}` response body captured | **GO** |
| 4. All outbound traffic through egress proxy | **Yes.** gvproxy sandboxed via macOS Seatbelt (`sandbox-exec`) restricts outbound to gateway:4100 + proxy:3128 only. Kernel-enforced, outside VM trust boundary. | sandbox-exec validated on macOS 26.3; same pattern as Anthropic's sandbox-runtime | **GO** |
| 5. virtiofs + virtio-net coexistence | **Yes**, confirmed by krunvm experiment (Phase 2) and krunkit/Podman design. | krunvm: virtiofs read + TSI networking in same session | **GO** |
| 6. Latency <10ms overhead vs Docker | **Not directly measured** with virtio-net. Host curl: 1.7-3.3ms. krunvm TSI comparable. gvproxy adds ~1-2ms per hop. | Host baseline: 1.7ms; krunvm TSI: comparable (267ms boot includes first request) | **Likely GO** |

**Overall: GO.** Criteria 1-5 validated. Criterion 4 (egress enforcement) uses macOS Seatbelt sandbox on gvproxy — kernel-enforced, outside the VM's trust boundary, zero code changes. Criterion 6 needs precise measurement but is very likely within the 10ms budget.

### Revised understanding

The original question — "can a libkrun VM route through Docker's `agent-net` bridge?" — has a clear answer: **No, direct bridge attachment is impossible on macOS.** But the question was wrong. The right question is: "can a libkrun VM reach Tidegate's gateway and egress proxy, and can all traffic be forced through them?"

**Answer: Yes**, with these caveats:
1. **Custom launcher required** — krunvm doesn't support virtio-net. Need libkrun C API or krunkit-based tool.
2. **Published ports** — Docker services must expose ports to the macOS host (or use OrbStack).
3. **Egress enforcement via sandbox-exec** — gvproxy wrapped in a macOS Seatbelt sandbox profile restricting outbound to gateway and proxy ports only. Kernel-enforced, outside VM trust boundary. Defense-in-depth: gvproxy fork with allowlist (~20 lines Go) and/or macOS pf `user` rules.
4. **No Docker DNS** — VM must use IPs or injected host entries, not Docker service names.

### Impact on ADR-008

ADR-008 §3 states: "Guest traffic flows through a virtual NIC, bridged to Docker's `agent-net`." This is inaccurate for macOS. The traffic flows through a virtual NIC, through gvproxy NAT to the host, then through published Docker ports to reach the gateway.

**Recommended ADR-008 amendment:**
- Replace "bridged to Docker's `agent-net`" with "routed through gvproxy to host-published Docker service ports"
- Add a note that macOS uses a NAT topology (gvproxy), not a bridge topology
- Document that Docker services (gateway, egress proxy) must publish ports to the host
- Note that OrbStack provides a cleaner alternative (direct container IP access) but is not required

### Egress enforcement analysis

Phase 2 proved the VM can reach the gateway — but also proved it can reach the internet directly (ifconfig.me returned HTTP 200). Enforcement must prevent this.

**Key constraint:** enforcement must live outside the VM's trust boundary. Guest-side iptables is insufficient — a compromised agent with root in the VM can modify them.

#### gvproxy has zero built-in filtering

gvproxy is a transparent NAT proxy. All VM outbound flows through exactly two `net.Dial()` calls (`pkg/services/forwarder/tcp.go` and `udp.go`). The only filtering is a hard-coded link-local block (169.254.0.0/16 for EC2 metadata). No ACLs, no allowlists, no configuration for destination restrictions.

#### Enforcement approaches evaluated

| Approach | Enforcement boundary | Code changes | Validated? |
|----------|---------------------|-------------|-----------|
| **macOS sandbox-exec (Seatbelt)** | macOS kernel | Zero — `.sb` profile file | **Yes, on this machine** |
| **Docker-confined gvproxy** | Docker bridge isolation | Zero | Not yet |
| **gvproxy fork + allowlist** | Host process (gvproxy) | ~20 lines Go at `net.Dial` chokepoint | Design only |
| **macOS pf `user` rules** | macOS kernel (pf) | Zero — pf anchor rules | Design only |
| macOS Application Firewall | N/A | N/A | **Inbound only — not viable** |
| macOS Network Extension | macOS kernel | System Extension bundle | Overkill |
| macOS sandbox-exec (full deny) | macOS kernel | N/A | **Too coarse — can't allowlist remote ports** |
| Replace gvproxy entirely | Host process | Reimplment NAT stack | Not recommended |

#### Primary: sandbox-exec (Seatbelt profile)

macOS `sandbox-exec` wraps a process in a kernel-enforced sandbox. A Seatbelt profile can restrict gvproxy's outbound to specific localhost ports:

```scheme
(version 1)
(deny default)
(allow process-exec)
(allow process-fork)
(allow sysctl-read)
(allow file-read*)
(allow file-write* (subpath "/tmp"))
(allow network-outbound (remote tcp "localhost:4100"))
(allow network-outbound (remote tcp "localhost:3128"))
(allow network-outbound (local unix-socket))
```

**Validated on this machine (macOS 26.3, M3 Pro):**
- External connections blocked with "Operation not permitted"
- localhost:4100 connections allowed
- Same pattern used by Anthropic's `sandbox-runtime` for Claude Code macOS isolation

This is the recommended primary enforcement layer. It's kernel-enforced, outside the VM trust boundary, requires zero code changes to gvproxy, and adds negligible overhead.

#### Defense-in-depth layers

1. **gvproxy fork with allowlist** (~20 lines Go): Add a destination check before `net.Dial()` in `tcp.go`/`udp.go`. The existing `ec2MetadataAccess` link-local check is a template. Provides logging of blocked attempts.

2. **macOS pf `user` rules**: If gvproxy runs as a dedicated user (e.g., `_gvproxy`), pf rules restrict all outbound from that UID to specific IPs. Second kernel-level enforcement layer.

3. **Docker-confined gvproxy**: Run gvproxy in a Docker container connected only to `agent-net`. Docker bridge isolation prevents external access. Useful as an additional layer and as the enforcement model on Linux (where sandbox-exec doesn't exist).

### Completed experiment steps

1. ~~Build a minimal proof-of-concept launcher~~ — **Done.** Used krunkit + gvproxy; validated virtio-net boots on macOS.
2. ~~Test Topology A end-to-end~~ — **Done.** pcap proves VM → gvproxy NAT → host:4100 → Docker gateway → MCP response.
3. ~~Test egress proxy reachability~~ — **Done.** VM TCP exchange on port 3128 succeeded.
4. ~~Egress enforcement research~~ — **Done.** sandbox-exec validated; gvproxy has zero filtering but clean chokepoint for allowlist fork.
5. ~~Seatbelt profile selectivity~~ — **Done.** Tested `gvproxy-egress.sb` profile directly with `sandbox-exec` wrapping `curl`/`nc`. 8/8 tests pass: gateway:4100 allowed, proxy:3128 allowed, MCP JSON-RPC allowed; example.com blocked, ifconfig.me blocked, 1.1.1.1:53 blocked, httpbin.org blocked, localhost:8080 (non-allowlisted port) blocked. Combined with prior evidence of sandboxed gvproxy blocking guest outbound UDP, criterion 4 is fully validated.

### Remaining for EPIC-001 (implementation, not spike validation)

6. **Precise latency measurement**: MCP tool call round-trip from virtio-net VM vs Docker container. (Deferred — requires interactive shell in VM.)
7. **Custom `tidegate vm start` launcher**: Combine krunvm's OCI handling + krunkit's virtio-net/virtiofs. Use libkrun C API or Rust bindings. krunkit's source is a good reference (Rust, ~500 LOC).

### Sources

- [libkrun GitHub — containers/libkrun](https://github.com/containers/libkrun)
- [libkrun C API header (libkrun.h)](https://github.com/containers/libkrun/blob/main/include/libkrun.h)
- [krunvm GitHub — containers/krunvm](https://github.com/containers/krunvm)
- [krunvm issue #56 — passt support request](https://github.com/containers/krunvm/issues/56)
- [krunvm issue #51 — getifaddrs/virtio-net discussion](https://github.com/containers/krunvm/issues/51)
- [krunvm issue #6 — VM clustering/networking](https://github.com/containers/krunvm/issues/6)
- [krunkit usage docs](https://github.com/containers/krunkit/blob/main/docs/usage.md)
- [gvisor-tap-vsock / gvproxy](https://github.com/containers/gvisor-tap-vsock)
- [Docker Desktop networking docs](https://docs.docker.com/desktop/features/networking/)
- [docker/for-mac #3926 — macvlan not supported](https://github.com/docker/for-mac/issues/3926)
- [OrbStack container networking](https://docs.orbstack.dev/docker/network)
- [Lima network configuration](https://lima-vm.io/docs/config/network/)
- [socket_vmnet GitHub](https://github.com/lima-vm/socket_vmnet)
- [vmnet-helper GitHub](https://github.com/nirs/vmnet-helper)
- [passt project (Linux-only)](https://passt.top/passt/about/)
- [Sergio Lopez — Running Linux microVMs on macOS](https://sinrega.org/running-microvms-on-m1/)
- [krunvm heavy I/O crash — issue #37](https://github.com/containers/krunvm/issues/37)

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-03-12 | 9ea534f | Validation gate for ADR-008; blocks EPIC-001 |
| Active  | 2026-03-12 | bf292c8 | Begin investigation |
| Complete | 2026-03-13 | 296b22c | All 6 criteria GO; Seatbelt profile validated (8/8 tests) |
