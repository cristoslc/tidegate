# SPIKE-017 Experiment Results

**Date:** 2026-03-12
**Platform:** macOS 26.3.1, Apple M3 Pro (arm64), Docker Desktop 29.2.1
**Tools:** krunvm 0.2.6, libkrun 1.17.4, gvproxy (installed but not used — krunvm doesn't support virtio-net)

## Phase 1: Docker mock gateway

| Test | Result | Notes |
|------|--------|-------|
| Gateway reachable from host (localhost:4100) | PASS | `{"status":"ok"}` |
| Gateway returns MCP response (/mcp) | PASS | Valid JSON-RPC response |
| Egress proxy reachable from host (localhost:3128) | PASS | socat forwards to gateway |

## Phase 2: krunvm TSI baseline

| Test | Result | Notes |
|------|--------|-------|
| VM boots (Alpine 3.21) | PASS | Kernel 6.12.68, aarch64 |
| Cold boot time | PASS | **267ms** (including virtiofs) — far below <2s target |
| No eth0 interface (confirms TSI) | PASS | Only loopback; TSI uses vsock, no virtual NIC |
| VM reaches gateway:4100 via busybox wget | PASS | First call succeeds, subsequent calls intermittently fail |
| VM reaches gateway:4100 via netcat | PASS | Consistent — raw HTTP/1.0 over TCP works reliably |
| VM gets MCP JSON-RPC response | PASS | Full `{"jsonrpc":"2.0",...}` response received |
| VM reaches egress proxy:3128 | **FAIL** | socat TCP forwarding works from host but not from VM via TSI |
| VM DNS resolution | PASS | Resolves via 1.1.1.1 (configured in /etc/resolv.conf) |
| VM external TCP (1.1.1.1:53) | PASS | Raw TCP connects to external IPs |
| VM external TCP (google:80) | PASS | Raw TCP connects — **confirms TSI bypasses any proxy** |
| VM external HTTP (wget to external sites) | **FAIL** | busybox wget gets "Invalid argument" on external HTTP responses |
| virtiofs mount | PASS | Reads host files correctly |
| virtiofs + TSI networking coexistence | PASS | Both work in same session |

## Key observations

### TSI networking quirks

1. **busybox wget is unreliable with TSI sockets.** The first wget to localhost often works, but subsequent calls intermittently fail with "Invalid argument" or "Host is unreachable." Raw TCP via netcat works consistently. This appears to be a TSI socket emulation issue with HTTP response parsing or connection reuse.

2. **External HTTP is broken via busybox wget.** TCP connects fine (`nc -z` succeeds), DNS resolves, but `wget` to any external HTTP site fails. Likely related to TSI's socket emulation not fully implementing all socket options that wget uses.

3. **TSI confirms the proxy bypass problem.** External TCP connections succeed directly — the VM can reach the internet without going through any proxy. This validates ADR-008's requirement to use virtio-net instead of TSI.

### Boot time

267ms cold boot on M3 Pro is significantly faster than the 1-2s estimate from SPIKE-015. The OCI image was pre-extracted (krunvm create does this once), so startup is just VMM init + kernel boot + init. This eliminates boot time as a concern entirely.

### virtiofs

Works seamlessly. No virtiofsd daemon — libkrun handles it internally. Zero measurable overhead on boot time (267ms with and without volume mount). Reads host files correctly.

## Phase 3: gvproxy + virtio-net

**NOT TESTED.** krunvm 0.2.6 does not support virtio-net — only TSI. Testing virtio-net requires either:

1. **krunkit** — not available in the slp/krun Homebrew tap; separate project at github.com/containers/krunkit
2. **Custom launcher** using libkrun C API (`krun_add_net_unixgram()` with gvproxy)
3. **Podman Machine** with `CONTAINERS_MACHINE_PROVIDER=libkrun` — uses libkrun + gvproxy internally

### Recommended next step

Install krunkit and gvproxy to test Topology A (gvproxy NAT → host published ports → Docker gateway). krunkit accepts `--device virtio-net,type=unixgram,path=<gvproxy-socket>` which is exactly the configuration Tidegate needs.
