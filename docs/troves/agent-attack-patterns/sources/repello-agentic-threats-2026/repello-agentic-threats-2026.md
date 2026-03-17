---
source-id: "repello-agentic-threats-2026"
title: "The Agentic AI security threat landscape in 2026: what attackers are actually doing"
type: web
url: "https://repello.ai/blog/agentic-ai-security-threats-2026"
fetched: 2026-03-17T00:00:00Z
hash: "d24837021a5cab5a2c706f21b6903d09e1d1a7af63e86129505659df6fa0bd9f"
---

# The Agentic AI Security Threat Landscape in 2026: What Attackers Are Actually Doing

**Author:** Archisman Pal, Head of GTM, Repello AI
**Published:** Feb 28, 2026 | 10 min read

## TL;DR

- The CrowdStrike 2026 Global Threat Report documents an **89% year-over-year increase** in AI-enabled attacks, with average eCrime breakout time now at **29 minutes**.
- AI is being used offensively across five attack classes: spearphishing at scale, voice cloning, LLM-assisted vulnerability discovery, automated lateral movement, and direct exploitation of AI systems via prompt injection.
- Agentic AI deployments are the **highest-value target** in this threat landscape because a single successful attack propagates across every chained tool call downstream.
- The 90+ organizations already compromised via AI prompt injection in 2025 are a leading indicator, not an outlier.

## Context

The CrowdStrike 2026 Global Threat Report, released in February 2026, quantifies what security teams have been watching build for two years: AI-enabled attacks surged 89% year-over-year, and the average time from initial access to lateral movement now sits at 29 minutes. The fastest observed breakout in the dataset happened in **27 seconds**. In one tracked intrusion, data exfiltration began within four minutes of initial access.

At 29-minute breakout times, the window for human-in-the-loop detection and response has effectively closed. When attackers combine that speed with agentic AI as the target, the blast radius of a single successful intrusion multiplies across every tool call the agent can make.

## What the 89% Increase Covers

The headline figure spans five distinct technique classes:

### 1. AI-Generated Spearphishing

Highest-volume application. Threat actors use LLMs to produce highly personalized phishing content at industrial scale, eliminating the grammatical errors and generic phrasing that historically made phishing detectable. ChatGPT was referenced in criminal forums **550% more** than any other model, reflecting its role as a commodity tool in offensive operations.

### 2. Voice Cloning and Vishing

Fastest-growing social engineering vector. Deepfake voice technology has matured to the point where short audio samples produce convincing impersonations. CrowdStrike's dataset includes threat actors using voice cloning to bypass multi-factor authentication workflows by impersonating executives and IT helpdesk personnel in real-time calls.

### 3. LLM-Assisted Vulnerability Discovery

Being operationalized by nation-state actors. FANCY BEAR deployed LLM-enabled malware (LAMEHUG) to automate reconnaissance and document collection. The eCrime actor PUNK SPIDER used AI-generated scripts to accelerate credential dumping and erase forensic evidence. Both represent the shift from **AI as a planning tool** to **AI as an active component in the kill chain**.

### 4. Malware-Free Intrusion

Continues to dominate: **82% of detections** in the CrowdStrike dataset were malware-free, relying on credential theft, living-off-the-land techniques, and identity-based access. AI accelerates every stage by reducing the skill floor required to move through environments without triggering traditional detection.

### 5. Direct Exploitation of AI Systems

The newest attack class and most relevant to agentic AI teams. CrowdStrike documented AI tools being exploited at **more than 90 organizations** by injecting malicious prompts to generate commands for stealing credentials and cryptocurrency. This is prompt injection operating at enterprise scale, not in a research context.

## Why Agentic AI Systems Are the Primary Target

Traditional AI deployments (a model behind a chat interface, a classifier in a pipeline) have a bounded blast radius. A successful attack on a single-turn chatbot produces a single malicious output -- bad, but contained.

Agentic AI deployments do not have this property. An agent with access to email, calendar, code execution, file systems, and external APIs is not one attack surface -- it is **all of those attack surfaces simultaneously**, connected by a model that will act on whatever instructions it receives.

The blast radius math: an agent that can read email, execute shell commands, and make API calls operates with the **combined permissions of every integration it holds**. A single successful prompt injection that hijacks one tool call can propagate instructions to every downstream tool in the chain. Compromise the agent; compromise everything the agent touches.

The **OWASP Agentic AI Top 10** for 2026 reflects this in its threat taxonomy. Tool call hijacking, memory poisoning, and orchestrator manipulation are attack classes that exist because of the agentic architecture itself, not because of any individual tool's vulnerability.

## The Agentic Attack Playbook

Attack techniques that exploit agentic architecture properties specifically:

### Prompt Injection via External Content

**Primary entry point.** Agentic systems routinely process external data: web pages retrieved by a search tool, documents passed to a summarization tool, emails read by a calendar integration. Any of that content can carry embedded instructions that the model interprets as legitimate, overriding its original task. The CrowdStrike finding about 90+ organizations compromised via prompt injection represents the real-world maturation of this attack class.

### Memory Poisoning

Targets agents with **persistent context**. Many production agentic deployments maintain memory across sessions for continuity. An attacker who successfully injects content into an agent's long-term memory store can influence every future session that draws on that memory. The attack does not need to be repeated -- it persists until the memory is explicitly cleared or audited.

### Tool Definition Manipulation ("Rug Pull")

Exploits the trust model most teams use for tool registries. If an attacker can modify a tool's description or input schema in a registry without triggering an integrity check, the model will follow the modified definition. OWASP calls this the **"rug pull" vulnerability**. Closely related to the supply chain risk documented in CrowdStrike's findings around AI-assisted code generation and dependency injection.

### Credential Harvesting Through Agent Context

Directly evidenced in the CrowdStrike data. Agents that hold API tokens, OAuth credentials, or session cookies in their context window are carrying high-value targets. The 90+ organizations compromised through AI prompt injection were largely targeted for **credential theft, not data destruction**. Attackers understand that an agent's context window is a credential store.

## The Speed Problem: 29-Minute Breakout and Agentic Systems

The 29-minute average breakout time is significant for any security program, but especially for agentic AI:

- Traditional intrusion response assumes a detection and containment window measured in **hours**. Most SOCs are not staffed or tooled to operate at the speed the CrowdStrike data describes.
- For agentic AI deployments, the timeline is **potentially shorter still**. An agent that processes external content in real time can be compromised, manipulated, and used to exfiltrate data within a single task execution cycle.
- There is **no lateral movement phase** to detect -- the agent's tool access means the attacker is already everywhere the agent can reach.
- The NIST AI Risk Management Framework emphasizes mapping and measuring AI-specific risks across the deployment lifecycle. The speed data from CrowdStrike makes the case for why measurement cannot be periodic -- by the time a quarterly review identifies an exploitable weakness, the window for exploitation has been open for months.

## OWASP Agentic AI Top 10 Mapping

The article maps observed attacks to the following OWASP Agentic AI threat classes:

| OWASP Threat Class | Attack Technique | Evidence |
|---|---|---|
| Tool Call Hijacking | Prompt injection redirects tool calls to attacker-controlled endpoints | 90+ orgs compromised via prompt injection (CrowdStrike 2026) |
| Memory Poisoning | Injected content persists in agent long-term memory | Architectural property of persistent-context agents |
| Orchestrator Manipulation | Modified tool definitions alter agent behavior | "Rug pull" in tool registries (OWASP taxonomy) |
| Credential Exfiltration | Agent context window holds tokens and session cookies | CrowdStrike data: credential theft was primary objective |

## Defense Recommendations

Two capabilities described as non-negotiable for agentic AI security in 2026:

### 1. Continuous Automated Red Teaming

Point-in-time assessments cannot keep pace with an attack surface that changes every time a new tool is added, a model is updated, or a prompt template is modified. Automated red teaming engines must run ongoing attack batteries against deployed agentic systems across the full threat taxonomy: prompt injection, tool call hijacking, memory poisoning, and credential exfiltration.

### 2. Runtime Monitoring at the Inference Layer

Even with rigorous red teaming, novel attacks will reach production. Runtime monitoring must detect behavioral anomalies in tool call patterns, flag oversized outputs, and block injection attempts in real time. This is the difference between a detected incident and a completed breach.

**Neither is sufficient alone.** Red teaming without runtime monitoring leaves production exposed to novel attacks. Runtime monitoring without red teaming has no visibility into what weaknesses exist until an attack succeeds.

## Key Takeaways

- The 89% increase in AI-enabled attacks is a data point, not a ceiling. Underlying drivers (lower skill floor for attackers, commodity access to capable models, AI-amplified attack speed) are not slowing down.
- Agentic AI deployments sit at the intersection of the highest-value target class and the least-mature security posture in most organizations.
- Security teams that get ahead treat agentic AI security as a **continuous discipline** rather than a pre-deployment checklist.
- The 27-second breakout time in the CrowdStrike data is an extreme case today. It is a baseline case in two years.
