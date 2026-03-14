package egress

import (
	"fmt"
	"net"
	"sync"
	"testing"
	"time"
)

// TestIntegrationTCPAllowlistDialFlow simulates the gvproxy TCP forwarder
// flow: check the allowlist, then dial (or reject) the connection.
func TestIntegrationTCPAllowlistDialFlow(t *testing.T) {
	// Start a local TCP listener simulating the gateway
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to start listener: %v", err)
	}
	defer listener.Close()

	// Accept connections in background
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			conn, err := listener.Accept()
			if err != nil {
				return // listener closed
			}
			conn.Close()
		}
	}()

	addr := listener.Addr().(*net.TCPAddr)

	filter := NewFilter([]AllowEntry{
		{IP: addr.IP.String(), Port: uint16(addr.Port)},
	})

	// Simulate forwarder: check allowlist, then dial
	t.Run("allowed_connection_succeeds", func(t *testing.T) {
		if err := filter.CheckEgress(addr.IP.String(), uint16(addr.Port)); err != nil {
			t.Fatalf("allowlist check should pass: %v", err)
		}

		conn, err := net.DialTimeout("tcp",
			fmt.Sprintf("%s:%d", addr.IP.String(), addr.Port),
			2*time.Second)
		if err != nil {
			t.Fatalf("dial to allowed destination failed: %v", err)
		}
		conn.Close()
	})

	// Simulate forwarder: check allowlist for wrong port on non-loopback IP
	// (loopback is always permitted, so we test with a non-loopback address)
	t.Run("denied_connection_never_dials", func(t *testing.T) {
		// Use a non-loopback IP to test port denial
		err := filter.CheckEgress("172.20.0.2", uint16(addr.Port))
		if err == nil {
			t.Fatal("allowlist check should deny non-allowlisted IP:port")
		}
		// In a real forwarder, we would NOT call net.Dial here.
		// The connection is rejected before it ever reaches the host network.
	})

	// Simulate forwarder: check allowlist for external IP
	t.Run("external_ip_denied", func(t *testing.T) {
		err := filter.CheckEgress("93.184.216.34", 443)
		if err == nil {
			t.Fatal("allowlist check should deny external IP")
		}
	})

	// Simulate forwarder: loopback on different port
	t.Run("loopback_always_allowed", func(t *testing.T) {
		err := filter.CheckEgress("127.0.0.1", 9999)
		if err != nil {
			t.Fatalf("loopback should always be allowed: %v", err)
		}
	})

	listener.Close()
	wg.Wait()
}

// TestIntegrationUDPAllowlistDropFlow simulates the gvproxy UDP forwarder
// flow: check the allowlist before creating the UDP proxy.
func TestIntegrationUDPAllowlistDropFlow(t *testing.T) {
	// Start a local UDP listener
	udpAddr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to resolve UDP addr: %v", err)
	}
	conn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		t.Fatalf("failed to start UDP listener: %v", err)
	}
	defer conn.Close()

	addr := conn.LocalAddr().(*net.UDPAddr)

	filter := NewFilter([]AllowEntry{
		{IP: addr.IP.String(), Port: uint16(addr.Port)},
	})

	t.Run("allowed_udp_passes_check", func(t *testing.T) {
		if err := filter.CheckEgress(addr.IP.String(), uint16(addr.Port)); err != nil {
			t.Fatalf("UDP allowlist check should pass: %v", err)
		}
	})

	t.Run("external_dns_dropped", func(t *testing.T) {
		// AC4: VM UDP to external DNS dropped
		if err := filter.CheckEgress("8.8.8.8", 53); err == nil {
			t.Fatal("external DNS should be denied")
		}
	})

	t.Run("empty_allowlist_drops_all_udp", func(t *testing.T) {
		// Use a non-loopback IP since loopback is always permitted
		emptyFilter := NewFilter([]AllowEntry{})
		if err := emptyFilter.CheckEgress("172.20.0.2", 4100); err == nil {
			t.Fatal("empty allowlist should drop all non-loopback UDP")
		}
	})
}

// TestIntegrationConcurrentAccess verifies the filter is safe under
// concurrent reads and writes (simulating runtime config reload).
func TestIntegrationConcurrentAccess(t *testing.T) {
	filter := NewFilter([]AllowEntry{
		{IP: "172.20.0.2", Port: 4100},
	})

	var wg sync.WaitGroup
	done := make(chan struct{})

	// Concurrent readers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-done:
					return
				default:
					// These should never panic
					filter.CheckEgress("172.20.0.2", 4100) //nolint:errcheck
					filter.CheckEgress("10.0.0.1", 80)     //nolint:errcheck
					filter.Entries()
				}
			}
		}()
	}

	// Concurrent writer
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			filter.SetEntries([]AllowEntry{
				{IP: "172.20.0.2", Port: 4100},
				{IP: fmt.Sprintf("10.0.0.%d", i%256), Port: uint16(8000 + i)},
			})
		}
	}()

	// Let it run for a bit
	time.Sleep(50 * time.Millisecond)
	close(done)
	wg.Wait()
}
