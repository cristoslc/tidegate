# VISION-002 Documentation Update

## Context

VISION-002 reframes Tidegate as a reference architecture for data-flow enforcement in AI agent deployments. It supersedes VISION-001, which was implementation-focused and described a five-seam system (including eBPF taint tracking, seccomp-notify, and a Tideclaw orchestrator CLI) that was never validated as necessary.

The repo currently has no README. The existing architecture docs live under the Sunset VISION-001 directory and describe a system far more ambitious than VISION-002's scope. AGENTS.md describes the current code accurately but doesn't reflect the project's actual posture: an intellectual exercise and reference architecture that may or may not get built.

The primary audience is people who'd contribute to the analysis — refining the threat model, evaluating the architecture, researching the landscape. Secondary audience is people evaluating AI agent security tools who'd use this as a reference. Implementation contributors are possible but last in priority.

## Deliverables

Three deliverables. No changes to VISION-001's supporting docs (they're historical artifacts; Sunset status is sufficient signal).

### 1. README.md (new, project root)

A substantive landing page that stands on its own without requiring click-through. Not a link hub.

**Voice:** Tidegate is a reference architecture. It maps what comprehensive agent data-flow enforcement requires. It may get built, it may remain an analytical tool for evaluating commercial solutions. The value is in the analysis regardless.

**Sections:**

1. **Opening** — One paragraph. What Tidegate is (reference architecture for data-flow enforcement in AI agent deployments), why it exists (scanning tool call payloads isn't enough when agents can bypass MCP entirely).

2. **The Problem** — Agents read sensitive files and call external APIs in the same breath. A community skill can read bank statements and post them to any endpoint. A prompt injection in a document can instruct the agent to exfiltrate credentials through a tool call. Agent frameworks sandbox code execution but not data flow. MCP gateways scan tool call payloads but agents route around them via curl, cron, IPC, or encoding data in the LLM API request.

3. **Existing Landscape** — Categories from VISION-002:
   - Agent frameworks (code-execution sandboxing, no data-flow boundaries)
   - MCP gateways with payload scanning (Docker MCP Gateway, Pipelock, Lasso, Pangea, etc.)
   - MCP governance tools (Snyk agent-scan, Promptfoo, Trail of Bits)
   - AI gateway DLP (Cloudflare, Lakera, Nightfall)
   - Cloud sandboxes (E2B, Daytona, microsandbox)

   Gap statement: the gap isn't "nobody scans MCP payloads" — many tools now do. The gap is that scanning alone is insufficient without structural enforcement that makes bypass structurally impossible.

4. **What Comprehensive Enforcement Requires** — High-level summary: MCP gateway scanning + network-level egress control + credential isolation + Docker network topology. Three enforcement seams that operate independently. Links to the architecture doc.

5. **Honest Limitations** — Non-goals and accepted risks:
   - No sabotage prevention (Tidegate prevents data leaving, not destructive commands)
   - Semantic exfiltration is a fundamental limit of all scanning approaches
   - LLM API as exfiltration channel (agent's API key must exist in the agent container)
   - Not multi-tenant
   - Not replacing agent frameworks

   Links to the threat model for full analysis.

6. **Status** — This is a reference architecture and may remain one. The repo contains research spikes, a threat model, ADRs, and personas alongside the architecture. There is no roadmap. If it gets built, the architecture doc guides implementation. If it doesn't, it serves as a point of comparison for evaluating commercial tools against.

7. **Navigation** — Links to: architecture doc, VISION-002, threat model, research spikes index, ADRs index, personas index.

### 2. system-architecture.md (new, under VISION-002)

Path: `docs/vision/Draft/(VISION-002)-Tidegate/system-architecture.md`

Prescriptive architecture — describes how the system would be built, not existing code. Scoped to VISION-002: MCP gateway scanning, egress proxy, credential isolation, Docker networking. No L1 taint, no Tideclaw, no eBPF. If those are ever needed, they enter through the ADR process.

**Sections:**

1. **Purpose** — Tidegate is an MCP gateway + egress proxy + Docker network topology that enforces data-flow boundaries for AI agents. The operator picks their runtime; Tidegate provides the boundary. Explicitly framed as a design.

2. **Design Principles** — Four principles that survive VISION-002's scope:
   - Seams first: every container boundary, network segment, and mount point exists to enable enforcement
   - Runtime-agnostic: any CLI agent that runs in a container
   - No cooperation required: runtime runs unmodified, sees MCP servers at expected URLs, reaches internet through a proxy it doesn't know about
   - Fail-closed: scanner unavailable = deny, proxy down = no egress

3. **Components** — Four components described as design:
   - **tg-gateway** — MCP interposition proxy. Connects to downstream MCP servers, discovers tools via listTools(), mirrors them to the agent. Five-step pipeline: allowlist check, scan arguments, forward, scan response, return or shaped deny. Zero knowledge of credentials. Shaped denies use isError: false.
   - **Egress proxy** — Squid CONNECT-only. Domain allowlisting. LLM API domains get passthrough; everything else blocked. Sole path to the internet from the agent container.
   - **MCP server containers** — Each downstream MCP server runs in its own container on mcp-net. Each holds only its own credentials. Agent cannot reach mcp-net.
   - **Agent container** — Runs the operator's chosen runtime. Sits on agent-net only. Has no external service credentials. MCP config points to the gateway. HTTPS_PROXY points to egress proxy.

4. **Network Topology** — Three Docker networks:
   - `agent-net` (internal): agent, gateway, egress proxy
   - `mcp-net` (internal): gateway, MCP servers
   - `proxy-net`: egress proxy to internet

   ASCII diagram showing the topology. Simplified from VISION-001 (no tg-scanner node).

5. **Enforcement Seams** — Three seams (down from VISION-001's five), each with what it enforces and its bypass condition:
   - MCP interposition: scans all tool call parameters and responses. Bypass: agent reaches MCP servers without the gateway (network misconfiguration).
   - Egress mediation: domain allowlisting, blocks direct internet. Bypass: agent reaches internet without proxy (network misconfiguration).
   - Credential isolation: API keys exist only in containers that need them. Bypass: credentials mounted into wrong container (compose misconfiguration).

6. **Scanning Pipeline** — How tg-gateway scans: recursive extraction of all string values from tool call arguments and responses. Two tiers:
   - L1 in-process (TypeScript): fast regex patterns for high-confidence credential formats (AWS keys, GitHub tokens, etc.)
   - L2/L3 Python subprocess: checksum validation (Luhn for credit cards, python-stdnum for government IDs), entropy analysis

   L2 patterns must have zero mathematical false positives (checksum-validated). Scanner is stateless: receives a string, returns allow/deny.

7. **Trust Boundaries** — Untrusted: agent runtime, community skills, workspace files, downloaded MCP servers. Trusted: tg-gateway, egress proxy, operator's MCP servers. All enforcement infrastructure runs outside the agent container.

8. **Configuration** — The tidegate.yaml schema: server URLs, optional tool allowlists, scan timeout, failure mode. No per-field mappings — the gateway scans every string value in every tool call.

9. **Accepted Limitations** — Honestly documented:
   - Semantic exfiltration: LLM rephrases sensitive data as prose. No pattern scanner catches this. Fundamental limit.
   - LLM API as exfiltration channel: agent's API key must exist in the agent container. Sophisticated attacker could encode data in API requests.
   - CONNECT passthrough: LLM API traffic is not inspected (end-to-end TLS).

10. **Future Directions** — L1 taint tracking (Tideclaw research, SPIKE-013) explored the question of whether eBPF-based file access observation + seccomp-notify connect() enforcement could close the encryption-before-exfiltration gap. Not committed. If structural gaps in the three-seam model are identified that require it, the decision enters through the ADR process.

11. **Key Decisions** — Links to relevant ADRs. Notes which are still applicable to VISION-002's scope and which are VISION-001 context only.

### 3. AGENTS.md (edit)

One-line change to the opening paragraph. Current:

> MCP gateway that sits between an agent and downstream MCP servers.

Change to frame as reference architecture:

> Reference architecture for an MCP gateway that sits between an agent and downstream MCP servers.

No other changes. Conventions, key files table, skill routing, and pre-implementation protocol all stay as-is — they'll guide implementation if it happens.

## What This Design Does NOT Include

- No changes to VISION-001's supporting docs (system-architecture.md, target-state.md). They're historical artifacts under a Sunset vision.
- No CONTRIBUTING.md. Premature for a project that may remain a reference architecture.
- No updates to docs/README.md index. The new files (root README, VISION-002 architecture) are discoverable without an index entry.
- No target-state.md under VISION-002. The setup.sh narrative was VISION-001's framing. VISION-002 doesn't commit to a specific deployment UX yet.
- No roadmap. VISION-002 is a vision, not a plan.
