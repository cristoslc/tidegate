# Hermes Agent — Synthesis

## Key Findings

### Architecture and Design Philosophy

Hermes Agent is a **single-process, synchronous agent loop** architecture. The core loop in `run_agent.py` iterates up to 90 times, calling LLM APIs via OpenAI-compatible chat completions, dispatching tool calls through `handle_function_call()`, and appending results back to the message history. There is no async in the agent loop itself — async is confined to the gateway (messaging platforms) and the TUI JSON-RPC bridge.

The tool system is built on a **self-registering registry** pattern: each `tools/*.py` file calls `registry.register()` at module import time, and `discover_builtin_tools()` uses AST inspection to auto-import only modules that contain top-level `registry.register()` calls. This eliminates manual import lists.

### Security Model — Trust Boundaries

Hermes assumes a **single trusted operator**. The security model has several distinct boundaries:

1. **Approval system** (`tools/approval.py`): Pattern-based detection of dangerous commands (rm -rf, chmod 777, writes to ~/.ssh, writes to ~/.hermes/.env). Three modes: "on" (default, interactive approval), "auto" (timed auto-approve), "off" (break-glass). Per-session state via contextvars for thread-safe gateway use.

2. **Secret redaction** (`agent/redact.py`): Regex-based pattern matching against 40+ known API key prefixes (OpenAI sk-*, GitHub ghp_*, Slack xox*, AWS AKIA*, etc.) plus generic ENV assignment and JSON field patterns. Redaction is snapshotted at import time to prevent runtime bypass.

3. **MCP sandboxing** (`tools/mcp_tool.py`): MCP server subprocesses receive a filtered environment (`_build_safe_env()`) — only baseline vars (PATH, HOME, XDG_*) plus explicitly declared env config entries. OSV malware database checking runs before spawning npx/uvx packages.

4. **Code execution sandbox** (`tools/code_execution_tool.py`): API keys and tokens stripped from child process environment. Only variables declared by skills (`env_passthrough`) or user config are passed through. Child accesses tools via RPC, not direct API calls.

5. **Subagent isolation** (`tools/delegate_tool.py`): `delegate_task` is disabled for child agents (no recursive delegation). `MAX_DEPTH = 2`. Children run with `skip_memory=True` — no access to parent's persistent memory.

### Subagent Architecture

Hermes spawns child `AIAgent` instances via `delegate_tool.py` with:
- Fresh conversation (no parent history leakage)
- Own `task_id` (own terminal session, file ops cache)
- Restricted toolset (delegate_task, clarify, memory, send_message, execute_code stripped)
- Default max 50 iterations per child
- ThreadPoolExecutor for parallel batch delegation
- Default 3 concurrent children

The parent sees only the delegation call and summary result, not intermediate tool calls.

### MCP Integration

The MCP client (`tools/mcp_tool.py`, ~2600 lines) implements:
- **Stdio transport** (command + args) and **HTTP/StreamableHTTP** transport (url)
- Automatic reconnection with exponential backoff (5 retries)
- Dedicated background event loop in daemon thread
- `sampling/createMessage` support — MCP servers can request LLM completions
- Configurable per-server timeouts for tool calls and connections

### Multi-Platform Gateway

The gateway (`gateway/run.py`) is a single process handling 14+ messaging platforms (Telegram, Discord, Slack, WhatsApp, Signal, Matrix, Mattermost, Email, SMS, DingTalk, Feishu, WeCom/WeChat, QQ Bot, Home Assistant). Each platform adapter lives in `gateway/platforms/`. Session routing uses session keys, not authorization boundaries — all authorized callers receive equal trust.

### TUI Architecture

A dual-process model: Node.js (Ink/React) owns the screen, Python (`tui_gateway/`) owns sessions/tools/model calls. Communication via newline-delimited JSON-RPC over stdio. The TUI is activated via `hermes --tui`.

## Points of Agreement

Both the repository source and the GitHub page agree on:
- Core feature set: self-improving loop, multi-platform gateway, 40+ tools, skills system, cron, MCP
- Security boundaries: approval system, container sandboxing, redaction
- Version: 0.10.0

## Points of Disagreement

No meaningful disagreement between sources — the GitHub page summarizes what the repo details.

## Gaps

- **No public threat model**: SECURITY.md defines trust boundaries and out-of-scope items but does not provide a formal threat model or attack tree analysis
- **No data-flow enforcement**: Redaction is pattern-based (regex) — there is no taint tracking or information-flow control. Secret patterns that don't match the ~40 known prefixes will pass through
- **Gateway trust model is flat**: All authorized callers (Telegram, Discord, etc.) receive equal trust. If one platform account is compromised, the attacker has equal access to the agent
- **No egress control**: No outbound network proxy or filtering — the agent can make arbitrary network requests via tools
- **Approval system is bypassable**: `approvals.mode: "off"` disables the gate entirely, and the system relies on pattern-based detection rather than allowlisting
- **MCP server trust is coarse**: While MCP processes get filtered environments, there is no capability-based restriction on what MCP tools can do once registered