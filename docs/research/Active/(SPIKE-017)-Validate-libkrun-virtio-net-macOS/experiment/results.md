# SPIKE-017 Experiment Results

**Date:** 2026-03-12
**Platform:** macOS 26.3.1, Apple M3 Pro (arm64), Docker Desktop 29.2.1
**Tools:** krunvm 0.2.6, libkrun 1.17.4, libkrun-efi 1.16.0, krunkit 1.1.1, gvproxy 0.8.8

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

## Phase 3: krunkit + gvproxy virtio-net

**Topology A validated.** Used krunkit 1.1.1 + gvproxy 0.8.8 + Alpine 3.21 cloud image (nocloud UEFI cloudinit, aarch64 qcow2).

### Setup

1. gvproxy started on unix datagram socket (`-listen-vfkit unixgram:///tmp/spike017-gvproxy.sock`)
2. krunkit launched with:
   - `--device virtio-blk,path=alpine-cloudinit.qcow2,format=qcow2` (boot disk)
   - `--device virtio-blk,path=spike017-seed.iso,format=raw` (cloud-init NoCloud seed)
   - `--device virtio-net,type=unixgram,path=/tmp/spike017-gvproxy.sock,mac=52:54:00:92:fe:ba,offloading=on,vfkitMagic=on`
   - `--device virtio-serial,logFilePath=/tmp/spike017-serial.log`
3. Docker mock gateway on `agent-net`, ports published: 4100 (gateway), 3128 (egress proxy)

### Results (from pcap capture)

| Test | Result | Evidence |
|------|--------|----------|
| VM boots with virtio-net on macOS (HVF) | **PASS** | krunkit REST API reports `VirtualMachineStateRunning` |
| VM gets IP via DHCP from gvproxy | **PASS** | DHCP ACK: `YourClientIP=192.168.127.3` (gvproxy log) |
| VM has real eth0 interface (not TSI) | **PASS** | ARP, DHCP, NTP over Ethernet frames in pcap |
| VM TCP to gateway:4100 via host IP | **PASS** | TCP 3-way handshake: `192.168.127.3:41204 → 192.168.0.16:4100` (pcap) |
| VM HTTP GET /health → 200 OK | **PASS** | Response body: `{"status":"ok"}` (pcap) |
| VM HTTP GET /mcp → MCP response | **PASS** | Response body: `{"jsonrpc":"2.0","id":1,"result":{"tools":[...]}}` (pcap) |
| VM TCP to egress proxy:3128 | **PASS** | Full TCP handshake + HTTP exchange on port 3128 (pcap) |
| VM external HTTP (ifconfig.me) | **PASS** | HTTP 200 from ifconfig.me — **confirms direct internet access is possible (proxy enforcement needed)** |
| VM DNS resolution | **PASS** | NTP to external IPs succeeded (implies DNS worked via gvproxy) |
| gvproxy NAT routing | **PASS** | All traffic from VM (192.168.127.3) NATed through host to reach Docker published ports and external IPs |

### Key observations

1. **Topology A works end-to-end.** VM → gvproxy NAT → host IP → Docker published port → container. The VM sent `GET /health` to `192.168.0.16:4100` and received `{"status":"ok"}` from the nginx mock gateway running on Docker's `agent-net`.

2. **MCP JSON-RPC response received.** The VM got the full `{"jsonrpc":"2.0",...}` response, proving that MCP tool calls from a libkrun VM through the gateway are viable.

3. **Egress proxy reachable.** Port 3128 (socat → gateway) had a successful TCP exchange with the VM.

4. **Direct internet access works (needs enforcement).** The VM successfully fetched `http://ifconfig.me` — gvproxy NATs all outbound traffic through the host. To enforce egress proxy policy, the guest needs iptables rules blocking all outbound except through the proxy. This is the same enforcement model as Docker containers.

5. **No SSH needed for validation.** Cloud-init `runcmd` triggered the test; pcap captured the full HTTP exchange. The `tcpdump -A` output shows request/response payloads.

6. **Boot time.** EFI boot with cloudinit image took ~10-15s (cloud-init initialization). The krunvm OCI boot (267ms) is much faster. Tidegate's custom launcher should use the OCI/rootfs approach (like krunvm) with virtio-net (like krunkit) for optimal boot time.

### Topology A diagram (validated)

```
┌────────────────────────┐     ┌──────────────────────────────────┐
│  libkrun VM (krunkit)   │     │  Docker Desktop LinuxKit VM       │
│  192.168.127.3          │     │  ┌──────────┐  ┌──────────────┐  │
│  eth0 (virtio-net)      │     │  │ gateway   │  │ egress-proxy │  │
│         │               │     │  │ :80       │  │ :3128        │  │
│         ▼               │     │  └─────┬────┘  └──────┬───────┘  │
│  gvproxy (NAT)          │     │        │               │          │
│  192.168.127.1          │     │     agent-net (bridge)            │
│         │               │     └────────┼───────────────┼──────────┘
│         ▼               │              │               │
│  macOS host network ────┼──→ 0.0.0.0:4100         0.0.0.0:3128
│  192.168.0.16           │     (Docker port publishing)
└────────────────────────┘
```
