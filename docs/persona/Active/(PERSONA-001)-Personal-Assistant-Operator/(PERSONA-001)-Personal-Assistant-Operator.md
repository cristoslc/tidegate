---
artifact: PERSONA-001
title: "Personal Assistant Operator"
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
# PERSONA-001: Personal Assistant Operator

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Draft | 2026-02-21 | db146de | Initial persona definition |
| Validated | 2026-02-26 | 35f707d | Migrated to spec-management format |

**The primary persona.**

## Archetype

Individual who runs an AI agent as a daily assistant to process bank statements, tax documents, emails, medical records, and personal files. Installs skills from community marketplaces without careful vetting. Highest-risk, lowest-attention audience for malicious extensions.

## Goals and motivations

An agent that handles personal tasks — managing email, scheduling, filing documents, writing drafts — without worrying about data leakage or malicious skills.

## Frustrations and pain points

- A skill stealing their credentials
- A prompt injection exfiltrating their bank data through Slack
- Personal documents ending up on an attacker's server
- Security tools that block legitimate operations with false positives

## Behavioral patterns

- Installs skills without reading source code
- Processes highly sensitive personal data daily
- Will not debug configuration issues
- Disables security tools that produce false positives

## Context of use

Install Tidegate instead of installing an agent framework directly. Credentials stay in isolated containers. All tool calls are scanned. Malicious skills can't phone home.

## Pain tolerance

Zero. If setup takes more than `git clone && ./setup.sh`, they'll use the unprotected agent directly. If the scanner blocks legitimate tool calls with false positives, they'll disable it.

## Related

- [VISION-001](../../../vision/Sunset/(VISION-001)-Secure-AI-Agent-Deployment/(VISION-001)-Secure-AI-Agent-Deployment.md)
- For adversary profiles (who attacks Tidegate), see [threat-personas.md](../../../threat-model/threat-personas.md)
