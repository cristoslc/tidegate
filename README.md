# Tidegate

A reference architecture for data-flow enforcement in AI agent deployments. Tidegate maps what it takes to prevent an AI agent from leaking sensitive data — not through best-effort scanning of one channel, but through a topology where every data path from the agent passes through an enforcement boundary. It may get built; it may remain an analytical tool for evaluating how well commercial solutions cover the problem. The value is in the analysis regardless.

## The problem

AI agents read your most sensitive files and call external APIs in the same breath. A community skill can read your bank statements and post them to any endpoint. A prompt injection in a document can instruct the agent to exfiltrate credentials through a tool call.

Agent frameworks sandbox *code execution* (bubblewrap, Landlock, Seatbelt) but not *data flow*. MCP gateways scan *tool call payloads* but can't stop the agent from bypassing MCP entirely — `curl`, cron jobs, IPC, or encoding data in the LLM API request. Each layer covers one exit; nothing covers them all. A determined or compromised agent routes around whichever single layer is present.

## Existing landscape

The landscape for agent security tooling has matured rapidly, but each category covers only part of the problem:

- **Agent frameworks** (Claude Code, Codex CLI, Aider, Goose) provide code-execution sandboxing and permission prompts. None enforce data-flow boundaries — a sandboxed agent can still pipe your SSN through a tool call.
- **MCP gateways with payload scanning** — Docker MCP Gateway (`--block-secrets`), Pipelock (36 DLP patterns), Lasso Security (PII masking via Presidio), Pangea (50+ PII types with format-preserving encryption), Enkrypt AI, Operant AI, MintMCP, and others all scan MCP tool call payloads for credentials and PII. Most are SaaS or enterprise products. Pipelock and Docker MCP Gateway are self-hostable.
- **MCP governance tools** — Snyk agent-scan (formerly Invariant mcp-scan), Promptfoo, MCP Manager, and Trail of Bits mcp-context-protector focus on tool poisoning, prompt injection, and access control. Some include PII detection as a secondary feature.
- **AI gateway DLP** — Cloudflare AI Gateway, Lakera Guard, and Nightfall AI provide DLP for LLM interactions. Not MCP-specific but converging toward agent-aware scanning.
- **Cloud sandboxes** (E2B, Daytona, microsandbox) provide isolated execution environments. They contain blast radius but don't inspect what leaves the sandbox.

The gap is not "nobody scans MCP payloads" — many tools now do. The gap is that scanning alone is insufficient without *structural enforcement*. An MCP gateway that scans tool calls doesn't help when the agent bypasses MCP entirely — shelling out to `curl`, writing to a cron job, encoding data in the LLM API request, or exfiltrating through IPC. No existing tool combines payload scanning with network-level enforcement that makes bypass structurally impossible.

## What comprehensive enforcement requires

Tidegate's architecture addresses the gap by combining three independent enforcement seams:

- **MCP gateway scanning** — An interposition proxy sits between the agent and all downstream MCP servers. It discovers tools automatically, scans every string value in every tool call parameter and response, and returns shaped denies on policy violations. The agent never contacts MCP servers directly.
- **Network egress control** — A CONNECT-only proxy is the agent container's sole path to the internet. LLM API domains get passthrough; everything else is blocked. The agent cannot reach the internet without going through the proxy.
- **Credential isolation** — API keys and tokens live in isolated MCP server containers on a network the agent cannot reach. The agent has zero external service credentials. Credential exposure requires a Docker compose misconfiguration, not a `curl` command.

These seams operate independently — compromise of one does not disable the others. The topology is enforced by Docker networking: the agent container sits on a single internal network and can only reach the gateway and the proxy. Bypass requires a container escape, not a creative shell command.

See the [system architecture](docs/vision/Active/(VISION-002)-Tidegate/system-architecture.md) for the full design.

## Honest limitations

Tidegate is honest about what it cannot do:

- **Semantic exfiltration** — If the LLM rephrases your bank balance as prose, no pattern scanner catches it. This is a fundamental limit of all scanning approaches. Documented as accepted risk, not claimed as blocked.
- **LLM API as exfiltration channel** — The agent's API key must exist in the agent container (it's how the agent thinks). A sophisticated attacker could encode data in API requests. This is a hard architectural limit.
- **Sabotage prevention** — Tidegate prevents data *leaving*; it doesn't prevent the agent from deleting files or running destructive commands. Containerization and workspace backups handle that.
- **Multi-tenant hosting** — This is a single-operator deployment, not a shared platform.
- **Replacing agent frameworks** — Tidegate wraps your existing agent (Claude Code, Codex, Aider, Goose). It doesn't compete with them. You pick the brain; Tidegate provides the boundary.

See the [threat model](docs/threat-model/) for the full analysis including attack scenarios, defense mapping, and a security scorecard.

## Status

Tidegate is a reference architecture. There is no roadmap.

The repo contains research spikes, a threat model, architecture decision records, and user personas alongside the architecture design. If it gets built, the architecture doc guides implementation. If it doesn't, it serves as a point of comparison for evaluating commercial tools — a way to ask "does this product actually cover the gaps it claims to?"

## Navigation

| Document | What it covers |
|----------|---------------|
| [System architecture](docs/vision/Active/(VISION-002)-Tidegate/system-architecture.md) | Components, network topology, enforcement seams, scanning pipeline, trust boundaries |
| [VISION-002](docs/vision/Active/(VISION-002)-Tidegate/(VISION-002)-Tidegate.md) | Product vision — target audience, value proposition, problem statement, landscape analysis |
| [Threat model](docs/threat-model/) | Attack scenarios, defense mapping, sensitive data catalog, threat personas, security scorecard |
| [Research spikes](docs/research/list-spikes.md) | Investigations — leak detection tools, taint models, architecture options, RL-trained agent risks |
| [Architecture decisions](docs/adr/list-adrs.md) | ADRs — taint-and-verify model, IPC scanning, composable VM isolation |
| [Personas](docs/persona/list-personas.md) | User archetypes — personal assistant operator, small team operator, security-conscious developer, contributor |
