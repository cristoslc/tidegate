---
artifact: PERSONA-004
title: "Contributor"
status: Validated
author: cristos
created: 2026-02-21
last-updated: 2026-02-26
linked-journeys: []
linked-stories: []
depends-on: []
---

# PERSONA-004: Contributor

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Draft | 2026-02-21 | db146de | Initial persona definition |
| Validated | 2026-02-26 | 35f707d | Migrated to spec-management format |

## Archetype

Wants to add an MCP server configuration, improve scanning patterns, or extend the architecture. Needs to understand module boundaries and conventions without reading every file.

## Goals and motivations

Clear project instructions, logical directory structure, documented conventions. Knows where to put new code and how to test it.

## Frustrations and pain points

- Unclear module boundaries leading to accidental coupling
- Missing or outdated project instructions
- No "key files" guide for common tasks
- Having to read the entire codebase to make a small change

## Behavioral patterns

- Reads AGENTS.md and key files table first
- Tests changes in dev mode before Docker
- Follows existing conventions rather than inventing new ones
- Contributes scanning patterns, MCP server configs, or architecture improvements

## Context of use

AGENTS.md covers conventions and module boundaries. Key files table points to the right starting file. Dev mode runs without Docker.

## Pain tolerance

Moderate to high. Comfortable with TypeScript, Python, Docker. Expects well-documented module boundaries.

## Related

- [VISION-001](../../../vision/Active/(VISION-001)-Secure-AI-Agent-Deployment/(VISION-001)-Secure-AI-Agent-Deployment.md)
- [AGENTS.md](../../../../AGENTS.md)
