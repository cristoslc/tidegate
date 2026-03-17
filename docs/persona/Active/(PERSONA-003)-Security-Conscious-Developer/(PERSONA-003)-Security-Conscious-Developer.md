---
artifact: PERSONA-003
title: "Security-Conscious Developer"
status: Active
author: cristos
created: 2026-02-21
last-updated: 2026-02-26
linked-journeys: []
linked-stories: []
depends-on: []
linked-artifacts:
  - VISION-001
---
# PERSONA-003: Security-Conscious Developer

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Draft | 2026-02-21 | db146de | Initial persona definition |
| Validated | 2026-02-26 | 35f707d | Migrated to spec-management format |

## Archetype

Evaluates Tidegate for adoption. Reads the threat model first, checks the Docker topology, looks for escape hatches. Won't adopt a tool that claims to be secure but has obvious bypasses.

## Goals and motivations

Honest threat model with real-world incidents. Clear documentation of what's protected and what isn't. No security theater.

## Frustrations and pain points

- Security claims without evidence
- Undocumented bypass paths
- Missing threat model or incomplete adversary coverage
- Tools that claim "secure" but fail open on component crashes

## Behavioral patterns

- Reads ADRs and inspects Dockerfiles before adopting
- Files issues for gaps they find
- Evaluates against known attack patterns
- Values transparency over marketing

## Context of use

Three hard boundaries (kernel, network, network). Honest scorecard showing what's blocked and what's accepted risk. Architecture that doesn't require trust in the agent container.

## Pain tolerance

High. Happy to read ADRs and inspect Dockerfiles. Will file issues for gaps they find.

## Related

- [VISION-001](../../../vision/Sunset/(VISION-001)-Secure-AI-Agent-Deployment/(VISION-001)-Secure-AI-Agent-Deployment.md)
- [Threat model](../../../threat-model/README.md)
