---
id: tid-yyyq
status: closed
deps: [tid-ca33]
links: []
created: 2026-03-13T05:13:22Z
type: task
priority: 2
assignee: cristos
parent: tid-jl64
tags: [spec:SPEC-001]
---
# Implement gvproxy lifecycle manager

Start/stop gvproxy as a subprocess. Configure virtio-net socket. Handle cleanup on exit.


## Notes

**2026-03-13T05:17:39Z**

Implemented in tidegate-vm.sh: starts gvproxy under sandbox-exec, PID tracking, cleanup on exit.
