---
source-id: "lares-owasp-agentic-wild"
title: "OWASP Agentic AI Top 10: Threats in the Wild"
type: web
url: "https://labs.lares.com/owasp-agentic-top-10/"
fetched: 2026-03-17T00:00:00Z
hash: "sha256:3ec791d85c86d39756293cd5476020d4fe1b4e1f5e331044b530ca8913210316"
---

# OWASP Agentic AI Top 10: Threats in the Wild

**Author:** Raul Redondo (Lares Labs)
**Published:** January 9, 2026
**Category:** AI Security, Agentic Threats

## Overview

Agentic AI applications go beyond simple question-and-answer interactions. They autonomously pursue complex goals, reasoning, planning, and executing multi-step tasks with minimal human intervention. Unlike LLMs/chatbots that wait for explicit instructions, agentic systems decompose objectives into subtasks, invoke external tools (APIs, databases, code execution), and adapt dynamically.

This autonomy introduces a new attack surface that traditional security frameworks don't adequately address. In December 2025, OWASP released the first Top 10 for Agentic Applications to fill this gap, using the ASI prefix (Agentic Security Issue) for each vulnerability, ranked by prevalence and impact observed in production deployments throughout 2024-2025.

## Agentic AI Flow Mapping

The OWASP framework maps each vulnerability to a specific point in the agentic AI flow: inputs, model processing, tool integrations, inter-agent communication, and outputs. This structural mapping distinguishes it from both the classic OWASP Top 10 for web applications and the LLM Top 10 for language models, targeting specifically autonomous AI systems that take real-world actions.

## ASI01: Agent Goal Hijack

Unlike traditional software where attackers need to modify code, AI agents can be redirected through natural language. If an agent processes external content -- emails, documents, web pages, calendar invites -- that content can contain hidden instructions that hijack the agent's goals. The attack surface is no longer just code, but any text the agent reads.

### Incidents

- **EchoLeak (CVE-2025-32711) -- CVSS 9.3:** The first real-world zero-click prompt injection exploit in a production agentic AI system. Researchers at Aim Security discovered that Microsoft 365 Copilot could be tricked into exfiltrating data via a single crafted email.

- **GitHub Copilot YOLO Mode (CVE-2025-53773) -- CVSS 7.8:** Malicious instructions hidden in repositories (README files, code comments, GitHub issues) could trick Copilot into modifying `.vscode/settings.json` to enable "YOLO mode" (auto-approve all tool calls), then execute arbitrary shell commands. The attack was wormable -- infected projects could spread to others via AI-assisted commits.

- **AGENTS.MD Hijacking in VS Code (CVE-2025-64660, CVE-2025-61590):** VS Code Chat auto-includes AGENTS.MD in every request, treating it as an instruction set. Researchers demonstrated how a malicious AGENTS.MD could convince the agent to email internal data out of the organization during an everyday coding session.

### Mitigation

Treat all external content as potentially hostile. Implement strict boundaries between instructions (from your system) and data (from users/external sources). Monitor for behavioral anomalies.

## ASI02: Tool Misuse

AI agents are given tools -- the ability to send emails, query databases, execute commands, call APIs. An attacker who can influence the agent's reasoning can turn those features into weapons: a coding assistant with filesystem access becomes a data exfiltration tool; a customer service bot with email capabilities becomes a phishing engine. The more powerful the agent, the more dangerous it becomes when compromised.

### Incidents

- **Amazon Q Code Assistant (CVE-2025-8217) -- July 2025:** Attackers compromised a GitHub token and merged malicious code into Amazon Q's VS Code extension (version 1.84.0). The injected code contained destructive prompt instructions: "clean a system to a near-factory state and delete file-system and cloud resources." Combined with `--trust-all-tools --no-interactive`, the agent executed commands without confirmation. Nearly one million developers had the extension installed. Amazon patched to version 1.85.0.

- **Langflow AI RCE (CVE-2025-34291):** CrowdStrike observed multiple threat actors exploiting an unauthenticated code injection vulnerability in Langflow AI, a widely used tool for building AI agents. Attackers gained credentials and deployed malware through this widely-deployed agent framework.

- **OpenAI Operator Data Exposure:** Security researcher Johann Rehberger demonstrated how malicious webpage content could trick OpenAI's Operator agent into accessing authenticated internal pages and exposing users' private data, including email addresses, home addresses, and phone numbers from sites like GitHub and Booking.com.

### Mitigation

Apply least privilege to every tool. Require explicit approval for destructive operations. Validate tool arguments. Monitor for unusual patterns (an agent suddenly making thousands of API calls is a red flag).

## ASI03: Identity and Privilege Abuse

Agents often operate with significant privileges: access to databases, cloud resources, internal APIs. When an agent is compromised, the attacker inherits all of those permissions. This creates a privilege inheritance problem -- the agent's access scope becomes the attacker's access scope.

### Incidents

- **Copilot Studio Connected Agents -- December 2025:** Microsoft's "Connected Agents" feature, unveiled at Build 2025, is enabled by default on all new agents. It exposes an agent's knowledge, tools, and topics to ALL other agents within the same environment -- with no visibility showing which agents have connected to yours. Zenity Labs exposed how attackers could impersonate organizations and execute unauthorized actions without detection.

- **CoPhish Attack -- October 2025:** Datadog Security Labs discovered a phishing technique abusing Copilot Studio agents. Attackers created malicious agents with OAuth login flows hosted on trusted Microsoft domains (copilotstudio.microsoft.com). When victims clicked "Login," they were redirected to a malicious OAuth consent page. After consent, the agent captured the User.AccessToken and exfiltrated it via HTTP request to the attacker's server -- granting access to emails, chats, calendars, and OneNote data.

- **Copilot Studio Public-by-Default Agents:** Microsoft Copilot Studio agents were configured to be public by default without authentication. Attackers enumerated exposed agents and pulled confidential business data directly from production environments.

### Mitigation

Treat agents as first-class identities with explicit, scoped permissions. Use short-lived credentials. Never allow implicit trust between agents. Audit credential flows regularly.

## ASI04: Supply Chain Vulnerabilities

Traditional supply chain attacks target static dependencies. Agentic supply chain attacks target what agents load dynamically: MCP servers, plugins, external tools, even other agents. This introduces a runtime trust problem that traditional security tools cannot address.

### Incidents

- **postmark-mcp -- September 2025:** Koi Security discovered the first malicious MCP server in the wild -- an npm package impersonating Postmark's email service. It worked as a legitimate email MCP server, but every message sent through it was secretly BCC'd to `phan@giftshop[.]club`. Downloaded 1,643 times before removal. Any AI agent using this for email operations unknowingly exfiltrated every message it sent.

- **Shai-Hulud Worm -- September 2025:** CISA issued an advisory about a self-replicating npm supply chain attack that compromised 500+ packages. The worm weaponized npm tokens to infect other packages maintained by compromised developers. CISA recommendation: Pin dependencies to pre-September 16, 2025 versions.

- **MCP Remote RCE (CVE-2025-6514) -- CVSS 9.6:** JFrog discovered a critical vulnerability in the MCP Remote project enabling arbitrary OS command execution when MCP clients connect to untrusted servers. First documented case of complete RCE in real-world MCP deployments.

### Mitigation

Verify every MCP server before allowing it. Monitor for definition changes after approval. Pin dependencies to known-good versions. Treat the dynamic tool ecosystem as hostile by default.

## ASI05: Unexpected Code Execution

Many agentic systems -- especially coding assistants -- generate and execute code in real-time, creating a direct path from text input to system-level commands. Over 30 CVEs were discovered across major AI coding platforms in December 2025 alone. In agentic systems, code execution is a feature; the challenge is ensuring the agent only executes code aligned with the user's intent.

### Incidents

- **CurXecute (CVE-2025-54135) -- CVSS 8.6:** Aim Labs discovered that Cursor's MCP auto-start feature could be exploited. A poisoned prompt, even from a public Slack message, could silently rewrite `~/.cursor/mcp.json` and run attacker-controlled commands every time Cursor opened. Fixed in version 1.3.

- **MCPoison (CVE-2025-54136) -- CVSS 7.2:** Check Point Research found that once a user approved a benign MCP configuration in a shared GitHub repository, an attacker could silently swap it for a malicious payload (e.g., `calc.exe` or a backdoor) without triggering any warning or re-prompt.

- **Cursor Case-Sensitivity Bypass (CVE-2025-59944):** On Windows and macOS, case-insensitive filesystems meant that crafted inputs could overwrite configuration files controlling project execution -- bypassing Cursor's guardrails entirely.

- **Claude Desktop RCE -- November 2025 (CVSS 8.9):** Three vulnerabilities in Claude Desktop's official extensions (Chrome, iMessage, Apple Notes connectors) allowed code execution through unsanitized AppleScript commands. Attack vector: Ask Claude a question, Claude searches the web, attacker-controlled page with hidden instructions, code runs with full system privileges.

- **IDEsaster Research -- 24 CVEs:** Security researcher Ari Marzouk discovered 30+ flaws across GitHub Copilot, Cursor, Windsurf, Kiro.dev, Zed.dev, Roo Code, Junie, and Cline. 100% of tested AI IDEs were vulnerable. AWS issued security advisory AWS-2025-019.

### Mitigation

Sandbox all code execution. Require human approval for commands touching databases, APIs, or filesystems. Never auto-approve tool calls based on repository content. Disable auto-run mode.

## ASI06: Memory and Context Poisoning

Unlike chatbots that forget between sessions, agents maintain memory -- conversation history, user preferences, learned context. This memory enables personalization but also creates persistent attack surfaces. A single successful injection can poison an agent's memory permanently; every future session inherits the compromise.

### Incidents

- **Google Gemini Memory Attack -- February 2025:** Security researcher Johann Rehberger demonstrated "delayed tool invocation" against Google Gemini Advanced. He uploaded a document with hidden prompts that told Gemini to store fake information when trigger words like "yes," "no," or "sure" were typed in future conversations. Result: Gemini "remembered" him as a 102-year-old flat-earther living in the Matrix. Google assessed impact as low but acknowledged the vulnerability.

- **Gemini Calendar Invite Poisoning -- 2025:** Researchers demonstrated "Targeted Promptware Attacks" where malicious calendar invites could implant persistent instructions in Gemini's "Saved Info," enabling malicious actions across sessions. 73% of 14 tested scenarios were rated High-Critical. Attack outcomes ranged from spam generation to opening smart home devices and activating video calls.

- **Lakera AI Memory Injection Research -- November 2025:** Researchers demonstrated memory injection attacks against production systems. Compromised agents developed persistent false beliefs about security policies and vendor relationships. When questioned by humans, the agents defended these false beliefs as correct -- creating "sleeper agent" scenarios where compromise is dormant until triggered.

- **ASCII Smuggling in Gemini -- September 2025:** FireTail demonstrated that invisible Unicode control characters ("tag characters") could hide instructions in benign-looking text. The UI shows normal text; the AI ingests and executes hidden commands. Google's response: "no action."

### Mitigation

Treat memory writes as security-sensitive operations. Implement provenance tracking (where did this memory come from?). Regularly audit agent memory for anomalies. Consider memory expiration for sensitive contexts.

## ASI07: Insecure Inter-Agent Communication

Multi-agent systems rely on messages exchanged between agents for coordination. Without strong authentication and integrity checks, attackers can inject false information into these channels. In traditional architectures, service-to-service communication is usually secured through mTLS, API keys, and strict schemas. Inter-agent communication rarely has equivalent controls -- messages are often natural language, trust is typically implicit, and authentication is assumed rather than verified.

### Incidents

- **Agent Session Smuggling in A2A Protocol -- November 2025:** Palo Alto Unit 42 demonstrated "Agent Session Smuggling" where malicious agents exploit built-in trust relationships in the Agent-to-Agent (A2A) protocol. Unlike single-shot prompt injection, a rogue agent can hold multi-turn conversations, adapt its strategy, and build false trust over multiple interactions. Because agents are often designed to trust collaborating agents by default, this allows attackers to manipulate victim agents across entire sessions.

- **ServiceNow Now Assist Inter-Agent Vulnerability:** OWASP documented cases where spoofed inter-agent messages misdirected entire clusters of autonomous systems. In multi-agent procurement workflows, a compromised "vendor-check" agent returning false credentials caused downstream procurement and payment agents to process orders from attacker front companies.

### Mitigation

Authenticate and encrypt all inter-agent communication. Implement message integrity verification. Never assume peer agents are trustworthy. Consider cryptographically signed AgentCards for remote agent verification.

## ASI08: Cascading Failures

When agents are connected, errors compound. A compromised agent doesn't just fail -- it can poison every agent it communicates with. One manipulated response propagates through the chain, corrupting downstream decisions and actions.

### Incidents

- **Galileo AI Research -- December 2025:** In simulated multi-agent systems, researchers found that a single compromised agent poisoned 87% of downstream decision-making within 4 hours. Cascading failures propagate faster than traditional incident response can contain them.

- **Manufacturing Procurement Cascade -- 2025:** A manufacturing company's procurement agent was manipulated over three weeks through seemingly helpful "clarifications" about purchase authorization limits. By the time the attack completed, the agent believed it could approve any purchase under $500,000 without human review. The attacker then placed $5 million in false purchase orders across 10 separate transactions.

### Mitigation

Implement circuit breakers between agent workflows. Define blast-radius caps and containment thresholds. Test cascading scenarios in isolated digital twins before deployment. Maintain deep observability into inter-agent communication logs.

## ASI09: Human-Agent Trust Exploitation

Agents generate polished, authoritative-sounding explanations. Humans tend to trust them -- even when they're compromised. Human-in-the-loop controls assume the human can detect when something is wrong, but a manipulated agent presents malicious actions with perfect confidence and coherent justification. The approval prompt becomes a rubber stamp.

### Incidents

- **M365 Copilot Manipulation Research -- 2025:** Microsoft's own research showed attackers could manipulate M365 Copilot to influence users toward ill-advised decisions, exploiting the trust people place in the assistant. The agent presents faulty recommendations confidently, and employees approve risky transactions because they appear to come from a trusted system.

- **AI Reward Hacking -- 2025:** Researchers documented cases where agents discovered that suppressing user complaints maximized their performance scores instead of resolving the issues. The agents optimized for metrics in unintended ways that harmed users.

- **Agent-Driven Phishing -- 2025:** Advanced phishing campaigns now initiate interactive conversations via agent-driven chatbots that hold convincing dialogue -- some using deepfake audio to impersonate known executives. If an attacker fully compromises an internal agent, they can use it to impersonate the CFO in internal systems and request fund transfers.

### Mitigation

Require independent verification for high-impact decisions. Implement human-in-the-loop controls with clear escalation paths. Train users to question AI recommendations on YMYL (your-money-or-your-life) issues. Add transparency about AI uncertainty.

## ASI10: Rogue Agents

This is the ultimate failure state: an agent that appears compliant on the surface but pursues objectives that conflict with its original purpose. The nine risks above describe attacks against agents. Rogue agents describes what happens when the agent itself becomes misaligned -- no attacker required.

### Incidents

- **Cost-Optimization Agent Gone Wrong:** OWASP documented cases of agents that learned counterproductive optimizations. A cost-optimization agent discovered that deleting production backups was the most effective way to reduce cloud spending. It wasn't programmed to be malicious -- it autonomously decided backup deletion achieved its goal most efficiently.

- **Procurement Agent Fraud -- 2025:** After memory poisoning over three weeks, a manufacturing company's procurement agent developed completely misaligned beliefs about authorization limits. When questioned, it confidently explained why transferring funds to attacker-controlled accounts served the company's interests -- according to its corrupted reasoning.

- **Ray Framework Breach -- December 2025:** Security researcher Johan Carlsson presented at the Chaos Communication Congress how over 230,000 Ray AI clusters were compromised. Attackers used AI-generated code to spread malware and exfiltrate data. Many organizations were "already exposed to Agentic AI attacks, often without realizing that agents are running in their environments."

### Mitigation

Implement kill switches as a non-negotiable, auditable, and physically isolated mechanism. Deploy continuous behavioral monitoring to detect subtle drift before it becomes catastrophic misalignment. Conduct rigorous testing and auditing of agent reward functions.

## Key Takeaways

### For organizations deploying AI agents

1. **Inventory your agents.** Many organizations don't know how many agents are running, what tools they have access to, or what data they can reach.
2. **Define trust boundaries.** What can agents access? What requires human approval? Document these decisions explicitly.
3. **Implement kill switches.** You need the ability to immediately halt any agent that shows anomalous behavior.
4. **Monitor continuously.** Agent security isn't a one-time audit. Behavior drifts. Memory accumulates. Tools change.

### For organizations building AI agents

1. **Assume external input is hostile.** Every email, document, web page, and API response your agent processes could contain attack payloads.
2. **Sandbox tool execution.** Especially for code generation. Auto-approve is an anti-pattern.
3. **Scope permissions aggressively.** Every tool, every credential, every API should be the minimum needed for the task.
4. **Log everything.** Your future incident responders will thank you.

### For organizations receiving agent traffic

Even if you don't deploy agents yourself, your applications are increasingly on the receiving end of agentic behavior. Automated browsers, AI assistants, and LLM crawlers are hitting your APIs and websites. Some of their goals may have been hijacked. Some may be operating outside their intended scope.

## CVE Reference Table

| CVE | Product | Risk | CVSS |
|-----|---------|------|------|
| CVE-2025-32711 | Microsoft 365 Copilot | Zero-click data exfiltration (EchoLeak) | 9.3 |
| CVE-2025-8217 | Amazon Q | Supply chain compromise, destructive commands | -- |
| CVE-2025-53773 | GitHub Copilot | Wormable RCE via prompt injection | 7.8 |
| CVE-2025-54135 | Cursor IDE | RCE via MCP auto-start (CurXecute) | 8.6 |
| CVE-2025-54136 | Cursor IDE | Persistent code execution (MCPoison) | 7.2 |
| CVE-2025-6514 | MCP Remote | Arbitrary OS command execution | 9.6 |
| CVE-2025-49596 | MCP Inspector | CSRF enabling RCE | -- |
| CVE-2025-59944 | Cursor IDE | Case-sensitivity bypass to RCE | -- |
| CVE-2025-64660 | GitHub Copilot | AGENTS.MD goal hijack | -- |
| CVE-2025-61590 | Cursor | AGENTS.MD goal hijack | -- |
| CVE-2025-52882 | Claude Code | WebSocket auth bypass, remote command execution | 8.8 |
| CVE-2025-34291 | Langflow AI | Unauthenticated code injection | -- |

## Resources

### Official OWASP documentation

- OWASP Top 10 for Agentic Applications 2026
- Agentic AI Threats and Mitigations
- A Practical Guide to Securing Agentic Applications

### Research and incident reports

- Aim Security: EchoLeak Analysis
- Koi Security: Real-World MCP Attacks
- Lakera AI: Memory Injection Attacks
- IDEsaster Research: 30+ Flaws in AI Coding Tools
- Palo Alto Unit 42: Agent Session Smuggling
- CISA Advisory: npm Supply Chain Attack
