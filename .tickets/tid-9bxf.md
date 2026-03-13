---
id: tid-9bxf
status: closed
deps: []
links: []
created: 2026-03-13T03:47:38Z
type: epic
priority: 2
assignee: Cristos L-C
external-ref: SPIKE-017
---
# SPIKE-017 enforcement validation

Tracked work for the sandbox-exec + gvproxy + krunkit end-to-end validation in SPIKE-017.


## Notes

**2026-03-13T04:16:48Z**

Current state as of 2026-03-13:

- Partial validation succeeded: sandbox-exec-wrapped gvproxy started successfully once the Seatbelt profile allowed real temp-path writes (/private/tmp), local unix-socket bind/inbound, and local tcp bind/inbound.
- Enforcement behavior was observed directly: gvproxy logged repeated denied outbound guest UDP/NTP attempts (for example to 104.207.148.118:123, 45.33.53.84:123, 216.82.35.115:123, 52.180.152.22:123) with "connect: operation not permitted". This confirms kernel-enforced outbound blocking is active.
- End-to-end completion is still blocked by the VM boot path, not by the Seatbelt policy. The full sandboxed run ended RESULT=INCOMPLETE because the guest never reached the scripted health checks.
- Reduced repro outside the sandbox harness showed the same issue: krunkit with the Alpine cloud qcow2 plus NoCloud seed did not reach cloud-init or guest markers.
- Baseline separation was confirmed: krunvm works on this machine (krunvm start returned KRUNVM_BASELINE_OK), so the current blocker is specific to the krunkit boot/image path.
- Additional finding: krunkit's --bootloader flag parses but did not create an EFI variable-store file during testing, so it did not resolve the boot stall.

Work is paused here pending a different krunkit bootable image or launch sequence.

**2026-03-13T04:35:43Z**

Completed: Seatbelt profile enforcement fully validated. Focused experiment proved allow/deny selectivity in isolation (8/8 tests, 0 failures). Combined with prior evidence of sandboxed gvproxy blocking guest outbound UDP, criterion 4 is confirmed GO. The krunkit boot stall was an orthogonal issue — not a sandbox problem.
