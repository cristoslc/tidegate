---
title: "Linux Egress Enforcement"
artifact: SPIKE-021
status: Abandoned
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
linked-artifacts:
  - SPEC-002
  - SPIKE-017
  - SPIKE-020
  - SPIKE-022
---
# SPIKE-021: Linux Egress Enforcement

## Question

SPEC-002 solves macOS egress enforcement with Seatbelt on gvproxy — kernel-enforced, zero code changes, outside the VM trust boundary. SPIKE-020 ruled out TSI scope as a sole enforcement mechanism. **What is the Linux equivalent?**

The enforcement must:
- Block all direct internet access from the VM
- Allow only gateway:4100 and proxy:3128
- Be outside the VM's trust boundary (a root attacker in the VM cannot disable it)
- Work with libkrun's gvproxy or passt networking

## Key Architectural Constraint

**gvproxy on Linux uses a Unix socket to communicate with libkrun, NOT a host TAP interface.** This means:
- nftables FORWARD chain rules on a TAP interface are **not applicable** — there is no TAP.
- Enforcement must be **process-level on gvproxy** (intercepting its outbound `connect()` calls), not network-level on a virtual interface.
- This mirrors the macOS situation exactly: Seatbelt restricts gvproxy's `connect()` syscall at the process level.

The Linux equivalent must therefore be a process-level, kernel-enforced mechanism that can filter `connect()` by destination IP + port on the gvproxy process.

## Candidates Evaluated

### 1. cgroup v2 + eBPF (BPF_CGROUP_INET4_CONNECT) — RECOMMENDED

Attach a BPF program to gvproxy's cgroup that intercepts every `connect()` call with full visibility into the destination `struct sockaddr_in` (IP + port).

```c
SEC("cgroup/connect4")
int restrict_connect4(struct bpf_sock_addr *ctx) {
    __u32 dst_ip = ctx->user_ip4;
    __u16 dst_port = bpf_ntohs(ctx->user_port);

    // Allow gateway:4100
    if (dst_ip == GATEWAY_IP && dst_port == 4100) return 1;
    // Allow proxy:3128
    if (dst_ip == PROXY_IP && dst_port == 3128) return 1;
    // Allow localhost (gvproxy ↔ libkrun Unix socket traffic)
    if ((dst_ip & 0xFF) == 127) return 1;

    return 0;  // Block everything else
}
```

**How it works:**
1. Create a dedicated cgroup for gvproxy: `mkdir /sys/fs/cgroup/tidegate-gvproxy`
2. Compile and load the BPF program with allowed IPs/ports baked in
3. Attach to the cgroup via `BPF_PROG_ATTACH` with type `BPF_CGROUP_INET4_CONNECT`
4. Move gvproxy's PID into the cgroup
5. Every `connect()` call from gvproxy is intercepted by the kernel — blocked calls return `EPERM`

**Pros:**
- **Kernel-enforced** — the BPF program runs in kernel space, cannot be bypassed by gvproxy or the VM
- **Process-scoped** via cgroup — only affects gvproxy, not the entire host
- **Full IP + port visibility** — `ctx->user_ip4` and `ctx->user_port` give exact destination
- **Available since kernel 4.17** — widely available on modern Linux
- **~20 lines BPF C + ~100 lines loader** — comparable complexity to Seatbelt profile
- **Closest Linux equivalent to macOS Seatbelt** — same enforcement point (connect syscall), same scope (single process), same kernel enforcement

**Cons:**
- Requires `CAP_BPF` + `CAP_NET_ADMIN` (or root) to load the program. Once loaded, enforcement is kernel-level.
- Requires BPF toolchain (libbpf or cilium/ebpf Go library) for compilation
- cgroup v2 must be enabled (default on all modern distros since ~2020)

**Operational model:**
```
tidegate vm start
  → creates cgroup /sys/fs/cgroup/tidegate-gvproxy/
  → compiles BPF program with gateway_ip:4100 + proxy_ip:3128 from tidegate.yaml
  → loads BPF program, attaches to cgroup
  → starts gvproxy in the cgroup (cgexec or echo PID > cgroup.procs)
  → starts libkrun VM
```

Teardown: killing gvproxy + removing the cgroup automatically detaches the BPF program.

### 2. Landlock LSM — DEFENSE-IN-DEPTH LAYER

Landlock v4 (kernel 6.7+) added `LANDLOCK_ACCESS_NET_CONNECT_TCP` for restricting `connect()` by port.

```c
struct landlock_net_port_attr net_port = {
    .allowed_access = LANDLOCK_ACCESS_NET_CONNECT_TCP,
    .port = 4100,
};
landlock_add_rule(ruleset_fd, LANDLOCK_RULE_NET_PORT, &net_port, 0);
// Repeat for port 3128
landlock_restrict_self(ruleset_fd, 0);
```

**Pros:** Unprivileged (no root, no CAP_BPF). Self-restricting — gvproxy applies the policy to itself before starting.
**Cons:** **Port-only filtering — no destination IP.** Allows `connect()` to ANY IP on ports 4100 and 3128. Insufficient as sole enforcement (an attacker could run a server on port 3128 at any IP). Useful as a defense-in-depth layer narrowing the attack surface.

**Verdict:** Layer with cgroup/eBPF. Landlock restricts the port set (unprivileged), eBPF restricts the IP+port combination (privileged). Defense-in-depth.

### 3. Network namespace + nftables — FALLBACK

Place gvproxy in a network namespace with only the allowed routes:

```sh
ip netns add gvproxy-ns
ip link add veth-gvproxy type veth peer name veth-host
ip link set veth-gvproxy netns gvproxy-ns
# Configure addresses and routes
ip netns exec gvproxy-ns ip route add <gateway-ip>/32 via <veth-gvproxy-ip>
ip netns exec gvproxy-ns ip route add <proxy-ip>/32 via <veth-gvproxy-ip>
# nftables inside namespace for port filtering
ip netns exec gvproxy-ns nft add table inet filter
ip netns exec gvproxy-ns nft add chain inet filter output '{ type filter hook output priority 0; policy drop; }'
ip netns exec gvproxy-ns nft add rule inet filter output tcp dport 4100 accept
ip netns exec gvproxy-ns nft add rule inet filter output tcp dport 3128 accept
```

**Pros:** Kernel-enforced, full IP+port control, standard tooling.
**Cons:** Requires CAP_NET_ADMIN. More complex setup/teardown than cgroup/eBPF. Veth pair adds latency. Harder to template.

**Verdict:** Viable fallback if eBPF toolchain is unavailable (e.g., embedded or locked-down systems). Higher operational complexity.

### 4. nftables on host TAP — NOT APPLICABLE

gvproxy on Linux communicates with libkrun via Unix socket, not a host TAP. There is no network interface to filter. **Disqualified.**

### 5. AppArmor — DISQUALIFIED

AppArmor's policy language has `network` rules with IP+port syntax:
```
network inet tcp connect to 192.168.1.1:4100,
```
However, **this syntax is not implemented in the kernel module.** The kernel only enforces protocol-level allow/deny (`network inet tcp`), not destination filtering. The fine-grained syntax exists in the parser but is silently ignored at enforcement time. **Disqualified.**

### 6. seccomp-bpf — DISQUALIFIED

seccomp BPF can only inspect syscall number and register arguments, but `connect()` passes a pointer to `struct sockaddr` — seccomp cannot dereference pointers. Would require seccomp-notify (SECCOMP_RET_USER_NOTIF) to forward `connect()` to a userspace supervisor, adding latency and complexity. **Disqualified** — cgroup/eBPF achieves the same result with less complexity and no userspace hop.

### 7. systemd socket activation / IPAddressAllow — DISQUALIFIED

systemd's `IPAddressAllow=` / `IPAddressDeny=` directives use BPF cgroup internally but only filter by IP, not port. `connect()` to the allowed IP on any port would pass. **Insufficient** for our requirement of IP+port filtering. Same limitation as Landlock but without the unprivileged benefit.

## Comparison Matrix

| Mechanism | IP+Port | Process-scoped | Kernel-enforced | No root | Kernel req | Verdict |
|-----------|---------|----------------|-----------------|---------|------------|---------|
| cgroup/eBPF (connect4) | Yes | Yes (cgroup) | Yes | No (CAP_BPF) | 4.17+ | **PRIMARY** |
| Landlock | Port only | Yes (self) | Yes | Yes | 6.7+ | Defense-in-depth |
| Network namespace + nftables | Yes | Yes (netns) | Yes | No (CAP_NET_ADMIN) | Any | Fallback |
| nftables on TAP | — | — | — | — | — | N/A (no TAP) |
| AppArmor | Not implemented | — | — | — | — | Disqualified |
| seccomp-bpf | No (pointer) | — | — | — | — | Disqualified |
| systemd IPAddress | IP only | Yes | Yes | Yes | 4.15+ | Insufficient |

## Sub-question Answers

1. **Does gvproxy use a TAP on Linux?** No. gvproxy communicates with libkrun via Unix socket (`krun_add_net_unixgram()` or `krun_add_net_unixstream()`). No host TAP is created.
2. **Can Landlock filter by destination IP + port?** No. Landlock v4 (kernel 6.7+) filters by port only. IP filtering is not supported as of kernel 6.x.
3. **Does AppArmor support per-destination filtering?** The syntax exists in the policy parser but is NOT enforced by the kernel module. Effectively no.
4. **Operational complexity?** cgroup/eBPF: moderate (BPF toolchain needed, but ~120 LOC total). Network namespace: high (veth setup, routing, nftables). Landlock: low (self-restricting, no setup).
5. **Closest to macOS Seatbelt?** cgroup/eBPF — same enforcement point (connect syscall), same scope (single process), kernel-enforced.

## Findings

### Verdict: GO

**Primary mechanism: cgroup v2 + eBPF (BPF_CGROUP_INET4_CONNECT)**

This is the Linux equivalent of macOS Seatbelt on gvproxy. It provides:
- Kernel-enforced `connect()` filtering with full IP + port visibility
- Process-scoped enforcement via cgroup (only gvproxy is affected)
- Outside the VM trust boundary (root in the VM cannot disable host BPF programs)
- Templateable from `tidegate.yaml` (IPs and ports are compiled into the BPF program)

### Recommended layered enforcement

| Layer | Mechanism | Privilege | What it restricts |
|-------|-----------|-----------|-------------------|
| 1 (primary) | cgroup/eBPF connect4 | CAP_BPF + CAP_NET_ADMIN | IP + port on connect() |
| 2 (defense-in-depth) | Landlock | Unprivileged | Port set on connect() |
| 3 (defense-in-depth) | TSI scope=Group | Unprivileged | IP range inside VM |

Layers 2 and 3 are optional hardening. Layer 1 alone meets all Go criteria.

### Cross-platform egress architecture

| | macOS | Linux |
|---|---|---|
| **Primary enforcement** | Seatbelt on gvproxy (SPEC-002) | cgroup/eBPF on gvproxy (this spike) |
| **Enforcement point** | `connect()` syscall | `connect()` syscall |
| **Scope** | Process (sandbox-exec) | Process (cgroup) |
| **Kernel enforcement** | Yes (Seatbelt/TrustedBSD) | Yes (BPF) |
| **IP + port filtering** | Yes | Yes |
| **Root required** | No | Yes (CAP_BPF to load; enforcement is then automatic) |
| **Defense-in-depth** | TSI scope | Landlock + TSI scope |
| **Templateable** | Yes (Seatbelt .sb profile) | Yes (BPF program with baked-in IPs/ports) |

### Implementation complexity estimate

- BPF C program: ~20 lines
- Go/Rust loader (using cilium/ebpf or libbpf-rs): ~100 lines
- cgroup setup/teardown: ~30 lines shell or equivalent
- Total: ~150 LOC, comparable to SPEC-002's Seatbelt implementation

## Go / No-Go Criteria

**Go:** All four criteria met.

| # | Criterion | Met? | Evidence |
|---|-----------|------|----------|
| 1 | Block gvproxy except gateway:4100 + proxy:3128 | Yes | BPF_CGROUP_INET4_CONNECT inspects ctx->user_ip4 + ctx->user_port |
| 2 | Kernel-level, outside VM trust boundary | Yes | BPF runs in kernel; cgroup is on host, not in VM |
| 3 | No root preferred, or initial-only root | Partial | CAP_BPF needed to load; enforcement is then automatic. Landlock layer is unprivileged. |
| 4 | Templateable from tidegate.yaml | Yes | IPs and ports compiled into BPF program at launch time |

## References

- SPEC-002: Seatbelt Egress Enforcement (macOS equivalent)
- SPIKE-017: Validate libkrun virtio-net macOS (gvproxy egress analysis)
- SPIKE-020: TSI Scope Egress Sufficiency (NO-GO for sole enforcement)
- [BPF_CGROUP_INET4_CONNECT](https://docs.kernel.org/bpf/prog_cgroup_sockaddr.html) — kernel docs for cgroup/connect BPF programs
- [cilium/ebpf](https://github.com/cilium/ebpf) — Go eBPF library (recommended for loader)
- [libbpf-rs](https://github.com/libbpf/libbpf-rs) — Rust eBPF library (alternative)
- [Linux Landlock](https://landlock.io/) — Landlock LSM documentation
- [Landlock network access control](https://docs.kernel.org/userspace-api/landlock.html#network-flags) — kernel 6.7+ network rules
- [gvproxy / gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock) — gvproxy source
- [nftables](https://wiki.archlinux.org/title/Nftables) — fallback enforcement reference

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-03-13 | 11e46d3 | Evaluate Linux egress enforcement mechanisms |
| Complete | 2026-03-13 | 245eba5 | GO: cgroup/eBPF (BPF_CGROUP_INET4_CONNECT) is the Linux Seatbelt equivalent |
| Abandoned | 2026-03-13 | 2779ae9 | Wrong framing: device-level enforcement violates trust zone requirements. Superseded by SPIKE-022. OS mechanism catalog remains valid as defense-in-depth reference. |
