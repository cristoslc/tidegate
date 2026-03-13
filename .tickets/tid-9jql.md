---
id: tid-9jql
status: closed
deps: [tid-yyyq]
links: []
created: 2026-03-13T05:13:22Z
type: task
priority: 2
assignee: cristos
parent: tid-jl64
tags: [spec:SPEC-001]
---
# Implement libkrun VM configuration

Configure libkrun: set CPU/memory, add virtio-net device, add virtiofs mount, set kernel cmdline with network params.


## Notes

**2026-03-13T05:17:39Z**

Implemented via krunkit wrapper in tidegate-vm.sh: --cpus, --memory, --virtiofs, --net virtio-net.
