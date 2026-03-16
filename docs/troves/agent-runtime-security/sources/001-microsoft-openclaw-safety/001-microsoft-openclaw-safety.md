---
source-id: "001"
title: "Running OpenClaw safely: identity, isolation, and runtime risk"
type: web
url: "https://www.microsoft.com/en-us/security/blog/2026/02/19/running-openclaw-safely-identity-isolation-runtime-risk/"
fetched: 2026-03-15T00:00:00Z
hash: "sha256:pending"
---

# Running OpenClaw safely: identity, isolation, and runtime risk

**Published:** 2026-02-19
**Author:** Microsoft Defender Security Research Team (with contributions from Idan Hen)
**Source:** Microsoft Security Blog

Self-hosted agent runtimes like OpenClaw are showing up fast in enterprise pilots, and they introduce a blunt reality: OpenClaw includes limited built-in security controls. The runtime can ingest untrusted text, download and execute skills (i.e. code) from external sources, and perform actions using the credentials assigned to it.

This effectively shifts the execution boundary from static application code to dynamically supplied content and third-party capabilities, without equivalent controls around identity, input handling, or privilege scoping.

In an unguarded deployment, three risks materialize quickly:

- Credentials and accessible data may be exposed or exfiltrated.
- The agent's persistent state or "memory" can be modified, causing it to follow attacker-supplied instructions over time.
- The host environment can be compromised if the agent is induced to retrieve and execute malicious code.

Because of these characteristics, OpenClaw should be treated as untrusted code execution with persistent credentials. It is not appropriate to run on a standard personal or enterprise workstation. If an organization determines that OpenClaw must be evaluated, it should be deployed only in a fully isolated environment such as a dedicated virtual machine or separate physical device. The runtime should use dedicated, non-privileged credentials and access only non-sensitive data. Continuous monitoring and a rebuild plan should be part of the operating model.

This post explains how the two supply chains inherent to self-hosted agents -- untrusted code (skills and extensions) and untrusted instructions (external text inputs) -- converge into a single execution loop. We examine how this design creates compounding risk in workstation environments, provide a representative compromise chain, and outline deployment, monitoring, and hunting guidance aligned to Microsoft Security controls, including Microsoft Defender XDR.

## Clarifying the landscape: runtime vs platform

**OpenClaw (runtime):** A self-hosted agent runtime that runs on a workstation, VM, or container. It can load skills and interact with local and cloud resources. The key security point: it inherits the trust (and risk) of the machine and the identities it can use. Installing a skill is basically installing privileged code. Skills are often discovered and installed through ClawHub, the public skills registry for OpenClaw.

**Moltbook (platform):** An agent-focused platform and identity layer where agents post, read, and authenticate through APIs. The key security point is that it can become a high-volume stream of attacker-influenceable content that agents ingest on a schedule. A single malicious post can therefore reach multiple agents.

In practice, OpenClaw expands the code execution boundary within your environment, while Moltbook expands the instruction influence surface at scale. When these two interact without appropriate guardrails, a single malicious input can result in durable, credentialed execution.

## How agents shift the security boundary

Most security teams already know how to secure automation. Agents change the risk because the entity deciding what to do isn't always the one taking the action. At runtime, the agent loads third-party code, reads untrusted input, and acts using durable credentials, making the runtime environment the new security boundary.

That boundary has three components:

- **Identity:** The tokens the agent uses to do work (SaaS APIs, repos, mail, cloud control planes).
- **Execution:** The tools it can run that change state (files, shell, infrastructure, messages).
- **Persistence:** The ways it can keep changes across runs (tasks, config, schedules).

Two types of security problems:

- **Indirect prompt injection:** Attackers can hide malicious instructions inside content an agent reads and can either steer tool use or modify its memory to affect its behavior over time unless users put strong boundaries in place.
- **Skill malware:** Agents acquire skills from a variety of sources, basically by downloading and running code off the Internet, and can contain malicious code.

## Managed platforms vs. self-hosted runtimes

With managed assistants and agent platforms, security controls typically center on identity scopes, connector governance, and data boundaries, because the runtime and updates are centrally managed. With self-hosted runtimes, that responsibility shifts to the organization. The host system, plugin surface, and local state become part of the trust boundary.

With a self-hosted runtime, you are responsible for the blast radius. If the agent is able to browse external content and install extensions, it should be assumed that it will eventually process malicious input. Controls should therefore prioritize containment and recoverability, rather than relying on prevention alone.

## End-to-end attack scenario: The poisoned skill

1. **Distribution:** An attacker publishes a malicious skill to ClawHub, sometimes disguised as a utility and sometimes openly malicious, and promotes it through community channels.
2. **Installation:** A developer or an agent initiates installation because the skill appears relevant. In permissive deployments, the runtime may execute the installation flow without human approval.
3. **State access (tokens and durable instructions):** The attacker's objective is access to agent state, including tokens, cached credentials, configuration data, and transcripts, as well as durable instruction channels that influence future runs.
4. **Privilege reuse through legitimate APIs:** With valid identity material, the attacker can perform actions through standard APIs and tooling. This activity often resembles legitimate automation unless strong monitoring and logging controls are in place.
5. **Persistence through configuration:** Persistence frequently manifests as durable configuration changes, such as new OAuth consents, scheduled executions, modified agent tasks, or tools that remain permanently approved.

### Variant: indirect prompt injection through shared feeds

If agents are configured to poll a shared feed, an attacker can place malicious instructions inside content the agents ingest. In multi-agent settings, a single malicious thread can reach many agents at once.

## Minimum safe operating posture

1. **Run only in isolation** -- Use a dedicated VM or separate physical device that is not used for daily work. Treat the environment as disposable.
2. **Use dedicated credentials and non-sensitive data** -- Create accounts, tokens, and datasets solely for the agent's purpose. Assume compromise is possible and plan for regular rotation.
3. **Monitor for state or memory manipulation** -- Regularly review the agent's saved instructions and state for unexpected persistent rules, newly trusted sources, or changes in behavior.
4. **Back up state to enable rapid rebuild** -- Backing up `.openclaw/workspace/` captures working state without credentials.
5. **Treat rebuild as an expected control** -- Reinstall regularly and rebuild immediately if anomalous behavior is observed.

## Controls mapping

| What to do | How to do it with Microsoft controls |
|---|---|
| **Identity** -- Use dedicated identities for agents. Minimize permissions. Prefer short-lived tokens. | Microsoft Entra ID: Enforce least privilege, Conditional Access, and Admin consent workflows for sensitive scopes. |
| **Endpoint and host** -- Treat agent hosts as privileged. Separate pilots from production. | Microsoft Defender for Endpoint: Onboard agent hosts and use device groups for stricter policies. |
| **Supply chain** -- Restrict install sources and publishers. Pin versions. | Microsoft Defender for Endpoint: Use telemetry to spot suspicious extension installs. |
| **Network and egress** -- Restrict outbound access to known destinations. | Defender for Endpoint web content filtering: restrict categories and access to agent device groups. |
| **Data protection** -- Reduce sensitive data ingestion into agent prompts. | Microsoft Purview: Use sensitivity labeling and Endpoint DLP. |
| **Monitoring and response** -- Log agent actions and treat abnormal tool use as incident signal. | Microsoft Defender XDR: Use hunting and incident correlation. Microsoft Sentinel for deeper correlation. |

## Hunting queries (KQL)

Six KQL hunting queries provided for:

1. Discovering agent runtimes and related tooling (DeviceProcessEvents)
2. Cloud workloads variant (CloudProcessEvents) for container/Kubernetes
3. ClawHub skill installs and low-prevalence skill slugs
4. Extension installs and churn on developer endpoints (DeviceFileEvents)
5. High-privilege OAuth apps and consent drift (OAuthAppInfo)
6. Unexpected listening services created by agent processes (DeviceNetworkEvents)
7. Agent runtimes spawning unexpected shells or download tools (DeviceProcessEvents)

## Conclusion

Self-hosted agents combine untrusted code and untrusted instructions into a single execution loop that runs with valid credentials. That is the core risk. Running OpenClaw is not simply a configuration choice. It is a trust decision about which machine, identities, and data you are prepared to expose when the agent processes untrusted input.
