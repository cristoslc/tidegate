# Personas

Product user personas — who uses Tidegate and why. For adversary profiles (who attacks it), see [threat-model/threat-personas.md](threat-model/threat-personas.md).

## Personal assistant operator

**The primary persona.** Runs an AI agent as a daily assistant to process bank statements, tax documents, emails, medical records, and personal files. Installs skills from community marketplaces without careful vetting. Highest-risk, lowest-attention audience for malicious extensions.

**What they want**: An agent that handles personal tasks — managing email, scheduling, filing documents, writing drafts — without worrying about data leakage or malicious skills.

**What they fear**: A skill stealing their credentials, a prompt injection exfiltrating their bank data through Slack, their personal documents ending up on an attacker's server.

**How Tidegate helps**: Install Tidegate instead of installing an agent framework directly. Credentials stay in isolated containers. All tool calls are scanned. Malicious skills can't phone home.

**Pain tolerance**: Zero. If setup takes more than `git clone && ./setup.sh`, they'll use the unprotected agent directly. If the scanner blocks legitimate tool calls with false positives, they'll disable it.

## Small team operator

Runs an AI agent for a team — shared Slack workspace, GitHub org, internal tools. Multiple people's data flows through the agent. The blast radius of a compromised skill is organizational, not personal.

**What they want**: The same personal assistant capabilities, but with team-scoped credentials and audit trails. Needs to demonstrate to the team that the agent won't leak internal data.

**How Tidegate helps**: Audit log records every tool call. Credential isolation means a compromised skill only gets the API keys it needs. Network topology prevents lateral movement.

**Pain tolerance**: Moderate. Willing to edit YAML configs and manage Docker. Needs clear documentation.

## Security-conscious developer

Evaluates Tidegate for adoption. Reads the threat model first, checks the Docker topology, looks for escape hatches. Won't adopt a tool that claims to be secure but has obvious bypasses.

**What they want**: Honest threat model with real-world incidents. Clear documentation of what's protected and what isn't. No security theater.

**How Tidegate helps**: Three hard boundaries (kernel, network, network). Honest scorecard showing what's blocked and what's accepted risk. Architecture that doesn't require trust in the agent container.

**Pain tolerance**: High. Happy to read ADRs and inspect Dockerfiles. Will file issues for gaps they find.

## Contributor

Wants to add an MCP server configuration, improve scanning patterns, or extend the architecture. Needs to understand module boundaries and conventions without reading every file.

**What they want**: Clear CLAUDE.md, logical directory structure, documented conventions. Knows where to put new code and how to test it.

**How Tidegate helps**: CLAUDE.md covers how the gateway works. "Key files for common tasks" table points to the right starting file. Dev mode runs without Docker.
