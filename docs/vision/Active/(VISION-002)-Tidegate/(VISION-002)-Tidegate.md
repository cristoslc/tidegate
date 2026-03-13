---
title: "Tidegate"
artifact: VISION-002
status: Active
product-type: personal
author: cristos
created: 2026-03-11
last-updated: 2026-03-13
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

AI agents read your most sensitive files and call external APIs in the same breath. A community skill can read your bank statements and post them to any endpoint. A prompt injection in a document can instruct the agent to exfiltrate credentials through a tool call.

Agent frameworks sandbox *code execution* (bubblewrap, Landlock, Seatbelt) but not *data flow*. MCP gateways scan *tool call payloads* but can't stop the agent from bypassing MCP entirely — `curl`, cron jobs, IPC, or encoding data in the LLM API request. Each layer covers one exit; nothing covers them all. A determined or compromised agent routes around whichever single layer is present.

## Existing Landscape

- **Agent frameworks** (Claude Code, Codex CLI, Aider, Goose) provide code-execution sandboxing and permission prompts. None enforce data-flow boundaries — a sandboxed agent can still pipe your SSN through a tool call.
- **MCP gateways with payload scanning** — The landscape has matured rapidly. Docker MCP Gateway (`--block-secrets`), Pipelock (36 DLP patterns), Lasso Security (PII masking via Presidio), Pangea (50+ PII types with format-preserving encryption), Enkrypt AI, Operant AI, MintMCP, and others all scan MCP tool call payloads for credentials and PII. Most are SaaS or enterprise products. Pipelock and Docker MCP Gateway are self-hostable.
- **MCP governance tools** — Snyk agent-scan (formerly Invariant mcp-scan), Promptfoo, MCP Manager, and Trail of Bits mcp-context-protector focus on tool poisoning, prompt injection, and access control. Some include PII detection as a secondary feature.
- **AI gateway DLP** — Cloudflare AI Gateway, Lakera Guard, and Nightfall AI provide DLP for LLM interactions. Not MCP-specific but converging toward agent-aware scanning.
- **Cloud sandboxes** (E2B, Daytona, microsandbox) provide isolated execution environments. They contain blast radius but don't inspect what leaves the sandbox.

The gap is not "nobody scans MCP payloads" — many tools now do. The gap is that scanning alone is insufficient without *structural enforcement*. An MCP gateway that scans tool calls doesn't help when the agent bypasses MCP entirely — shelling out to `curl`, writing to a cron job, encoding data in the LLM API request, or exfiltrating through IPC. No existing tool combines payload scanning with network-level enforcement that makes bypass structurally impossible.

## Build vs. Buy

Tier 2 — glue-code existing tools. The individual components exist: Docker MCP Gateway or Pipelock for MCP scanning, Squid for egress proxying, Docker networks for isolation. What doesn't exist is the *composition* — a turnkey, self-hosted package that wires these layers together so that every data path from the agent is covered, credential isolation is structural, and bypass requires a container escape rather than a `curl` command.

Tidegate's custom code is the gateway scanning pipeline and the glue that makes the topology work as a unit. The architecture is built from standard tools (Docker networks, MCP SDK, Python regex/checksums, Squid proxy) to keep maintenance feasible for one person. If a single existing product covers the full topology in the future, the right move is to adopt it and sunset Tidegate.

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
| Active | 2026-03-13 | _pending_ | Value proposition and scope confirmed |
