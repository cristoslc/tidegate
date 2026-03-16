# Tidegate

Reference architecture for data-flow enforcement in AI agent deployments.

Tidegate maps what it takes to prevent an AI agent from leaking sensitive data -- through a topology where every data path from the agent passes through an enforcement boundary. It is a design document, not a deployable product. Any code in this repository is exploratory -- proof-of-concept work that tests architectural assumptions.

## The problem

Simon Willison's [lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/): any AI agent that combines (1) access to **private data**, (2) exposure to **untrusted content**, and (3) the ability to **externally communicate** can be tricked into exfiltrating your data to an attacker. Remove any one leg and the attack breaks. Today's agents have all three legs wide open.

As of early 2026, [36% of community agent skills have security flaws](https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/), [credential exfiltration via prompt-injected emails](https://www.kaspersky.com/blog/openclaw-vulnerabilities-exposed/55263/) has been demonstrated in the wild, and [over 18,000 agent instances](https://www.reddit.com/r/MachineLearning/comments/1r30nzv/) were found exposed on the public internet.

The industry has responded with partial solutions: agent frameworks sandbox code execution but not data flow. MCP gateways scan tool-call payloads but can't stop the agent from bypassing MCP entirely -- `curl`, cron jobs, IPC, or encoding data in the LLM API request. Cloud sandboxes provide VM-grade isolation but don't inspect what leaves the boundary. Each layer covers one exit. Nothing covers them all.

## The architecture

Tidegate's reference architecture breaks the trifecta by layering enforcement so that no single bypass defeats the system.

| Trifecta leg | Enforcement layer |
|---|---|
| **Private data access** | Taint-and-verify data flow model -- track what sensitive data enters the agent boundary |
| **External communication** | gvproxy egress allowlist -- the VM's only network path, enforcing per-destination allowlisting at the infrastructure level |
| **Untrusted content** | MCP scanning gateway -- inspects every tool-call argument and response crossing the boundary |
| *All three at once* | VM boundary -- the agent runs inside a VM; bypass requires a VM escape, not a `curl` command |

These layers operate independently -- compromise of one does not disable the others. The agent's only path to the outside world is through gvproxy, which routes traffic through the scanning gateway and egress proxy. There is no alternative path.

The architecture wraps existing agents (Claude Code, Codex CLI, Aider, Goose). You pick the brain; Tidegate defines the boundary.

## Limitations

- **Semantic exfiltration** -- If the LLM rephrases your bank balance as prose, no pattern scanner catches it. Fundamental limit of all scanning approaches.
- **LLM API channel** -- The agent's API key must exist inside the VM. A sophisticated attacker could encode data in API requests.
- **Sabotage** -- Tidegate prevents data *leaving*; it doesn't prevent the agent from deleting files or running destructive commands.
- **Single operator** -- This targets personal deployment, not shared platforms.

See the [threat model](docs/threat-model/) for the full analysis.

## What's here

This repository contains the architecture itself -- documented as visions, epics, specs, ADRs, research spikes, personas, journeys, and a threat model. Any code is exploratory: proof-of-concept scripts that test whether specific components (VM launchers, egress proxies, MCP scanners) behave as the architecture requires. It is not packaged, not versioned for release, and not intended to be deployed as-is.

If a deployable product emerges from this work, it will live in a separate repository.

## Documentation

| | |
|---|---|
| **[Project identity](docs/vision/Active/(VISION-000)-Reference-Architecture/(VISION-000)-Reference-Architecture.md)** | Why this is a reference architecture, not a product |
| **[Vision](docs/vision/Active/(VISION-002)-Tidegate/(VISION-002)-Tidegate.md)** | Target audience, value proposition, landscape analysis |
| **[Architecture](docs/vision/Active/(VISION-002)-Tidegate/system-architecture.md)** | Components, network topology, enforcement seams, trust boundaries |
| **[Epic](docs/epic/Active/(EPIC-002)-VM-Isolated-Agent-Runtime/(EPIC-002)-VM-Isolated-Agent-Runtime.md)** | VM-isolated agent runtime with MCP scanning and egress enforcement |
| **[Specs](docs/spec/)** | VM launcher CLI, gvproxy egress allowlist, guest image, MCP scanning gateway |
| **[ADRs](docs/adr/list-adrs.md)** | Taint-and-verify model, IPC scanning, composable VM isolation, infrastructure-embedded enforcement |
| **[Research](docs/research/list-spikes.md)** | Research spikes on VM isolation, egress enforcement, taint models, architecture evaluations |
| **[Threat model](docs/threat-model/)** | Attack scenarios, defense mapping, sensitive data catalog, security scorecard |
| **[Personas](docs/persona/list-personas.md)** | Personal assistant operator, small team operator, security-conscious developer, contributor |
