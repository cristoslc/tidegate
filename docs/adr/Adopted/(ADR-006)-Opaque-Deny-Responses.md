---
artifact: ADR-006
title: "Opaque Deny Responses"
status: Adopted
author: cristos
created: 2026-03-12
last-updated: 2026-03-12
linked-epics: []
linked-specs: []
depends-on: []
---

# Opaque Deny Responses

## Context

When the gateway scanner detects sensitive data in a tool call, it blocks the call and returns a shaped deny response. The current implementation returns `isError: false` with a plain-text explanation including the pattern name and reason for the block.

SPIKE-003 identified this as an adversarial oracle: a prompt-injected agent receives structured feedback about what was detected and can iterate toward evasion. SPIKE-016 validated the risk with production evidence — RL-trained agents can efficiently map detection boundaries through exactly this kind of feedback, achieving 97% bypass rates against pattern-based defenses (IEEE 9720473).

The question is what information a deny response should contain.

## Decision

**Deny responses return only a generic instruction telling the agent not to include sensitive data. They contain no information about what was detected, what pattern matched, or what scanner layer triggered the block.**

A deny response looks like:

> Do not include sensitive data such as [category] in tool call parameters. Rephrase your request without the sensitive content.

Where `[category]` is a broad data class (e.g., "credit card numbers", "API keys", "personal identifiers") — never a pattern name, regex, field path, or layer identifier.

This is the same response regardless of whether L1 regex, L2 checksum validation, or L3 ML classification triggered the block.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| **Tiered disclosure** — full detail for cooperative agents, minimal for suspected adversarial ones | Requires distinguishing cooperative from adversarial agents, which is the hard problem. Any signal used for classification can itself be gamed. Adds complexity without clear benefit. |
| **Rate-based throttling** — reduce detail after repeated denials on the same path | Adds state tracking, threshold tuning, and false-positive risk. Doesn't solve the oracle on the first few attempts, which may be enough for an RL agent. |
| **Full diagnostic feedback** (current implementation) | Validated as an exploitable oracle by SPIKE-003 and SPIKE-016. |
| **Silent drop** — block with no response at all | Hostile to cooperative agents. A legitimate agent that accidentally included sensitive data needs to know what to do differently. |

## Consequences

**Positive:**
- Eliminates the shaped deny oracle entirely. No detection metadata leaks to the agent.
- Cooperative agents get actionable guidance — "don't include credit card numbers" is sufficient for self-correction.
- Simpler implementation than tiered disclosure or rate-based approaches.
- Multi-session persistence is harmless — stored denies contain only correct guidance, not evasion knowledge.

**Negative:**
- Debugging is harder for operators. When a legitimate tool call is blocked, the agent's response won't say which pattern matched. Operators must check the audit log (NDJSON structured logging in `audit.ts`) for detection details.
- Broad category names ("personal identifiers") may occasionally be too vague for a cooperative agent to understand exactly what to remove. Acceptable trade-off given the oracle risk.

**Neutral:**
- Audit logs retain full detection metadata (pattern, layer, field path) for operator visibility. The opacity applies only to the agent-facing response.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Adopted | 2026-03-12 | — | SPIKE-003 findings made the decision straightforward; skipped Draft/Proposed |
