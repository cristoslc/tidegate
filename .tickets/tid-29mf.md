---
id: tid-29mf
status: closed
deps: [tid-9jql]
links: []
created: 2026-03-13T05:13:22Z
type: task
priority: 2
assignee: cristos
parent: tid-jl64
tags: [spec:SPEC-001]
---
# Implement /etc/hosts and env injection

Inject gateway/proxy addresses into guest /etc/hosts and set HTTP_PROXY, HTTPS_PROXY, TIDEGATE_GATEWAY env vars.


## Notes

**2026-03-13T05:17:39Z**

Implemented in tidegate-vm.sh start_vm(): injects /etc/hosts entries and sets HTTP_PROXY, HTTPS_PROXY, TIDEGATE_GATEWAY.
