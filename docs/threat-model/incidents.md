# Real-World Incidents

These are documented attacks against AI agent ecosystems, not hypotheticals.

## Malicious marketplace skills

**ClawHavoc (2025)**: Researchers planted 1,184 malicious skills on ClawHub. Over 42,000 installations before detection. Attack patterns included credential theft from environment variables, `fetch()` calls to attacker-controlled servers, and reading SSH keys from `~/.ssh/`. The skills passed ClawHub's automated review because they performed legitimate functions alongside the malicious code.

**postmark-mcp**: First documented malicious MCP server on npm. Exfiltrated data through a legitimate-looking email sending interface.

## Prompt injection via content

**Superhuman email exfil**: A single unopened email in a user's inbox contained prompt injection that caused the agent to exfiltrate 40+ emails to an attacker-controlled address. The user never opened the email — the agent read it as part of inbox processing.

**EchoLeak (CVE-2025-32711, CVSS 9.3)**: MCP tool responses containing prompt injection caused agents to leak conversation context through subsequent tool calls. The injection was in the *response* from a legitimate MCP server, not in user input.

## Agent framework vulnerabilities

**Claude Desktop Extensions zero-click RCE (CVSS 10.0)**: Remote code execution through malicious MCP server responses, requiring zero user interaction.

**Cursor RCE**: Multiple remote code execution vulnerabilities in the Cursor IDE's agent integration, exploitable through crafted project files.

## State-sponsored

**GTG-1002**: First documented state-sponsored campaign specifically targeting AI agent infrastructure for espionage. Demonstrates that agent security is now a nation-state concern.
