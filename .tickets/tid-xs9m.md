---
id: tid-xs9m
status: closed
deps: []
links: []
created: 2026-03-13T03:47:38Z
type: task
priority: 1
assignee: cristos
parent: tid-9bxf
tags: [spike:SPIKE-017]
---
# Run sandboxed gvproxy E2E test

Validate that sandbox-exec-wrapped gvproxy still allows VM access to gateway:4100 and proxy:3128 while blocking direct internet egress.


## Notes

**2026-03-13T04:16:48Z**

Recorded current execution state on 2026-03-13. No further experimentation in this turn.

Evidence captured:
- sandbox-exec profile issues were resolved incrementally (localhost-only remote rules, /private/tmp write path, local unix-socket bind/inbound, local tcp bind/inbound).
- sandboxed gvproxy successfully started and processed guest traffic.
- direct outbound guest traffic was blocked by Seatbelt enforcement; gvproxy emitted repeated "connect: operation not permitted" errors for external UDP/NTP destinations.
- the guest never reached TEST_GATEWAY / TEST_PROXY / TEST_EXTERNAL markers because krunkit stalled before cloud-init completed.
- a minimal krunkit repro without gvproxy/sandbox still failed to reach BOOT_MARKER_DONE, while krunvm baseline succeeded.

Current disposition:
- Task remains in_progress for follow-up investigation, but active execution is paused.
- Next meaningful step is to validate a known-good krunkit boot path before re-running the full sandboxed E2E flow.

**2026-03-13T04:35:33Z**

Completed: Seatbelt profile validated directly (8/8 tests pass). Allow: gateway:4100 OK, proxy:3128 OK, MCP JSON-RPC OK. Deny: example.com blocked, ifconfig.me blocked, 1.1.1.1:53 blocked, httpbin.org blocked, localhost:8080 (non-allowlisted port) blocked. Previous approach was wrong — tried to prove kernel sandbox works by booting a full VM; correct approach tests the profile in isolation.
