# Tideclaw — Landscape: AI Coding Tool Profiles (Feb 2026)

> Supporting document for [(SPIKE-013) Tideclaw Architecture](./(SPIKE-013)-Tideclaw-Architecture.md).

---

## Claude Code (Anthropic)
- **Auth**: `claude login` → OAuth tokens stored in `~/.claude/`
- **Billing**: Subscription-based (Max plan) or API key
- **Execution**: Single Node.js process, structured tools (Read, Write, Edit, Bash, Glob, Grep, WebFetch, etc.)
- **MCP**: First-class support — reads `~/.claude/settings.json` for MCP server configs, connects as client. MCP tools appear in hooks as `mcp__<server>__<tool>` (e.g., `mcp__github__search_repositories`).
- **Hooks**: `PreToolUse` / `PostToolUse` hooks — three types: command (shell), prompt (LLM yes/no), agent (subagent with tools). **Critical**: As of v2.0.10, PreToolUse hooks can **modify tool inputs** before execution — enabling transparent sandboxing invisible to the model. Returns `allow`, `deny`, `escalate`, or modified params.
- **Sandboxing**: Open-source `@anthropic-ai/sandbox-runtime` ([GitHub](https://github.com/anthropic-experimental/sandbox-runtime)) using **bubblewrap** (Linux) and **Seatbelt** (macOS). On Linux: `clone(2)` with `CLONE_NEWNET` + `CLONE_NEWPID` → own network namespace with only loopback. All traffic forced through proxy via Unix domain sockets (bridged by `socat`). seccomp BPF blocks unauthorized Unix socket creation. Reduces permission prompts by 84%.
- **Permissions**: Interactive approval or `--dangerously-skip-permissions` for headless
- **Network**: Direct HTTPS to Anthropic API + any configured MCP servers. Sandbox mode forces all traffic through proxy with domain allowlists.
- **Agent SDK**: `@anthropic-ai/claude-code` npm package, `query()` API with `bypassPermissions`. `can_use_tool` handler for custom permission logic. `SandboxSettings` for configuring excluded commands and sandbox policies.
- **Skills**: First-class support. CLAUDE.md for persistent project context. `.claude/skills/` for on-demand expertise (SKILL.md format). Slash commands merged into skills (v2.1.3, Jan 2026). Skills use progressive disclosure (~50 tokens at rest, ~5,000 when activated). Plugins bundle skills + hooks + MCP into installable units.
- **Key insight**: Claude Code extends via two planes: MCP (tool connectivity) and Skills (procedural knowledge). All external tools go through MCP — this is our scanning seam. The PreToolUse hook with input modification is directly analogous to Tideclaw's gateway interception. But skills also influence agent behavior — a malicious skill can instruct the agent to craft legitimate-looking tool calls that exfiltrate data. Tideclaw needs both MCP gateway scanning AND skill vetting. The sandbox-runtime is reusable for sandboxing downstream MCP servers.

## OpenAI Codex CLI
- **Auth**: ChatGPT OAuth login or `OPENAI_API_KEY` env var. Credentials stored in OS keyring (macOS Keychain, Windows Credential Manager, Linux Secret Service) or encrypted `~/.codex/auth.json`.
- **Billing**: API usage-based (metered) or ChatGPT Plus/Pro subscription
- **Execution**: **Rewritten in Rust** (from TypeScript). SQ/EQ protocol (`protocol.rs`) for bidirectional comms between surfaces (TUI, exec, app-server) and core agent loop. Model: `gpt-5.3-codex`. One primary tool: unified shell executor (not structured tools like Claude Code).
- **Sandbox**: OS-native kernel sandboxing, NOT containers:
  - **Linux**: **Landlock** (kernel 5.13+) for filesystem access control + **seccomp-BPF** blocking `connect()`, `accept()`, `bind()` (preserves `recvfrom`). Helper binary `codex-linux-sandbox` applies restrictions before `execvp`. Also strips `LD_PRELOAD`, disables ptrace, zeros core file limits.
  - **macOS**: Apple Seatbelt (`sandbox-exec`) with runtime-generated profiles. `.git` and `.codex` kept read-only to prevent repo corruption.
  - **Windows**: AppContainer with `CreateRestrictedToken()` + job objects.
  - Three modes: `read-only` (read anywhere, write nowhere, no network), `workspace-write` (default — writes in project dir only, no network), `danger-full-access` (unrestricted).
- **MCP**: **Yes — both client and server.** `rmcp-client` crate for connecting to external MCP servers. `codex mcp-server` exposes Codex as an MCP server. Supports stdio and Streamable HTTP.
- **Credential protection**: Environment variables containing `KEY`, `SECRET`, or `TOKEN` are **automatically excluded** from subprocess environments (case-insensitive glob). Cloud mode: secrets available during setup phase only, **removed before agent phase starts**.
- **Network**: Binary on/off at the syscall level. No domain-level filtering or proxy. Cloud mode: internet disabled by default during agent phase, configurable per-environment domain allowlists.
- **Web search**: Default is cached mode (pre-crawled index, not live fetches) to reduce prompt injection risk from arbitrary content.
- **Key insight**: Strong OS-native sandboxing but coarse-grained network control (all or nothing). MCP support exists, so Tideclaw can use MCP gateway mode. Env var stripping catches credential leaks but not content-embedded credentials. Cloud two-phase model (setup with creds → agent without) is a clean pattern.

## Google Gemini Code Assist / Jules
- **Auth**: Google account OAuth
- **Billing**: Workspace subscription ($75/dev/month enterprise) or API key
- **Execution**: **Jules**: Cloud-hosted, each task runs in a dedicated ephemeral Ubuntu VM on Google Cloud, powered by Gemini 3 Pro. VMs destroyed after task completion — no persistent containers. Pre-installed toolchains (Node.js, Bun, Python, Go, Java, Rust). **Code Assist**: VS Code extension with newer "Agent Mode" for codebase-wide changes.
- **Sandbox**: Jules VMs get two layers: hardware-backed VM isolation (x86 virtualization) + software kernel layer (likely gVisor). VMs have **full internet access** (necessary for dependency installation). Concurrency limited per plan.
- **MCP**: Gemini Code Assist migrating from Tool Calling API to MCP (deadline March 2026). Jules has CLI and public API (October 2025).
- **Network**: Jules VMs have full internet — no fine-grained egress controls. Google emphasizes "privacy by design" (no training on user code).
- **Key insight**: VM-per-task with destruction provides strongest isolation but at compute cost. Full internet access is the opposite of Tideclaw's default-deny model. Jules' ephemeral VMs mean credentials cease to exist when the task ends — a clean answer to credential leakage that doesn't require scanning.

## Goose (Block)
- **Auth**: Any LLM provider API key. Stored in OS keyring. Supports 25+ providers including Anthropic, OpenAI, Google, xAI, Mistral, Bedrock, Vertex AI, plus local via Ollama/Docker Model Runner. Multi-model configuration (use different models per task).
- **Billing**: Free and open source (Apache 2.0). You only pay your LLM provider.
- **Execution**: **Rust** binary (Cargo workspace: `goose`, `goose-cli`, `goose-server`, `goose-mcp`). Agent loop dispatches tool calls to extensions. Context revision prunes old information to manage token usage. Errors are sent back to the model for self-correction. Up to 10 concurrent subagents with isolated execution contexts.
- **MCP**: **Foundational** — MCP is the backbone of Goose's extensibility. All extensions (built-in and external) are MCP servers. Block co-designed MCP with Anthropic. Six extension types: Builtin (compiled Rust), Platform (in-process Rust), Frontend (UI-side), UVX (Python via uv), SSE/Streamable HTTP (remote), Stdio (local). Migrating from internal implementation to official `rmcp` Rust SDK.
- **Skills**: **Yes — Agent Skills standard.** `SKILL.md` files with YAML frontmatter. Enabled by default via the **Summon extension** (v1.25.0), which unifies skills and recipes into two tools: `load` (inject skill instructions into context on demand) and `delegate` (spin up subagent with skill in isolation). Three discovery directories in priority order: `~/.claude/skills/` (global, shared with Claude Desktop — cross-agent portability), `.goose/skills/` (project-level, goose-specific), `.agents/skills/` (project-level, portable across all Agent Skills-compatible tools). Progressive disclosure: only name/description at startup, full SKILL.md on demand. Block runs an internal skills marketplace (100+ skills, curated bundles by team role).
- **Recipes**: Parameterized YAML workflow definitions. Support sub-recipes, retry logic, cron scheduling, extension requirements, max turns. Composable automation for CI/CD.
- **Sandboxing**: **Yes (v1.25.0, Feb 23, 2026)**. macOS: Seatbelt (`sandbox-exec`) with dynamically generated profiles. Linux: bubblewrap (bwrap). Both work without Docker and can sandbox network access. SLSA provenance attestations on all release artifacts via Sigstore.
- **Docker**: Official images at `ghcr.io/block/goose:<version>`. Debian Bookworm Slim, non-root UID 1000. Docker Compose workflows supported. Docker Model Runner integration for fully local LLM stacks.
- **Headless/API**: `goose run` for non-interactive execution. `--quiet` suppresses non-response output. `--output-format json` or `stream-json` for structured output. `--no-session` for one-off CI invocations. `--max-turns <N>` to cap autonomous turns. Cron scheduling for recipes.
- **Network**: No built-in network isolation beyond sandbox (no proxy, no domain allowlists). MCP servers connect to external APIs directly.
- **Community**: 31K+ GitHub stars, 373+ contributors, 100+ releases in one year. Contributed to Linux Foundation AAIF (Dec 2025) alongside MCP and AGENTS.md. Block internal adoption: 60% of 12K employees use weekly. Red-teamed with published results ("Operation Pale Fire," Jan 2026).
- **Key insight**: Goose is the strongest non-Claude/Codex alternative for Tideclaw. MCP-native architecture means the gateway seam activates cleanly. Rust binary means fast startup and single-binary distribution like Codex. Skills support means Tideclaw needs to consider skill security scanning (not just MCP tool scanning). Headless mode with structured JSON output makes container orchestration straightforward. The gap: no built-in egress control or credential isolation — exactly what Tideclaw provides.

## Aider (Aider-AI)
- **Auth**: Direct API keys for any LLM provider. `--api-key anthropic=<key>` or env vars. Supports OpenAI, Anthropic, Google, xAI, DeepSeek, Cohere, plus OpenRouter, Azure, Bedrock, Vertex AI, GitHub Copilot tokens. Local models via Ollama.
- **Billing**: Free and open source (Apache 2.0). Pay your LLM provider.
- **Execution**: **Python** single process. The architecture centers on a tree-sitter-based **repository map** that builds an AST graph of the entire codebase, then uses **PageRank** (personalized to chat context) to select the most relevant code for the LLM's context window. Modular coders (`aider/coders/`) support search/replace, diff, patch, editor-diff formats. Architect mode uses two LLM calls (plan then edit). Automatic lint-and-fix loop after every edit. Git commit after every change.
- **MCP**: **No native support.** Open feature requests (Issues [#3314](https://github.com/Aider-AI/aider/issues/3314), [#4506](https://github.com/aider-ai/aider/issues/4506)) remain unaddressed. Community workarounds exist (mcpm-aider, third-party MCP servers wrapping aider). AiderDesk (GUI wrapper) has MCP, but the CLI does not.
- **Skills/Plugins**: **None.** No formal plugin, skill, or extension system. No hook events. The `.aider.conventions` file provides basic project context but is not comparable to SKILL.md or CLAUDE.md. IDE integration via `--watch-files` (monitors `AI!`/`AI?` comments in code). Unofficial Python API (`from aider.coders import Coder`) exists but is undocumented and may break.
- **Sandboxing**: **None.** Runs with full user permissions. No filesystem isolation, no network isolation. Must rely on external sandboxing (Docker containers, bubblewrap, etc.).
- **Docker**: Official images (`paulgauthier/aider`, `paulgauthier/aider-full`). Runs as non-root. Limitation: `/run` command executes inside the container, making project test execution tricky.
- **Headless/API**: Limited. `--message` / `-m` for single instruction. `--yes` for auto-approve. `--dry-run` for preview. No structured JSON output. No proper headless daemon mode.
- **Network**: Direct HTTPS to LLM API. No proxy support. No egress control.
- **Community**: 41K GitHub stars, 168 contributors, Apache 2.0. **Single maintainer risk** (Paul Gauthier). Self-dogfooding metric: 21-88% of each release written by aider itself. Maintains [LLM code editing leaderboards](https://aider.chat/docs/leaderboards/).
- **Key insight**: Aider has the best code editing engine (tree-sitter + PageRank repo map) among open-source tools, but lacks every integration point Tideclaw needs: no MCP (no gateway seam), no headless mode (no container orchestration), no plugin system (no skill scanning needed but also no extensibility). Tideclaw could orchestrate aider in proxy-only mode (Mode 2), but the lack of MCP means medium-fidelity scanning only. The missing headless/API mode makes container lifecycle management harder than necessary.

## llm CLI (Simon Willison)
- **Auth**: API keys per provider. Supports OpenAI (built-in), plus 51+ plugins for Anthropic, Google, Mistral, Groq, xAI, OpenRouter, Bedrock, and 7 local model backends (Ollama, MLX, GGUF, llamafile, etc.).
- **Execution**: **Python** single process, Click-based CLI + Python library. Plugin architecture via pluggy (entry-point-based discovery). Six hook types: `register_models`, `register_embedding_models`, `register_tools`, `register_fragment_loaders`, `register_template_loaders`, `register_commands`.
- **Tool calling**: Added in v0.26 (May 2025). Inline Python functions via `--functions`, plugin-based tools (`--tool/-T`), templates with tools (v0.27). Agent loop via `--chain-limit` (max consecutive tool calls, default 5). Comprehensive SQLite logging of all tool calls.
- **MCP**: **Community plugin only** (`llm-tools-mcp` by VirtusLab). Not in core. Simon Willison has stated intent to add native MCP client support but it is not yet built.
- **Skills/Plugins**: Rich plugin ecosystem (51+ plugins) but for model access, tool registration, and fragment loading — not for coding workflows or agent behavior. No SKILL.md support. No coding skills.
- **Sandboxing**: **None.** `llm-tools-docker` plugin (early alpha) grants access to a Docker container per chat session, but this is for tool execution, not agent sandboxing.
- **Coding capabilities**: **Not a coding agent.** No built-in file editing, code manipulation, or autonomous iteration. Designed for chat, completion, and Unix pipelines (`cat file.py | llm "refactor this"`). `llm-cmd` plugin generates shell commands. Simon uses Claude Code for actual coding.
- **Key differentiator**: SQLite logging of every interaction (the original motivation for building llm). Provider-agnostic. Unix pipeline composability. Fragments system for assembling context from multiple sources.
- **Community**: 11K GitHub stars, single maintainer (Simon Willison). v0.28 (Dec 2025).
- **Key insight**: llm is **not a viable base for Tideclaw**. It is a completion/chat tool, not a coding agent. It has no file editing, no autonomous agent loop, no code execution. Its plugin architecture is elegant but solves a different problem. Tideclaw could theoretically wrap llm as a provider abstraction layer, but that would mean building the entire agent runtime from scratch — defeating the purpose of having a base.

## Other Emerging Tools
- **Cursor Agent Mode**: IDE-embedded, no CLI, no container boundary
- **Windsurf (Codeium)**: IDE-embedded, "Memories" feature for persistent project context (conceptually similar to skills)
- **Continue.dev**: VS Code/JetBrains extension, MCP support, no sandbox

## Summary: What Can Tideclaw Orchestrate?

| Tool | Has CLI? | Has sandbox? | Has MCP? | Has Skills? | Integration mode |
|------|----------|-------------|----------|-------------|-------------------|
| **Claude Code** | Yes | bubblewrap + seccomp | Yes (first-class) | Yes (SKILL.md, CLAUDE.md, hooks) | **MCP gateway** — route all MCP calls through scanner |
| **Codex CLI** | Yes | Landlock + seccomp | Yes (client + server) | Yes (Agent Skills standard) | **MCP gateway + proxy** — hybrid mode |
| **Goose** | Yes | bubblewrap / seatbelt (v1.25.0) | Yes (foundational) | Yes (SKILL.md + recipes) | **MCP gateway** — all extensions are MCP servers |
| **Gemini (Jules)** | Yes (new CLI) | Yes (cloud VM) | Migrating to MCP | Yes (Agent Skills standard) | **Not orchestrable locally** (cloud only) |
| **Gemini (Code Assist)** | No (extension) | VS Code sandbox | Migrating to MCP | Yes (Agent Skills standard) | **Not orchestrable** as CLI tool |
| **Aider** | Yes | No | No | No (`.aider.conventions` only) | **Container + proxy** — full isolation |
| **llm CLI** | Yes | No | Community plugin | No | **Not a coding agent** — completion tool only |
| **Continue.dev** | No (extension) | No | Yes | No | **MCP gateway** (if extracted from IDE) |

**Conclusion**: **Claude Code**, **Codex CLI**, and **Goose** all have both MCP and Skills support, meaning Tideclaw can activate the MCP gateway seam for all three. Goose is the strongest open-source alternative — its MCP-native architecture means all extensions route through the gateway seam by design. The Skills column is new: the Agent Skills standard (agentskills.io, Dec 2025) has been adopted by 40+ agents, making skill security scanning a Tideclaw concern alongside MCP tool scanning (see [security-landscape.md](./security-landscape.md)).
