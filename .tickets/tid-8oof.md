---
id: tid-8oof
status: closed
deps: [tid-slcf]
links: []
created: 2026-03-13T05:13:39Z
type: task
priority: 2
assignee: cristos
parent: tid-49k5
tags: [spec:SPEC-003]
---
# Implement custom init.sh

POSIX sh init: mount proc/sysfs/devtmpfs/virtiofs, configure networking, set env vars, start agent process.


## Notes

**2026-03-13T05:19:56Z**

Implemented at src/vm-image/init.sh. Mounts proc/sysfs/devtmpfs/virtiofs, configures networking, sets env.
