---
source-id: "013"
title: "From runtime risk to real-time defense: Securing AI agents"
type: web
url: "https://www.microsoft.com/en-us/security/blog/2026/01/23/runtime-risk-realtime-defense-securing-ai-agents/"
fetched: 2026-03-15T00:00:00Z
hash: "sha256:pending"
---

# From runtime risk to real-time defense: Securing AI agents

**Published:** 2026-01-23
**Authors:** Microsoft Defender Security Research Team (with Dor Edry and Uri Oren)
**Source:** Microsoft Security Blog

## Core thesis

AI agent security is a **runtime enforcement problem**, not a build-time configuration problem. Because agents use generative orchestration to dynamically chain tools, topics, and knowledge sources based on natural language input, every tool invocation must be treated as a high-value, high-risk event requiring real-time inspection.

## Agent architecture (Copilot Studio)

- **Topics:** Conversation flows
- **Tools:** Connector actions, AI models
- **Knowledge sources:** Enterprise content grounding

These three components define the agent's attack surface. Because generative orchestration dynamically chains them at runtime, crafted input becomes the primary vector for steering agents toward unintended execution paths.

## Defense model

Microsoft Defender performs **real-time security checks before each tool invocation via webhook**. The approach is an external enforcement layer that wraps the agent's execution without modifying its internal orchestration logic. Fail-closed: if the webhook blocks, the tool invocation does not proceed.

## Attack scenarios

### Scenario 1: Malicious instruction injection via email

A finance agent processes emails to invoice@contoso.com using a CRM connector and email tool plus a finance policy knowledge base. An attacker sends an email that appears to contain invoice data but includes hidden instructions telling the agent to search its knowledge base for unrelated sensitive information and email results to the attacker.

**Defense:** Before the knowledge component executes, Copilot Studio sends a webhook to Defender, which blocks the invocation. Action logged, XDR alert triggered.

### Scenario 2: Prompt injection via shared document

An agent connected to SharePoint retrieves and summarizes documents. A malicious insider edits a SharePoint document, inserting crafted instructions. The agent is tricked into reading a sensitive file (transactions.pdf) from a different SharePoint location the attacker cannot directly access but the agent can. It then attempts to email contents to an attacker-controlled domain.

**Defense:** Microsoft Threat Intelligence detects and blocks the email, preventing exfiltration.

### Scenario 3: Capability reconnaissance

A publicly accessible, unauthenticated support chatbot with a customer knowledge base. An attacker uses crafted prompts to probe and enumerate internal capabilities -- discovering available tools and knowledge sources. After identifying knowledge sources, the attacker extracts sensitive customer data.

**Defense:** Defender detects the probing pattern and blocks subsequent tool invocations.

## Key insights

1. **Knowledge source extraction is the primary threat** -- not arbitrary code execution, but the agent reading sensitive data it can access and forwarding it to an attacker
2. **Attacks operate within allowed permissions** -- the agent is using its granted access, making attacks invisible to traditional access controls
3. **Webhook-based interception is a "gate at the action boundary"** -- similar in spirit to Tidegate's enforcement seam concept, but implemented as a cloud service call rather than infrastructure-embedded enforcement

## Contrast with February 2026 OpenClaw post

This earlier post focuses on **managed platform security** (Copilot Studio + Defender), where the vendor controls the runtime. The later OpenClaw post shifts to **self-hosted runtime security**, where the organization owns the entire blast radius. The defense models differ accordingly:

- January: Webhook-based, application-layer interception (cloud service)
- February: Isolation + monitoring + assume-breach (infrastructure-level)

Both converge on the same principle: enforcement must happen before the action executes, not after.
