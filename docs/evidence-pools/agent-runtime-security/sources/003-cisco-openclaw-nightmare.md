---
source-id: "003"
title: "Personal AI Agents like OpenClaw Are a Security Nightmare"
type: web
url: "https://blogs.cisco.com/ai/personal-ai-agents-like-openclaw-are-a-security-nightmare"
fetched: 2026-03-15T00:00:00Z
hash: "sha256:pending"
---

# Personal AI Agents like OpenClaw Are a Security Nightmare

**Published:** 2026-01-28
**Authors:** Amy Chang, Vineeth Sai Narajala, Idan Habler (Cisco AI Threat and Security Research Team)
**Source:** Cisco Blogs

Over the past few weeks, Clawdbot (then renamed Moltbot, later renamed OpenClaw) has achieved virality as an open source, self-hosted personal AI assistant agent that runs locally and executes actions on the user's behalf. The bot's explosive rise is driven by several factors; most notably, the assistant can complete useful daily tasks like booking flights or making dinner reservations by interfacing with users through popular messaging applications including WhatsApp and iMessage.

OpenClaw also stores persistent memory, meaning it retains long-term context, preferences, and history across user sessions. Beyond chat functionalities, the tool can also automate tasks, run scripts, control browsers, manage calendars and email, and run scheduled automations. The broader community can add "skills" to the molthub registry which augment the assistant with new abilities.

## Key security risks

- OpenClaw can run shell commands, read and write files, and execute scripts on your machine. Granting an AI agent high-level privileges enables it to do harmful things if misconfigured or if a user downloads a skill injected with malicious instructions.
- OpenClaw has already been reported to have leaked plaintext API keys and credentials, which can be stolen by threat actors via prompt injection or unsecured endpoints.
- OpenClaw's integration with messaging applications extends the attack surface to those applications, where threat actors can craft malicious prompts causing unintended behavior.

Security for OpenClaw is an option, but it is not built in. The product documentation itself admits: "There is no 'perfectly secure' setup."

## Skill Scanner analysis

The Cisco AI Threat and Security Research team built an open source Skill Scanner tool that scans agent skills files for threats and untrusted behavior embedded in descriptions, metadata, or implementation details. It combines static and behavioral analysis, LLM-assisted semantic analysis, Cisco AI Defense inspection workflows, and VirusTotal analysis.

### Case study: "What Would Elon Do?" skill

The team ran a vulnerable third-party skill against OpenClaw and surfaced nine security findings:

- **2 Critical:** Active data exfiltration (silent curl command sending data to attacker-controlled server) and direct prompt injection to bypass safety guidelines
- **5 High:** Command injection via embedded bash commands; tool poisoning with malicious payloads
- **2 Additional findings**

This skill was artificially inflated to rank as #1 in the skill repository.

## Enterprise implications

1. AI agents with system access become covert data-leak channels bypassing traditional DLP, proxies, and endpoint monitoring
2. Models become execution orchestrators where the prompt is the instruction, difficult to catch with traditional security tooling
3. Actors with malicious intentions can manufacture popularity on skill registries, amplifying supply chain risk
4. Skills are local file packages loaded from disk -- local packages are still untrusted inputs, distinct from remote MCP servers
5. Shadow AI risk: employees unknowingly introduce high-risk agents into workplace environments under the guise of productivity tools

Prior research showed 26% of 31,000 agent skills analyzed contained at least one vulnerability.
