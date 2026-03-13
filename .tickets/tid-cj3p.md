---
id: tid-cj3p
status: closed
deps: [tid-36kf]
links: []
created: 2026-03-13T05:13:40Z
type: task
priority: 2
assignee: cristos
parent: tid-49k5
tags: [spec:SPEC-003]
---
# Write test: eBPF tracepoints work in guest

Verify CONFIG_BPF=y, CONFIG_BPF_SYSCALL=y, CONFIG_BPF_JIT=y. Run a simple BPF program inside the guest.


## Notes

**2026-03-13T05:19:56Z**

Test written but deferred — requires custom kernel compilation. Config fragment has CONFIG_BPF=y/BPF_SYSCALL=y/BPF_JIT=y.
