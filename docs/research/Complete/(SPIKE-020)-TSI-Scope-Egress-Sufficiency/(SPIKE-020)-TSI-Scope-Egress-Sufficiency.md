---
title: "TSI Scope Egress Sufficiency"
artifact: SPIKE-020
status: Complete
author: cristos
created: 2026-03-13
last-updated: 2026-03-13
question: "Does libkrun's krun_set_tsi_scope() + krun_set_port_map() provide sufficient egress control for Tidegate's agent isolation requirements?"
parent-epic: EPIC-001
gate: Pre-SPEC-001 architecture decision
risks-addressed:
  - Adopting TSI-based egress control (microsandbox) when it may be too coarse for Tidegate's proxy-routing model
  - Committing to virtio-net + packet filtering when a simpler VMM-native solution exists
depends-on:
  - SPIKE-019
blocks:
  - SPEC-001 networking architecture decision
  - SPEC-002 egress enforcement approach on Linux
trove: "findings-2026-03-13"
linked-artifacts:
  - SPIKE-017
  - SPIKE-018
  - SPIKE-019
---
# SPIKE-020: TSI Scope Egress Sufficiency

## Question

SPIKE-019 found that libkrun's `krun_set_tsi_scope()` provides VMM-level egress control without gvproxy, Seatbelt, or nftables. microsandbox uses this for agent sandboxing. But Tidegate's model is more specific: all agent traffic must route through a gateway (port 4100) and an egress proxy (port 3128), with no direct internet access.

**Can TSI scope + port mapping enforce this model, or does Tidegate require virtio-net with packet-level filtering?**

## Background

### TSI (Transparent Socket Impersonation)

libkrun intercepts all guest socket syscalls (`connect`, `bind`, `listen`, `accept`, `sendto`, `recvfrom`) at the VMM level. Instead of emulating a network interface, TSI proxies socket operations through virtio-vsock to the host. The guest sees no NIC — `ip addr` shows nothing — but `curl` works because the syscalls are transparently proxied.

### TSI scope levels

| Scope | Value | Behavior |
|-------|-------|----------|
| None | 0 | Block all IP communication |
| Group | 1 | Allow connections only within the configured subnet |
| Public | 2 | Allow public IPs, block private ranges |
| Any | 3 | Allow all (default) |

### Port mapping

`krun_set_port_map()` maps guest ports to host ports. Example: guest `localhost:4100` → host `localhost:4100`. This is the mechanism for the agent to reach the Tidegate gateway.

## Go / No-Go Criteria

**Go (TSI scope is sufficient):**

1. The agent inside the VM can reach the Tidegate gateway at a mapped port and get a valid MCP response.
2. The agent can reach the egress proxy at a mapped port.
3. The agent CANNOT reach any internet destination directly (bypassing the proxy).
4. The agent CANNOT reach host services on unmapped ports.
5. DNS resolution works (the agent can resolve hostnames, routed through the proxy or a controlled resolver).
6. The egress proxy can reach the internet on the agent's behalf (proxy's outbound is not blocked by TSI — it runs on the host, outside the VM).

All six must pass.

**No-go pivot:** If TSI scope cannot enforce criteria 3 or 4, fall back to virtio-net + packet filtering (gvproxy + Seatbelt on macOS, TAP + nftables on Linux). TSI scope would still be usable as a defense-in-depth layer alongside packet filtering.

## Sub-questions

1. **Scope + port map interaction**: With scope=Group (subnet only), can a port-mapped service on `localhost` be reached? Or does scope=Group block localhost because it's not "in the subnet"? What subnet does Group use?
2. **Scope=None + port map**: Can scope=None (block all) be combined with port maps to create an allowlist model? (Block everything, then map only gateway:4100 and proxy:3128.)
3. **DNS under TSI**: How does DNS work? TSI intercepts `connect()` to UDP port 53 — does it proxy to the host's resolver? Can this be controlled?
4. **HTTP_PROXY env var under TSI**: If the agent has `HTTP_PROXY=host:3128` and port 3128 is mapped, does standard proxy-aware software (curl, npm, pip, git) route through the proxy correctly under TSI?
5. **Non-TCP protocols**: TSI handles TCP and UDP. What about ICMP (ping)? Raw sockets? Can an agent bypass TSI by using raw sockets?
6. **Scope enforcement boundary**: Is the scope enforced in the VMM (host-side) or in the guest kernel (libkrunfw)? If guest-side, a compromised agent with root could modify it.
7. **microsandbox's actual egress behavior**: What does microsandbox's `--scope=group --subnet=...` actually enforce? Has anyone tested it for security (not just functionality)?

## Key Experiments

1. **Scope=None + port map allowlist**: Configure `krun_set_tsi_scope(0)` (None) + port maps for gateway:4100 and proxy:3128 only. Verify: mapped ports reachable, everything else blocked.
2. **Direct internet bypass attempt**: With scope=Group, try `curl https://example.com` directly (no proxy). Verify it fails.
3. **Proxy routing**: Set `HTTP_PROXY` env var, scope=Group, proxy port mapped. Verify `curl https://example.com` succeeds through the proxy.
4. **DNS behavior**: Verify `nslookup`/`dig` behavior under each scope level. Can the agent resolve external hostnames?
5. **Raw socket escape**: Attempt `ping` or raw socket from inside the VM. Verify TSI blocks it.
6. **Enforcement boundary**: Check libkrun source — is scope enforced in the VMM (Rust, host-side) or in libkrunfw (guest kernel)?

## Pivot Recommendation

If TSI scope is insufficient:
- Use TSI scope as a defense-in-depth layer (scope=Group or scope=None)
- Primary enforcement via virtio-net + packet filtering (existing SPIKE-017/019 approach)
- microsandbox remains viable as the launcher — just add `--net=passt` mode (FFI bindings exist)

## References

- SPIKE-019: Linux VM Launcher Evaluation (microsandbox finding)
- SPIKE-017: Validate libkrun virtio-net macOS (gvproxy + Seatbelt approach)
- SPIKE-018: macOS VM Launcher Evaluation (Lima approach)
- [libkrun TSI implementation](https://github.com/containers/libkrun)
- [microsandbox](https://github.com/zerocore-ai/microsandbox)
- [microsandbox docs — networking](https://docs.microsandbox.dev/)
- [libkrun C API header](https://github.com/containers/libkrun/blob/main/include/libkrun.h)

## Findings (2026-03-13 Source Analysis)

### 1. TSI Scope Enforcement Boundary: HOST-SIDE (with a critical caveat)

**Answer: The IP filtering is enforced in the VMM (host-side Rust code), but the socket hijacking itself is guest-kernel-side and runtime-mutable.**

The architecture has two layers:

**Layer A -- Socket hijacking (GUEST kernel, libkrunfw):** Kernel patches `0009` and `0010` in `containers/libkrunfw` modify `net/socket.c` `__sock_create()` to intercept `socket()` syscalls. When `tsi_hijack=true`, any non-kernel call to `socket(AF_INET, SOCK_STREAM|SOCK_DGRAM, ...)` is silently redirected to `socket(AF_TSI, ...)`, which creates a dual-personality socket that communicates with the VMM via virtio-vsock.

**Layer B -- IP filtering (HOST VMM, microsandbox fork only):** The `IpFilterConfig` in `src/devices/src/virtio/vsock/ip_filter.rs` (zerocore-ai/libkrun `appcypher/ip-filtering` branch) checks destination IPs in `VsockMuxer::process_connect()` and `process_sendto_addr()` before proxying. This runs in the VMM process on the host. A guest cannot modify it.

**Critical vulnerability in Layer A:** The `tsi_hijack` parameter is declared as:
```c
core_param(tsi_hijack, tsi_hijack, bool, 0644);
```
With `CONFIG_SYSFS=y` and `CONFIG_MODULES=n` in libkrunfw's kernel config, this parameter is exposed at `/sys/module/kernel/parameters/tsi_hijack` and is **writable by root at runtime** (mode `0644` = owner-writable). A root process in the guest can:
```sh
echo 0 > /sys/module/kernel/parameters/tsi_hijack
```
After this, new `socket(AF_INET, ...)` calls bypass TSI entirely. They create real AF_INET sockets. However, these sockets would have no network interface to route through (TSI mode has no NIC), so they would fail with connection errors -- unless virtio-net is also configured.

**Exception: SEV/TDX builds** use `CONFIG_CMDLINE_OVERRIDE=y` with `tsi_hijack` baked into the kernel cmdline, but the `core_param` is still runtime-writable via sysfs regardless.

**Net assessment for enforcement boundary:** The IP filtering in Layer B is genuinely host-side and tamper-resistant. The hijacking mechanism in Layer A is guest-side and runtime-mutable, but disabling it without an alternative network path results in no connectivity rather than unrestricted connectivity. This is a defense-in-depth strength of TSI's architecture: there is no NIC to fall back to.

### 2. Scope + Port Map Interaction: INDEPENDENT MECHANISMS

**Answer: Port maps and scope filtering are orthogonal. Scope=0 (None) blocks ALL outbound connections including to port-mapped services. Port maps only affect inbound (host-to-guest) listening.**

From the source analysis:

- `krun_set_port_map()` configures `host_port_map: HashMap<u16, u16>` which maps host ports to guest ports. Format: `"host_port:guest_port"`. This is used in `TsiStreamProxy::try_listen()` to remap bind addresses for **inbound** connections (host connecting to guest service).

- Scope filtering (`IpFilterConfig::is_allowed_connect()`) checks **outbound** connections. With scope=0, `is_allowed_connect()` returns `false` for all IPs, and the muxer sends `ECONNREFUSED` back to the guest before any connection is attempted.

- There is no code path where port_map exempts an outbound connection from scope filtering.

**Implication for Tidegate:** The "scope=None + port map allowlist" model described in the spike's experiment #1 **will not work as hoped**. Scope=0 blocks all outbound, and port maps only allow inbound. The agent would not be able to connect to the gateway or proxy. You would need scope=Group (with the gateway/proxy subnet) or scope=Any, not scope=None.

### 3. Scope=Group Subnet Configuration

**Answer: Configured via `krun_set_tsi_scope(ctx_id, ip, subnet, 1)`. The subnet is an IPv4 CIDR string (e.g., "192.168.1.0/24"). Scope=Group requires a subnet; without one, `IpFilterConfig::is_valid()` returns false. There is no default subnet.**

From `ip_filter.rs`:
```rust
1 => self.subnet.map_or(false, |subnet| subnet.contains(dest_ip))
```

You could configure it to include only the gateway and proxy IPs by using a narrow subnet (e.g., `"10.0.0.0/30"` for IPs 10.0.0.1 and 10.0.0.2). However, this requires the gateway and proxy to be on the same subnet, and the guest needs to connect to IPs within that subnet.

**Problem:** TSI proxies connections to the host's actual network stack. The guest `connect("10.0.0.1:4100")` becomes a host-side `connect("10.0.0.1:4100")`. If the gateway is listening on `localhost:4100`, the guest would need to connect to `127.0.0.1:4100` -- but `127.0.0.1` is classified as private/loopback and would be blocked by scope=Group (unless the subnet includes `127.0.0.0/8`). Including `127.0.0.0/8` in the subnet would expose all host loopback services.

### 4. DNS Under TSI

**Answer: DNS has no special handling in TSI. UDP `connect()` to port 53 is proxied like any other UDP connection, subject to scope filtering. There is no host resolver proxy. DNS cannot be controlled per-scope.**

From the source analysis:
- `tsi_dgram.rs` is a generic UDP datagram proxy with no DNS-specific logic
- There is no port 53 detection, DNS packet inspection, or resolver injection
- The guest's `/etc/resolv.conf` determines which resolver is used
- With scope=0 (None), DNS is blocked. With scope=Group, DNS works only if the resolver IP is within the subnet. With scope=2 (Public), DNS to public resolvers (8.8.8.8) works but DNS to private resolvers (192.168.1.1) is blocked.

**Implication for Tidegate:** DNS resolution is a significant gap. If scope=Group restricts to a narrow subnet, the agent cannot resolve hostnames unless a DNS resolver is within that subnet or DNS is routed through the proxy (which requires the agent to use DNS-over-HTTPS or the proxy to handle DNS).

### 5. Raw Socket / ICMP Handling

**Answer: TSI does NOT intercept SOCK_RAW or ICMP. The hijacking only applies to `SOCK_STREAM` and `SOCK_DGRAM`.**

From patch 0010:
```c
if (!kern && (type == SOCK_STREAM || type == SOCK_DGRAM)) {
```

SOCK_RAW is not in this condition. A `socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)` call creates a real AF_INET raw socket, not a TSI socket.

**However, this is not a practical bypass** because:
1. TSI mode has no network interface (no NIC, no route). Raw sockets require a route to transmit packets.
2. `CONFIG_PACKET=y` is enabled in libkrunfw, which theoretically allows `AF_PACKET` sockets, but again there is no interface to bind to.
3. `ping` would fail because there is no interface to route ICMP through.

The absence of a network interface is the actual security boundary, not TSI's socket filtering. Raw sockets are harmless without a NIC.

### 6. Protocols TSI Proxies

**Answer: AF_INET/AF_INET6 (SOCK_STREAM, SOCK_DGRAM) and AF_UNIX (absolute paths only, Linux only).**

Confirmed from source:
- `TsiFlags::HIJACK_INET` (bit 0): hijacks AF_INET and AF_INET6 sockets of type SOCK_STREAM and SOCK_DGRAM
- `TsiFlags::HIJACK_UNIX` (bit 1): hijacks AF_UNIX sockets (Linux only, not supported on macOS per issue #526)
- SOCK_RAW: not intercepted
- AF_NETLINK: not intercepted
- AF_PACKET: not intercepted

Unsupported protocols that are not intercepted would fail silently (no route/interface) rather than succeed.

### 7. Port Mapping Details

**Answer: Format is `"host_port:guest_port"`. Maps host-side listening ports to guest-side ports. Used for INBOUND connections (host to guest), not outbound.**

From `include/libkrun.h`:
```c
int32_t krun_set_port_map(uint32_t ctx_id, const char *const port_map[]);
```

- Passing NULL: exposes all guest listening ports to the host
- Passing empty array: maps no ports
- The mapping is host_port:guest_port (host connects to host_port, arrives at guest on guest_port)
- Cannot map to specific host IPs -- the host port listens on the host's network stack
- Returns `-ENOTSUP` when passt networking is used

**Correction to spike assumptions:** The spike describes port_map as "guest `localhost:4100` -> host `localhost:4100`". This is inverted. Port maps enable the HOST to reach GUEST services, not vice versa. For the agent (in the guest) to reach the gateway (on the host), the agent uses a normal outbound `connect()` which TSI proxies to the host -- no port map needed. Port maps are needed if the gateway needs to send requests TO the agent.

### 8. microsandbox's Actual TSI Usage

**Answer: microsandbox declares `krun_set_tsi_scope()` in its FFI bindings and passes `config.scope as u8` to it. However, the IP filtering implementation exists only on the `appcypher/ip-filtering` feature branch of `zerocore-ai/libkrun`, NOT on the default `krun` branch. It is not merged to mainline.**

From `microsandbox-core/lib/vm/microvm.rs`:
```rust
ffi::krun_set_tsi_scope(ctx_id, ptr::null(), ptr::null(), config.scope as u8);
```

Note: `ip` and `subnet` are always passed as `ptr::null()`. The IP and subnet fields exist in `MicroVmConfig` but are never wired to the FFI call.

**NetworkScope enum** (from `microsandbox-core/lib/config/microsandbox/config.rs`):
- `None = 0`: Block all IP communication
- `Group = 1`: Allow within subnet (marked "Not implemented" in comments)
- `Public = 2`: Allow public IPs (DEFAULT)
- `Any = 3`: Allow any

The default scope is `Public` (value 2), which blocks private IPs but allows all public IPs. This is significantly more permissive than Tidegate needs.

microsandbox links dynamically to `libkrun` (`#[link(name = "krun")]`). The `krun_set_tsi_scope()` function must exist in the libkrun shared library at runtime. If using upstream `containers/libkrun`, this function does not exist and would cause a linker error.

### 9. Security Audits / Adversarial Testing of TSI

**Answer: No public security audits, CVEs, or adversarial testing of TSI scope found.**

- `containers/libkrun` has no SECURITY.md and no published security advisories
- No CVEs are registered for libkrun
- The README explicitly states: "the guest and the VMM pertain to the same security context"
- Several TSI-related bugs have been filed: #510 (internal sockets intercepted), #511 (degraded concurrent performance), #526 (broken on macOS), #579 (large POST dropped)
- Issue #576 documents an application compatibility problem (apps detect no routable interface)
- The IP filtering in microsandbox's fork is in a feature branch, suggesting it's not production-hardened

The libkrun maintainer (Sergio Lopez, Red Hat) positions TSI as a networking convenience for containers, not as a security boundary. The project's trust model assumes "the guest and the VMM pertain to the same security context."

### 10. TSI Scope + virtio-net Coexistence

**Answer: Both can be configured simultaneously. They are attached independently in `builder.rs`. When TSI hijacking is active, socket operations go through vsock/TSI; the virtio-net interface exists but receives less traffic. However, if `tsi_hijack` is disabled at runtime, traffic could route through virtio-net instead.**

From `builder.rs`:
```rust
#[cfg(feature = "net")]
attach_net_devices(&mut vmm, &vm_resources.net, intc.clone())?;

if let Some(vsock) = vm_resources.vsock.get() {
    attach_unixsock_vsock_device(&mut vmm, vsock, event_manager, intc.clone())?;
    // ... insert tsi_hijack into kernel cmdline
}
```

If both are configured and a root process disables `tsi_hijack` via sysfs, new socket operations would create real AF_INET sockets. With a virtio-net interface present, these sockets would have a route and could bypass TSI filtering entirely. **This combination would be insecure.**

The safe configuration is TSI-only (no virtio-net), where disabling tsi_hijack results in no connectivity rather than unrestricted connectivity.

## Analysis: Go / No-Go Assessment

### Go Criteria Results

| # | Criterion | Result | Notes |
|---|-----------|--------|-------|
| 1 | Agent reaches gateway at mapped port | PARTIAL | Agent uses outbound connect (not port map). Works with scope >= Group if gateway IP is in subnet. |
| 2 | Agent reaches egress proxy at mapped port | PARTIAL | Same as #1. "Mapped port" concept is inverted -- port maps are for inbound. |
| 3 | Agent CANNOT reach internet directly | PASS (scope 0-2) | Scope=None blocks all. Scope=Group blocks non-subnet. Scope=Public blocks private only. |
| 4 | Agent CANNOT reach host services on unmapped ports | FAIL | TSI proxies ALL outbound connections to the host's network stack. There is no port-level outbound allowlist. Any host-listening service on an IP within the scope is reachable. |
| 5 | DNS resolution works | CONDITIONAL | Only if the DNS resolver IP is allowed by the scope. No built-in DNS proxy. |
| 6 | Egress proxy reaches internet (host-side) | PASS | Proxy runs on host, outside VM, unaffected by TSI. |

### Verdict: NO-GO for TSI scope as sole enforcement

**TSI scope is insufficient for Tidegate's proxy-routing model** for these reasons:

1. **No outbound port-level allowlist.** TSI scope filters by IP address/range, not by port. With scope=Group on a subnet containing the gateway host, the agent can reach ANY service on that host, not just ports 4100 and 3128.

2. **Port maps are inbound-only.** The port_map mechanism does not create an outbound allowlist. It enables host-to-guest connections, which is the opposite of what Tidegate needs.

3. **DNS is uncontrolled.** There is no DNS proxy or DNS-specific filtering. DNS works only if the resolver IP passes scope checks, and the agent can query any DNS server within the allowed scope.

4. **Scope=None blocks everything including the gateway.** The "block all + allowlist exceptions" model is not achievable with TSI scope alone.

5. **No production hardening.** The IP filtering code is on a feature branch, not merged to mainline. microsandbox's Group scope is marked "Not implemented." No security audits exist.

### Recommended Pivot

Use TSI scope as a **defense-in-depth layer**, not the primary enforcement:

- **Primary enforcement:** Squid egress proxy + `HTTP_PROXY`/`HTTPS_PROXY` env vars. The agent's software uses the proxy voluntarily.
- **TSI scope (defense-in-depth):** Set scope=Group with a subnet containing only the host IP where the gateway and proxy listen. This prevents the agent from reaching arbitrary internet IPs even if it ignores the proxy env vars.
- **No virtio-net:** Do not configure virtio-net alongside TSI. This ensures disabling tsi_hijack results in no connectivity, not unrestricted connectivity.
- **DNS:** Configure the guest's `/etc/resolv.conf` to point to a resolver within the allowed subnet, or use DNS-over-HTTPS through the proxy.
- **Future hardening:** If microsandbox merges IP filtering to mainline and adds per-port filtering, revisit this assessment.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-03-13 | b8cbfc6 | Validate TSI scope for Tidegate egress model |
| Active | 2026-03-13 | b8cbfc6 | Source analysis complete: NO-GO for sole enforcement, YES for defense-in-depth |
