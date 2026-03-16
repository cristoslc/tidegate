---
title: "Secure AI Agent Deployment Platform"
artifact: VISION-001
status: Sunset
author: cristos
created: 2026-02-21
last-updated: 2026-03-11
depends-on: []
linked-artifacts:
  - ADR-002
  - PERSONA-001
  - PERSONA-004
  - VISION-002
---
# VISION-001: Secure AI Agent Deployment Platform

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Draft | 2026-02-21 | db146de | Initial gateway + threat model |
| Active | 2026-02-23 | 94efd00 | M1 complete, architecture validated |
| Sunset | 2026-03-11 | 30fbbc9 | Superseded by VISION-002; too technical, drifted from aspirational intent |

## Target audience

Personal assistant operators, small teams, and security-conscious developers who run AI agents with access to sensitive data (bank statements, credentials, medical records, internal tools) and install community skills without careful vetting. See [PERSONA-001](../../../persona/Validated/(PERSONA-001)-Personal-Assistant-Operator/(PERSONA-001)-Personal-Assistant-Operator.md) through [PERSONA-004](../../../persona/Validated/(PERSONA-004)-Contributor/(PERSONA-004)-Contributor.md).

## Value proposition

Run `git clone && ./setup.sh` and get an AI agent deployment where:

- **All MCP tool calls** are scanned for sensitive data (credentials, credit cards, SSNs) before reaching external APIs
- **Credentials** live in isolated MCP server containers, never in the agent container
- **Network egress** is blocked or proxied — a compromised skill can't phone home
- **Audit trail** records every tool call with verdict, layer, and reason

The operator gets the full power of an AI agent without trusting every skill it installs.

## Success metrics

1. `./setup.sh` on a Mac with Docker Desktop produces a working system in under 5 minutes
2. Agent can call real MCP tools (Slack, GitHub, Gmail) through the scanned gateway
3. Credential patterns in tool calls are blocked with shaped denies the agent can understand
4. Zero credentials accessible from the agent container
5. Audit log captures every tool call for post-incident analysis

## Non-goals

- **Sabotage prevention**: Destructive commands are handled by containerization + mounted workspace backups, not command validation
- **Semantic exfiltration**: Data rephrased by the LLM to avoid pattern matching is a fundamental limit of all scanning approaches — documented as accepted risk, not claimed as blocked
- **Multi-tenant hosting**: This is a single-operator deployment, not a shared platform
- **Agent framework development**: Tidegate wraps existing frameworks (NanoClaw, Claude Code), it doesn't build one

## Architecture summary

See [system-architecture.md](system-architecture.md) for the system architecture. See [target-state.md](target-state.md) for the `./setup.sh` end goal.

The security model has three enforcement layers:
- **L2/L3 (MCP gateway)**: Scans all string values in tool call parameters and responses. Credential patterns, checksums, entropy analysis.
- **L1 (kernel-level taint tracking)**: eBPF observes file access, scanner daemon tracks taint, seccomp-notify blocks tainted processes from network access. Not yet built — see [ADR-002](../../../adr/Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md).
- **Network isolation**: Three Docker networks. Agent can only reach gateway and egress proxy. MCP servers hold credentials on an internal network.

## Related

- [ADR-002](../../../adr/Accepted/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) — L1 taint architecture
