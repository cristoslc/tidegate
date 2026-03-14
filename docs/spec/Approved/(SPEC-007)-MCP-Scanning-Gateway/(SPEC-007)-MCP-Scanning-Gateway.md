---
title: "MCP Scanning Gateway"
artifact: SPEC-007
status: Approved
author: cristos
created: 2026-03-14
last-updated: 2026-03-14
type: feature
parent-epic: EPIC-002
linked-research: []
linked-adrs:
  - ADR-002
  - ADR-004
depends-on: []
addresses:
  - JOURNEY-001.PP-01
evidence-pool: ""
source-issue: ""
swain-do: required
---

# SPEC-007: MCP Scanning Gateway

## Problem Statement

Tidegate's enforcement topology routes all MCP traffic from the agent VM through a gateway before it reaches downstream MCP servers. The gateway is the L2 enforcement seam (ADR-002): it scans every tool-call argument and response for structured sensitive data before the data leaves the operator's infrastructure.

No gateway exists yet. SPEC-004 (VM Launcher) and SPEC-005 (gvproxy Egress Allowlist) create a VM whose only permitted network destinations are the gateway IP and the egress proxy IP — but neither the gateway nor the proxy have been specified. Without the gateway, gvproxy allowlists an IP that serves nothing, and MCP tool calls either fail or bypass scanning entirely.

The vision (VISION-002) identifies the gap: "No existing tool combines payload scanning with network-level enforcement that makes bypass structurally impossible." The gateway is the payload scanning half of that equation; the VM + gvproxy is the network enforcement half. Neither works without the other.

## External Behavior

**Process:** `tg-gateway` — a Docker container that acts as an MCP protocol proxy.

**Topology:**
- Listens on `agent-net` (reachable from the VM via gvproxy allowlist)
- Connects to downstream MCP servers on `mcp-net`
- The agent sees `tg-gateway` as its MCP server; `tg-gateway` mirrors tools from all configured downstream servers

**MCP protocol flow:**
1. Agent sends `tools/list` → gateway aggregates tool lists from all downstream servers, returns combined list
2. Agent sends `tools/call` with tool name and arguments → gateway identifies the downstream server, scans arguments, forwards if clean, returns shaped deny if blocked
3. Downstream server responds → gateway scans response content, forwards if clean, returns shaped deny if blocked

**Scanning pipeline (two tiers):**

| Tier | Scope | Technique | Examples |
|------|-------|-----------|---------|
| L1 (fast, in-process) | All string values in arguments and responses | Regex patterns for high-confidence credentials | AWS `AKIA...`, GitHub `ghp_...`, Slack `xoxb-...`, PEM private keys, Bearer tokens |
| L2 (subprocess, zero false-positives) | All string values in arguments and responses | Checksum/structure validation | Luhn (credit cards), IBAN mod-97, SSN structure (python-stdnum) |

**Scanning rules:**
- Scan ALL string values recursively — no per-tool or per-field configuration
- Nested JSON strings are decoded and scanned (one level of decode)
- A single match in any value blocks the entire tool call
- Scan timeout: configurable (default 500ms), failure mode: configurable (default deny)

**Shaped denies:**
- Blocked tool calls return `isError: false` with a result explaining what was blocked and why
- This causes the agent to adjust its approach (e.g., redact the value) rather than retry the same call
- The deny response never echoes the matched sensitive value

**Audit logging:**
- Every tool call is logged: timestamp, tool name, downstream server, scan result (pass/block), block reason (if any)
- Sensitive values in logs are replaced with the pattern name and a truncated hash (e.g., `[CREDIT_CARD:a3f2]`)

**Configuration (from `tidegate.yaml`):**
```yaml
gateway:
  listen: "0.0.0.0:4100"
  scan_timeout_ms: 500
  scan_failure_mode: deny  # deny | allow

servers:
  gmail:
    transport: http
    url: http://gmail-mcp:3000/mcp
  slack:
    transport: http
    url: http://slack-mcp:3000/mcp
  github:
    transport: http
    url: http://github-mcp:3000/mcp
```

**Preconditions:**
- Downstream MCP servers are running and reachable on `mcp-net`
- `tidegate.yaml` exists with at least one server entry

## Acceptance Criteria

1. **Given** a running gateway with one downstream MCP server, **when** the agent sends `tools/list`, **then** the gateway returns the downstream server's tool list.
2. **Given** a running gateway with two downstream MCP servers, **when** the agent sends `tools/list`, **then** the gateway returns the combined tool list from both servers with no name collisions (prefixed by server name if needed).
3. **Given** a tool call with a string argument containing an AWS access key (`AKIA...`), **when** the gateway scans it, **then** the call is blocked and a shaped deny is returned.
4. **Given** a tool call with a string argument containing a valid credit card number (passes Luhn), **when** the gateway scans it, **then** the call is blocked and a shaped deny is returned.
5. **Given** a tool call with a string argument containing a valid IBAN, **when** the gateway scans it, **then** the call is blocked and a shaped deny is returned.
6. **Given** a tool call with arguments containing no sensitive data, **when** the gateway scans it, **then** the call is forwarded to the downstream server and the response is returned.
7. **Given** a downstream MCP server response containing a GitHub token (`ghp_...`), **when** the gateway scans the response, **then** the response is blocked and a shaped deny is returned to the agent.
8. **Given** a scan that exceeds the configured timeout, **when** `scan_failure_mode` is `deny`, **then** the call is blocked.
9. **Given** a blocked tool call, **when** the shaped deny is returned, **then** it does not echo the matched sensitive value.
10. **Given** any tool call (pass or block), **when** the call completes, **then** an audit log entry is written with timestamp, tool name, server, and result.

## Verification

| Criterion | Evidence | Result |
|-----------|----------|--------|

## Scope & Constraints

- The gateway scans MCP tool calls only. HTTP egress from the agent (LLM API calls, curl) is handled by the egress proxy — a separate concern.
- The gateway does NOT implement per-tool allowlists or denylists in the MVP. All tools from all configured servers are mirrored. Per-tool filtering is a future enhancement.
- The gateway does NOT perform semantic analysis or ML-based detection. Pattern matching (regex + checksums) only.
- The gateway does NOT scan tool descriptions for prompt injection (that's a governance concern, not a data-flow concern).
- Transport: HTTP (Streamable HTTP) between agent and gateway, and between gateway and downstream servers. stdio transport is not supported in the MVP (MCP servers run as containers, not subprocesses).
- The scanning pipeline is stateless — no cross-request taint tracking. L1 taint tracking (ADR-002) is a separate, future component.
- Python implementation. Scanner uses stdlib regex + python-stdnum for checksum validation. No ML dependencies.

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Draft | 2026-03-14 | — | Initial creation; L2 enforcement seam per ADR-002 |
| Approved | 2026-03-14 | 326ed14 | L2 enforcement seam approved; completes EPIC-002 dependency graph |
