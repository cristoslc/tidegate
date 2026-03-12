---
artifact: SPIKE-001
title: "MCP Protocol Abuse Resistance"
status: Complete
author: cristos
created: 2026-02-21
last-updated: 2026-03-12
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
| Active | 2026-03-12 | cc37c4b | Research in progress |

## Question

How should the gateway handle malformed, oversized, or adversarial MCP messages?

The gateway parses every MCP message — it's an attack surface. A compromised agent could send malformed JSON-RPC to crash or bypass the gateway. Oversized payloads could cause memory exhaustion.

## Sub-questions

1. **Message size limits**: What's a reasonable maximum message size for Streamable HTTP requests?
2. **JSON parsing safety**: TypeScript's `JSON.parse` handles most edge cases. Any concerns with deeply nested objects, duplicate keys?
3. **Rate limiting**: Should the gateway rate-limit tool calls from the agent?
4. **Malformed message handling**: Return JSON-RPC error? Log and drop?

## Findings

The MCP specification (2025-11-25) defines no message size limits, depth constraints, or rate limiting requirements at the protocol level. These are left to implementations. The MCP TypeScript SDK's `StreamableHTTPServerTransport` relies on Express's `express.json()` middleware for body parsing, which defaults to 100KB — a limit that is both too small for legitimate large tool responses and simultaneously provides no protection against the specific attacks that matter for a security gateway. The gateway must layer its own defenses on top of both the MCP SDK and the HTTP framework.

**Verdict:** The gateway needs four hardening layers applied before the MCP SDK processes any message: HTTP body size cap, JSON nesting depth limit, malformed message rejection with standard JSON-RPC errors, and tool-call rate limiting. All four are implementable with minimal code and no architectural changes. Fail-closed on every error path.

### Sub-question dispositions

| Sub-question | Answer |
|---|---|
| Message size limits | 1MB hard cap at the HTTP layer, configurable in `tidegate.yaml`. The MCP spec is silent on limits; the SDK defaults to 100KB but this is configurable. 1MB accommodates large tool responses while preventing memory exhaustion. Reject with HTTP 413 before JSON parsing begins. |
| JSON parsing safety | `JSON.parse` is safe against prototype pollution (produces plain objects, `__proto__` becomes a data property) and handles duplicate keys predictably (last value wins, per ES5 spec). The real risk is deeply nested objects causing V8 stack overflow — enforce a depth limit of 64 levels via a pre-parse validation pass. |
| Rate limiting | Yes — token bucket, per-session. A compromised agent probing scanner boundaries (SPIKE-003) generates high request volume. 60 tool calls per minute default, configurable. Return JSON-RPC server error (-32001) when exceeded. |
| Malformed message handling | Return standard JSON-RPC error responses: -32700 (Parse error) for invalid JSON, -32600 (Invalid Request) for structurally valid JSON that violates JSON-RPC 2.0, -32602 (Invalid params) for schema violations. Log every rejection to the audit trail. Never drop silently — the agent must receive an error to avoid hanging. |

### Research details

#### 1. Message size limits

**MCP specification position**: The MCP specification (2025-11-25) does not define message size limits. It delegates to transport implementations. The spec's security section focuses on consent, data privacy, and tool safety — not protocol-level abuse resistance.

**SDK behavior**: The MCP TypeScript SDK's `createMcpExpressApp()` uses `express.json()` with its default 100KB limit. GitHub issue #1354 on the SDK repo documents that this limit is too restrictive for some workloads and proposes making it configurable. The `StreamableHTTPServerTransport` itself does not add any size checking beyond what Express provides.

**Recommended limit**: 1MB. Rationale:

- JSON-RPC best practices recommend approximately 1MB as a payload size cap for batch requests. Individual MCP tool calls should be well under this.
- The MCP SDK's 100KB default causes legitimate failures for servers returning large resource content (Claude Desktop enforces a similar cap but at 1MB for resources).
- 1MB is large enough for any reasonable tool call parameter set but small enough to prevent a single request from consuming significant memory. A burst of 100 concurrent 1MB requests = 100MB — manageable.
- The limit should be enforced at the HTTP layer (Express middleware) before JSON parsing begins. This means oversized payloads are rejected with HTTP 413 without allocating memory for parsing.

**Configuration**: Expose as `maxRequestBodyBytes` in `tidegate.yaml`. Default: 1048576 (1MB).

#### 2. JSON parsing safety

**Prototype pollution**: `JSON.parse()` is safe. Unlike recursive merge functions (lodash `_.merge`, `deep-extend`), `JSON.parse` produces plain JavaScript objects with `Object.prototype` as their prototype. Even if the input contains `"__proto__"` as a key, this creates a regular data property — it does not modify the prototype chain. The gateway should never pass parsed JSON through a recursive merge function; if it does, that merge function (not `JSON.parse`) becomes the attack surface.

**Duplicate keys**: `JSON.parse` follows the ES5 specification: last value wins. This is predictable and not exploitable unless the gateway makes decisions based on early-appearing values that are later overwritten. Since the gateway processes the fully parsed result, last-value-wins semantics are safe. No additional handling needed.

**Deeply nested objects**: This is the real risk. V8's `JSON.parse` uses recursive descent internally. A JSON object nested ~10,000 levels deep can cause a stack overflow, crashing the Node.js process. Historical CVEs confirm this: V8 memory corruption from deep JSON parsing was fixed in Node 0.8.28/0.10.30, and similar depth-related CVEs continue to appear in serialization libraries (e.g., CVE-2026-24006 in `seroval`).

**Mitigation**: Validate nesting depth before or during parsing. Two approaches:

1. **Pre-parse scan**: Walk the raw JSON string, counting `{` and `[` minus `}` and `]` to track depth. Reject if depth exceeds the limit before calling `JSON.parse`. Cost: O(n) string scan, but avoids any risk of crash.
2. **Reviver function**: Use `JSON.parse(text, reviver)` where the reviver tracks depth. Less reliable — the reviver runs after internal parsing, so the stack overflow may already have occurred.

Recommended: pre-parse scan. Limit: 64 levels. No legitimate MCP tool call requires nesting beyond ~10 levels. 64 provides ample margin while staying well below the ~10,000 level crash threshold.

**Configuration**: Expose as `maxJsonDepth` in `tidegate.yaml`. Default: 64.

#### 3. Rate limiting

**Threat model context**: The gateway's threat model assumes a compromised agent. A compromised agent has two motivations for high request volume:

1. **Scanner probing**: Sending many variations of a tool call to map detection boundaries (the shaped-deny oracle from SPIKE-003). ADR-006 mitigates the information leakage, but rate limiting reduces the iteration speed.
2. **Resource exhaustion**: Flooding the gateway or downstream servers with requests to cause denial of service.

**Recommended algorithm**: Token bucket, per session. Token bucket is the industry standard (used by AWS API Gateway, Stripe, GitHub) and handles bursty traffic naturally — an agent may legitimately send several tool calls in quick succession during a complex task, then go idle.

**Parameters**:
- Capacity: 60 tokens (tool calls per minute)
- Refill rate: 1 token per second
- Scope: per MCP session (identified by session ID from `StreamableHTTPServerTransport`)

This allows a burst of up to 60 rapid calls (accommodating parallel tool execution) while sustaining at most 1 call per second over time. For reference, even aggressive agentic workflows rarely exceed 10-20 tool calls per minute.

**Response on limit**: Return JSON-RPC error code -32001 (server overloaded, from the reserved implementation-defined range). Include `Retry-After` header in the HTTP response. Log the rate limit event to the audit trail with session ID and request count.

**Configuration**: Expose `rateLimitCapacity` and `rateLimitRefillPerSecond` in `tidegate.yaml`.

**Not recommended**: Per-IP or per-user rate limiting. In the Tidegate architecture, there is typically a single agent client. Per-session limiting is the correct granularity.

#### 4. Malformed message handling

**Principle**: Always return a JSON-RPC error response. Never drop silently. Never crash.

The JSON-RPC 2.0 specification defines clear error codes for protocol violations. The gateway should use them precisely:

| Condition | Error code | HTTP status | Action |
|---|---|---|---|
| Request body exceeds size limit | N/A (HTTP layer) | 413 | Reject before parsing; log |
| Invalid JSON syntax | -32700 (Parse error) | 200 | Return JSON-RPC error; log |
| JSON depth exceeds limit | -32700 (Parse error) | 200 | Return JSON-RPC error; log |
| Valid JSON but not valid JSON-RPC 2.0 | -32600 (Invalid Request) | 200 | Return JSON-RPC error; log |
| Unknown method | -32601 (Method not found) | 200 | Return JSON-RPC error; log |
| Invalid parameters | -32602 (Invalid params) | 200 | Return JSON-RPC error; log |
| Rate limit exceeded | -32001 (Server overloaded) | 200 | Return JSON-RPC error; log; include Retry-After |
| Internal processing error | -32603 (Internal error) | 200 | Return JSON-RPC error; log; fail closed (do not forward) |

**Error response format**: Per JSON-RPC 2.0 and ADR-006 (opaque denies), error messages must not leak implementation details. The `message` field should be generic:

- Parse error: "Parse error: invalid JSON"
- Invalid request: "Invalid request"
- Rate exceeded: "Rate limit exceeded"

The `data` field should be omitted or contain only the error code — no stack traces, no internal state, no detection metadata.

**Batch requests**: JSON-RPC 2.0 supports batch requests (JSON array of requests). The gateway should enforce a batch size limit (default: 20, consistent with JSON-RPC best practice recommendations) and reject oversized batches with -32600. Each request in a valid batch should be processed independently — a malformed request in the batch should not prevent processing of valid requests.

**HTTP request smuggling**: The gateway uses Streamable HTTP (HTTP/1.1 or HTTP/2). HTTP request smuggling via Content-Length/Transfer-Encoding disagreement is a risk if a reverse proxy sits in front of the gateway. Mitigation: use HTTP/2 end-to-end where possible (inherently immune to request smuggling), or ensure Content-Length and Transfer-Encoding are never both present (reject with 400 if they are).

**Content-Type validation**: Reject requests with `Content-Type` other than `application/json` with HTTP 415 (Unsupported Media Type). This prevents accidental processing of form-encoded or multipart data.

### Recommendations

1. **Add HTTP body size middleware** before the MCP SDK processes any request. Use `express.json({ limit: '1mb' })` or equivalent. Configurable via `tidegate.yaml` as `maxRequestBodyBytes`.

2. **Add JSON depth validation** as a pre-parse step in `host.ts`. Scan the raw request body string for nesting depth before calling `JSON.parse`. Reject with -32700 if depth exceeds 64 (configurable as `maxJsonDepth`).

3. **Add Content-Type validation** in `host.ts`. Reject non-`application/json` requests with HTTP 415.

4. **Add batch size limit** in `router.ts`. If the parsed JSON is an array, reject with -32600 if its length exceeds the configured maximum (default: 20, configurable as `maxBatchSize`).

5. **Add token bucket rate limiter** in `host.ts`, keyed by MCP session ID. Default: 60 capacity, 1/second refill. Return -32001 on exhaustion. Configurable as `rateLimitCapacity` and `rateLimitRefillPerSecond`.

6. **Audit log all rejections** via `audit.ts`. Every rejected message (size, depth, rate, malformed) should produce an NDJSON audit event with timestamp, session ID, rejection reason code, and request size. No message content in the log — it may contain sensitive data.

7. **Fail closed on all error paths**. If the depth scanner fails, reject the message. If rate limit state is corrupted, reject the message. If JSON parsing throws an unexpected error, reject the message. Never forward a message the gateway could not fully validate.

8. **Do not implement custom JSON parsing**. Use `JSON.parse` — it is safe against prototype pollution and duplicate-key attacks. The depth check is the only pre-processing needed. Introducing a custom parser would expand the attack surface.

9. **HTTP request smuggling defense**: If deploying behind a reverse proxy, enforce HTTP/2 end-to-end. If HTTP/1.1 is required, reject requests containing both Content-Length and Transfer-Encoding headers.

10. **Configuration defaults** in `tidegate.yaml`:

```yaml
protocol:
  maxRequestBodyBytes: 1048576    # 1MB
  maxJsonDepth: 64
  maxBatchSize: 20
  rateLimitCapacity: 60           # tokens (tool calls)
  rateLimitRefillPerSecond: 1     # token per second
```

## Why it matters

The gateway is the security boundary. If it can be crashed or confused by adversarial input, the entire model fails.

## Context at time of writing

The gateway (`src/gateway/src/router.ts`) accepts arbitrary JSON-RPC over Streamable HTTP. The MCP SDK does its own parsing, but the gateway adds no size limits, depth limits, or rate controls on top. The threat model assumes a compromised agent — so adversarial input to the gateway is a realistic scenario.
