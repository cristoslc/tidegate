---
title: "Tidegate is a Reference Architecture"
artifact: VISION-000
status: Active
product-type: reference-architecture
author: cristos
created: 2026-03-16
last-updated: 2026-03-16
depends-on: []
linked-artifacts:
  - VISION-002
---
# VISION-000: Tidegate is a Reference Architecture

## Statement

Tidegate is a reference architecture for data-flow enforcement in AI agent deployments. It maps the topology, enforcement layers, and threat model required to prevent an AI agent from exfiltrating sensitive data. It is not a product, not a framework, and not a deployable system.

Any code in this repository is exploratory -- proof-of-concept work that tests architectural assumptions. It is not packaged, not versioned for release, and not intended to be deployed as-is.

## Why this matters

Reference architectures are valuable precisely because they separate the design from the implementation. The enforcement topology Tidegate defines (VM isolation + egress allowlisting + MCP scanning + taint-and-verify) can be implemented with different tools, on different platforms, at different scales. Locking the architecture to a specific implementation would limit its usefulness.

If a deployable product emerges from this work, it will live in a separate repository and reference this architecture.

## Implications

- **Documentation is the primary artifact.** Visions, epics, specs, ADRs, spikes, personas, journeys, and the threat model are the work product.
- **Code is exploratory.** Scripts and prototypes test specific architectural assumptions. They are not production code.
- **No release packaging.** No versioned releases, no install instructions, no deployment guides.
- **The architecture is tool-agnostic.** Specific tools (libkrun, gvproxy, Docker, Squid) appear in specs as reference implementations, not requirements.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-03-16 | pending | Established project identity |
