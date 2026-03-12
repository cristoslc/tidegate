# Tideclaw — Tool-Call Process Isolation: Comparative Analysis

> Supporting document for [(SPIKE-013) Tideclaw Architecture](./(SPIKE-013)-Tideclaw-Architecture.md).

---

## Overview

When an AI coding agent calls a tool, what process boundaries exist? This analysis examines the four primary CLI runtimes Tideclaw orchestrates — Claude Code, Codex CLI, Gemini CLI, and Goose — and how each isolates tool execution at the OS level.

The key finding: **no runtime provides per-tool-call isolation**. All four sandbox the session or the Bash subprocess, not individual tool invocations. Within a sandbox boundary, all tool calls share the same filesystem view, network policy, and credential set. This is the gap Tideclaw fills — by placing the agent inside a container topology with external enforcement seams (gateway, proxy, taint tracker), Tideclaw adds isolation boundaries that the runtimes themselves don't provide.

---

## Claude Code (Anthropic)

### Tool categories by execution model

| Category | Tools | Process model | Sandboxed? |
|----------|-------|--------------|-----------|
| **In-process** | Read, Write, Edit, Glob, Grep, WebFetch, WebSearch, TodoWrite, NotebookEdit | Node.js event loop (same process as agent) | **No** — permission checks only |
| **Subprocess (Bash)** | Bash | New child process per command | **Yes** — bubblewrap/Seatbelt wraps each command |
| **MCP tools** | `mcp__server__tool` | Separate process (stdio) or HTTP connection | **No** — unless MCP server is independently sandboxed |

### Bash tool sandbox mechanics

Each Bash command invocation is individually wrapped by the sandbox runtime:

- **Linux**: `bubblewrap` creates a new namespace per command. `CLONE_NEWNET` removes the network namespace entirely. `CLONE_NEWPID` isolates the process tree. All network traffic is forced through a Unix domain socket connected to a proxy running **outside** the sandbox. Pre-compiled seccomp BPF filters (x86-64, ARM) further restrict syscalls. All child processes (e.g., `npm install` postinstall scripts) inherit the same restrictions.
- **macOS**: `sandbox-exec` applies a dynamically generated Seatbelt profile per command.
- **Overhead**: <15ms per sandboxed command.
- **Escape hatch**: The model can set `dangerouslyDisableSandbox: true` in the Bash tool input, which falls back to the normal permission flow (can be disabled entirely via `allowUnsandboxedCommands: false`).

### In-process tools: no OS sandbox

Read, Write, Edit, Glob, Grep, and WebFetch execute **within the Claude Code Node.js process**. They are not wrapped by bubblewrap or Seatbelt. Their access control is:

- **Filesystem**: Permission deny rules checked before execution. The `Read` and `Edit` deny patterns translate to OS-level sandbox restrictions for Bash, but for the in-process tools themselves, enforcement is application-level only.
- **Network**: WebFetch domain access is controlled by permission rules, not the sandbox proxy. WebSearch goes through Anthropic's API.

This means: a prompt injection that gets Claude to use `Read` to access `~/.ssh/id_rsa` is blocked by permission rules, not by the OS sandbox. The defense is application-level, not kernel-level.

### MCP tool isolation

- **stdio transport**: MCP server runs as a child process of Claude Code. Communication via stdin/stdout JSON-RPC. Process isolation is the OS process boundary — no sandbox, no namespace. The server inherits the user's filesystem and network access unless independently sandboxed.
- **HTTP transport**: MCP server runs remotely. Isolation is network-level (separate machine/container).
- **Sandboxing MCP servers**: The open-source `@anthropic-ai/sandbox-runtime` can wrap MCP servers: `npx @anthropic-ai/sandbox-runtime <mcp-server-command>`. This is opt-in and independent of the agent's sandbox.

### Hook interception model

PreToolUse hooks run **before** any tool executes (Bash, Read, Edit, MCP, etc.):

- **Command hooks**: Shell subprocess. JSON context on stdin. Exit code determines allow/deny.
- **Prompt hooks**: Single-turn LLM API call (no subprocess).
- **Agent hooks**: Subagent with tool access (Read, Grep, Glob).
- All matching hooks run in **parallel**. Since v2.0.10, hooks can **modify tool inputs** before execution (transparent to the model).

### Tideclaw implications

Claude Code's sandbox covers Bash but not in-process tools or MCP servers. Tideclaw's container topology adds:

- **MCP interposition**: Gateway scans all MCP tool calls (L2) — this covers the gap where stdio MCP servers run unsandboxed.
- **Egress proxy**: Catches network traffic from both Bash commands and MCP servers on `mcp-net`.
- **Mount isolation**: The agent container doesn't mount MCP server credentials — so even if Read/Edit tools are compromised via prompt injection, there are no third-party credentials to exfiltrate.
- **Taint tracking**: eBPF observes file reads across all tools (in-process and subprocess), not just Bash.

---

## Codex CLI (OpenAI)

### Tool execution model

Codex CLI (rewritten in Rust) has a fundamentally different tool model from Claude Code: **one primary tool** — a unified shell executor. The model generates shell commands (or "apply patch" operations), and Codex executes them.

| Category | Tools | Process model | Sandboxed? |
|----------|-------|--------------|-----------|
| **Shell executor** | Shell commands, patch application | New subprocess per command via `process_exec_tool_call` | **Yes** — Landlock + seccomp (Linux), Seatbelt (macOS) |
| **MCP tools** | Via `rmcp-client` crate | Separate process (stdio) or HTTP | Follows session sandbox policy |

### Per-command sandbox mechanics

Every command routes through `process_exec_tool_call` in `codex-rs/core/src/exec.rs`, which selects the sandbox based on `SandboxType`. The core uses a queue-based SQ/EQ (Submission Queue / Event Queue) protocol for bidirectional communication between surfaces (TUI, exec, app-server) and the agent loop.

- **Linux**: The `codex-linux-sandbox` is not a separate binary — it is the **same Codex binary** invoked via an `arg0` dispatch mechanism. When `argv[0]` is `codex-linux-sandbox`, it activates sandbox mode. For each command, a child process is spawned that constrains itself before calling `execvp`:
  1. **Environment clearing**: All env vars are wiped and rebuilt with only necessary values. Variables matching `KEY`, `SECRET`, `TOKEN` (case-insensitive) are stripped from subprocess environments.
  2. **Landlock** (ABI V5): Default-deny model for writes. Read access allowed filesystem-wide (write restriction only). Writable roots derived from policy. `.git` directories carved out as read-only.
  3. **seccomp-BPF**: Blocks `connect()`, `accept()`, `bind()`, `listen()` when network is disabled. Preserves `recvfrom` (needed for tools like `cargo clippy` that use socketpair). Allows `AF_UNIX` domain sockets for local IPC. x86-64 and aarch64 only.
  4. **Process hardening**: Strips `LD_PRELOAD` (prevents library injection). Disables `ptrace` (prevents debugging/manipulation). Zeros core file limits. Tags network-disabled runs with `CODEX_SANDBOX_NETWORK_DISABLED=1`. Registers parent-death signal handlers (prevents orphans).

- **macOS**: `sandbox-exec` with dynamically generated Seatbelt profile. `.git` and `.codex` directories kept read-only. Binary network on/off (no domain-level filtering).

### Three sandbox modes

| Mode | Filesystem | Network | Use case |
|------|-----------|---------|----------|
| `read-only` | Read anywhere, write nowhere | Blocked | Safe browsing |
| `workspace-write` (default) | Read anywhere, write in project dir only | Blocked | Normal development |
| `danger-full-access` | Unrestricted | Unrestricted | CI containers, externally secured environments |

### Cloud two-phase model

Codex Cloud implements the cleanest credential isolation pattern in the industry:

1. **Setup phase**: Full network access + all secrets available. Used for `npm install`, `pip install`, etc.
2. **Agent phase**: Network disabled by default. Secrets removed from environment. Configurable domain allowlists per environment.

Credentials cease to exist in the agent's environment before it starts autonomous work. This is a temporal isolation model — credentials are available when needed (dependency installation) and destroyed before the attack window opens (autonomous agent execution).

### Apply-patch sandbox

File edits use an `apply_patch` tool that was originally in-process (bypassing the OS sandbox). PR #1705 fixed this: patches now run through `codex --codex-run-as-apply-patch PATCH`, dispatched via the `arg0` mechanism and sandboxed identically to shell commands. This prevents symlink escape attacks where a symlink inside the writable workspace points to files outside it.

### MCP tool isolation

- Codex supports MCP via the `rmcp-client` Rust crate (as client) and `codex mcp-server` (as server).
- MCP server child processes do **not** run inside the Landlock/seccomp sandbox. The sandbox is applied specifically to shell tool calls. MCP servers receive env vars as configured but have no sandbox policy applied.
- **Key limitation**: Codex's primary tool is the shell executor, not MCP. Most agent actions are shell commands that bypass MCP entirely. This is why Codex needs both Mode 1 (MCP gateway) and Mode 2 (proxy) in Tideclaw's topology.

### Tideclaw implications

Codex's per-command sandbox is the strongest among the four CLIs — every subprocess gets Landlock + seccomp + env clearing. But:

- **Network is binary**: All or nothing. No domain-level filtering, no proxy. Tideclaw's egress proxy adds domain allowlists and credential injection.
- **MCP is secondary**: Most Codex actions are shell commands. Tideclaw's proxy seam catches HTTP traffic from shell commands that MCP doesn't see.
- **Credential stripping is pattern-based**: Catches `KEY`/`SECRET`/`TOKEN` env vars but not content-embedded credentials (API keys in config files, tokens in tool call parameters). Tideclaw's gateway and proxy scan content, not just env vars.
- **`danger-full-access` recommended**: Inside Tideclaw's container topology, Codex should run in `danger-full-access` mode — Tideclaw provides the isolation layer instead of Codex's built-in sandbox. Running both creates conflicts (Codex's seccomp blocks `connect()`, breaking proxy access).

---

## Gemini CLI (Google)

### Tool execution model

Gemini CLI provides structured tools (not just a shell executor):

| Category | Tools | Process model | Sandboxed? |
|----------|-------|--------------|-----------|
| **File system tools** | `read_file`, `write_file`, `replace`, `glob`, `search_file_content`, `list_directory` | In-process (Node.js) | `rootDirectory` constraint (app-level) + optional Seatbelt/Docker |
| **Shell tool** | `run_shell_command` | New subprocess per command (`bash -c`) | Optional Seatbelt/Docker |
| **Network tools** | `web_fetch`, `google_web_search` | In-process | No sandbox |
| **MCP tools** | Configured MCP servers | Separate process (stdio) or HTTP | Environment sanitization only |

### Sandbox mechanics

Gemini CLI supports three sandboxing backends, all **per-tool-call**:

#### macOS Seatbelt

`CoreToolScheduler` wraps each tool invocation with `sandbox-exec` using the selected profile. Six built-in profiles follow a `{permissive,restrictive}-{open,closed,proxied}` naming pattern:

| Profile | Writes | Reads | Network |
|---------|--------|-------|---------|
| `permissive-open` (default) | Project dir only | Everywhere | Allowed |
| `permissive-closed` | Project dir only | Everywhere | **Blocked** |
| `permissive-proxied` | Project dir only | Everywhere | Proxy only |
| `restrictive-open` | Project dir only | Project dir only | Allowed |
| `restrictive-closed` | Project dir only | Project dir only | **Blocked** |
| `restrictive-proxied` | Project dir only | Project dir only | Proxy only |

Custom `.sb` profiles can be placed in `.gemini/sandbox-macos-<name>.sb`.

#### Docker/Podman

Complete process isolation via containers. The project directory is mounted read-write. System temp is also mounted. Files created inside the sandbox are mapped to the host user/group. `sandboxPersist: true` reuses the container across tool executions to avoid repeated startup.

#### Key behaviors

- **Sandbox is OFF by default.** Must be explicitly enabled via `--sandbox`, `GEMINI_SANDBOX=true`, or `settings.json`.
- **Sandbox is ON by default in YOLO mode** (`--approval-mode=yolo`).
- Each tool call goes through the sandbox independently.
- The `excludeTools` restriction for `run_shell_command` uses simple string matching and is **not a security mechanism** (easily bypassed).

### MCP tool isolation

- MCP servers are spawned as **separate OS processes** (stdio transport).
- **Environment sanitization**: Gemini CLI redacts sensitive env vars from MCP server processes by default. Redacted patterns: `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*KEY*`, `*AUTH*`, `*CREDENTIAL*`, certificate/private-key patterns.
- Explicitly declared env vars in the server config are trusted and bypass redaction.
- Trust levels: per-tool confirmation (default), server-level trust, or full trust bypass.

### Jules (cloud agent)

Jules takes a fundamentally different approach — **VM-per-task isolation**:

- Each task gets a dedicated, ephemeral Ubuntu VM in Google Cloud.
- Full internet access (needed for dependency installation).
- No per-tool-call isolation within the VM — the agent has full filesystem and process access.
- VM is destroyed after task completion. Credentials cease to exist.
- Changes arrive as GitHub PRs.

### GKE Agent Sandbox (enterprise)

For enterprise scale, Google offers gVisor-based isolation:

- Each agent action can get its own **gVisor pod** (user-space kernel).
- Kubernetes CRDs: `Sandbox`, `SandboxTemplate`, `SandboxClaim`.
- Pod Snapshots reduce startup from minutes to seconds.
- Gemini CLI can orchestrate remote gVisor sandboxes via MCP extension.

### Tideclaw implications

Gemini CLI's sandbox is the most configurable (six profiles, Docker/Seatbelt/Podman backends, custom profiles). But:

- **Default-off is dangerous**: Users must opt in. Tideclaw's container topology enforces isolation by default.
- **Proxied profiles exist**: The `*-proxied` profiles route traffic through a proxy — conceptually similar to Tideclaw's egress proxy. But the proxy is user-configured, not Tideclaw's scanning proxy.
- **Environment sanitization for MCP is good**: Pattern-based redaction of sensitive env vars before MCP server spawning. Similar to Codex's approach but more comprehensive (pattern matching vs. keyword matching).
- **Jules model validates Tideclaw**: VM-per-task with destruction is the strongest credential isolation — credentials cease to exist when the task ends. Tideclaw achieves similar isolation via container topology without the compute cost of full VMs.

---

## Goose (Block)

### Tool execution model

Goose's architecture is unique: **all extensions are MCP servers**, including built-in tools. Six extension types with different process models:

| Extension type | Process model | Transport | Sandboxed? |
|---------------|--------------|-----------|-----------|
| **Builtin** (developer, computer, memory) | **In-process** (compiled Rust) | In-memory function calls | Session-level sandbox wraps the whole process |
| **Platform** (todo, skills, chat_recall) | **In-process** (compiled Rust) | In-memory function calls | Session-level sandbox |
| **Stdio** (npm/pip MCP servers) | Child process (stdin/stdout pipes) | MCP JSON-RPC | Child process inherits sandbox |
| **InlinePython** (UVX) | Ephemeral child process via `uvx` | MCP JSON-RPC | Ephemeral env + process boundary |
| **StreamableHttp** (remote servers) | Remote HTTP connection | HTTP + SSE | Network-level isolation |
| **Frontend** (UI tools) | UI-managed | Event callbacks | N/A |

### Session-level sandbox mechanics

Goose v1.25.0 (Feb 2026) added sandboxing for **Goose Desktop** on macOS:

- **macOS**: `sandbox-exec` with a dynamically generated Seatbelt profile (via `buildSandboxProfile()`). Zero performance penalty (native OS facility). Wraps the `goosed` daemon process on each spawn.
- **Linux**: **Not yet shipped.** The original feature request ([#5943](https://github.com/block/goose/issues/5943)) proposed bubblewrap support referencing Anthropic's `sandbox-runtime`, but v1.25.0 only implements macOS. Linux bubblewrap support is planned but not released.
- **Scope**: Session-level, not per-tool-call. The entire Goose process runs inside the sandbox. All MCP extensions and tools inherit the restrictions.

The sandbox enforces:
- **Filesystem restrictions**: `~/.ssh` and shell configs are write-protected (configurable via `GOOSE_SANDBOX_PROTECT_FILES`). Goose config files are always write-protected. Kernel extension loading is denied.
- **Network**: All outbound network is blocked except localhost. An HTTP CONNECT proxy in the Electron main process (on `127.0.0.1`) mediates all HTTP/HTTPS traffic. The proxy enforces a multi-layered blocking chain: loopback detection → raw IP blocking → local blocklist (`blocked.txt`, live-reloaded via `fs.watch`) → SSH/Git host restriction → optional LaunchDarkly egress-allowlist. Tunneling tools (`nc`, `ncat`, `netcat`, `socat`, `telnet`) are blocked. Raw sockets (`SOCK_RAW`) are denied.
- **Config protection**: Prevents modifying Goose config files or accessing sensitive system areas.

Key architectural property: **"Because sandboxing happens at the OS level, it applies regardless of which MCP extensions or tools Goose is using."** This is session-wide enforcement — every tool call, every extension, every subprocess inherits the same restrictions.

### Extension isolation details

**Builtin extensions** (developer, computer, memory) are compiled Rust code running in the same process as the agent. There is no process boundary between the agent and these tools. The `developer` extension provides file editing and shell execution. Shell commands spawned by the developer extension run as child processes that inherit the session sandbox.

**Stdio extensions** spawn child processes managed by `child_process_client`:
- Process stderr captured for diagnostics.
- Default timeout: 300 seconds.
- Environment variables: direct `envs` map + `env_keys` retrieved from config/keyring.
- 31 sensitive environment variables blocked via `Envs::DISALLOWED_KEYS`.

**InlinePython (UVX) extensions**:
- Creates temporary directory with `pyproject.toml`.
- Spawns `uvx` process with dependencies.
- Temp directory deleted when Extension struct drops.
- Provides dependency isolation (ephemeral virtualenv) + process boundary.

**Docker containerization**: Stdio extensions can run inside Docker containers when `Agent::set_container()` is called. Commands execute via `docker exec`. This provides full container isolation for MCP servers.

### Subagent isolation

Goose supports up to 10 concurrent subagents with "isolated execution contexts":
- Each subagent gets its own conversation context.
- The Summon extension's `delegate` tool spins up a subagent with a skill loaded.
- Isolation is **context-level** (separate conversation), not **process-level** (same Goose process).
- Subagents share the same sandbox boundaries as the parent.

### Tideclaw implications

Goose's MCP-native architecture is the best fit for Tideclaw's gateway seam:

- **All extensions are MCP**: Point all extensions at `tg-gateway:4100/mcp` → 100% tool call visibility. No shell commands bypass MCP (unlike Codex where the primary tool is a shell executor).
- **Session-level sandbox**: Goose's sandbox wraps the whole process. Inside Tideclaw's container, this sandbox should be **disabled** — Tideclaw's container topology provides the isolation layer. Running both creates unnecessary overhead and potential conflicts.
- **31 blocked env vars**: Good but incomplete. Tideclaw's credential isolation is stronger — MCP server credentials never exist in the agent container's mount namespace.
- **Docker extension support**: Goose can already run stdio MCP servers in Docker containers. In Tideclaw's topology, these containers would be on `mcp-net`, adding network-level isolation on top.
- **Context-level subagent isolation**: Subagents share the same process and sandbox. Tideclaw doesn't add per-subagent isolation (out of scope — context isolation is the runtime's responsibility).

---

## Comparative Summary

### Sandbox granularity

| Runtime | Sandbox boundary | What's sandboxed | What's NOT sandboxed |
|---------|-----------------|-----------------|---------------------|
| **Claude Code** | Per-Bash-command | Each Bash invocation (bubblewrap/Seatbelt) | Read, Write, Edit, Glob, Grep, WebFetch (in-process); MCP servers (separate process, no sandbox by default) |
| **Codex CLI** | Per-command | Each shell command (Landlock + seccomp + env clearing) | MCP tool calls use same sandbox policy as shell |
| **Gemini CLI** | Per-tool-call | Each tool invocation (Seatbelt or Docker) | MCP servers (env sanitization only); sandbox is OFF by default |
| **Goose** | Per-session | Entire Goose process + all child processes (macOS only; Linux not yet shipped) | Nothing escapes session sandbox; but no per-tool-call granularity |

### Network isolation

| Runtime | Mechanism | Granularity | Domain filtering |
|---------|-----------|------------|-----------------|
| **Claude Code** | Proxy via Unix socket (sandbox only) | Bash commands only | Domain allowlist (via proxy) |
| **Codex CLI** | seccomp blocks `connect()` | Per-command (binary on/off) | **None** (all or nothing) |
| **Gemini CLI** | Seatbelt profile or Docker networking | Per-tool-call or per-container | Via proxy (`*-proxied` profiles) or Docker network rules |
| **Goose** | Proxy via Electron main process (macOS only) | All tools share same policy | Blocklist + optional LaunchDarkly allowlist |

### Credential protection

| Runtime | Mechanism | Scope |
|---------|-----------|-------|
| **Claude Code** | Permission deny rules (app-level for in-process tools); sandbox filesystem restrictions (OS-level for Bash) | Session-wide config, per-tool enforcement |
| **Codex CLI** | Env var stripping (`KEY`/`SECRET`/`TOKEN`); cloud two-phase model (secrets removed before agent phase) | Per-subprocess env clearing |
| **Gemini CLI** | Env sanitization for MCP servers (pattern-based redaction); `rootDirectory` constraint | Per-MCP-server spawning |
| **Goose** | 31 blocked env vars (`DISALLOWED_KEYS`); keyring-based secret storage | Per-extension spawning |

### MCP tool dispatch

| Runtime | MCP process model | MCP sandbox treatment |
|---------|------------------|----------------------|
| **Claude Code** | stdio: child process; HTTP: remote connection | Not sandboxed by default. Can wrap with `sandbox-runtime`. |
| **Codex CLI** | `rmcp-client` crate (stdio/HTTP) | **Not sandboxed** — Landlock/seccomp only applies to shell commands |
| **Gemini CLI** | stdio: child process | Env sanitization only. Trust-based confirmation bypass. |
| **Goose** | Six types: builtin (in-process), stdio (child), UVX (ephemeral child), HTTP (remote), platform (in-process), frontend (UI) | All inherit session sandbox. Docker containerization optional. |

---

## What Tideclaw Adds

None of the four runtimes provide:

1. **Cross-tool-call isolation**: All share filesystem/network within their sandbox boundary. Tideclaw's container topology isolates the agent from MCP servers, and MCP servers from each other, at the network level.

2. **MCP content scanning**: No runtime scans the content of MCP tool call parameters or responses. Tideclaw's L2 gateway inspects every string value in every tool call.

3. **Domain-level egress control with credential injection**: Only Claude Code has domain filtering (via sandbox proxy), but it doesn't inject credentials. Codex has no domain filtering at all. Tideclaw's proxy does both.

4. **Taint tracking**: No runtime tracks data flow from file reads to network writes. Tideclaw's L1 eBPF layer observes all `openat()` calls and correlates with `connect()` attempts.

5. **MCP server credential isolation**: All runtimes keep MCP server credentials in the same process or accessible filesystem. Tideclaw isolates each MCP server's credentials in its own container on a separate network.

6. **Skill vetting**: No runtime scans SKILL.md files for malicious intent before loading. Tideclaw plans this for Phase 3.

The architectural insight: **runtimes sandbox the agent; Tideclaw sandboxes the topology**. The runtime prevents the agent from accessing files or network. Tideclaw prevents credentials from existing where they can be stolen, prevents tool calls from containing exfiltrated data, and prevents network traffic from reaching unauthorized destinations — regardless of what the agent's sandbox does or doesn't enforce.
