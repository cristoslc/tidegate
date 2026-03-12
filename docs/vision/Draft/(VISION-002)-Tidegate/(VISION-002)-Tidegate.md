---
title: "Tidegate"
artifact: VISION-002
status: Draft
product-type: personal
author: cristos
created: 2026-03-11
last-updated: 2026-03-11
depends-on: []
evidence-pool: ""
---

# VISION-002: Tidegate

## Target Audience

People who give their AI agent access to the most sensitive parts of their digital life — bank statements, medical records, tax documents, credentials, private conversations — and who install community skills without reading the source code first.

See [PERSONA-001](../../../persona/Validated/(PERSONA-001)-Personal-Assistant-Operator/(PERSONA-001)-Personal-Assistant-Operator.md) (Personal Assistant Operator), [PERSONA-002](../../../persona/Validated/(PERSONA-002)-Small-Team-Operator/(PERSONA-002)-Small-Team-Operator.md) (Small Team Operator), [PERSONA-003](../../../persona/Validated/(PERSONA-003)-Security-Conscious-Developer/(PERSONA-003)-Security-Conscious-Developer.md) (Security-Conscious Developer).

## Value Proposition

You should be able to hand your AI agent the keys to your digital life and trust that nothing leaks. Not through security theater or best-effort scanning, but because the system is physically structured so that no skill, no prompt injection, and no compromised tool can send your data somewhere it shouldn't go.

The agent does useful work. Tidegate makes sure it can't betray your trust.

## Problem Statement

Every AI agent framework gives the agent unrestricted access to everything. Install a community skill, and it can read your bank statements and post them to any API. A prompt injection in a document can instruct the agent to exfiltrate credentials through a tool call. There is no boundary between "the agent reads my sensitive files" and "the agent sends data to the outside world."

Existing frameworks sandbox *code execution* (bubblewrap, Landlock, Seatbelt) but not *data flow*. They prevent the agent from running `rm -rf /` but happily let it pipe your SSN through a Slack message. The sandboxing protects the host machine; nothing protects the operator's data.

## Existing Landscape

- **Agent frameworks** (Claude Code, Codex CLI, Aider, Goose) provide code-execution sandboxing and permission prompts. None inspect data flowing through tool calls or HTTP requests for sensitive content.
- **MCP gateways** (Docker MCP Gateway, Pipelock) route and filter tool calls but don't scan for sensitive data patterns in payloads.
- **Cloud sandboxes** (E2B, Daytona, microsandbox) provide isolated execution environments. They contain blast radius but don't inspect what leaves the sandbox.
- **DLP products** exist for enterprise email and cloud storage. None are designed for the MCP tool-call / agent-HTTP data paths.

Nothing addresses the specific problem: an AI agent that reads sensitive local files and calls external APIs through MCP, with no enforcement on what data crosses that boundary.

## Build vs. Buy

Tier 3 — build from scratch. The gap between "agent reads sensitive files" and "agent calls external APIs" is not addressed by any existing tool. The security boundary that Tidegate provides (scanning data at every exit point from the agent) does not exist as a product, a library, or a composable service.

The architecture is built from standard tools (Docker networks, MCP SDK, Python regex/checksums, Squid proxy) to keep maintenance feasible for a single person.

## Maintenance Budget

One person, part-time. This constrains everything downstream: the architecture must be simple enough to reason about solo, composed from standard tools, and debuggable without specialized infrastructure. If a component requires more than one person to maintain, it's scoped wrong.

## Success Metrics

1. An operator who doesn't read security papers can set up Tidegate and get meaningful protection
2. A malicious community skill cannot exfiltrate sensitive data through tool calls or HTTP — the operator's bank statements stay private
3. A security-conscious evaluator reads the threat model and finds it honest — accepted risks are documented, not hidden
4. The audit trail tells you exactly what happened after an incident
5. False positives are rare enough that operators don't disable the scanner

## Non-Goals

- **Sabotage prevention** — Tidegate prevents data *leaving*; it doesn't prevent the agent from deleting files or running destructive commands. Containerization and workspace backups handle that.
- **Semantic exfiltration** — If the LLM rephrases your bank balance as prose, no pattern scanner catches it. This is a fundamental limit of all scanning approaches. Documented as accepted risk, not claimed as blocked.
- **Multi-tenant hosting** — This is a single-operator deployment, not a shared platform.
- **Replacing agent frameworks** — Tidegate wraps your existing agent (Claude Code, Codex, Aider, Goose). It doesn't compete with them. You pick the brain; Tidegate provides the boundary.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Draft | 2026-03-11 | 7c0ac59 | Fresh start; aspirational framing, replaces VISION-001 |
