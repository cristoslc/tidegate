---
id: tid-36kf
status: open
deps: [tid-8oof]
links: []
created: 2026-03-13T05:13:40Z
type: task
priority: 2
assignee: Cristos L-C
parent: tid-49k5
tags: [spec:SPEC-003]
---
# Implement minimal kernel config

Strip Alpine kernel config: keep eBPF, virtio drivers, ext4, tmpfs, networking. Remove USB, audio, GPU, Bluetooth, wireless. Target ~10-15MB compressed.

