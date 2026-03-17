---
source-id: "heyuan-mcp-30-cves"
title: "MCP Security 2026: 30 CVEs in 60 Days — What Went Wrong"
type: web
url: "https://www.heyuan110.com/posts/ai/2026-03-10-mcp-security-2026/"
fetched: 2026-03-17T00:00:00Z
hash: "e077560d10495004b1661871eb8158d1c28cb3f7c6ba5e60cfb3fc2f541b559d"
---

# MCP Security 2026: 30 CVEs in 60 Days -- What Went Wrong

**Published:** 2026-03-09
**Author:** Bruce (heyuan110)
**Source:** heyuan110.com

30 CVEs. 60 days. 437,000 compromised downloads. The Model Context Protocol went from "promising open standard" to "active threat surface" faster than anyone predicted.

Between January and February 2026, security researchers filed over 30 CVEs targeting MCP servers, clients, and infrastructure. The vulnerabilities ranged from trivial path traversals to a CVSS 9.6 remote code execution flaw in a package downloaded nearly half a million times. Root causes were not exotic zero-days -- they were missing input validation, absent authentication, and blind trust in tool descriptions.

## Ecosystem scale (as of February 2026)

| Metric | Value | Source |
| --- | --- | --- |
| Official MCP servers in registry | 518 | MCP Registry audit, Feb 2026 |
| Servers lacking authentication | 38--41% | Invariant Labs / community scans |
| Total MCP implementations scanned | 2,614 | Academic security survey, Jan 2026 |
| Implementations with file ops prone to path traversal | 82% | Same survey |
| Code injection risk | 67% | Same survey |
| Command injection risk | 34% | Same survey |
| SSRF exposure rate | 36.7% | Adversa AI SecureClaw report |
| CVEs filed (Jan--Feb 2026) | 30+ | NVD / GitHub Security Advisories |

Among 2,614 MCP implementations surveyed, 82% use file operations vulnerable to path traversal. Two-thirds have code injection risk. Over a third are susceptible to command injection.

## Attack type breakdown (30+ CVEs categorized)

- **43% -- Exec/shell injection**: MCP servers passing user input to shell commands without sanitization. Many MCP servers are thin wrappers around CLI tools; string interpolation into `exec()` or `subprocess.run()` is the dominant pattern.
- **20% -- Tooling infrastructure flaws**: Vulnerabilities in MCP clients, inspectors, and proxy tools -- not the servers themselves.
- **13% -- Authentication bypass**: Servers that lack auth entirely or implement it incorrectly.
- **10% -- Path traversal**: Sandbox escapes and directory traversal in filesystem-related servers.
- **14% -- Other**: SSRF, cross-tenant exposure, supply chain attacks, trust mechanism bypasses.

## CVE timeline (2025--2026)

### April 2025 -- WhatsApp tool poisoning

**Attack type:** Tool Poisoning

Researchers demonstrated the WhatsApp MCP Server was vulnerable to tool poisoning. Malicious instructions injected into tool descriptions tricked AI agents into exfiltrating entire chat histories. No authentication bypass or code exploitation required -- the AI agent simply followed instructions it found in tool metadata, treating them as authoritative.

### May 2025 -- GitHub MCP prompt injection

**Attack type:** Prompt Injection

Attackers embedded crafted prompts in public GitHub Issues and Pull Requests. When an AI agent processed these through the GitHub MCP Server, it was manipulated into leaking private repository code into public Pull Requests. Any MCP server that reads user-generated content from external platforms is a potential prompt injection vector.

### June 2025 -- Asana cross-tenant data exposure

**Attack type:** Cross-Tenant Exposure

A flaw in the Asana MCP Server's access control logic allowed one tenant's AI agent to access project data belonging to other tenants. In SaaS environments, cross-tenant isolation is the most fundamental security boundary -- this vulnerability broke it completely.

### June 2025 -- MCP Inspector RCE (CVE-2025-49596)

**Attack type:** Remote Code Execution

Anthropic's own MCP Inspector tool -- designed for debugging and inspecting MCP servers -- contained a remote code execution vulnerability. The tool developers used to check their MCP servers was itself an attack vector, underscoring that the entire MCP toolchain is part of the attack surface.

### July 2025 -- mcp-remote command injection (CVE-2025-6514)

**Attack type:** Command Injection | **CVSS:** 9.6 | **Downloads:** 437,000+

The watershed moment. `mcp-remote`, a widely-used package for connecting to remote MCP servers, contained a command injection vulnerability. Attackers could craft malicious remote MCP server URLs that executed arbitrary commands on the client machine. With over 437,000 downloads, this was the first documented MCP vulnerability with mass-scale impact.

### July 2025 -- Cursor trust bypass (CVE-2025-54136, "MCPoison")

**Attack type:** Trust Bypass

Cursor IDE's MCP trust mechanism was fundamentally broken. Once a user approved an MCP server configuration, it was never re-validated. Attackers submitted benign-looking MCP configurations to gain approval, then injected malicious logic in subsequent updates. The malicious changes took effect silently. This vulnerability class -- "MCPoison" -- affects any MCP client that caches trust decisions without periodic re-validation.

### August 2025 -- Filesystem MCP sandbox escape

**Attack type:** Sandbox Escape / Path Traversal

Anthropic's official Filesystem MCP Server was supposed to restrict file access to specified directories. Attackers bypassed this using path traversal techniques, gaining read and write access to arbitrary files outside the sandbox.

### September 2025 -- Postmark MCP supply chain attack

**Attack type:** Supply Chain Attack

A malicious package impersonating the Postmark email service was uploaded to the MCP registry. Developers who installed it received a functional-seeming email MCP server that quietly exfiltrated API keys and environment variables. Classic supply chain attack adapted for MCP -- it worked because the registry lacked adequate vetting.

### October 2025 -- Smithery path traversal

**Attack type:** Path Traversal

Smithery, a popular MCP server hosting platform, had a path traversal vulnerability in its isolation layer. Attackers could break out of their container boundary and read Docker credentials and environment variables belonging to other users' MCP deployments.

### January--February 2026 -- The CVE flood

The first two months of 2026 saw an unprecedented wave of MCP CVE filings from Check Point, Invariant Labs, Adversa AI, and independent researchers:

- **Check Point** found that Claude Code itself could be attacked through malicious hooks, MCP configurations, and environment variables. Their research demonstrated attack chains combining multiple MCP weaknesses.
- Multiple MCP servers on popular registries had basic **SSRF vulnerabilities**, allowing pivoting from MCP server into internal networks.
- Several community-maintained MCP servers used **`eval()` or `exec()`** on unsanitized inputs, creating trivial RCE paths.

## Five core attack patterns

### Pattern 1: Tool poisoning

Injecting malicious instructions into MCP tool descriptions or metadata. AI agents read these descriptions and follow them as legitimate instructions. No standard mechanism exists for validating or signing tool descriptions. An attacker who controls or can modify a tool description effectively controls the agent's behavior.

**Real-world example:** WhatsApp MCP attack (April 2025) -- exfiltrated chat histories without any code exploit.

### Pattern 2: Prompt injection via external data

Planting malicious prompts in data sources that MCP servers read -- GitHub issues, Slack messages, database records, emails, or any external content. MCP servers act as bridges between AI agents and external systems. The AI cannot reliably distinguish legitimate data from injected prompts.

**Real-world example:** GitHub MCP prompt injection (May 2025) -- public Issues used to exfiltrate private repository code.

### Pattern 3: Trust bypass

Exploiting weaknesses in how MCP clients store and validate trust decisions. Most MCP clients implement "trust on first use" (TOFU). Initial approval is thorough, but subsequent changes go unverified, creating a window where approved servers can be silently compromised.

**Real-world example:** Cursor MCPoison (CVE-2025-54136).

### Pattern 4: Supply chain attack

Publishing malicious MCP servers to registries, either by impersonating legitimate services or by compromising existing packages. The MCP registry ecosystem is still maturing -- vetting processes are minimal and developers often install based on name recognition alone.

**Real-world example:** Postmark supply chain attack (September 2025).

### Pattern 5: Cross-tenant exposure

Exploiting shared infrastructure to access data belonging to other users or organizations. Many MCP servers run on shared hosting or process requests from multiple tenants through the same service. If tenant isolation is not properly implemented at every layer, cross-tenant data leaks become possible.

**Real-world examples:** Asana cross-tenant exposure (June 2025), Smithery path traversal (October 2025).

## OWASP Agentic Security Top 10

Published late 2025, the OWASP Agentic Security Top 10 maps nearly perfectly to MCP vulnerabilities. Every risk category has at least one confirmed MCP CVE or documented exploit.

| # | Risk | MCP Relevance |
| --- | --- | --- |
| 1 | **Prompt Injection** | Direct: tool description poisoning, external data injection |
| 2 | **Broken Access Control** | Direct: cross-tenant exposure, missing auth on 38% of servers |
| 3 | **Tool Misuse** | Direct: agents calling tools with unintended parameters |
| 4 | **Excessive Agency** | Tools granted more permissions than needed |
| 5 | **Improper Output Handling** | MCP servers returning unsanitized data to agents |
| 6 | **Supply Chain Vulnerabilities** | Direct: malicious MCP packages in registries |
| 7 | **Sensitive Data Disclosure** | API keys and credentials leaked via MCP tool calls |
| 8 | **Insecure Interfaces** | MCP transport layer (stdio, SSE) security gaps |
| 9 | **Denial of Service** | MCP servers with no rate limiting or resource caps |
| 10 | **Insufficient Logging** | Most MCP servers have zero audit trail for tool invocations |

## Security tools comparison (March 2026)

| Feature | mcp-scan | SecureClaw | agent-audit | Cisco Scanner | Snyk Agent |
| --- | --- | --- | --- | --- | --- |
| **Price** | Free | Enterprise | Free | Free | Freemium |
| **Tool poisoning detection** | Yes | Yes | Partial | No | No |
| **Dependency scanning** | No | Yes | No | No | Yes |
| **OWASP mapping** | No | Yes | Yes | No | No |
| **Network analysis** | No | No | No | Yes | No |
| **CI/CD integration** | Basic | Yes | No | Yes | Yes |
| **Setup time** | < 1 min | Hours | Minutes | Hours | Minutes |
| **Best for** | Individual devs | Enterprises | Compliance | SOC teams | Dev teams |

- **mcp-scan** (Invariant Labs): Open-source, runs locally, auto-detects MCP configs for Claude Code / Claude Desktop / Cursor / Windsurf. Inspects tool descriptions for poisoning indicators, checks against known vulnerability database. Install: `uvx mcp-scan`.
- **SecureClaw** (Adversa AI): Enterprise SaaS with 55 distinct audit checks. SSRF detection, auth testing, input validation analysis, compliance reporting, continuous monitoring.
- **agent-audit**: Open-source, OWASP-aligned. Maps MCP server configs against Agentic Security Top 10, generates risk scores and remediation guidance.
- **Cisco MCP Scanner**: Open-source, network-level. Analyzes MCP traffic patterns, detects anomalous tool calls, monitors for data exfiltration indicators.
- **Snyk Agent Scan**: Commercial (free tier). Extends Snyk dependency scanning to MCP and AI agent dependencies. CI/CD integration. Focused on dependency-level vulns, not tool descriptions or runtime behavior.

## Defense checklist

### Priority 1 -- Today

- Run `mcp-scan` on current MCP configuration. Fix findings before proceeding.
- Pin MCP server versions. Never use `@latest` in production. Specify exact versions.
- Review tool descriptions for every approved MCP server. Look for unusual instructions, URLs, or references to sensitive data.
- Remove unused MCP servers. Every inactive server is unnecessary attack surface.
- Verify credentials use minimum necessary permissions. Rotate broadly-shared credentials.

### Priority 2 -- This week

- Implement permission boundaries. Restrict which MCP tools can be called without explicit approval.
- Audit MCP server sources: verify publisher identity, check GitHub repo activity and maintainer reputation, review open issues for security reports.
- Set up monitoring. Log all MCP tool invocations (tool name, input parameters, timestamp) for audit trail.
- Separate sensitive operations. Restrict to read-only mode where possible.
- Audit hooks and environment variables. Ensure no MCP server has access to sensitive environment variables.

### Priority 3 -- Ongoing

- Run `mcp-scan` weekly or add to CI pipeline (`uvx mcp-scan --exit-code` for CI gate checks).
- Subscribe to MCP security advisories (MCP GitHub repository, NVD alerts).
- Test new MCP servers in sandboxed environments before production use.
- Report discovered vulnerabilities through responsible disclosure channels.
- Track MCP specification changes. New versions may introduce security improvements or new attack surfaces.

## Outlook

- **Protocol-level improvements**: MCP specification team working on built-in authentication standards, tool description signing, and server attestation. Could address root causes of tool poisoning and supply chain attacks at protocol level.
- **Registry vetting**: Major MCP registries implementing publisher verification and automated security scanning. Should reduce (but not eliminate) supply chain risks.
- **Client-side defenses**: AI coding tools adding more granular permission controls. Claude Code already requires explicit approval for MCP tool calls.
- **Enterprise adoption blockers**: Current MCP security posture is a significant barrier to enterprise adoption. Organizations with strict security requirements are waiting for signed tools, verified registries, and standardized audit frameworks.

## FAQ highlights

- **Production use**: Possible with caveats -- pin versions, scan regularly, use minimal permissions, only install from trusted verified sources.
- **SOC 2 compliance**: Not without additional controls (comprehensive logging, regular scanning, access controls, MCP-specific incident response plan).
- **stdio vs SSE transport**: stdio is generally more secure (local, no network endpoint). SSE requires proper authentication, TLS, and network access controls.
- **Custom vs community servers**: Custom servers give full control but require handling security yourself. Community servers benefit from broader testing but introduce supply chain risk. For critical operations, prefer custom servers with security audits.
