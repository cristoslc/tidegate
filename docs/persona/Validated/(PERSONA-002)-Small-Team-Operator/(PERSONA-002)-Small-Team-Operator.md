---
title: "PERSONA-002: Small Team Operator"
status: Validated
author: cristos
created: 2026-02-21
last_updated: 2026-02-26
related_journeys: []
related_stories: []
---

# PERSONA-002: Small Team Operator

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Draft | 2026-02-21 | db146de | Initial persona definition |
| Validated | 2026-02-26 | 35f707d | Migrated to spec-management format |

## Archetype

Runs an AI agent for a team — shared Slack workspace, GitHub org, internal tools. Multiple people's data flows through the agent. The blast radius of a compromised skill is organizational, not personal.

## Goals and motivations

The same personal assistant capabilities as [PERSONA-001](../(PERSONA-001)-Personal-Assistant-Operator/(PERSONA-001)-Personal-Assistant-Operator.md), but with team-scoped credentials and audit trails. Needs to demonstrate to the team that the agent won't leak internal data.

## Frustrations and pain points

- Inability to prove to teammates that agent access is safe
- Shared credentials with unclear blast radius
- No audit trail for post-incident analysis
- Compliance requirements for data handling

## Behavioral patterns

- Willing to invest time in configuration
- Reads documentation before deploying
- Needs to justify tool adoption to others
- Evaluates audit and compliance features

## Context of use

Audit log records every tool call. Credential isolation means a compromised skill only gets the API keys it needs. Network topology prevents lateral movement.

## Pain tolerance

Moderate. Willing to edit YAML configs and manage Docker. Needs clear documentation.

## Related

- [VISION-001](../../../vision/Active/(VISION-001)-Secure-AI-Agent-Deployment/(VISION-001)-Secure-AI-Agent-Deployment.md)
- [PERSONA-001](../(PERSONA-001)-Personal-Assistant-Operator/(PERSONA-001)-Personal-Assistant-Operator.md)
