---
artifact: ADR-007
title: "Human-in-the-Loop Exception Approval"
status: Accepted
author: cristos
created: 2026-03-12
last-updated: 2026-03-14
linked-epics: []
linked-specs: []
depends-on:
  - ADR-006
trove: ""
affected-artifacts:
  - ADR-006
  - SPIKE-001
---
# Human-in-the-Loop Exception Approval

## Context

SPIKE-001 established four hardening layers for MCP protocol abuse resistance: HTTP body size cap (1MB), JSON nesting depth limit (64 levels), token bucket rate limiter (60 calls/min), and standard JSON-RPC error responses. ADR-006 established that deny responses are opaque — the agent learns nothing about what triggered the block.

These limits are fail-closed by design. But legitimate operations will exceed them:

- **File uploads/management**: An agent writing a large file via MCP tool call, or reading a multi-megabyte response, exceeds the 1MB body cap.
- **Bulk operations**: Batch tool calls during a migration or refactor can exceed the rate limit.
- **Complex structured data**: Deeply nested JSON (GraphQL responses, AST representations) can exceed the 64-level depth limit.

The operator knows these operations are legitimate but isn't always at a workstation. They might be monitoring from their phone, in a meeting, or on the go. The exception mechanism must work via messaging — push notification, SMS, chat — not just a web dashboard.

### The trust problem

The gateway enforces policy on behalf of the operator against a potentially compromised agent. An exception mechanism creates a channel where the agent can request the operator to weaken enforcement. This is the right design — the operator is the authority — but it introduces risks:

1. **Approval fatigue**: Too many exception requests train the operator to approve reflexively.
2. **Social engineering**: A compromised agent could craft exception requests that look legitimate ("I need to upload the quarterly report" when it's actually exfiltrating data).
3. **Channel compromise**: If the messaging channel is compromised, an attacker can approve their own exceptions.
4. **Timing attacks**: Request exceptions at 2 AM when the operator is likely to approve without reading.

### What other systems do

- **sudo**: Synchronous, local, time-scoped (5-15 min timeout). No remote approval.
- **AWS IAM permission boundaries**: Pre-configured, no runtime approval. Requires anticipating all legitimate operations.
- **Teleport Access Requests**: Async approval via Slack/PagerDuty. Time-boxed. Requires justification. Dual approval optional.
- **StrongDM / Opal**: Request-approve-audit loop with Slack integration. Session-scoped or time-boxed.
- **Mobile banking transaction approval**: Push notification with transaction details, approve/deny with biometric confirmation.

The common pattern: request with context, approve with authentication, time-box the grant, audit everything.

## Decision

**The gateway supports a human-in-the-loop exception approval flow where the agent's blocked request triggers a notification to the operator, who approves or denies via a messaging-friendly interface. Exceptions are scoped, time-boxed, and audited.**

### The flow

```
Agent → tool call exceeds limit
  → Gateway blocks, generates exception request
  → Gateway sends notification to operator (push/SMS/webhook)
  → Operator sees: what tool, what limit exceeded, request context
  → Operator approves (with optional scope adjustment) or denies
  → Gateway caches approval grant
  → Agent retries → Gateway checks grant → allows (if valid)
```

### Exception request format

The gateway generates a request containing:

| Field | Content | Purpose |
|-------|---------|---------|
| `request_id` | UUID | Correlation |
| `tool_name` | e.g., `write_file` | What operation |
| `limit_exceeded` | e.g., `body_size` | Which limit |
| `requested_value` | e.g., `3.2MB` | How far over |
| `context` | Agent's last message summary | Why (from agent's perspective) |
| `timestamp` | ISO 8601 | When |

**No sensitive data in the notification.** The notification says "write_file wants to send 3.2MB (limit: 1MB)" — it does not include the payload content. This is consistent with ADR-006's opacity principle: the agent doesn't learn what was detected, and the notification channel doesn't carry sensitive data.

### Grant format

An approval creates a grant:

```yaml
grant_id: uuid
request_id: uuid         # what was approved
scope:
  tool: "write_file"     # or "*" for any tool (discouraged)
  limit: "body_size"     # which limit is relaxed
  ceiling: "10MB"        # new limit (not unlimited)
expiry:
  type: "single_use"     # or "ttl" or "session"
  ttl: "15m"             # for ttl type
approved_by: "operator"  # identity
approved_at: "2026-03-12T14:30:00Z"
approved_via: "push_notification"  # channel
```

### Scope types

| Scope | Use case | Risk |
|-------|----------|------|
| **Single-use** | One specific operation that needs an exception | Lowest — grant consumed immediately |
| **TTL** (default: 15 min) | Short burst of operations (batch migration) | Medium — window of relaxed enforcement |
| **Session** | Entire agent session needs elevated limits | Highest — effectively disables the limit for the session |

Default is single-use. TTL and session require explicit operator selection. The notification UI should make single-use the easy path (one-tap approve) and TTL/session require an additional step.

### Approval channels

The gateway doesn't implement messaging directly. It emits a webhook event that an operator-configured integration delivers:

```yaml
# tidegate.yaml
exceptions:
  enabled: true
  webhook_url: "https://hooks.example.com/tidegate"
  approval_url: "https://tidegate.local/approve"  # callback
  timeout: 300  # seconds to wait for approval
  default_on_timeout: "deny"
  channels:
    - type: webhook  # generic webhook → Slack, Discord, ntfy, etc.
```

The webhook carries the exception request. The approval callback receives the grant. The operator's messaging platform (Slack bot, iOS shortcut, ntfy push, custom app) bridges the two.

This keeps the gateway channel-agnostic. Mobile-friendly approval is an integration concern, not a gateway concern.

### Synchronous vs. asynchronous

**The gateway blocks the agent's request while waiting for approval, up to a configurable timeout (default: 5 minutes).**

Why synchronous (blocking):
- The agent doesn't need special retry logic — the request either succeeds (after approval) or fails (timeout/deny).
- The operator sees the request in real time and knows the agent is waiting.
- No state management for pending approvals across requests.

Why not fully async:
- Async requires the agent to understand "your request is pending, retry later" — a new response type that every agent framework would need to handle.
- The agent might do something else in the meantime that changes the context.
- Tracking pending approvals across multiple requests adds complexity.

The timeout ensures the agent isn't blocked indefinitely. On timeout: deny (fail-closed).

### Fail-closed guarantees

| Scenario | Behavior |
|----------|----------|
| Webhook delivery fails | Deny (operator never saw the request) |
| Approval callback unreachable | Deny (can't receive the grant) |
| Timeout expires | Deny |
| Grant is malformed or unsigned | Deny |
| Channel is compromised (forged approval) | Mitigated by HMAC signature on grants |

No exception path leads to an unauthenticated allow.

### Grant authentication

Grants are HMAC-signed with a shared secret between the gateway and approval endpoint. The gateway validates the signature before accepting any grant. This prevents a compromised messaging channel from forging approvals.

For higher-security deployments, grants can require TOTP confirmation — the operator enters a code from their authenticator app in addition to tapping "approve."

### Rate limiting exception requests

To prevent approval fatigue attacks:
- Maximum 5 exception requests per 10-minute window per session.
- After the limit, subsequent requests are denied without notifying the operator (the agent receives a generic "request denied" — consistent with ADR-006 opacity).
- The operator sees a single summary: "Agent requested 12 exceptions in the last 10 minutes. All denied after the 5th."

### Audit trail

Every exception event is logged to the NDJSON audit trail:

- `exception.requested` — request details, limit exceeded, context
- `exception.approved` — grant details, who approved, via what channel
- `exception.denied` — explicit denial or timeout
- `exception.used` — grant was consumed (for single-use) or invoked (for TTL/session)
- `exception.expired` — grant expired without use or TTL elapsed

## Alternatives Considered

### Pre-configured allowlists only (no runtime approval)

Operator pre-configures exceptions in `tidegate.yaml`: "tool X is allowed up to 10MB."

**Rejected as sole mechanism because**: Requires anticipating all legitimate exceptions in advance. A new MCP tool or unexpected large response would be blocked with no recourse until the operator edits the config and restarts. Unacceptable for an agent that's supposed to operate with autonomy.

**Retained as complement**: Static allowlists are useful for known patterns (e.g., "file management tools always need >1MB"). They reduce notification noise. Runtime approval handles the unexpected cases.

### Automatic escalation tiers (no human approval)

Gateway auto-relaxes limits for requests that match known-safe patterns (e.g., file write tools always get 10MB).

**Rejected because**: "Known-safe" patterns are exactly what a compromised agent would target. The point of the limit is to create a checkpoint that requires human judgment. Auto-escalation removes the human from the loop.

### Fully asynchronous approval (agent gets "pending" and retries later)

Gateway returns immediately with "pending approval" status. Agent retries periodically.

**Rejected because**: Adds a new response type that agent frameworks don't handle. The retry loop adds complexity. The agent's context may change between request and retry, making the approval stale. Synchronous blocking with timeout is simpler and sufficient.

### Blanket session exceptions (approve once, allow all)

First exception request triggers approval. Once approved, all limits are relaxed for the session.

**Rejected because**: Effectively disables enforcement for the session. A compromised agent only needs one legitimate-looking request to get a blanket pass. Per-request or narrowly-scoped approval is safer.

## Consequences

### Positive

- Operators can approve legitimate exceptions without being at a workstation — push notification, one-tap approve, done.
- Fail-closed by default: every failure mode results in denial.
- Scoped and time-boxed: exceptions are as narrow as possible.
- Consistent with ADR-006: notifications carry operational metadata, not sensitive data.
- Gateway stays channel-agnostic: webhook out, callback in. Mobile-friendly is an integration concern.
- Approval fatigue is bounded by rate limiting exception requests.

### Negative

- Adds latency: blocked requests wait up to 5 minutes for approval. Acceptable for exceptional operations, but the agent is stalled during this time.
- Requires operator availability: if the operator is unreachable, the agent can't proceed with operations that exceed limits. This is the intended behavior (fail-closed) but can frustrate users.
- Webhook + callback infrastructure: operator needs to set up a messaging integration. This is non-trivial for personal users (though a simple ntfy or Slack webhook is minimal).
- HMAC key management: shared secret between gateway and approval endpoint. Key rotation, secure storage.

### Open questions

1. **UX for the operator notification**: What's the minimum context needed to make an informed approval decision without leaking sensitive data? "write_file wants 3.2MB" — is that enough?
2. **Multi-operator approval**: For team deployments, should exceptions require dual approval? Different trust levels for different operators?
3. **Retrospective exceptions**: Can the operator approve a class of exceptions after the fact? ("All write_file calls over 1MB are fine for this project.") This would create a static allowlist entry, reducing future notifications.
4. **Agent-side UX**: What does the agent see while blocked? A spinner? A message? Should the agent be told "waiting for operator approval" (leaks that an exception mechanism exists) or just "request in progress"?

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Draft | 2026-03-12 | 01eb2ac | Motivated by SPIKE-001 exception needs; depends on ADR-006 opacity |
| Accepted | 2026-03-14 | 9c9f201 | Decision accepted by operator |
