---
id: tid-slcf
status: closed
deps: [tid-nkxq]
links: []
created: 2026-03-13T05:13:39Z
type: task
priority: 2
assignee: cristos
parent: tid-49k5
tags: [spec:SPEC-003]
---
# Implement Alpine rootfs Dockerfile

Multi-stage Dockerfile: Alpine base + Node.js + Python + git. Produces rootfs tarball. Target <200MB compressed.


## Notes

**2026-03-13T05:19:56Z**

Implemented at src/vm-image/Dockerfile. Alpine 3.21 base, 53MB image. Node.js + Python + git.
