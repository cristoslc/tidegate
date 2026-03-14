# Applying gvproxy Egress Allowlist Patches

These patches add IP:port egress filtering to gvproxy's TCP/UDP forwarders.

## Target repository

https://github.com/containers/gvisor-tap-vsock

## Files modified

| File | Change |
|------|--------|
| `pkg/types/configuration.go` | Add `EgressAllowEntry` type and `EgressAllowlist` field to `Configuration` |
| `pkg/services/forwarder/tcp.go` | Add allowlist check before `net.Dial("tcp", ...)` |
| `pkg/services/forwarder/udp.go` | Add allowlist check before `net.Dial("udp", ...)` |

## Additional file required

Copy the `egress/` package into the gvproxy repo at `pkg/services/forwarder/egress/` (or another suitable location) and add the import to both forwarder files.

## How to apply

```sh
# Clone the fork
git clone https://github.com/containers/gvisor-tap-vsock.git
cd gvisor-tap-vsock

# Copy the egress filter package
cp -r /path/to/gvproxy-patch/egress/ pkg/services/forwarder/egress/

# Apply patches
git apply /path/to/gvproxy-patch/patches/configuration.go.patch
git apply /path/to/gvproxy-patch/patches/tcp.go.patch
git apply /path/to/gvproxy-patch/patches/udp.go.patch
```

## Configuration example

In gvproxy's YAML config:

```yaml
egressAllowlist:
  - ip: "172.20.0.2"
    port: 4100
  - ip: "172.20.0.3"
    port: 3128
```

## Behavior

- TCP connections to allowlisted IP:port pairs succeed
- TCP connections to non-allowlisted destinations get `RST` (r.Complete(true))
- UDP packets to non-allowlisted destinations are silently dropped
- Loopback (127.0.0.0/8, ::1) always permitted
- Host-to-guest port forwards are unaffected (separate code path)
- Empty allowlist = default-deny (all non-loopback blocked)
