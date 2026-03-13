---
id: tid-z85k
status: closed
deps: []
links: []
created: 2026-03-13T05:13:00Z
type: task
priority: 2
assignee: cristos
parent: tid-jbo8
tags: [spec:SPEC-002]
---
# Write test: Seatbelt profile blocks external hosts

Test that sandbox-exec blocks TCP to example.com:80, ifconfig.me:443, 1.1.1.1:53. Also test non-allowlisted localhost port (8080).


## Notes

**2026-03-13T05:15:03Z**

PASS: 6 blocked cases verified — example.com, ifconfig.me, 1.1.1.1:53, httpbin.org, localhost:8080, 1.1.1.1:443
