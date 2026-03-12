---
artifact: SPIKE-001
title: "MCP Protocol Abuse Resistance"
status: Planned
author: cristos
created: 2026-02-21
last-updated: 2026-02-21
question: "How should the gateway handle malformed, oversized, or adversarial MCP messages?"
parent-vision: VISION-002
gate: Pre-MVP
risks-addressed: []
depends-on: []
---

# MCP Protocol Abuse Resistance

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-21 | db146de | Initial commit; gateway had basic JSON-RPC parsing but no hardening |

## Question

How should the gateway handle malformed, oversized, or adversarial MCP messages?

The gateway parses every MCP message — it's an attack surface. A compromised agent could send malformed JSON-RPC to crash or bypass the gateway. Oversized payloads could cause memory exhaustion.

## Sub-questions

1. **Message size limits**: What's a reasonable maximum message size for Streamable HTTP requests?
2. **JSON parsing safety**: TypeScript's `JSON.parse` handles most edge cases. Any concerns with deeply nested objects, duplicate keys?
3. **Rate limiting**: Should the gateway rate-limit tool calls from the agent?
4. **Malformed message handling**: Return JSON-RPC error? Log and drop?

## Why it matters

The gateway is the security boundary. If it can be crashed or confused by adversarial input, the entire model fails.

## Context at time of writing

The gateway (`src/gateway/src/router.ts`) accepts arbitrary JSON-RPC over Streamable HTTP. The MCP SDK does its own parsing, but the gateway adds no size limits, depth limits, or rate controls on top. The threat model assumes a compromised agent — so adversarial input to the gateway is a realistic scenario.
