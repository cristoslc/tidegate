# Tideclaw — Architecture Spike: Security-First Orchestrator for AI Coding Tools

## Lifecycle

| Stage | Commit | Date | Notes |
|---|---|---|---|
| active | — | 2026-02-25 | Spike started; researched Claude Code, Codex CLI, Gemini, MCP security, E2B, Daytona |
| active | — | 2026-02-27 | Added Aider, Goose, llm CLI deep-dives; added Skills Paradigm section; added non-Claude/Codex base evaluation |

## Purpose

Design **Tideclaw** from scratch: a security-first orchestrator for AI coding tools. Like ClaudeClaw or NanoClaw, Tideclaw is an orchestrator — it manages the lifecycle of an agentic runtime (Claude Code, Codex CLI, Aider, etc.). Unlike those orchestrators, Tideclaw's primary concern is providing the **process separation and enforcement seams** that Tidegate's security layers need to attach to.

The user picks their agentic runtime. Tideclaw orchestrates it with credential isolation, network segmentation, MCP scanning boundaries, egress control, and taint tracking built into the orchestration topology.

### Why a new orchestrator?

The current Tidegate approach (ADR-003) chose NanoClaw as the first agent runtime — a specific orchestrator that already has Docker containers and filesystem IPC. That gave Tidegate an enforcement seam but coupled the security framework to one orchestrator. The problem: NanoClaw's process boundaries weren't designed for security enforcement. They're incidental to its orchestration model, not intentional seams.

Tideclaw asks: **what if the orchestrator IS designed around the seams?**

ClaudeClaw and NanoClaw are orchestrators that happen to use containers. Tideclaw is an orchestrator that exists *because of* containers — because process separation, network isolation, and mount boundaries are the seams that make security enforcement possible.

Tideclaw provides:
- Process separation between agent and MCP servers (the scanning seam)
- Network segmentation between agent, gateway, and servers (the egress control seam)
- Mount isolation for credentials (the credential isolation seam)
- Kernel-level observation points (the taint tracking seam)

The agentic runtime runs inside these seams, unmodified.

---

## The Landscape: Login-Based AI Coding Tools (Feb 2026)

### Claude Code (Anthropic)
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

### OpenAI Codex CLI
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

### Google Gemini Code Assist / Jules
- **Auth**: Google account OAuth
- **Billing**: Workspace subscription ($75/dev/month enterprise) or API key
- **Execution**: **Jules**: Cloud-hosted, each task runs in a dedicated ephemeral Ubuntu VM on Google Cloud, powered by Gemini 3 Pro. VMs destroyed after task completion — no persistent containers. Pre-installed toolchains (Node.js, Bun, Python, Go, Java, Rust). **Code Assist**: VS Code extension with newer "Agent Mode" for codebase-wide changes.
- **Sandbox**: Jules VMs get two layers: hardware-backed VM isolation (x86 virtualization) + software kernel layer (likely gVisor). VMs have **full internet access** (necessary for dependency installation). Concurrency limited per plan.
- **MCP**: Gemini Code Assist migrating from Tool Calling API to MCP (deadline March 2026). Jules has CLI and public API (October 2025).
- **Network**: Jules VMs have full internet — no fine-grained egress controls. Google emphasizes "privacy by design" (no training on user code).
- **Key insight**: VM-per-task with destruction provides strongest isolation but at compute cost. Full internet access is the opposite of Tideclaw's default-deny model. Jules' ephemeral VMs mean credentials cease to exist when the task ends — a clean answer to credential leakage that doesn't require scanning.

### Goose (Block)
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

### Aider (Aider-AI)
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

### llm CLI (Simon Willison)
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

### Other Emerging Tools
- **Cursor Agent Mode**: IDE-embedded, no CLI, no container boundary
- **Windsurf (Codeium)**: IDE-embedded, "Memories" feature for persistent project context (conceptually similar to skills)
- **Continue.dev**: VS Code/JetBrains extension, MCP support, no sandbox

### Summary: What Can Tideclaw Orchestrate?

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

**Conclusion**: **Claude Code**, **Codex CLI**, and **Goose** all have both MCP and Skills support, meaning Tideclaw can activate the MCP gateway seam for all three. Goose is the strongest open-source alternative — its MCP-native architecture means all extensions route through the gateway seam by design. The Skills column is new: the Agent Skills standard (agentskills.io, Dec 2025) has been adopted by 40+ agents, making skill security scanning a Tideclaw concern alongside MCP tool scanning (see Skills Paradigm section below).

---

## Prior Art: How Others Solve Agent Sandboxing

### Isolation Tier Hierarchy

| Tier | Technology | Isolation Strength | Startup Time | Example |
|------|-----------|-------------------|-------------|---------|
| **MicroVMs** | Firecracker, Kata, libkrun | Strongest (dedicated kernel, KVM) | ~125ms | E2B, microsandbox |
| **gVisor** | User-space kernel | Strong (syscall interception) | Fast | Modal, GKE Agent Sandbox |
| **Hardened containers** | Docker + seccomp/AppArmor | Moderate (shared host kernel) | Fastest | Tideclaw, Docker MCP |
| **OS-native** | Landlock + seccomp, bubblewrap | Moderate (process-level) | Zero overhead | Codex CLI, Claude Code |
| **Prompt-based** | System prompt instructions | None | N/A | ClaudeClaw |

NVIDIA's AI Red Team recommends fully virtualized environments (VMs, unikernels, Kata Containers) isolated from the host kernel for production untrusted code execution.

### E2B (e2b.dev)
- **Mechanism**: Firecracker microVMs backed by KVM hardware virtualization. Each sandbox gets its own Linux kernel. Companion "jailer" process provides second layer via cgroups + namespaces. Same technology as AWS Lambda/Fargate.
- **Performance**: Boot <125ms. Memory <5 MiB per VM. Pre-warmed snapshots eliminate cold starts (<200ms full provision).
- **Network**: Global `allowInternetAccess` boolean (default: true). Fine-grained `allowOut`/`denyOut` lists (IP/CIDR). Domain filtering via HTTP Host header (port 80) and TLS SNI (port 443). No UDP/QUIC domain filtering. Firecracker rate limiter constrains bandwidth/IOPS per VM.
- **Credential management**: App-level injection. Isolation guarantee: sandbox escape can't reach other tenants.
- **Deployment**: Managed cloud (default) or BYOC in AWS/GCP/Azure/on-premises.
- **Relevance**: Strongest isolation tier. If Docker containers aren't enough for Tideclaw's threat model, Firecracker is the upgrade path. E2B's template system (Dockerfiles → snapshotted VM images) could inspire Tideclaw's image build process.

### Daytona
- **Mechanism**: Tiered isolation — default Docker (shared kernel), optional Kata Containers (full VM), Sysbox (rootless). **Critical**: security posture depends entirely on backend choice. Default Docker is weakest.
- **Performance**: Sub-90ms sandbox creation (container mode). Faster than E2B because containers only need namespaces + mount.
- **Network**: `networkAllowList` (up to 5 CIDR blocks), `networkBlockAll`. Tier-gated — lower billing tiers have restricted network.
- **Stateful**: Unlike E2B (ephemeral by default), supports snapshot/restore for long-running agent tasks.
- **Relevance**: Workspace model similar to Tideclaw but without security scanning layers. Kata Containers backend worth considering if Tideclaw upgrades past Docker.

### Pipelock — Most Architecturally Similar to Tideclaw
[Pipelock](https://github.com/luckyPipewrench/pipelock) is a single Go binary sitting between AI agents and the outside world. **The closest existing analog to Tideclaw's architecture.**

- **Capability separation**: Agent (has secrets, no network) vs. fetch proxy (has network, no secrets) — directly maps to Tideclaw's `agent-net` vs `mcp-net` split.
- **9-layer scanner pipeline**: Domain blocklist, SSRF protection, DLP patterns (regex for API keys/tokens/secrets), env variable leak detection (raw + base64, values ≥16 chars with entropy > 3.0), path entropy analysis (Shannon), subdomain entropy analysis.
- **MCP server scanning**: Wraps any MCP server as stdio proxy. Scans both directions: client requests for DLP leaks and injection in tool arguments; server responses for prompt injection; `tools/list` responses for poisoned descriptions and rug-pull definition changes.
- **Docker integration**: Generated compose creates two containers — pipelock (fetch proxy with internet) and agent (internal-only network).
- **Actions**: block, strip (redact), warn (log and pass), ask (terminal prompt with timeout).
- **Relevance**: Validates Tideclaw's architecture. Key differences: Pipelock is a single binary (proxy+scanner), Tideclaw separates gateway from proxy. Pipelock does MCP tool description scanning (tool poisoning defense) that Tideclaw doesn't yet. Pipelock lacks taint tracking (ADR-002).

### Docker MCP Gateway (Open Source)
[docker/mcp-gateway](https://github.com/docker/mcp-gateway) — **The closest commercial analog to Tideclaw's gateway.**

- **Architecture**: Sits between agents and MCP servers as middleware. Manages server lifecycles — starts containers on demand, injects credentials, applies security restrictions, forwards requests.
- **Interceptor framework**: Custom scripts/plugins inspect, modify, or block requests in real time:
  - "Before" interceptors: argument/type checks, safety classifiers, session enforcement
  - "After" interceptors: response logging, secret masking, PII scrubbing
- **Policy enforcement**: `--verify-signatures` (image provenance), `--block-secrets` (payload scanning), `--log-calls` (audit).
- **Credential management**: Docker Desktop integration. OAuth flows. Credentials injected by gateway, never passed by agent.
- **Docker Sandboxes**: MicroVM-based isolation for coding agents. Supports Claude Code, Codex CLI, Copilot CLI, Gemini CLI, Kiro. Domain allow/deny lists.
- **Relevance**: Docker's gateway validates the interceptor pattern. Tideclaw's gateway does deeper content scanning (L1/L2/L3 vs Docker's regex `--block-secrets`). Docker's microVM sandboxes for coding agents are a competitive offering. Tideclaw differentiates via taint tracking, shaped denies, and self-hosted operation.

### Claude Code sandbox-runtime
[anthropic-experimental/sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) — Open-source, reusable sandbox for arbitrary processes, agents, and MCP servers.

- **Linux**: bubblewrap + seccomp BPF. Network namespaces (`CLONE_NEWNET` + `CLONE_NEWPID`). Only loopback device. Traffic forced through proxy via Unix domain sockets (bridged by `socat`). Pre-compiled BPF programs for x64 and arm64.
- **macOS**: Seatbelt profiles.
- **Filesystem**: Read/write restricted to CWD. Mandatory deny paths for sensitive locations. ripgrep scans write paths for dangerous files.
- **Relevance**: Could be used inside Tideclaw's agent container to sandbox individual tool executions. Also usable for sandboxing downstream MCP servers on `mcp-net`. Reduces permission prompts by 84%.

### Codex CLI's Sandbox (detailed)
- **Linux**: Landlock + seccomp-BPF (NOT Docker on local). Helper binary `codex-linux-sandbox` applies restrictions before `execvp`. Landlock grants read everywhere, restricts writes to workspace + `/dev/null`. seccomp blocks `connect()`, `accept()`, `bind()` but preserves `recvfrom`. Also strips `LD_PRELOAD`, disables ptrace, zeros core files.
- **macOS (Seatbelt)**: Runtime-generated profiles. `.git` and `.codex` kept read-only. Binary network on/off.
- **Windows**: AppContainer with restricted tokens + job objects.
- **Cloud two-phase model**: Setup phase (network + secrets available for dependency installation) → Agent phase (network disabled by default, secrets removed). This is the cleanest credential isolation pattern in the industry.
- **Gap for Tideclaw**: Codex handles local process isolation well. What it doesn't do: scan tool call/shell command contents for sensitive data, isolate third-party API credentials from the agent process, provide domain-level egress control, or track data flow via taint analysis. These are Tideclaw's additions.

### Kubernetes Agent Sandbox (kubernetes-sigs)
[kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) — Declarative CRD API for sandboxed agent workloads.

- **Backend-agnostic**: gVisor (default) or Kata Containers.
- **CRDs**: `Sandbox`, `SandboxTemplate` (blueprints), `SandboxClaim` (for LangChain, ADK, etc.).
- **Performance**: Pre-warmed pools deliver sub-second latency (90% improvement over cold starts).
- **Relevance**: Kubernetes-native. If Tideclaw targets k8s deployment, these CRDs are the integration point.

### microsandbox (zerocore-ai)
[zerocore-ai/microsandbox](https://github.com/zerocore-ai/microsandbox) — Self-hosted microVMs via libkrun.

- **Isolation**: KVM-based hardware virtualization. Each sandbox gets own kernel and memory.
- **Performance**: Under 200ms boot. OCI-compatible (runs standard container images).
- **Key difference from E2B**: Entirely self-hosted. No managed cloud dependency.
- **Relevance**: If Tideclaw needs stronger isolation than Docker but must stay self-hosted, microsandbox is the upgrade path.

### MCP Security Landscape (2025-2026)

#### Authorization (spec evolution)
Three major spec revisions since March 2025:
- **2025-03-26**: OAuth 2.1 introduced. MCP servers were both Resource Server and Authorization Server (bad).
- **2025-06-18**: Decoupled. Servers are OAuth Resource Servers. Resource Indicators (RFC 8707) mandatory — tokens scoped to specific MCP servers, preventing cross-server replay. SSE deprecated → Streamable HTTP.
- **2025-11-25**: Client ID Metadata Documents (CIMD) replace Dynamic Client Registration. Enterprise-Managed Auth via Identity Assertion Authorization Grant (XAA). OpenID Connect Discovery. Incremental scope consent.

#### Security incidents (real-world)
| Incident | Impact | Relevance |
|----------|--------|-----------|
| **Postmark-MCP supply chain** (Sep 2025) | Backdoored npm package BCC'd all emails to attackers. 1,500 weekly downloads. | Tideclaw's response scanning catches credential patterns in outbound email content. |
| **Smithery supply chain** (Oct 2025) | Path-traversal in build config exfiltrated API tokens from 3,000+ hosted apps. | Tideclaw isolates credentials in MCP server containers — even compromised servers can't leak other servers' credentials. |
| **mcp-remote RCE** (CVE-2025-6514) | Command injection via malicious `authorization_endpoint`. CVSS 9.6. 437,000+ downloads. Featured in official Cloudflare/Auth0 guides. | Tideclaw's gateway doesn't process OAuth metadata URLs — downstream servers handle their own auth. |
| **Claude Desktop Extensions RCE** (CVSS 10.0) | Malicious MCP responses → remote code execution. Zero user interaction. | Tideclaw's response scanning catches payloads before they reach the agent. |
| **GitHub MCP prompt injection** | Malicious GitHub issue hijacked agent, exfiltrated private repos via over-privileged PAT. | Tideclaw's credential isolation: PAT lives in MCP server container, not agent. Agent can't access it even when compromised. |

#### Tool poisoning
- 5.5% of public MCP servers contain tool poisoning vulnerabilities
- 43% of public servers contain command injection flaws
- 84.2% attack success rate with auto-approval enabled
- Tool poisoning works even if the tool is never called — just being loaded into context is enough
- **Rug pulls**: Tool behavior changes silently after initial approval
- **MCP shadowing**: Malicious server redefines tool descriptions of already-loaded trusted servers

#### Elicitation (new data channel)
Introduced in 2025-06-18 spec. MCP servers can request user input via `elicitation/create`:
- **Form mode**: Structured data collection (strings, numbers, booleans, enums). Data returned directly.
- **URL mode** (2025-11-25): Server provides URL for user to visit externally. Used for OAuth, payments. **Potential phishing vector.**
- **Implication for Tideclaw**: The gateway should scan/audit elicitation requests. URL mode elicitations could be used for social engineering.

#### Ecosystem scale
- 13,000+ MCP servers on GitHub (2025)
- 8 million+ total downloads (up from 100K in Nov 2024 — 80x in 5 months)
- ~7,000 servers exposed on open web; ~1,800 without authentication
- Docker MCP Catalog hosts 270+ enterprise-grade servers

#### Key gap
**MCP has no built-in concept of a security gateway between client and server.** The spec's security model is client-side consent (user approves tool calls). This fails when the agent runs headless with `--dangerously-skip-permissions`. Tideclaw fills this gap with server-side policy enforcement.

### The Skills Paradigm (2025-2026)

Skills are an emerging extension paradigm **complementary to MCP** that Tideclaw must account for alongside tool-level scanning. While MCP provides connectivity (structured tool APIs for accessing external systems), Skills provide expertise (natural-language instructions encoding domain knowledge and workflow logic). Both are attack surfaces. Tideclaw's original architecture over-indexed on MCP as the sole extension mechanism — the reality is that modern agentic runtimes have two extension planes: **tools (MCP)** and **knowledge (Skills)**.

#### What are Skills?

A skill is a folder containing a `SKILL.md` file with YAML frontmatter (name, description, allowed-tools) and a markdown body of instructions. Optional subfolders hold scripts, references, and assets. Skills teach agents *how* to perform tasks using the tools they have access to.

**Progressive disclosure** is the key architectural feature: at session start, only skill name + description load (~50 tokens per skill). The full SKILL.md body (~5,000 tokens) loads on demand when the agent determines relevance. Compare this to MCP, where a typical 5-server setup consumes ~55,000 tokens upfront to load all tool definitions.

#### Agent Skills open standard (Dec 2025)

Anthropic released Agent Skills as an open standard at agentskills.io in December 2025. Adoption was rapid:
- **40+ agents** adopted the SKILL.md format within weeks: Claude Code, Codex CLI, Gemini CLI, GitHub Copilot, Cursor, Windsurf, Goose, Roo Code, Trae, Amp, and more.
- **Vercel's skills.sh** (launched Jan 20, 2026): Package manager and registry. 110,000+ installs in four days across 17 agents. Snyk security scans on every install.
- **96,000+ skills** in circulation across marketplaces (skills.sh, ClawHub/OpenClaw, SkillsMP) as of Feb 2026.

Before the standard, each tool had its own approach: Cursor `.cursor/rules/*.mdc`, Windsurf `.windsurfrules`, GitHub Copilot `.github/copilot-instructions.md`, Aider `.aider.conventions`. The Agent Skills standard unifies these under a single portable format.

#### Skills vs MCP: complementary, not competing

| Dimension | Skills | MCP |
|-----------|--------|-----|
| **What it provides** | Procedural knowledge (how to do things) | Tool connectivity (what can be reached) |
| **Format** | Natural language markdown | Structured JSON-RPC protocol |
| **Token cost** | ~50 tokens at rest, ~5,000 when active | ~55,000 tokens for typical 5-server setup |
| **Who can author** | Anyone who can write markdown | Developers who implement servers |
| **Portability** | Works across 40+ agents via open standard | Requires client/server implementation |
| **Security surface** | Prompt injection, memory poisoning, supply chain | Tool poisoning, RCE, supply chain |
| **Relationship** | Consumes MCP tools | Consumed by Skills |

A single skill can orchestrate multiple MCP servers (e.g., a "deploy" skill coordinating GitHub, Docker, and AWS MCP servers). A single MCP server can support dozens of skills. The full extension stack: CLAUDE.md (always-on context) → Skills (on-demand expertise) → MCP (external connections) → Hooks (guaranteed automation) → Plugins (packaging layer).

#### Skills security: a new attack surface

Skills represent a **distinct and serious security surface** that pattern scanning alone cannot address:

**ClawHavoc campaign (Jan 2026)**: Security audit of ClawHub found 341 malicious skills (~12% of registry) delivering Atomic Stealer (AMOS), a macOS infostealer. Professional documentation, names like "solana-wallet-tracker" and "youtube-summarize-pro." Target: exchange API keys, wallet private keys, SSH credentials, browser passwords.

**Snyk ToxicSkills study (Feb 2026)**: Scanning 3,984 skills from ClawHub and skills.sh:
- **13.4% (534 skills)** contain critical-level security issues (malware, prompt injection, exposed secrets)
- **36.82% (1,467 skills)** have at least one security flaw
- 36% contain prompt injection
- Snyk demonstrated going "from SKILL.md to shell access in three lines of markdown"

**Key attack vectors**:
1. **SKILL.md as code execution**: Natural-language instructions that result in shell commands, inheriting the agent's access. Traditional AppSec tools don't scan markdown for intent.
2. **Memory poisoning**: Adversaries implant false information into agent long-term storage. Unlike session-scoped prompt injection, poisoned memory persists across sessions.
3. **Supply chain poisoning**: Malicious skills published to registries with professional documentation. Same class of attack as npm/PyPI malware, adapted for AI skill ecosystems.
4. **The "lethal trifecta"**: Skills are dangerous because agents combine access to private data + exposure to untrusted content + ability to communicate externally.

**Why existing scanners fail**: Community skill scanners using denylist approaches are fundamentally flawed — you cannot block specific words in a system designed to understand concepts. Snyk found that a malicious skill received a verdict of CLEAN while the scanner itself was flagged as DANGEROUS.

#### Implications for Tideclaw

Tideclaw's original architecture focuses on three enforcement layers: taint tracking (L1), MCP gateway scanning (L2), and egress proxy scanning (L3). **Skills introduce a fourth attack surface that none of these layers address directly:**

1. **L2 (MCP gateway)** catches malicious tool call parameters — but a poisoned skill can instruct the agent to craft tool calls that *look legitimate* while exfiltrating data. The parameters may not contain credential patterns; the *intent* is malicious.
2. **L3 (egress proxy)** catches unauthorized network destinations — but a poisoned skill can instruct the agent to exfiltrate data through *allowed* channels (e.g., committing sensitive data to a GitHub repo the agent has write access to).
3. **L1 (taint tracking)** catches file-to-network data flows — this layer *does* help, because taint tracking is intent-agnostic. If a skill causes the agent to read a sensitive file and then make a network call, the taint tracker fires regardless of whether the skill instructed it.

**New enforcement seam needed**: Skill vetting/scanning before load. Options:
- **(a) Static analysis of SKILL.md at load time**: Scan skill instructions for known malicious patterns (exfiltration instructions, credential harvesting, persistence mechanisms). Integrate with Snyk agent-scan or similar.
- **(b) Skill allowlisting**: Tideclaw config specifies which skills are permitted. Unknown skills are blocked or require approval.
- **(c) Skill isolation**: Run skills in separate context/subagent with restricted tool access (the `allowed-tools` frontmatter field enables this, but enforcement is runtime-dependent).
- **(d) All of the above** (recommended for defense in depth).

This is a **Phase 3 concern** (hardening), not MVP. But the architecture should anticipate it now.

---

## Tideclaw Architecture

### Core Concept

Tideclaw is a **security-first orchestrator** for AI coding tools. It manages the lifecycle of an agentic runtime (Claude Code, Codex CLI, Aider, etc.) inside a topology that provides the enforcement seams Tidegate's security layers attach to:

1. **Process separation** — agent, gateway, MCP servers, and proxy run in separate containers
2. **Network segmentation** — three isolated networks control what can talk to what
3. **MCP interposition** — gateway sits between agent and MCP servers (the scanning seam)
4. **Egress mediation** — proxy sits between agent and internet (the egress control seam)
5. **Credential isolation** — mount boundaries ensure each container sees only its own credentials
6. **Kernel observation** — eBPF/seccomp attach points for taint tracking

The agentic runtime runs unmodified inside this topology. It sees MCP servers at the URLs it expects. It reaches the internet through a proxy it doesn't know about. Its file access is observed without its knowledge.

### Design Principles

1. **Seams first**: The orchestration topology is designed around the enforcement boundaries Tidegate needs. Every container boundary, network segment, and mount point exists to enable a security layer.
2. **Runtime-agnostic**: Works with any CLI-based AI coding tool that can run in a container. The orchestrator provides the seams; the runtime is pluggable.
3. **No cooperation required**: The agentic runtime doesn't need modification, plugins, or special flags (beyond headless mode). Seams are structural, not contractual.
4. **MCP-first scanning**: For runtimes with MCP support, scan at the MCP protocol level (highest fidelity). The gateway seam provides structured tool name + argument + value visibility.
5. **Network-fallback scanning**: For runtimes without MCP, scan at the HTTP proxy level (lower fidelity but universal). The proxy seam provides payload-level visibility.
6. **Skills-aware security**: Modern runtimes extend via two planes: tools (MCP) and knowledge (Skills/SKILL.md). Tideclaw's gateway seam covers the tool plane. The skills plane requires additional enforcement: skill vetting at load time, skill allowlisting, and skill isolation via restricted tool access. MCP is not the only extension mechanism — skills are becoming equally important.
7. **Defense in depth**: MCP scanning, network scanning, skill vetting, and taint tracking run simultaneously when available. Multiple seams firing independently.
8. **Fail-closed**: Scanner unavailable = deny. Proxy down = no egress. Container crash = session over.

### Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        TIDECLAW HOST                        │
│                                                             │
│  tideclaw CLI                                               │
│    - reads tideclaw.yaml                                    │
│    - generates compose spec                                 │
│    - starts containers                                      │
│    - manages lifecycle                                      │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │               Docker / Podman                       │    │
│  │                                                     │    │
│  │  ┌──────────────────────┐    agent-net (internal)   │    │
│  │  │   AGENT CONTAINER    │◄──────────────────────┐   │    │
│  │  │                      │                       │   │    │
│  │  │  Claude Code / Codex │     ┌──────────────┐  │   │    │
│  │  │  / Aider / any CLI   │────►│  tg-gateway   │  │   │    │
│  │  │                      │     │  (MCP proxy)  │  │   │    │
│  │  │  MCP config points   │     │  port 4100    │  │   │    │
│  │  │  to tg-gateway       │     └──────┬───────┘  │   │    │
│  │  │                      │            │          │   │    │
│  │  │  HTTPS_PROXY points  │     ┌──────▼───────┐  │   │    │
│  │  │  to egress-proxy     │────►│ egress-proxy  │  │   │    │
│  │  │                      │     │  port 3128    │──┼───┼──► Internet
│  │  │  /workspace (rw)     │     └──────────────┘  │   │    │
│  │  │  ~/.claude (ro)      │            │          │   │    │
│  │  └──────────────────────┘     ┌──────▼───────┐  │   │    │
│  │                               │  MCP servers  │  │   │    │
│  │            mcp-net (internal) │  (gmail,slack │  │   │    │
│  │                               │   github,..) │  │   │    │
│  │                               └──────────────┘  │   │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### The Three Integration Modes

Tideclaw's orchestration topology adapts based on the agentic runtime's capabilities — specifically, which seams can be activated:

#### Mode 1: MCP Gateway (Claude Code, Codex CLI, Goose, Continue.dev, any MCP-native runtime)

```
Agent → tg-gateway (scan all values) → downstream MCP servers
Agent → egress-proxy → internet (LLM API only)
```

**Seams activated**: MCP interposition (gateway) + egress mediation (proxy) + credential isolation (mount boundaries)

**How it works**:
- Tideclaw generates MCP config for the runtime, pointing all servers at `http://tg-gateway:4100/mcp`
- The gateway mirrors tools from real downstream servers
- Every tool call parameter and response is scanned (L1/L2/L3)
- Shaped denies on policy violations
- Runtime sees one MCP endpoint; gateway fans out to real servers on `mcp-net`

**Scanning fidelity**: **High**. Every string value in every tool call is scanned. Structured data is preserved. Tool name, argument names, and values are all visible.

**Claude Code specific**:
- Mount `~/.claude/` read-only for OAuth auth
- Generate `~/.claude/settings.json` with MCP servers pointing to gateway
- Optionally install `PreToolUse` hooks for double-checking at the tool level (defense in depth — hooks + gateway both scan)
- `--dangerously-skip-permissions` for headless operation

**Codex CLI specific** (MCP mode):
- Codex supports MCP via `rmcp-client` crate. Configure gateway as MCP server.
- Run with `--sandbox danger-full-access` (Tideclaw's orchestration provides isolation instead)
- `OPENAI_API_KEY` or ChatGPT OAuth auth passed via env/mount
- Codex's shell commands (primary tool) are NOT MCP — they bypass the gateway seam. This is why Codex also needs Mode 2 (proxy) as a backup.

#### Mode 2: Network Proxy (Aider, any runtime without MCP, backup for shell-heavy runtimes)

```
Agent → egress-proxy (scan HTTP bodies) → internet
Agent → egress-proxy (scan HTTP bodies) → external APIs
```

**Seams activated**: Egress mediation (proxy) + credential isolation (mount boundaries). No MCP interposition.

**How it works**:
- Tideclaw runs the runtime in a container on `agent-net` (internal) with proxy env vars
- All HTTP/HTTPS traffic routes through `egress-proxy`
- For LLM API domains: CONNECT passthrough (no inspection — encrypted, high volume)
- For external API domains: MITM, scan request/response bodies, inject credentials
- Domain allowlist controls what's reachable

**Scanning fidelity**: **Medium**. HTTP request/response bodies are scanned, but there's no structured MCP framing. Scanner sees raw JSON/form payloads, not tool names and argument schemas. The proxy seam provides less visibility than the gateway seam.

**Codex CLI backup layer**:
- Codex's primary tool is a unified shell executor — shell commands don't go through MCP
- If a shell command makes HTTP requests (curl, wget, Python requests), those hit the proxy seam
- Codex's env var stripping (`KEY`/`SECRET`/`TOKEN` excluded from subprocesses) provides additional defense
- Tideclaw's proxy seam catches content-embedded credentials that Codex's env var filter misses

#### Mode 3: Hybrid (runtimes with partial MCP + HTTP)

```
Agent → tg-gateway (MCP tools, high-fidelity scan)
Agent → egress-proxy (HTTP tools, medium-fidelity scan)
```

**Seams activated**: All — MCP interposition + egress mediation + credential isolation + kernel observation (when available).

**How it works**: Combine modes 1 and 2. MCP traffic goes through the gateway seam. Non-MCP HTTP traffic goes through the proxy seam. Both scanning pipelines run independently.

This is the default for Claude Code (which uses MCP for tools but HTTPS for the Anthropic API).

### Tideclaw Configuration

```yaml
# tideclaw.yaml
version: "1"

# Which agentic runtime to orchestrate
agent:
  tool: claude-code           # claude-code | codex | aider | custom
  image: tideclaw/claude-code:latest  # pre-built image or custom
  auth:
    mount: ~/.claude:/home/agent/.claude:ro  # tool-specific auth mount
  env:
    HTTPS_PROXY: http://egress-proxy:3128
  headless: true              # --dangerously-skip-permissions / equivalent

# MCP servers (tool-call-level scanning)
mcp_servers:
  gmail:
    transport: http
    url: http://gmail-mcp:3000/mcp
    credentials:
      GMAIL_CLIENT_ID: ${GMAIL_CLIENT_ID}
      GMAIL_CLIENT_SECRET: ${GMAIL_CLIENT_SECRET}
  slack:
    transport: http
    url: http://slack-mcp:3000/mcp
    credentials:
      SLACK_BOT_TOKEN: ${SLACK_BOT_TOKEN}
    allow_tools: [post_message, list_channels]
  github:
    transport: http
    url: http://github-mcp:3000/mcp
    credentials:
      GITHUB_TOKEN: ${GITHUB_TOKEN}

# Egress control
egress:
  # LLM API: passthrough (no inspection)
  passthrough:
    - api.anthropic.com
    - api.openai.com
    - generativelanguage.googleapis.com
  # Allowed with MITM scanning + credential injection
  allowed:
    - api.github.com:
        credentials:
          Authorization: "Bearer ${GITHUB_TOKEN}"
    - api.slack.com:
        credentials:
          Authorization: "Bearer ${SLACK_BOT_TOKEN}"
  # Everything else: blocked

# Scanning policy
scanning:
  timeout_ms: 500
  failure_mode: deny          # deny | allow
  # L1 (in-process): credential patterns, JSON key patterns
  # L2 (subprocess): Luhn, IBAN, SSN
  # L3 (subprocess): entropy, base64/hex detection
  layers: [L1, L2, L3]

# Taint tracking (post-MVP, requires Linux kernel 5.8+)
taint:
  enabled: false              # true when tg-scanner is built
  workspace: /workspace
```

### Container Images: Pre-Built vs Custom

Tideclaw ships **pre-built container images** for supported runtimes:

| Image | Base | Contents |
|-------|------|----------|
| `tideclaw/claude-code` | `node:22-slim` | Claude Code CLI, non-root user, MCP config template, skill directory |
| `tideclaw/codex` | `debian:bookworm-slim` | Codex CLI (Rust binary), non-root user, MCP + proxy config |
| `tideclaw/goose` | `debian:bookworm-slim` | Goose CLI (Rust binary), non-root user, MCP extension config pointing to gateway, proxy config. All extensions route through gateway seam. |
| `tideclaw/aider` | `python:3.12-slim` | Aider, non-root user, proxy config (no MCP) |
| `tideclaw/custom` | `ubuntu:24.04` | Base image with proxy config, user adds their runtime |

Each image:
- Runs as non-root user
- Has `HTTPS_PROXY` pre-configured
- Has MCP config templates (for MCP-capable runtimes)
- Includes health check scripts
- Is pinned to specific runtime versions

For **custom runtimes**, users can extend the base image:

```dockerfile
FROM tideclaw/custom:latest
RUN pip install my-agent-tool
COPY my-config /home/agent/.config/
```

### The tideclaw CLI

```sh
# Initialize (creates tideclaw.yaml from template)
tideclaw init --tool claude-code

# Start (generates compose, builds, starts)
tideclaw up

# Status
tideclaw status

# Attach to agent container
tideclaw attach

# View audit logs
tideclaw logs

# Stop
tideclaw down
```

Under the hood, `tideclaw up`:
1. Reads `tideclaw.yaml`
2. Generates a `docker-compose.yaml` with:
   - Agent container (runtime-specific image)
   - `tg-gateway` container
   - `egress-proxy` container
   - MCP server containers (one per configured server)
   - Network topology / seams (`agent-net`, `mcp-net`, `proxy-net`)
3. Generates MCP config for the agentic runtime (pointing to gateway seam)
4. Generates proxy config (allowlists, credential injection rules)
5. Runs `docker compose up --build`
6. Waits for health checks
7. Prints status

### How MCP Config Injection Works

Each runtime has a different MCP config format. Tideclaw generates the appropriate config:

**Claude Code** (`~/.claude/settings.json`):
```json
{
  "mcpServers": {
    "tideclaw": {
      "type": "streamable-http",
      "url": "http://tg-gateway:4100/mcp"
    }
  }
}
```

Claude Code sees one MCP server ("tideclaw") that exposes all tools from all downstream servers. The gateway handles the fan-out.

**Codex CLI** (`~/.codex/config.toml` + MCP config):
```toml
# config.toml — disable Codex's own sandbox (Tideclaw provides isolation)
[sandbox]
sandbox_mode = "danger-full-access"
```
```json
// MCP server config — point to gateway
{
  "mcpServers": {
    "tideclaw": {
      "type": "streamable-http",
      "url": "http://tg-gateway:4100/mcp"
    }
  }
}
```
Plus `HTTPS_PROXY=http://egress-proxy:3128` for shell commands that make HTTP requests.

**Goose** (`~/.config/goose/config.yaml` — extension config pointing to gateway):
```yaml
extensions:
  tideclaw:
    type: streamable-http
    uri: http://tg-gateway:4100/mcp
    # All downstream MCP servers exposed via single gateway endpoint
    # Goose sees one extension; gateway fans out to real servers on mcp-net
```
Plus `HTTPS_PROXY=http://egress-proxy:3128` for any direct HTTP traffic. Run with `--no-session --quiet --output-format json` for headless container operation. Goose's own sandbox (seatbelt/bubblewrap) should be disabled — Tideclaw's container topology provides the isolation.

**Aider** (proxy-only, no MCP):
```
HTTPS_PROXY=http://egress-proxy:3128
```

### Credential Flow

```
User's machine
  ├── ~/.claude/auth.json        → mounted :ro into agent container (Claude Code auth)
  ├── tideclaw.yaml              → read by tideclaw CLI
  └── .env (or 1Password CLI)    → MCP server credentials

Agent container
  ├── Sees: ~/.claude/auth.json (read-only, for LLM API auth)
  ├── Sees: HTTPS_PROXY env var
  ├── Does NOT see: SLACK_BOT_TOKEN, GITHUB_TOKEN, GMAIL_*, etc.
  └── Does NOT see: any credential except its own LLM API auth

tg-gateway container
  ├── Sees: downstream MCP server URLs
  ├── Does NOT see: MCP server credentials (they're in the MCP server containers)
  └── Does NOT see: agent's LLM API auth

MCP server containers (each isolated)
  ├── gmail-mcp: Sees GMAIL_* only
  ├── slack-mcp: Sees SLACK_BOT_TOKEN only
  └── github-mcp: Sees GITHUB_TOKEN only

egress-proxy container
  ├── Sees: domain allowlist
  ├── Sees: credential injection rules (for MITM mode)
  └── Injects credentials into matching requests (agent never sees the creds)
```

### Network Topology

```
agent-net (internal: true)
  ├── agent container
  ├── tg-gateway
  └── egress-proxy

mcp-net (internal: true)
  ├── tg-gateway
  └── MCP server containers

proxy-net
  ├── egress-proxy
  └── → internet
```

**Key properties**:
- Agent cannot reach MCP servers directly (different networks)
- Agent cannot reach internet directly (internal network, proxy only)
- MCP servers cannot reach agent (different networks)
- MCP servers can reach their external APIs (via `mcp-net` → direct or through own proxy)
- Only `egress-proxy` spans `agent-net` and `proxy-net`
- Only `tg-gateway` spans `agent-net` and `mcp-net`

### Enforcement Layers (Tidegate components attached to Tideclaw seams)

| Layer | What | Where | Fidelity |
|-------|------|-------|----------|
| **L1: Taint tracking** | eBPF `openat` + seccomp-notify `connect()` | Agent container kernel | **File-level** — tracks which files were read, blocks network if tainted |
| **L2: MCP gateway** | Scan all string values in tool call params and responses | tg-gateway | **Field-level** — sees tool name, arg names, values. Highest fidelity. |
| **L3: Egress proxy** | Scan HTTP request/response bodies, domain allowlisting, credential injection | egress-proxy | **Payload-level** — sees raw HTTP bodies. Medium fidelity. |

Defense in depth: a credential in a tool call parameter hits L2 (gateway scan) AND L3 (proxy scan if it reaches egress). A file tainted by a read hits L1 (taint tracker blocks connect). All three layers fire independently.

---

## Tideclaw vs ClaudeClaw vs NanoClaw: Orchestrator Comparison

All three are orchestrators. They differ in what they optimize for:

```
ClaudeClaw (orchestrator — optimizes for web UI + chat bridges)
  - Web dashboard, WhatsApp/Telegram bridge
  - User-facing interaction layer
  - No security seams — trusts the runtime

NanoClaw (orchestrator — optimizes for multi-session management)
  - Container-per-session, skills, scheduling, memory
  - WhatsApp/Telegram bridge
  - Incidental container boundaries (not designed as security seams)

Tideclaw (orchestrator — optimizes for security enforcement)
  - Orchestration topology designed around enforcement seams
  - Process separation, network segmentation, credential isolation
  - Seams that Tidegate's security layers (gateway, proxy, scanner) attach to
  - Runtime-agnostic: any CLI tool runs inside the topology
```

**Key distinction**: NanoClaw and ClaudeClaw use containers for operational reasons (isolation between sessions, deployment convenience). Tideclaw uses containers for security reasons (each container boundary is an enforcement seam). The topology isn't incidental — it's the point.

### Where does Tidegate fit?

Tidegate is NOT an orchestrator. It's the **security framework** — the gateway, scanner, proxy, and taint tracker. Tidegate's components attach to the seams that an orchestrator provides. The problem: most orchestrators don't provide the right seams. Tideclaw is the orchestrator designed to provide them.

```
Tidegate (security framework — the enforcement layers)
  - MCP gateway + scanner (attaches to the MCP interposition seam)
  - Egress proxy (attaches to the network segmentation seam)
  - Taint tracker (attaches to the kernel observation seam)
  - Needs an orchestrator that provides these seams

Tideclaw (orchestrator — provides the seams Tidegate needs)
  - Process separation → gateway can sit between agent and MCP servers
  - Network segmentation → proxy can mediate all egress
  - Mount isolation → credentials stay in their containers
  - Kernel attach points → eBPF/seccomp can observe the agent
```

### What happens to ClaudeClaw and NanoClaw?

They're peer orchestrators with different priorities. A user who wants a web dashboard picks ClaudeClaw. A user who wants WhatsApp integration and multi-session scheduling picks NanoClaw. A user who wants security enforcement picks Tideclaw.

In principle, the features aren't mutually exclusive — a future orchestrator could combine Tideclaw's security seams with ClaudeClaw's web UI. But that's a later concern. For now, Tideclaw focuses on getting the seams right.

```yaml
# tideclaw.yaml — Claude Code as the agentic runtime (most common)
agent:
  tool: claude-code
```

```yaml
# tideclaw.yaml — Codex CLI as the agentic runtime
agent:
  tool: codex
```

```yaml
# tideclaw.yaml — Goose as the agentic runtime (best open-source option)
agent:
  tool: goose
```

---

## Implementation Plan

### Phase 1: Core (MVP)

**Goal**: `tideclaw init --tool claude-code && tideclaw up` produces a working system.

1. **tideclaw CLI** — Go or shell script. `init`, `up`, `down`, `status`, `attach`, `logs`.
2. **Claude Code container image** — `tideclaw/claude-code`. Claude Code CLI + non-root user + MCP config template.
3. **Compose generator** — Reads `tideclaw.yaml`, generates `docker-compose.yaml` with correct topology.
4. **MCP config injector** — Generates Claude Code's `settings.json` pointing to gateway.
5. **Reuse existing tg-gateway** — Tidegate's gateway is Tideclaw's gateway. No changes needed.
6. **Reuse existing egress-proxy** — Squid CONNECT-only proxy. No changes needed.

### Phase 2: Multi-Runtime Support

**Goal**: `tideclaw init --tool codex` and `tideclaw init --tool goose` also work.

1. **Codex CLI container image** — `tideclaw/codex`. Rust binary + non-root user + MCP config pointing to gateway + `danger-full-access` sandbox mode + proxy env vars.
2. **Goose container image** — `tideclaw/goose`. Rust binary + non-root user + MCP extension config pointing to gateway + proxy env vars. Goose's MCP-native architecture means ALL extensions route through the gateway seam (highest coverage among open-source tools). Disable Goose's own seatbelt/bubblewrap sandbox (Tideclaw provides the isolation layer). Run with `--no-session --quiet --output-format json` for headless operation.
3. **Proxy-mode scanning (MITM)** — Upgrade egress-proxy from CONNECT-only to MITM for allowed domains. This catches shell command HTTP traffic that bypasses MCP.
4. **Credential injection** — Proxy injects auth headers on matching domains. Codex's shell commands can make API calls without knowing the credentials.
5. **Aider container image** — `tideclaw/aider`. Python-based, proxy-only mode (no MCP).
6. **Tool description scanning** — Scan `tools/list` responses from downstream MCP servers for poisoned descriptions (hidden instructions, rug-pull detection). Pipelock demonstrates this is feasible.

### Phase 3: Hardening

**Goal**: Full defense-in-depth.

1. **tg-scanner + tidegate-runtime** — L1 taint tracking (eBPF + seccomp-notify).
2. **Skill vetting** — Scan SKILL.md files at load time for malicious patterns (exfiltration instructions, credential harvesting, persistence). Integrate with Snyk agent-scan or equivalent. Skill allowlisting in `tideclaw.yaml`. Enforce `allowed-tools` restrictions from SKILL.md frontmatter.
3. **PreToolUse hooks** — Claude Code framework-specific double-checking.

### Phase 4: Extended Features

**Goal**: Tideclaw offers messaging and scheduling features for users who need them (comparable to ClaudeClaw/NanoClaw convenience features).

1. **Messaging bridge** — Optional container that bridges WhatsApp/Telegram/Slack to the agent.
2. **Task scheduler** — Optional container for cron-style scheduled prompts.
3. **Multi-session support** — Multiple agent containers, each isolated.

---

## Key Design Decisions

### D1: Agentic runtime runs unmodified inside the topology

The AI coding tool is installed as-is. No patches, no plugins, no forks. Tideclaw's seams are structural (process boundaries, network segments, mount points), not contractual (APIs the runtime must implement):
- MCP config injection (point runtime's MCP at gateway seam)
- Environment variables (HTTPS_PROXY → proxy seam)
- Container isolation (network, filesystem → all seams)

**Why**: Maintainability. Runtime updates don't break Tideclaw. Users can upgrade their runtime independently. No vendor-specific code in the security layer. The seams work because of topology, not cooperation.

**Exception**: Some runtimes may need `--headless` or `--dangerously-skip-permissions` flags for unattended operation. These are documented per-runtime, not code modifications.

### D2: MCP gateway is the highest-fidelity seam

For MCP-capable runtimes, the gateway seam provides the highest-fidelity scanning:
- Structured tool name + argument names + values
- Structured response content
- Shaped denies the runtime can understand and adjust to

The proxy seam provides backup scanning for traffic that bypasses MCP (direct HTTP calls, skill execution, etc.).

**Why**: MCP framing lets us scan *semantically*. We know "this string is the `message` parameter of the `post_message` tool." The proxy seam only sees "this string is somewhere in a JSON body sent to api.slack.com." The gateway seam enables better policy decisions.

### D3: Credentials never cross the mount isolation seam

The agent container has exactly ONE credential: its own LLM API auth token (for Claude/OpenAI/Google API calls). All other credentials (Slack, GitHub, Gmail, etc.) live in:
- MCP server containers (on `mcp-net`, unreachable from agent)
- Proxy config (credential injection on matching domains)

**Why**: Mount isolation is an enforcement seam. Each container's credentials are bounded by its mount namespace. If the agent is compromised (prompt injection, malicious skill), it cannot exfiltrate API credentials because they don't exist in its mount namespace. The LLM API token is the residual risk (accepted — see threat model).

### D4: Single MCP endpoint consolidates the gateway seam

The runtime sees one MCP server at `http://tg-gateway:4100/mcp` that exposes all tools from all downstream servers. All MCP traffic passes through a single interposition point.

**Why**: One seam is easier to enforce than many. Simplifies config injection — only one MCP entry in the runtime's settings. The gateway handles tool-to-server routing internally. Also enables cross-server policy (e.g., "don't allow tool X from server A if tool Y from server B was called in this session").

### D5: Compose generation, not static compose file

The `tideclaw.yaml` config generates a Docker Compose spec at `tideclaw up` time. This is better than a hand-maintained `docker-compose.yaml` because:
- Runtime-specific containers and configs are generated dynamically
- MCP server list changes don't require editing compose
- Network topology (the seams) is always correct (no manual network assignment errors)
- Credential injection rules are derived from `tideclaw.yaml`

The generated compose file is written to `.tideclaw/docker-compose.yaml` for inspection.

### D6: Go for the CLI (recommended)

The `tideclaw` CLI should be Go:
- Single static binary, no runtime deps
- Docker SDK available (`github.com/docker/docker/client`)
- YAML parsing (`gopkg.in/yaml.v3`)
- Fast startup (important for CLI tools)
- Consistent with tg-scanner (also Go for eBPF/seccomp)

Alternative: POSIX shell script for Phase 1 (simpler, follows Tidegate's shell conventions), upgrade to Go for Phase 2+.

### D7: Seams are structural, not contractual

Tideclaw's enforcement seams come from the orchestration topology (container boundaries, network segments, mount namespaces), not from APIs or hooks the runtime must implement. This means:
- Any CLI tool works, even ones with no plugin/hook system
- Seams can't be bypassed by the runtime (they're below the application layer)
- Security doesn't degrade when the runtime updates (no API contracts to break)

The exception is MCP config injection — we rely on the runtime reading MCP config from a known location. But even if MCP config fails, the network and mount seams still enforce.

---

## Open Questions

### Q1: Codex CLI's sandbox conflict

Codex CLI on Linux uses Landlock + seccomp-BPF for process-level sandboxing (NOT Docker). In `workspace-write` mode, it blocks all network syscalls (`connect`, `accept`, `bind`). This conflicts with Tideclaw's proxy-based egress control, which requires network access to the proxy.

**Options**:
- **(a) `danger-full-access` mode** — Codex's `--sandbox danger-full-access` or `sandbox_mode = "danger-full-access"` in config.toml disables all sandbox restrictions. Tideclaw's container provides the isolation instead. **This is the recommended approach** — Codex explicitly supports this for "externally hardened environments."
- (b) Custom seccomp profile — Codex's seccomp blocks `connect()`. We'd need to modify the seccomp filter to allow connections to the proxy IP only. Fragile and version-dependent.
- (c) Redundant layering — Run Codex in default mode. Its Landlock allows reads everywhere (good), and its seccomp blocks network (Tideclaw's proxy is unreachable). This breaks proxy-based scanning entirely. **Not viable.**

**Recommendation**: (a). Codex documents `danger-full-access` as appropriate for CI containers and externally secured environments. Tideclaw IS the external security layer. The `--yolo` flag (`--dangerously-bypass-approvals-and-sandbox`) also works as a single flag for fully headless operation.

### Q2: Claude Code session continuity

Claude Code uses `--resume <sessionId>` for session continuity. In a containerized environment:
- Sessions are stored in `~/.claude/` — mounted read-only, so new sessions go to a tmpfs
- Need a writable session directory — either a named volume or a bind mount
- Session IDs need to survive container restarts

**Options**:
- Mount a writable `sessions/` directory as a volume
- Store session IDs in a sidecar DB
- Accept ephemeral sessions (each `tideclaw up` is a fresh start)

### Q3: Multi-tool MCP server compatibility

Different MCP servers have different transport requirements (HTTP, stdio, SSE). The gateway currently supports HTTP and stdio. Some community MCP servers may only support stdio.

**Approach**: Gateway hosts stdio servers as child processes. These run inside the gateway container on `mcp-net` — acceptable isolation since the gateway is already trusted (it sees all tool calls).

### Q4: How does the user interact with the agent?

Tideclaw orchestrates the runtime but needs an interaction surface:
- **Terminal attach**: `tideclaw attach` → `docker exec -it agent-container <tool-cli>`
- **API**: Expose the agent's MCP endpoint (through the gateway) for programmatic use
- **Messaging bridge**: Optional NanoClaw-style WhatsApp/Telegram bridge
- **Web UI**: Optional dashboard (ClaudeClaw-style)

Phase 1: Terminal attach only. Phase 4: Messaging bridge.

### Q5: Should Tideclaw ship as a Claude Code extension/plugin?

One distribution model: Tideclaw as a Claude Code plugin. The plugin:
- Detects local Docker
- Generates compose from embedded config
- Starts containers
- Configures Claude Code's MCP settings to point to the gateway
- Provides `/tideclaw status`, `/tideclaw logs` commands

**Pro**: Zero-friction installation for Claude Code users. Plugin marketplace distribution.
**Con**: Couples to Claude Code. Can't orchestrate Codex or Aider this way. Plugin runs on host (not in container).

**Recommendation**: Ship as standalone CLI first. Plugin as a convenience layer later (Phase 4+).

---

## Comparison: Tideclaw vs Competitors

| Dimension | Tideclaw | Pipelock | Docker MCP Gateway | Goose (native) | E2B | Codex Sandbox |
|-----------|----------|---------|-------------------|----------------|-----|---------------|
| **Isolation** | Docker + network topology | Docker (2 containers) | MicroVM or Docker | bubblewrap/seatbelt (process-level) | Firecracker microVM | Landlock + seccomp |
| **MCP scanning** | L1/L2/L3 (regex, checksums, entropy) | 9-layer DLP + injection detection | `--block-secrets` (regex) | No | No | No |
| **Tool description scanning** | Not yet | Yes (rug-pull detection) | `--verify-signatures` | No | No | No |
| **Skill vetting** | Phase 3 (static analysis + allowlisting) | No | No | No | No | No |
| **Egress control** | Proxy + domain allowlist + credential injection | Domain blocklist + SSRF protection | Container networking | No | IP/CIDR + SNI domain filtering | Binary on/off (seccomp) |
| **Credential isolation** | Creds in MCP servers, never in agent | Agent has secrets + no network (capability separation) | Gateway injects credentials | No (env vars in process) | Env vars in sandbox | Env var stripping (`KEY`/`SECRET`/`TOKEN`) |
| **Taint tracking** | eBPF + seccomp-notify (Phase 3) | No | No | No | No | No |
| **Shaped denies** | Yes (valid MCP result + explanation) | block/strip/warn/ask | No | No | No | No |
| **Runtime-agnostic** | Yes (any CLI tool) | MCP servers only | MCP servers only | N/A (is the runtime) | Yes (any code) | Codex only |
| **Skills support** | Scans/vets skills loaded by runtime | No | No | Yes (Agent Skills standard) | No | Yes (Agent Skills standard) |
| **Self-hosted** | Yes | Yes | Yes | Yes | Cloud or BYOC | Yes |
| **Elicitation scanning** | Planned | No | No | No | No | No |
| **Audit logging** | NDJSON structured logs | Configurable | `--log-calls` | No | Partial | No |
| **Open source** | Yes (planned) | Yes (Apache-2.0) | Yes | Yes (Apache-2.0) | Yes (Apache-2.0) | Yes (Apache-2.0) |

**Tideclaw's differentiation**:
1. **Taint tracking** (eBPF + seccomp-notify) — no competitor has kernel-level data flow tracking
2. **Shaped denies** — agent reads explanation and adjusts behavior, doesn't retry blindly
3. **Runtime-agnostic** — orchestrates any CLI tool, not just MCP servers
4. **Defense-in-depth** — four independent layers (taint, gateway, proxy, skill vetting) vs. single-layer approaches
5. **Credential topology** — credentials in separate containers on isolated network, not env vars in the agent
6. **Skills-aware security** — only security framework that addresses both the MCP tool plane and the Skills knowledge plane as distinct attack surfaces

---

## Threat Model Delta (Tideclaw vs no Tideclaw)

| Attack | Without Tideclaw | With Tideclaw |
|--------|------------------|---------------|
| **Prompt injection → credential exfil via tool call** | Tool sends creds to attacker's Slack channel | L2 gateway scans tool call params, blocks credential patterns |
| **Malicious skill → `fetch()` to attacker server** | Succeeds (tool has full network) | Proxy blocks non-allowlisted domains |
| **Malicious skill → read `~/.ssh/id_rsa`** | Succeeds (tool has full filesystem) | Container isolation — `~/.ssh` not mounted |
| **Malicious skill → read workspace file, base64, exfil** | Succeeds | L1 taint tracking: eBPF sees file open, seccomp blocks connect |
| **Compromised MCP server → inject creds in response** | Tool receives and may forward | L2 gateway scans response, blocks credential patterns |
| **Credential theft from env vars** | All creds in one process | Only LLM API auth in agent. All others isolated. |
| **Malicious skill → instructs agent to craft legitimate-looking exfil** | Succeeds (agent follows skill instructions) | L1 taint tracking catches file-to-network flows regardless of intent. L3 proxy blocks non-allowlisted domains. **Partial mitigation** — skill vetting (Phase 3) adds pre-load static analysis. |
| **Supply chain skill poisoning (registry)** | Succeeds (agent loads poisoned skill) | Skill allowlisting in `tideclaw.yaml` blocks unknown skills. Snyk agent-scan integration for static analysis. **Phase 3.** |
| **Semantic rephrasing ("card ending in 4242")** | Not blocked | **Not blocked** (residual risk — fundamental limit of pattern scanning) |
| **Exfil via LLM API request** | N/A (direct API access) | **Not blocked** (residual risk — LLM API must be reachable) |

---

## Tideclaw Base Evaluation: Best Non-Claude/Codex/Gemini Runtime

If Tideclaw must work with a runtime that is not Claude Code, Codex CLI, or Gemini CLI, which tool makes the best base? Evaluated against Tideclaw's integration requirements:

### Evaluation Criteria

| Criterion | Weight | Why it matters for Tideclaw |
|-----------|--------|----------------------------|
| MCP support | Critical | Gateway seam requires MCP. Without it, only proxy mode (medium fidelity). |
| Headless/API mode | Critical | Container orchestration requires non-interactive execution with structured output. |
| Docker/containerization | High | Tideclaw's topology is container-based. The runtime must run cleanly in containers. |
| Skills support | High | Skills are a major extension paradigm. The runtime should support or be compatible with the Agent Skills standard. |
| Sandboxing (own) | Medium | Can be disabled in favor of Tideclaw's topology. Nice to have as defense-in-depth option. |
| Model agnosticism | Medium | Users should choose their LLM. Lock-in to one provider reduces Tideclaw's value. |
| Community/maintenance | Medium | Single-maintainer projects are riskier for production infrastructure. |
| Code editing quality | High | The runtime must actually be good at writing code — that's the user's goal. |

### Comparison

| | **Goose** | **Aider** | **llm CLI** |
|---|---|---|---|
| MCP support | **Foundational** — all extensions are MCP | None (community workarounds) | Community plugin only |
| Headless mode | **Yes** — `--quiet`, `--output-format json`, `--no-session`, recipes, cron | Minimal — `-m` flag, no structured output | Not applicable (not an agent) |
| Docker | **Official images**, non-root, Compose workflows | Official images, but `/run` limitations | No official images |
| Skills | **Yes** — Agent Skills standard, SKILL.md, recipes | None (`.aider.conventions` only) | None |
| Own sandbox | **Yes** — bubblewrap (Linux), seatbelt (macOS), v1.25.0 | None | None |
| Model agnosticism | **25+ providers** incl. local (Ollama) | Broad (any LLM via API) | Broadest (51+ plugins) |
| Community | **31K stars, 373 contributors**, Linux Foundation AAIF | 41K stars but **single maintainer** | 11K stars, single maintainer |
| Code quality | Full agent (file edit, shell, test, subagents) | **Best editing engine** (tree-sitter + PageRank repo map) | **Not a coding agent** |
| Integration mode | **MCP gateway** (high fidelity) | Container + proxy only (medium fidelity) | Not viable |
| Tideclaw seam coverage | **All seams activate**: MCP gateway, egress proxy, credential isolation, taint tracking | Proxy + credential isolation only. No MCP gateway seam. | — |

### Recommendation: Goose

**Goose is the clear best base for Tideclaw** outside of Claude Code, Codex CLI, and Gemini CLI. The reasoning:

1. **MCP-native = full seam activation.** Every Goose extension is an MCP server. Point all extensions at the gateway → 100% tool call visibility. This is the highest scanning fidelity achievable. Aider, by contrast, has no MCP support — Tideclaw can only scan its HTTP traffic (medium fidelity) and cannot see structured tool calls at all.

2. **Headless-ready for container orchestration.** `goose run --quiet --output-format json --no-session --max-turns N` gives Tideclaw exactly the non-interactive, structured-output interface needed for container lifecycle management. Aider's `-m` flag exists but produces no structured output and has no proper daemon mode.

3. **Skills-aware.** Goose supports the Agent Skills standard, meaning Tideclaw's Phase 3 skill vetting/scanning applies cleanly. Aider has no skill system, which means fewer attack surfaces but also less extensibility for users.

4. **Rust binary.** Like Codex CLI, Goose compiles to a single Rust binary — fast startup, no runtime dependency bloat inside the container. Aider requires a full Python environment.

5. **Community sustainability.** 373+ contributors, Linux Foundation governance (AAIF), Block corporate backing, 100+ releases in one year. Compare to Aider's single-maintainer model.

6. **The gap Tideclaw fills for Goose.** Goose v1.25.0 added sandboxing, but it's process-level (seatbelt/bubblewrap) — no credential isolation across containers, no MCP interposition scanning, no egress proxy with domain allowlists, no taint tracking. These are exactly Tideclaw's additions. Tideclaw + Goose is a natural pairing: Goose provides the agent runtime and MCP-native extensibility; Tideclaw provides the security topology.

**Aider is a viable but distant second.** Its tree-sitter + PageRank code editing engine is genuinely best-in-class, but the lack of MCP, headless mode, and skills support means Tideclaw can only offer medium-fidelity protection. If a user specifically wants aider's editing quality inside Tideclaw's security topology, proxy-only mode works — but they lose the gateway seam.

**llm CLI is not viable.** It is a chat/completion tool, not a coding agent. Tideclaw would need to build the entire agent runtime from scratch, defeating the purpose.

---

## What This Spike Decided

1. **Tideclaw is an orchestrator** — a peer to ClaudeClaw and NanoClaw, not a layer above or below them. It's the orchestrator you choose when security enforcement is the priority.

2. **The orchestrator's job is to provide seams**: process separation, network segmentation, credential isolation, kernel observation points. Tidegate's security layers (gateway, scanner, proxy, taint tracker) attach to these seams.

3. **Three integration modes**: MCP gateway (high fidelity), network proxy (medium fidelity), hybrid (both). Mode selected automatically based on the agentic runtime's capabilities — specifically, which seams can be activated.

4. **Claude Code, Codex CLI, and Goose are the three launch runtimes**. Claude Code via MCP gateway mode. Codex via hybrid mode (MCP + proxy). Goose via MCP gateway mode (all extensions are MCP servers → highest coverage among open-source tools).

5. **Runtime-agnostic design**: The agentic runtime is pluggable. Any CLI tool that can run in a container works inside Tideclaw's topology. Seams are structural (container boundaries, network segments), not contractual (APIs the runtime must implement).

6. **Pre-built container images** for each supported runtime. Custom Dockerfile support for unsupported runtimes.

7. **Compose generation** (not static compose file) from `tideclaw.yaml`. The generated topology encodes the seams.

8. **Two extension planes, not one**: Modern agentic runtimes extend via MCP (tool connectivity) AND Skills (procedural knowledge). Tideclaw's gateway seam covers MCP. Skill security (vetting, allowlisting, isolation) is a Phase 3 concern but the architecture must anticipate it now.

## What This Spike Did NOT Decide

- CLI implementation language (Go recommended, shell acceptable for Phase 1)
- Plugin distribution model (standalone first, plugin later)
- Codex sandbox conflict resolution (needs empirical testing)
- Goose sandbox conflict resolution (disable Goose's seatbelt/bubblewrap when inside Tideclaw's topology? needs empirical testing)
- Session persistence model for containerized Claude Code
- Skill scanning approach (static analysis vs. allowlisting vs. isolation vs. all three)
- Pricing/distribution model (open source? paid? freemium?)
- Whether to keep "Tidegate" as a name for the security framework or fold it into "Tideclaw"
- Whether Tideclaw's seam topology could be composed with other orchestrators' features (e.g., ClaudeClaw's web UI + Tideclaw's seams)

## References

### Internal
- Prior spike: `docs/research/completed/agent-selection/nanoclaw-tidegate-design-spike.md`
- ADR-002 (taint tracking): `docs/adr/proposed/002-taint-and-verify-data-flow-model.md`
- ADR-003 (agent runtime selection): `docs/adr/proposed/003-agent-runtime-selection.md`
- ClaudeClaw comparison: `docs/research/active/claudeclaw-vs-nanoclaw/claudeclaw-vs-nanoclaw.md`

### AI Coding Tools
- Claude Code docs: https://code.claude.com/docs/en/hooks
- Claude Code sandboxing: https://www.anthropic.com/engineering/claude-code-sandboxing
- Claude Code sandbox-runtime: https://github.com/anthropic-experimental/sandbox-runtime
- Claude Code Agent SDK: https://platform.claude.com/docs/en/agent-sdk
- OpenAI Codex CLI: https://github.com/openai/codex
- Codex security docs: https://developers.openai.com/codex/security/
- Codex cloud environments: https://developers.openai.com/codex/cloud/environments/
- Google Jules: https://blog.google/technology/google-labs/jules/
- Goose (Block): https://github.com/block/goose
- Goose architecture: https://block.github.io/goose/docs/goose-architecture/
- Goose v1.25.0 release: https://block.github.io/goose/blog/2026/02/23/goose-v1-25-0/
- Goose in Docker: https://block.github.io/goose/docs/guides/goose-in-docker/
- Goose + Docker (Docker blog): https://www.docker.com/blog/building-ai-agents-with-goose-and-docker/
- Goose red team report: https://www.theregister.com/2026/01/12/block_ai_agent_goose/
- Aider: https://aider.chat/
- Aider GitHub: https://github.com/Aider-AI/aider
- Aider Docker: https://aider.chat/docs/install/docker.html
- Aider MCP request (Issue #4506): https://github.com/aider-ai/aider/issues/4506
- Aider MCP request (Issue #3314): https://github.com/Aider-AI/aider/issues/3314
- llm CLI: https://github.com/simonw/llm
- llm tool calling (v0.26): https://simonwillison.net/2025/May/27/llm-tools/
- llm plugin directory: https://llm.datasette.io/en/stable/plugins/directory.html

### MCP Security
- MCP spec (latest): https://modelcontextprotocol.io/specification/2025-11-25
- MCP authorization spec: https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
- MCP security best practices: https://modelcontextprotocol.io/specification/2025-11-25/basic/security_best_practices
- MCP elicitation: https://modelcontextprotocol.io/specification/draft/client/elicitation
- Timeline of MCP security breaches: https://authzed.com/blog/timeline-mcp-breaches
- MCP tool poisoning: https://www.pillar.security/blog/the-security-risks-of-model-context-protocol-mcp
- Securing MCP (paper): https://arxiv.org/abs/2511.20920
- OWASP Agentic AI: https://www.kaspersky.com/blog/top-agentic-ai-risks-2026/55184/

### Skills Paradigm and Security
- Agent Skills specification: https://agentskills.io/specification
- Claude Code skills docs: https://code.claude.com/docs/en/skills
- Skills explained (Anthropic): https://claude.com/blog/skills-explained
- Extending Claude with skills and MCP: https://claude.com/blog/extending-claude-capabilities-with-skills-mcp-servers
- Claude Skills vs MCP (IntuitionLabs): https://intuitionlabs.ai/articles/claude-skills-vs-mcp
- Vercel skills.sh: https://vercel.com/changelog/introducing-skills-the-open-agent-skills-ecosystem
- Snyk ToxicSkills study: https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/
- Snyk SKILL.md to shell access: https://snyk.io/articles/skill-md-shell-access/
- Snyk agent-scan: https://github.com/snyk/agent-scan
- Snyk + Vercel securing skills: https://snyk.io/blog/snyk-vercel-securing-agent-skill-ecosystem/
- ClawHavoc malicious campaign: https://snyk.io/articles/clawdhub-malicious-campaign-ai-agent-skills/
- OpenClaw security (Cisco): https://blogs.cisco.com/ai/personal-ai-agents-like-openclaw-are-a-security-nightmare
- Federal Register RFI on AI agent security: https://www.federalregister.gov/documents/2026/01/08/2026-00206/request-for-information-regarding-security-considerations-for-artificial-intelligence-agents
- Linux Foundation AAIF: https://www.linuxfoundation.org/press/linux-foundation-announces-the-formation-of-the-agentic-ai-foundation

### Sandboxing and Agent Security
- Pipelock: https://github.com/luckyPipewrench/pipelock
- Docker MCP Gateway: https://github.com/docker/mcp-gateway
- Docker sandboxes for coding agents: https://www.docker.com/blog/docker-sandboxes-run-claude-code-and-other-coding-agents-unsupervised-but-safely/
- E2B: https://e2b.dev
- Daytona: https://www.daytona.io
- microsandbox: https://github.com/zerocore-ai/microsandbox
- Kubernetes Agent Sandbox: https://github.com/kubernetes-sigs/agent-sandbox
- How to sandbox AI agents (Northflank): https://northflank.com/blog/how-to-sandbox-ai-agents
- NVIDIA sandboxing guidance: https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/
- A deep dive on agent sandboxes: https://pierce.dev/notes/a-deep-dive-on-agent-sandboxes
- Awesome MCP gateways: https://github.com/e2b-dev/awesome-mcp-gateways
- UK AISI sandboxing toolkit: https://github.com/UKGovernmentBEIS/aisi-sandboxing
