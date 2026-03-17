---
source-id: "cyberdesserts-agent-security-2026"
title: "AI Agent Security Risks in 2026: A Practitioner's Guide"
type: web
url: "https://blog.cyberdesserts.com/ai-agent-security-risks/"
fetched: 2026-03-17T00:00:00Z
hash: "c1a378d36687e43ae991f2f44fc1bb25990f363f90a95a41a332e17e2abb13e0"
---

# AI Agent Security Risks in 2026: A Practitioner's Guide

**Author:** Shak (CyberDesserts)
**Published:** 2026-03-01
**Last updated:** March 2026

Gartner predicted in 2021 that 45% of organisations would experience software supply chain attacks by 2025. The reality exceeded their forecast: 75% of organisations were hit within a single year (BlackBerry, 2024). Third-party breaches now account for 30% of all data breaches (Verizon DBIR, 2025).

In February 2026, the same supply chain threat model arrived in AI agent infrastructure, and it arrived all at once.

Check Point Research disclosed remote code execution in Claude Code through poisoned repository config files. Antiy CERT confirmed 1,184 malicious skills across ClawHub, the marketplace for the OpenClaw AI agent framework. Trend Micro found 492 MCP servers exposed to the internet with zero authentication. Kali Linux shipped an official AI-assisted pentesting workflow through the same protocol. And the Pentagon designated Anthropic a "supply chain risk," the first time an American company has received the classification (CBS News, 2026).

The connective tissue across every incident is the Model Context Protocol (MCP).

## What Is MCP and Why Is It a Security Problem?

Model Context Protocol (MCP) is an open standard released by Anthropic in late 2024 that defines how AI models connect to external tools, data sources, and services. It is, in practical terms, a universal connector for AI agents: one protocol, many tools.

MCP uses a client-server architecture. The client sits inside a host application, typically an AI assistant like Claude Desktop, an IDE like Cursor, or a coding tool like Claude Code. The client tells the AI model what tools are available. The model decides which tool to use. The request goes to an MCP server, a lightweight program that wraps a specific capability: running terminal commands, querying a database, scanning a network, accessing a file system. The server executes the action and returns the result.

Adoption has been aggressive. Microsoft, OpenAI, Google, Amazon, and dozens of development tools now support MCP. GitHub Copilot, VS Code, Cursor, Autogen, and LangChain all use it. Deployments span financial services, healthcare, and customer support.

The security problem is architectural. Anthropic designed MCP for capability first and left authentication, authorisation, and sandboxing to the implementer. Most implementers skipped all three in the AI goldrush. The result: MCP servers deployed with no authentication, overprivileged credentials stored in plaintext, and default bindings that expose them to the public internet. Uma Reddy, founder of Uptycs, described the situation: connecting an LLM directly to internal systems without guardrails is leaving your digital front door open (Security Boulevard, 2026).

## The Lethal Trifecta for AI Agents

Security researcher Simon Willison identified a structural problem with AI agent architectures in June 2025 that applies to every MCP deployment. He calls it the "lethal trifecta." When an AI agent has all three of these characteristics simultaneously, it is exploitable by design:

1. **It has access to private data.** The agent reads files, retrieves API keys, queries databases, or connects to internal systems.
2. **It processes untrusted content.** The agent handles inputs from sources outside the operator's control: user prompts, third-party tool outputs, web content, or installed skills from community registries.
3. **It can communicate externally.** The agent makes network requests, sends messages, or writes data to endpoints beyond the local system.

Most deployed MCP agents have all three. That is the point. Agents are useful precisely because they access your data, process diverse inputs, and take actions on your behalf. The vulnerability is the value proposition.

The practical consequence is that prompt injection -- the technique of embedding hidden instructions in data that an AI model processes as commands -- becomes a full system compromise vector. An attacker embeds instructions in a web page, a document, or a tool's output. The agent reads the content, follows the embedded instruction, accesses your credentials, and sends them to an attacker-controlled endpoint. No malware binary. No exploit code. Just text the model interprets as instructions.

## Claude Code: CVEs and Attack Vectors

On February 25, 2026, Check Point Research disclosed critical vulnerabilities in Claude Code, Anthropic's command-line AI development tool used by thousands of developers to write code, manage Git repositories, and automate builds.

### CVE-2025-59536 (CVSS 8.7) -- Configuration Injection / RCE

Two configuration injection flaws:

- **Hooks injection:** Claude Code's Hooks feature runs predefined shell commands at specific lifecycle events (before sending a message, after receiving a response). By injecting a malicious Hook into the `.claude/settings.json` file within a repository, an attacker gains remote code execution the moment a developer opens the project. The command runs before the trust dialog appears on screen.
- **MCP consent bypass:** Claude Code uses `.mcp.json` to configure which MCP servers a project connects to. That file is version-controlled. Check Point found that two repository-controlled settings could override safeguards and auto-approve all MCP servers, triggering execution on launch without user confirmation.

### CVE-2026-21852 (CVSS 5.3) -- API Key Theft

Claude Code communicates with Anthropic's cloud services using an API key transmitted in every request. The `ANTHROPIC_BASE_URL` environment variable controls where those requests go. It can be overridden in the project configuration. By redirecting it to a proxy, an attacker captures the full authorisation header, including the plaintext API key, before the user ever sees a trust prompt.

In environments using Anthropic's Workspaces feature, where multiple API keys share access to cloud-stored project files, a single stolen key exposes the entire team's data.

### Key Takeaway

`.claude/settings.json` and `.mcp.json` are no longer configuration files -- they are execution vectors. They look like metadata. They function as installers. This applies to every AI coding tool that processes repository-level configuration, not just Claude Code.

All three flaws were patched in Claude Code 2.0.65+. The disclosure timeline stretches from July 2025 to January 2026.

## OpenClaw / ClawHavoc: AI Agent Supply Chain Attack

The OpenClaw malicious skills crisis represents the largest confirmed supply chain attack targeting AI agent infrastructure to date.

- **1,184 malicious skills** confirmed across ClawHub (Antiy CERT, 2026) -- approximately one in five packages in the ecosystem.
- **135,000 OpenClaw instances** exposed to the public internet with insecure defaults (SecurityScorecard).
- **Nine CVEs disclosed**, three with public exploit code.

### CVE-2026-25253 and Related OpenClaw CVEs

Attack techniques mirror traditional software supply chain attacks: typosquatting, automated mass uploads, social engineering through fake error messages. The critical difference is privilege. A compromised dependency in a web application runs in a sandboxed runtime. A compromised AI agent skill runs with whatever permissions the agent has been granted: terminal access, file system access, and stored credentials for cloud services.

Endor Labs noted that traditional static application security testing (SAST) tools cannot identify issues in LLM-to-tool communication flows, conversation state management, or agent-specific trust boundaries (Infosecurity Magazine, 2026).

ClawHub is the first AI agent registry to be systematically poisoned. It will not be the last.

## MCP Server Exposure

### Scale of Exposure

- **7,000+ MCP servers** analysed by BlueRock Security; **36.7% potentially vulnerable to SSRF** (Security Boulevard, 2026).
- **8,000+ MCP servers** on the public internet (r/cybersecurity scanning results, February 2026).
- **492 MCP servers** with zero client authentication and zero traffic encryption (Trend Micro, 2026).
- Exposed servers with admin panels, debug endpoints, and API routes accessible without credentials (Bitsight, 2026).

### MCP Server CVEs

**Anthropic's Git MCP Server** (Cyata / Yarden Porat, January 20, 2026):

| CVE | Type | Impact |
|-----|------|--------|
| CVE-2025-68143 | Path traversal | Arbitrary file read |
| CVE-2025-68144 | Argument injection | Command execution |
| CVE-2025-68145 | Repository scoping bypass | Cross-repo access |

The exploit achieved remote code execution through prompt injection alone (Dark Reading, 2026). If Anthropic's reference implementation had these flaws, every third-party MCP server built with fewer resources should be treated as suspect.

### BlueRock SSRF Proof of Concept

Against Microsoft's MarkItDown MCP server, researchers retrieved AWS IAM access keys, secret keys, and session tokens from an EC2 instance's metadata endpoint. A single misconfigured MCP server became a gateway to cloud infrastructure.

### CoSAI MCP Threat Taxonomy (January 2026)

The Coalition for Secure AI (CoSAI) released a comprehensive MCP Security whitepaper mapping **12 core threat categories** and **nearly 40 distinct threats**. Three stand out in practice:

- **Tool poisoning:** An attacker modifies an MCP tool's description so the AI model misinterprets what it does. The model thinks it is calling a search function. The tool exfiltrates data.
- **Confused deputy:** The MCP server executes actions using its own elevated privileges rather than the requesting user's. A user without database admin access asks the agent to run a query. The server, which does have admin access, complies without checking.
- **Overprivileged tokens:** MCP servers store credentials such as API keys and database passwords in plaintext configuration files. Every client connecting to that server inherits the same privileged access.

### Root Cause

Default configurations that bind to all network interfaces (`0.0.0.0`) rather than localhost (`127.0.0.1`). Developers deploy MCP servers as if they are internal tools, but the defaults expose them to the world.

## AI-Assisted Pentesting: Kali Linux + MCP

On February 25, 2026, the Kali Linux team published an official guide connecting Claude AI to a Kali environment via MCP. Architecture: Claude Desktop on macOS as the interface, Claude Sonnet 4.5 in the cloud as the AI engine, and a Kali instance running `mcp-kali-server` via Flask on localhost:5000. Communication runs over SSH with key-based authentication.

Hassan Aftab documented completing a full web application assessment in roughly 15 minutes -- a task he estimated at two to three hours manually.

**Security concern:** All reconnaissance data -- target IPs, open ports, vulnerability findings -- routes through Anthropic's cloud-hosted model. For engagements with strict data handling requirements, that may violate client agreements. When you wire a general-purpose LLM into a privileged execution environment, prompt injection stops being a text output problem and becomes a command execution problem.

Missing controls: execution sandboxing, granular audit logging, and output validation before action. Those gaps apply to any MCP-based workflow where the AI agent has command execution authority.

## Anthropic Supply Chain Risk Designation

On February 27, 2026, the Pentagon designated Anthropic a "supply chain risk" -- the first time an American company has received a classification normally reserved for foreign adversaries like Huawei (CBS News, 2026). President Trump ordered all federal agencies to cease using Anthropic technology within six months.

Anthropic recently stated that eight of the ten largest US companies use Claude. Many hold government contracts. Palantir, which powers its most sensitive military applications with Claude, now needs alternatives. CNN reported the Pentagon acknowledged replacing Claude would be a significant effort since it is the only AI model deployed on classified military networks.

**Three risk scenarios to evaluate:**

1. **Vendor concentration.** If your security toolchain, coding workflows, or automation pipelines depend on a single AI provider, access can be disrupted overnight.
2. **Compliance exposure.** If you hold US government contracts and use Claude-powered tools anywhere in your workflows, verify whether the designation applies.
3. **Contingency planning.** Document which workflows depend on which AI providers. Identify where a provider becoming unavailable creates operational gaps. AI vendor relationships are now part of your threat surface.

## Why Existing Security Tools Miss AI Agent Attacks

Cisco's State of AI Security 2026 found that while most organisations planned to deploy agentic AI, **only 29% reported being prepared to secure those deployments**.

Traditional endpoint detection and response (EDR) tools look for malicious binaries, suspicious process behaviour, and known indicators of compromise. AI agent attacks have none of these. The "exploit" is text. The "payload" is a natural language instruction. The "delivery mechanism" is a document, a web page, or a tool output that the agent processes as part of its normal workflow.

Johann Rehberger (Embrace The Red) published one prompt injection vulnerability per day throughout August 2025, each demonstrating a different way to make an AI agent perform unintended actions through crafted text inputs. Simon Willison called it "The Summer of Johann."

The closest parallel is the early cloud security gap. Organisations deployed cloud services before understanding the shared responsibility model. AI agent security is at the same inflection point, but with a compressed timeline because adoption is moving faster.

## Practitioner Hardening Framework

### Discovery and Inventory

Query endpoints for OpenClaw, Claude Code, Cursor, and other agent tools. Scan your network for common MCP endpoints (`/mcp`, `/sse`) and check for `0.0.0.0` bindings. Audit installed skills, MCP server configurations, and IDE extensions. Snyk's `mcp-scan` tool covers both MCP servers and agent skills.

### Authentication and Least Privilege

Never expose MCP servers without authentication. The specification recommends OAuth 2.1. At minimum, enforce token-based auth on all client-server connections. Bind servers to `127.0.0.1` unless remote access is explicitly required. Scope each server's permissions to only the resources its tools need.

### Configuration as Code

The Claude Code CVEs proved that `.claude/settings.json` and `.mcp.json` are execution vectors. Add agent configuration paths to your code review process. Block auto-approval settings for MCP servers. Pin and verify MCP server package versions with the same rigour you apply to any software dependency.

### Behavioural Monitoring

Log all MCP tool invocations: every request from client to server, every action the server takes. Alert on credential access patterns. If an agent or skill touches `.env` files, credential stores, or API key directories, that is investigable. Treat all data returned by MCP servers as untrusted input -- sanitise before it reaches the model.

### Governance Updates

AI Acceptable Use Policies need agent-specific language. An agent with terminal access and stored credentials is not the same risk profile as a chatbot in a browser tab. Include AI agents in your threat model. Map AI vendor dependencies.

## Disclosure Timeline

| Date | Event |
|------|-------|
| 2024-11 | Anthropic releases MCP as open standard |
| 2025-06 | Simon Willison identifies the "lethal trifecta" for AI agents |
| 2025-07 to 2026-01 | Check Point Research disclosure timeline for Claude Code CVEs |
| 2025-08 | Johann Rehberger's daily prompt injection disclosures ("The Summer of Johann") |
| 2026-01-20 | Cyata publishes exploit chain against Anthropic's Git MCP server (CVE-2025-68143, -68144, -68145) |
| 2026-01 | CoSAI releases MCP Security whitepaper (12 threat categories, ~40 threats) |
| 2026-02 | Antiy CERT confirms 1,184 malicious skills on ClawHub (ClawHavoc campaign) |
| 2026-02 | SecurityScorecard finds 135,000 exposed OpenClaw instances |
| 2026-02 | Trend Micro reports 492 MCP servers with zero auth, zero encryption |
| 2026-02 | Scanning results identify 8,000+ MCP servers on public internet |
| 2026-02-25 | Check Point publishes Claude Code CVE-2025-59536 and CVE-2026-21852 |
| 2026-02-25 | Kali Linux publishes official MCP pentesting guide |
| 2026-02-27 | Pentagon designates Anthropic a "supply chain risk" |

## CVE Index

| CVE | Product / Component | CVSS | Type |
|-----|---------------------|------|------|
| CVE-2025-59536 | Claude Code (Hooks + MCP consent) | 8.7 | Configuration injection / RCE |
| CVE-2026-21852 | Claude Code (API key via ANTHROPIC_BASE_URL) | 5.3 | Credential theft |
| CVE-2026-25253 | OpenClaw (+ 8 additional CVEs) | -- | Supply chain / malicious skills |
| CVE-2025-68143 | Anthropic Git MCP Server | -- | Path traversal |
| CVE-2025-68144 | Anthropic Git MCP Server | -- | Argument injection |
| CVE-2025-68145 | Anthropic Git MCP Server | -- | Repository scoping bypass |

## Statistics

- **1,184** malicious skills confirmed on ClawHub (~1 in 5 packages)
- **135,000** OpenClaw instances exposed to public internet
- **8,000+** MCP servers on public internet
- **492** MCP servers with zero authentication or encryption
- **36.7%** of 7,000+ MCP servers vulnerable to SSRF
- **29%** of organisations prepared to secure agentic AI deployments (Cisco, 2026)
- **75%** of organisations hit by software supply chain attacks in one year (BlackBerry, 2024)
- **30%** of all data breaches from third-party breaches (Verizon DBIR, 2025)
- **63%** of breached organisations lacked AI governance policies (IBM Security, 2025)

## References

- **Check Point Research** (Donenfeld, A. & Vanunu, O.). (2026). *Caught in the Hook: RCE and API Token Exfiltration Through Claude Code Project Files*. CVE-2025-59536 (CVSS 8.7) and CVE-2026-21852 (CVSS 5.3).
- **Antiy CERT.** (2026). *ClawHavoc Campaign Analysis*. Trojan/OpenClaw.PolySkill classification.
- **Trend Micro.** (2026). *MCP Security: Network-Exposed Servers Are Backdoors to Your Private Data*.
- **Bitsight.** (2026). *Exposed MCP Servers Reveal New AI Vulnerabilities*.
- **BlueRock Security / Security Boulevard** (Burt, J.). (2026). *Anthropic, Microsoft MCP Server Flaws Shine a Light on AI Security Risks*.
- **Cyata** (Porat, Y.) / **Dark Reading.** (2026). *Microsoft & Anthropic MCP Servers at Risk of RCE, Cloud Takeovers*.
- **Coalition for Secure AI (CoSAI).** (2026). *Model Context Protocol (MCP) Security White Paper*.
- **Cisco.** (2026). *State of AI Security 2026*.
- **Kali Linux.** (2026). *Kali & LLM: macOS with Claude Desktop GUI & Anthropic Sonnet LLM*.
- **Penligent AI.** (2026). *Kali Linux + Claude via MCP Is Cool, But It's the Wrong Default for Real Pentesting Teams*.
- **Palo Alto Networks.** (2026). *MCP Security Exposed: What You Need to Know Now*.
- **SecurityScorecard STRIKE Team.** (2026). *Beyond the Hype: Moltbot's Real Risk Is Exposed Infrastructure*.
- **CBS News** (Frias, L.). (2026). *Hegseth Declares Anthropic a Supply Chain Risk*.
- **NPR.** (2026). *OpenAI Announces Pentagon Deal After Trump Bans Anthropic*.
- **Infosecurity Magazine.** (2026). *Researchers Reveal Six New OpenClaw Vulnerabilities*.
- **Red Hat.** (2025). *Model Context Protocol (MCP): Understanding Security Risks and Controls*.
- **OWASP.** (2025). *Top 10 for LLM Applications*.
- **BlackBerry.** (2024). *Global Threat Intelligence Report*.
- **Verizon.** (2025). *Data Breach Investigations Report*.
- **IBM Security.** (2025). *Cost of a Data Breach Report 2025*.
