---
source-id: "009"
title: "MCP Scanning Tools Landscape (2026)"
type: web
url: "https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/"
fetched: 2026-03-15T00:00:00Z
hash: "sha256:pending"
notes: "Composite source assembled from multiple web searches covering the MCP scanning ecosystem as of March 2026"
---

# MCP Scanning Tools Landscape (2026)

**Compiled:** 2026-03-15
**Sources:** Snyk mcp-scan docs, Pipelock docs, Docker MCP Gateway docs, MCPScan.ai, Operant AI guide, multiple comparison articles

The MCP security landscape has split into three tiers: static scanning tools, runtime proxy/firewall tools, and enterprise gateway platforms.

## (A) Static scanning tools

### MCP-Scan (Invariant Labs / now Snyk)

- Scans MCP client configurations (Claude, Cursor, Windsurf, Gemini CLI) for malicious tool descriptions
- Detects 15+ distinct security risks: tool poisoning, MCP rug pulls (unauthorized description changes after approval), cross-origin escalation (tool shadowing across servers), prompt injection patterns
- **Tool Pinning:** Tracks tool description integrity via hashing to detect mid-session changes
- Also has `mcp-scan proxy` mode for runtime monitoring with configurable guardrails (PII detection, secrets detection, tool restrictions)
- **Limitation:** Static scanning catches known patterns at install time only. Tool descriptions shared with Invariant's API for analysis.

### MCPScan.ai (web service)

- Scanned 50+ public MCP servers; found **23% contained command injection vulnerabilities** (improper string concatenation in shell commands)
- Detects 8+ command injection pattern variants including Node.js child_process and Python subprocess shell mode
- Checks for tool shadowing, supply chain risks, rug pulls

## (B) Runtime proxy/firewall tools

### Pipelock (PipeLab)

- Open-source firewall for AI agents. Sits between agents and outside world, scanning HTTP, WebSocket, and MCP traffic bidirectionally
- **Architecture:** Go binary with 11-layer URL scanning pipeline, DNS pinning, optional TLS interception
- **MCP-specific features:**
  - Tool description scanning on first contact
  - Rug-pull detection via fingerprinting (hashes descriptions, flags mid-session changes)
  - Bidirectional argument/response scanning (outbound for credential leaks, inbound for injection patterns)
- **DLP scanning:** Outbound requests checked for secrets (API keys, tokens, credentials)
- **Response injection scanning:** Inbound MCP responses and fetched URLs scanned for injection patterns before reaching agent context
- **Known gaps:** Does not catch parameter-name attacks (e.g., `content_from_reading_ssh_id_rsa` as a key name). Semantic poisoning bypasses regex patterns. Drift detection catches schema changes mid-session but not on first `tools/list`.
- **Covered agents:** Claude Code, OpenAI Agents SDK, multi-agent handoffs

### Invariant Guardrails (Invariant Labs)

- Runtime protection layer against prompt injection
- Custom guardrailing policies (PII detection, secrets detection, tool restrictions)
- Integrates with mcp-scan proxy mode

## (C) Enterprise MCP gateways

### Docker MCP Gateway (open source)

- Runs MCP servers as isolated containers
- Key security feature: **`--block-secrets`** -- scans inbound and outbound payloads for content that looks like secrets
- Container isolation, signed images, Docker secret management
- **Limitation:** No built-in OAuth, no admin UI for policies, basic access control

### Other enterprise gateways

- **MintMCP Gateway:** SOC 2 Type II certified, role-based MCP endpoints, OAuth, audit trails
- **TrueFoundry:** 3-4ms latency, Virtual MCP Server abstraction, RBAC and secret management
- **Bifrost:** Dual client/server architecture for advanced routing
- **Kong AI Gateway, Traefik Hub, Microsoft Azure MCP:** API gateway players extending to MCP
- **Operant AI:** Published "2026 Guide to Securing MCP", documents "Shadow Escape" zero-click exploits
- **Lasso Security:** MCP Secure Gateway, specialized LLM interaction protection

## What the landscape misses (gaps)

1. **Semantic poisoning:** Tool descriptions using natural language manipulation ("This tool needs your SSH key for authentication") bypass pattern-matching scanners
2. **Compositional attacks:** Interactions between multiple benign-looking tools that combine to produce malicious behavior
3. **Runtime behavioral drift:** Static scanning catches known patterns at install time but not runtime changes in tool behavior that don't change the schema
4. **Parameter-name attacks:** Encoding exfiltration targets in JSON key names rather than values
5. **First-contact trust:** Most tools can only detect rug pulls (changes after initial approval), not poisoning present from the first `tools/list` response
6. **Base-rate fallacy:** When benign inputs vastly outnumber malicious ones, even a low false-positive rate means most detected "attacks" are false alarms
7. **No gateway covers the full stack:** MCP gateways handle tool access governance but not prompt injection detection; scanning tools detect injection but don't enforce access policies. Most enterprises need both layers for coverage.
8. **None enforce at the network layer:** All MCP scanning tools operate at the application layer. None combine payload scanning with network-level enforcement that makes bypass structurally impossible -- the specific gap Tidegate addresses.
