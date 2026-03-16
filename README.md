# Tidegate

Your AI agent reads your bank statements and calls external APIs in the same breath. Tidegate makes sure nothing leaks.

Not through best-effort scanning of one channel, but through a network topology where every data path from the agent passes through an enforcement boundary. The agent does useful work. Tidegate makes sure it can't betray your trust.

## The problem

Simon Willison's [lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/): any AI agent that combines (1) access to **private data**, (2) exposure to **untrusted content**, and (3) the ability to **externally communicate** can be tricked into exfiltrating your data to an attacker. Remove any one leg and the attack breaks. Today's agents have all three legs wide open.

This is not theoretical. As of early 2026, [36% of community agent skills have security flaws](https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/), [credential exfiltration via prompt-injected emails](https://www.kaspersky.com/blog/openclaw-vulnerabilities-exposed/55263/) has been demonstrated in the wild, and [over 18,000 agent instances](https://www.reddit.com/r/MachineLearning/comments/1r30nzv/) were found exposed on the public internet.

The industry has responded with partial solutions: agent frameworks sandbox code execution but not data flow. MCP gateways scan tool-call payloads but can't stop the agent from bypassing MCP entirely -- `curl`, cron jobs, IPC, or encoding data in the LLM API request. Cloud sandboxes (Google's [Agent Sandbox](https://cloud.google.com/blog/products/containers-kubernetes/agentic-ai-on-kubernetes-and-gke), E2B, Daytona) provide VM-grade isolation but don't inspect what leaves the boundary, and none target personal-device deployment. Each layer covers one exit. Nothing covers them all.

## How Tidegate breaks the trifecta

Each enforcement layer targets a specific leg. VM isolation makes all three inescapable.

| Trifecta leg | Tidegate control |
|---|---|
| **Private data access** | Taint-and-verify data flow model -- track what sensitive data enters the agent boundary |
| **External communication** | gvproxy egress allowlist -- the VM's only network path, enforcing per-destination allowlisting at the infrastructure level |
| **Untrusted content** | MCP scanning gateway -- inspects every tool-call argument and response crossing the boundary |
| *All three at once* | VM boundary -- the agent runs inside a VM; bypass requires a VM escape, not a `curl` command |

These layers operate independently -- compromise of one does not disable the others. The agent's only path to the outside world is through gvproxy, which routes traffic through the scanning gateway and egress proxy. There is no alternative path.

Tidegate wraps your existing agent (Claude Code, Codex CLI, Aider, Goose). You pick the brain; Tidegate provides the boundary.

## Limitations

- **Semantic exfiltration** -- If the LLM rephrases your bank balance as prose, no pattern scanner catches it. Fundamental limit of all scanning approaches. Documented as accepted risk, not claimed as blocked.
- **LLM API channel** -- The agent's API key must exist inside the VM. A sophisticated attacker could encode data in API requests. Hard architectural limit.
- **Sabotage** -- Tidegate prevents data *leaving*; it doesn't prevent the agent from deleting files or running destructive commands.
- **Single operator** -- This is a personal deployment, not a shared platform.

See the [threat model](docs/threat-model/) for the full analysis including attack scenarios, defense mapping, and security scorecard.

## Status

Active development. [EPIC-002](docs/epic/Active/(EPIC-002)-VM-Isolated-Agent-Runtime/(EPIC-002)-VM-Isolated-Agent-Runtime.md) covers the full enforcement boundary: VM-isolated agent runtime on macOS and Linux, MCP scanning gateway, and infrastructure-embedded egress enforcement. Four specs are approved.

Built from standard tools (libkrun, gvproxy, Docker networks, MCP SDK) to stay maintainable by one person part-time. If a single existing product covers the full topology in the future, the right move is to adopt it and sunset Tidegate.

## Documentation

| | |
|---|---|
| **[Vision](docs/vision/Active/(VISION-002)-Tidegate/(VISION-002)-Tidegate.md)** | Target audience, value proposition, lethal trifecta threat model, landscape analysis |
| **[Architecture](docs/vision/Active/(VISION-002)-Tidegate/system-architecture.md)** | Components, network topology, enforcement seams, trust boundaries |
| **[Epic](docs/epic/Active/(EPIC-002)-VM-Isolated-Agent-Runtime/(EPIC-002)-VM-Isolated-Agent-Runtime.md)** | VM-isolated agent runtime with MCP scanning and egress enforcement |
| **[Specs](docs/spec/)** | VM launcher CLI, gvproxy egress allowlist, guest image, MCP scanning gateway |
| **[ADRs](docs/adr/list-adrs.md)** | Taint-and-verify model, IPC scanning, composable VM isolation, infrastructure-embedded enforcement |
| **[Research](docs/research/list-spikes.md)** | 22 spikes -- VM isolation, egress enforcement, taint models, architecture evaluations |
| **[Threat model](docs/threat-model/)** | Attack scenarios, defense mapping, sensitive data catalog, security scorecard |
| **[Personas](docs/persona/list-personas.md)** | Personal assistant operator, small team operator, security-conscious developer, contributor |
| **[Evidence pool](docs/evidence-pools/agent-runtime-security/)** | 13 external sources on agent runtime security from vendor, regulatory, and practitioner perspectives |
