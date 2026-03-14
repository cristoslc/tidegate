// Package egress implements an IP:port allowlist filter for gvproxy's
// TCP/UDP forwarders. It is designed to be inserted into
// pkg/services/forwarder/tcp.go and udp.go right before net.Dial(),
// blocking connections to destinations not in the allowlist.
//
// Security properties:
//   - Default-deny: empty allowlist blocks all non-loopback traffic
//   - Fail-closed: invalid IPs are denied
//   - Loopback always permitted: 127.0.0.0/8 and ::1 bypass the allowlist
//   - Thread-safe: concurrent reads and writes via RWMutex
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
