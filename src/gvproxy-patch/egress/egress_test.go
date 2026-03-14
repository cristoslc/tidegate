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
