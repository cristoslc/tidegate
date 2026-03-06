# Tideclaw — MCP & Skills Security Landscape (2025-2026)

> Supporting document for [(SPIKE-013) Tideclaw Architecture](./(SPIKE-013)-Tideclaw-Architecture.md).

---

## MCP Security Landscape

### Authorization (spec evolution)
Three major spec revisions since March 2025:
- **2025-03-26**: OAuth 2.1 introduced. MCP servers were both Resource Server and Authorization Server (bad).
- **2025-06-18**: Decoupled. Servers are OAuth Resource Servers. Resource Indicators (RFC 8707) mandatory — tokens scoped to specific MCP servers, preventing cross-server replay. SSE deprecated → Streamable HTTP.
- **2025-11-25**: Client ID Metadata Documents (CIMD) replace Dynamic Client Registration. Enterprise-Managed Auth via Identity Assertion Authorization Grant (XAA). OpenID Connect Discovery. Incremental scope consent.

### Security incidents (real-world)
| Incident | Impact | Relevance |
|----------|--------|-----------|
| **Postmark-MCP supply chain** (Sep 2025) | Backdoored npm package BCC'd all emails to attackers. 1,500 weekly downloads. | Tideclaw's response scanning catches credential patterns in outbound email content. |
| **Smithery supply chain** (Oct 2025) | Path-traversal in build config exfiltrated API tokens from 3,000+ hosted apps. | Tideclaw isolates credentials in MCP server containers — even compromised servers can't leak other servers' credentials. |
| **mcp-remote RCE** (CVE-2025-6514) | Command injection via malicious `authorization_endpoint`. CVSS 9.6. 437,000+ downloads. Featured in official Cloudflare/Auth0 guides. | Tideclaw's gateway doesn't process OAuth metadata URLs — downstream servers handle their own auth. |
| **Claude Desktop Extensions RCE** (CVSS 10.0) | Malicious MCP responses → remote code execution. Zero user interaction. | Tideclaw's response scanning catches payloads before they reach the agent. |
| **GitHub MCP prompt injection** | Malicious GitHub issue hijacked agent, exfiltrated private repos via over-privileged PAT. | Tideclaw's credential isolation: PAT lives in MCP server container, not agent. Agent can't access it even when compromised. |

### Tool poisoning
- 5.5% of public MCP servers contain tool poisoning vulnerabilities
- 43% of public servers contain command injection flaws
- 84.2% attack success rate with auto-approval enabled
- Tool poisoning works even if the tool is never called — just being loaded into context is enough
- **Rug pulls**: Tool behavior changes silently after initial approval
- **MCP shadowing**: Malicious server redefines tool descriptions of already-loaded trusted servers

### Elicitation (new data channel)
Introduced in 2025-06-18 spec. MCP servers can request user input via `elicitation/create`:
- **Form mode**: Structured data collection (strings, numbers, booleans, enums). Data returned directly.
- **URL mode** (2025-11-25): Server provides URL for user to visit externally. Used for OAuth, payments. **Potential phishing vector.**
- **Implication for Tideclaw**: The gateway should scan/audit elicitation requests. URL mode elicitations could be used for social engineering.

### Ecosystem scale
- 13,000+ MCP servers on GitHub (2025)
- 8 million+ total downloads (up from 100K in Nov 2024 — 80x in 5 months)
- ~7,000 servers exposed on open web; ~1,800 without authentication
- Docker MCP Catalog hosts 270+ enterprise-grade servers

### Key gap
**MCP has no built-in concept of a security gateway between client and server.** The spec's security model is client-side consent (user approves tool calls). This fails when the agent runs headless with `--dangerously-skip-permissions`. Tideclaw fills this gap with server-side policy enforcement.

---

## The Skills Paradigm (2025-2026)

Skills are an emerging extension paradigm **complementary to MCP** that Tideclaw must account for alongside tool-level scanning. While MCP provides connectivity (structured tool APIs for accessing external systems), Skills provide expertise (natural-language instructions encoding domain knowledge and workflow logic). Both are attack surfaces. Tideclaw's original architecture over-indexed on MCP as the sole extension mechanism — the reality is that modern agentic runtimes have two extension planes: **tools (MCP)** and **knowledge (Skills)**.

### What are Skills?

A skill is a folder containing a `SKILL.md` file with YAML frontmatter (name, description, allowed-tools) and a markdown body of instructions. Optional subfolders hold scripts, references, and assets. Skills teach agents *how* to perform tasks using the tools they have access to.

**Progressive disclosure** is the key architectural feature: at session start, only skill name + description load (~50 tokens per skill). The full SKILL.md body (~5,000 tokens) loads on demand when the agent determines relevance. Compare this to MCP, where a typical 5-server setup consumes ~55,000 tokens upfront to load all tool definitions.

### Agent Skills open standard (Dec 2025)

Anthropic released Agent Skills as an open standard at agentskills.io in December 2025. Adoption was rapid:
- **40+ agents** adopted the SKILL.md format within weeks: Claude Code, Codex CLI, Gemini CLI, GitHub Copilot, Cursor, Windsurf, Goose, Roo Code, Trae, Amp, and more.
- **Vercel's skills.sh** (launched Jan 20, 2026): Package manager and registry. 110,000+ installs in four days across 17 agents. Snyk security scans on every install.
- **96,000+ skills** in circulation across marketplaces (skills.sh, ClawHub/OpenClaw, SkillsMP) as of Feb 2026.

Before the standard, each tool had its own approach: Cursor `.cursor/rules/*.mdc`, Windsurf `.windsurfrules`, GitHub Copilot `.github/copilot-instructions.md`, Aider `.aider.conventions`. The Agent Skills standard unifies these under a single portable format.

### Skills vs MCP: complementary, not competing

| Dimension | Skills | MCP |
|-----------|--------|-----|
| **What it provides** | Procedural knowledge (how to do things) | Tool connectivity (what can be reached) |
| **Format** | Natural language markdown | Structured JSON-RPC protocol |
| **Token cost** | ~50 tokens at rest, ~5,000 when active | ~55,000 tokens for typical 5-server setup |
| **Who can author** | Anyone who can write markdown | Developers who implement servers |
| **Portability** | Works across 40+ agents via open standard | Requires client/server implementation |
| **Security surface** | Prompt injection, memory poisoning, supply chain | Tool poisoning, RCE, supply chain |
| **Relationship** | Consumes MCP tools | Consumed by Skills |

A single skill can orchestrate multiple MCP servers (e.g., a "deploy" skill coordinating GitHub, Docker, and AWS MCP servers). A single MCP server can support dozens of skills. The full extension stack: CLAUDE.md (always-on context) → Skills (on-demand expertise) → MCP (external connections) → Hooks (guaranteed automation) → Plugins (packaging layer).

### Skills security: a new attack surface

Skills represent a **distinct and serious security surface** that pattern scanning alone cannot address:

**ClawHavoc campaign (Jan 2026)**: Security audit of ClawHub found 341 malicious skills (~12% of registry) delivering Atomic Stealer (AMOS), a macOS infostealer. Professional documentation, names like "solana-wallet-tracker" and "youtube-summarize-pro." Target: exchange API keys, wallet private keys, SSH credentials, browser passwords.

**Snyk ToxicSkills study (Feb 2026)**: Scanning 3,984 skills from ClawHub and skills.sh:
- **13.4% (534 skills)** contain critical-level security issues (malware, prompt injection, exposed secrets)
- **36.82% (1,467 skills)** have at least one security flaw
- 36% contain prompt injection
- Snyk demonstrated going "from SKILL.md to shell access in three lines of markdown"

**Key attack vectors**:
1. **SKILL.md as code execution**: Natural-language instructions that result in shell commands, inheriting the agent's access. Traditional AppSec tools don't scan markdown for intent.
2. **Memory poisoning**: Adversaries implant false information into agent long-term storage. Unlike session-scoped prompt injection, poisoned memory persists across sessions.
3. **Supply chain poisoning**: Malicious skills published to registries with professional documentation. Same class of attack as npm/PyPI malware, adapted for AI skill ecosystems.
4. **The "lethal trifecta"**: Skills are dangerous because agents combine access to private data + exposure to untrusted content + ability to communicate externally.

**Why existing scanners fail**: Community skill scanners using denylist approaches are fundamentally flawed — you cannot block specific words in a system designed to understand concepts. Snyk found that a malicious skill received a verdict of CLEAN while the scanner itself was flagged as DANGEROUS.

### Implications for Tideclaw

Tideclaw's original architecture focuses on three enforcement layers: taint tracking (L1), MCP gateway scanning (L2), and egress proxy scanning (L3). **Skills introduce a fourth attack surface that none of these layers address directly:**

1. **L2 (MCP gateway)** catches malicious tool call parameters — but a poisoned skill can instruct the agent to craft tool calls that *look legitimate* while exfiltrating data. The parameters may not contain credential patterns; the *intent* is malicious.
2. **L3 (egress proxy)** catches unauthorized network destinations — but a poisoned skill can instruct the agent to exfiltrate data through *allowed* channels (e.g., committing sensitive data to a GitHub repo the agent has write access to).
3. **L1 (taint tracking)** catches file-to-network data flows — this layer *does* help, because taint tracking is intent-agnostic. If a skill causes the agent to read a sensitive file and then make a network call, the taint tracker fires regardless of whether the skill instructed it.

**New enforcement seam needed**: Skill vetting/scanning before load. Options:
- **(a) Static analysis of SKILL.md at load time**: Scan skill instructions for known malicious patterns (exfiltration instructions, credential harvesting, persistence mechanisms). Integrate with Snyk agent-scan or similar.
- **(b) Skill allowlisting**: Tideclaw config specifies which skills are permitted. Unknown skills are blocked or require approval.
- **(c) Skill isolation**: Run skills in separate context/subagent with restricted tool access (the `allowed-tools` frontmatter field enables this, but enforcement is runtime-dependent).
- **(d) All of the above** (recommended for defense in depth).

This is a **Phase 3 concern** (hardening), not MVP. But the architecture should anticipate it now.
