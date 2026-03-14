# gvproxy Egress Allowlist Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan.

**Goal:** Implement an IP:port egress allowlist for gvproxy's TCP/UDP forwarders that blocks all VM-initiated connections to non-allowlisted destinations before they reach `net.Dial()`.

**Architecture:** A standalone Go module (`src/gvproxy-patch/`) contains the allowlist filter logic, configuration types, and comprehensive tests. The module mirrors gvproxy's interception point — the TCP and UDP forwarder callbacks — and provides a `CheckEgress(ip, port)` function that returns allow/deny. Patch files show the exact diff to apply to gvproxy's `pkg/services/forwarder/tcp.go`, `udp.go`, and `pkg/types/configuration.go`. Default-deny: empty allowlist blocks everything. Loopback always permitted.

**Tech Stack:** Go 1.26, standard library `net` package, `testing` package

---

## Chunk 1: Allowlist Filter Core + Tests

### Task 1: Initialize Go module

**Files:**
- Create: `src/gvproxy-patch/go.mod`
- Create: `src/gvproxy-patch/egress/egress.go`

- [ ] **Step 1: Create Go module**

```sh
cd src/gvproxy-patch && go mod init github.com/tidegate/gvproxy-patch
```

- [ ] **Step 2: Create `egress/egress.go` with types and CheckEgress function**

Create `src/gvproxy-patch/egress/egress.go`:

```go
package egress

import (
	"fmt"
	"net"
	"sync"
)

// AllowEntry represents a single IP:port pair in the egress allowlist.
type AllowEntry struct {
	IP   string `yaml:"ip"`
	Port uint16 `yaml:"port"`
}

// Filter checks outbound connections against an IP:port allowlist.
// Default-deny: if the allowlist is empty, all non-loopback connections are blocked.
// Loopback (127.0.0.0/8, ::1) is always permitted regardless of the allowlist.
type Filter struct {
	mu      sync.RWMutex
	entries []AllowEntry
}

// NewFilter creates a Filter from a list of AllowEntry.
func NewFilter(entries []AllowEntry) *Filter {
	return &Filter{entries: entries}
}

// CheckEgress returns nil if the connection to ip:port is allowed,
// or an error describing why it was denied.
func (f *Filter) CheckEgress(ip string, port uint16) error {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return fmt.Errorf("egress denied: invalid IP %q", ip)
	}

	// Loopback always permitted
	if parsed.IsLoopback() {
		return nil
	}

	f.mu.RLock()
	defer f.mu.RUnlock()

	for _, e := range f.entries {
		if e.IP == ip && e.Port == port {
			return nil
		}
	}

	return fmt.Errorf("egress denied: %s:%d not in allowlist", ip, port)
}

// SetEntries replaces the allowlist atomically. Safe for concurrent use.
func (f *Filter) SetEntries(entries []AllowEntry) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.entries = entries
}

// Entries returns a copy of the current allowlist.
func (f *Filter) Entries() []AllowEntry {
	f.mu.RLock()
	defer f.mu.RUnlock()
	out := make([]AllowEntry, len(f.entries))
	copy(out, f.entries)
	return out
}
```

---

### Task 2: Write failing tests for CheckEgress

**Files:**
- Create: `src/gvproxy-patch/egress/egress_test.go`

- [ ] **Step 1: Write test file covering all acceptance criteria**

Create `src/gvproxy-patch/egress/egress_test.go`:

```go
package egress

import "testing"

func TestAllowlistedTCPSucceeds(t *testing.T) {
	f := NewFilter([]AllowEntry{
		{IP: "172.20.0.2", Port: 4100},
		{IP: "172.20.0.3", Port: 3128},
	})

	// AC1: VM TCP to allowlisted gateway:4100 succeeds
	if err := f.CheckEgress("172.20.0.2", 4100); err != nil {
		t.Errorf("gateway:4100 should be allowed: %v", err)
	}

	// AC2: VM TCP to allowlisted proxy:3128 succeeds
	if err := f.CheckEgress("172.20.0.3", 3128); err != nil {
		t.Errorf("proxy:3128 should be allowed: %v", err)
	}
}

func TestExternalHostDenied(t *testing.T) {
	f := NewFilter([]AllowEntry{
		{IP: "172.20.0.2", Port: 4100},
	})

	// AC3: VM TCP to external host fails
	if err := f.CheckEgress("93.184.216.34", 443); err == nil {
		t.Error("external host should be denied")
	}
}

func TestExternalUDPDenied(t *testing.T) {
	f := NewFilter([]AllowEntry{
		{IP: "172.20.0.2", Port: 4100},
	})

	// AC4: VM UDP to external DNS dropped (same CheckEgress logic)
	if err := f.CheckEgress("8.8.8.8", 53); err == nil {
		t.Error("external DNS should be denied")
	}
}

func TestWrongPortOnAllowlistedIPDenied(t *testing.T) {
	f := NewFilter([]AllowEntry{
		{IP: "172.20.0.2", Port: 4100},
	})

	// AC5: VM TCP to non-allowlisted port on allowlisted IP fails
	if err := f.CheckEgress("172.20.0.2", 8080); err == nil {
		t.Error("wrong port on allowlisted IP should be denied")
	}
}

func TestEmptyAllowlistDeniesAll(t *testing.T) {
	f := NewFilter([]AllowEntry{})

	// AC8: Empty allowlist = all connections fail
	if err := f.CheckEgress("172.20.0.2", 4100); err == nil {
		t.Error("empty allowlist should deny all non-loopback")
	}
	if err := f.CheckEgress("10.0.0.1", 80); err == nil {
		t.Error("empty allowlist should deny all non-loopback")
	}
}

func TestLoopbackAlwaysPermitted(t *testing.T) {
	// Even with empty allowlist, loopback is allowed
	f := NewFilter([]AllowEntry{})

	if err := f.CheckEgress("127.0.0.1", 8080); err != nil {
		t.Errorf("loopback IPv4 should always be allowed: %v", err)
	}
	if err := f.CheckEgress("::1", 8080); err != nil {
		t.Errorf("loopback IPv6 should always be allowed: %v", err)
	}
}

func TestInvalidIPDenied(t *testing.T) {
	f := NewFilter([]AllowEntry{
		{IP: "172.20.0.2", Port: 4100},
	})

	if err := f.CheckEgress("not-an-ip", 4100); err == nil {
		t.Error("invalid IP should be denied")
	}
}

func TestSetEntriesUpdatesAllowlist(t *testing.T) {
	f := NewFilter([]AllowEntry{})

	// Initially denied
	if err := f.CheckEgress("172.20.0.2", 4100); err == nil {
		t.Error("should be denied before SetEntries")
	}

	// AC6: custom addresses reflected in allowlist
	f.SetEntries([]AllowEntry{
		{IP: "172.20.0.2", Port: 4100},
	})

	if err := f.CheckEgress("172.20.0.2", 4100); err != nil {
		t.Errorf("should be allowed after SetEntries: %v", err)
	}
}

func TestEntriesReturnsCopy(t *testing.T) {
	original := []AllowEntry{{IP: "172.20.0.2", Port: 4100}}
	f := NewFilter(original)

	entries := f.Entries()
	entries[0].Port = 9999

	// Modifying the returned slice should not affect the filter
	if err := f.CheckEgress("172.20.0.2", 4100); err != nil {
		t.Error("modifying returned entries should not affect filter")
	}
}

func TestMultipleEntries(t *testing.T) {
	f := NewFilter([]AllowEntry{
		{IP: "172.20.0.2", Port: 4100},
		{IP: "172.20.0.3", Port: 3128},
		{IP: "10.0.0.5", Port: 443},
	})

	tests := []struct {
		ip      string
		port    uint16
		allowed bool
		desc    string
	}{
		{"172.20.0.2", 4100, true, "gateway"},
		{"172.20.0.3", 3128, true, "proxy"},
		{"10.0.0.5", 443, true, "extra allowed"},
		{"172.20.0.2", 3128, false, "gateway IP wrong port"},
		{"172.20.0.3", 4100, false, "proxy IP wrong port"},
		{"10.0.0.5", 80, false, "extra IP wrong port"},
		{"192.168.1.1", 443, false, "unlisted IP"},
	}

	for _, tt := range tests {
		err := f.CheckEgress(tt.ip, tt.port)
		if tt.allowed && err != nil {
			t.Errorf("%s: should be allowed: %v", tt.desc, err)
		}
		if !tt.allowed && err == nil {
			t.Errorf("%s: should be denied", tt.desc)
		}
	}
}
```

- [ ] **Step 2: Run tests — verify they pass**

```sh
cd src/gvproxy-patch && go test ./egress/...
```

---

## Chunk 2: Patch Files for gvproxy

### Task 3: Create gvproxy configuration patch

**Files:**
- Create: `src/gvproxy-patch/patches/configuration.go.patch`

- [ ] **Step 1: Write the patch for `pkg/types/configuration.go`**

This patch adds `EgressAllowlist []EgressAllowEntry` to the Configuration struct.

---

### Task 4: Create TCP forwarder patch

**Files:**
- Create: `src/gvproxy-patch/patches/tcp.go.patch`

- [ ] **Step 1: Write the patch for `pkg/services/forwarder/tcp.go`**

The patch adds an allowlist check right before `net.Dial("tcp", ...)`. If `CheckEgress` denies the connection, the forwarder calls `r.Complete(true)` and returns — the connection never reaches the host network.

---

### Task 5: Create UDP forwarder patch

**Files:**
- Create: `src/gvproxy-patch/patches/udp.go.patch`

- [ ] **Step 1: Write the patch for `pkg/services/forwarder/udp.go`**

The patch adds the same allowlist check before `net.Dial("udp", ...)`. Denied UDP packets are silently dropped (no endpoint created).

---

## Chunk 3: Integration Test

### Task 6: Write integration test validating filter behavior end-to-end

**Files:**
- Create: `src/gvproxy-patch/egress/integration_test.go`

- [ ] **Step 1: Write integration test simulating TCP/UDP forwarder behavior**

The test creates a local TCP listener (simulating gateway), creates a Filter, and validates that:
- Connections to the listener's address succeed when allowlisted
- Connections to a non-allowlisted address fail
- The filter correctly handles the full dial-check-connect cycle

```sh
cd src/gvproxy-patch && go test ./egress/... -run Integration -v
```

---

## Chunk 4: Commit

### Task 7: Commit all work

- [ ] **Step 1: Stage and commit**

```sh
git add src/gvproxy-patch/ docs/superpowers/plans/2026-03-14-gvproxy-egress-allowlist.md
git commit -m "feat: gvproxy egress allowlist filter with TDD tests and patches"
```
