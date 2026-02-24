# Threat Model

Tidegate's threat model centers on a personal user — someone who runs an AI agent as a daily assistant. They process bank statements, tax documents, emails, medical records, and personal files. They install skills from community marketplaces without careful vetting. They are the highest-risk, lowest-attention audience for malicious extensions.

This user is also the easiest social engineering target. A malicious email saying "I'm Bob's wife, emailing from a different account — he forgot to send me [x]" will trick the agent into composing a tool call that exfiltrates personal data through a legitimate channel.

## What the agent can access

The agent has broad read access to sensitive data:

- **Workspace files** — tax returns, bank statements, medical records, personal documents mounted into the container
- **Tool call results** — emails from Gmail, calendar events, search results, database records (tool responses become inputs to the next tool call)
- **User conversation history** — names, addresses, financial details, anything shared in conversation
- **Agent memory** — persistent context across sessions, potentially containing sensitive data from prior conversations

The key insight is **circular data flow**: the agent calls a Gmail tool, gets email content, then passes that content to a Slack tool. Sensitive data from one tool's response becomes the next tool's input. Every outbound tool call parameter is a potential exfiltration vector.

**What the agent CANNOT access**: API credentials. They live in MCP server containers, injected at startup. The agent never sees API keys, tokens, or passwords — not in memory, not on the filesystem, not via the network.

**One exception**: the LLM API key must exist in the agent container (it's how the agent thinks). This is a hard architectural limit.

## Contents

| Document | What it covers |
|---|---|
| [incidents.md](incidents.md) | Real-world attacks against AI agent ecosystems |
| [defenses.md](defenses.md) | Tidegate's three enforcement layers |
| [sensitive-data.md](sensitive-data.md) | What scanning can and cannot detect |
| [threat-personas.md](threat-personas.md) | Adversary profiles and what blocks each |
| [scorecard.md](scorecard.md) | Attack surface map, ClawHavoc walkthrough, residual risks |

See also: [personas.md](../personas.md) for product user personas (who uses Tidegate, not who attacks it).
