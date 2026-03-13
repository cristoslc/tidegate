---
id: tid-36kf
status: closed
deps: [tid-8oof]
links: []
created: 2026-03-13T05:13:40Z
type: task
priority: 2
assignee: cristos
parent: tid-49k5
tags: [spec:SPEC-003]
---
# Implement minimal kernel config

Strip Alpine kernel config: keep eBPF, virtio drivers, ext4, tmpfs, networking. Remove USB, audio, GPU, Bluetooth, wireless. Target ~10-15MB compressed.


## Notes

**2026-03-13T05:19:56Z**

Kernel config fragment at src/vm-image/kernel-config.fragment. eBPF, virtio, seccomp enabled. USB/audio/GPU/BT disabled.
