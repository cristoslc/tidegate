---
id: tid-zcc4
status: closed
deps: [tid-z85k]
links: []
created: 2026-03-13T05:13:00Z
type: task
priority: 2
assignee: cristos
parent: tid-jbo8
tags: [spec:SPEC-002]
---
# Implement gvproxy-egress.sb Seatbelt profile

Create src/vm-launcher/gvproxy-egress.sb based on SPIKE-017 validated profile. Allow gateway:4100, proxy:3128, unix sockets. Deny everything else.


## Notes

**2026-03-13T05:15:03Z**

Implemented gvproxy-egress.sb at src/vm-launcher/gvproxy-egress.sb. 8/8 test cases pass.
