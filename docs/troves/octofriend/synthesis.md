# Octofriend Synthesis

## What it is

Octofriend is an open-source (MIT), zero-telemetry CLI coding assistant built by Synthetic Lab. It positions itself as a model-agnostic alternative to vendor-locked coding assistants, working with any OpenAI-compatible or Anthropic-compatible LLM API. Users can switch models mid-conversation.

## Architecture themes

### Transport-based sandboxing

The most architecturally distinctive feature is the **Transport abstraction** (`Transport` interface in `transports/transport-common.ts`). All filesystem and shell operations go through this interface, with two implementations:

- **LocalTransport** — native Node.js fs/child_process
- **DockerTransport** — executes all operations inside a Docker container via `docker exec`

This means the agent can be sandboxed in Docker with zero code changes to the agent loop. MCP servers and HTTP fetch remain on the host, creating a split where the agent's "hands" (file writes, shell commands) are contained but its "eyes" (MCP, web fetch) are not.

**Relevance to Tidegate:** This is a real-world example of transport-layer isolation in an AI agent. The Docker boundary provides containment for file/shell operations but does not enforce data-flow controls. There's no taint tracking, no egress filtering on the host-side operations (MCP, fetch), and no enforcement that prevents the agent from exfiltrating data through the fetch tool or MCP calls.

### Compiler abstraction (LLM integration)

The `Compiler` type (`compilers/compiler-interface.ts`) defines a model-agnostic interface for running LLM inference. Three implementations exist: `standard` (OpenAI chat completions), `anthropic` (Anthropic messages API), and `responses` (OpenAI responses API). The `run.ts` router selects the compiler based on model config.

The **autofix subsystem** uses custom-trained models to recover from:
- Malformed JSON in tool calls (fix-json model)
- Failed diff/edit applications (diff-apply model)

These are separate models from the main coding model, creating a two-model architecture where a specialized small model fixes errors from the primary model.

### Agent trajectory loop

The core agent loop (`agent/trajectory-arc.ts`) implements a single "arc" of the trajectory:

1. Check if autocompaction is needed (90% of context window)
2. If so, generate a summary of conversation history
3. Run the LLM with system prompt, history, and tool definitions
4. If the response contains a tool call, validate it
5. If validation fails (e.g., stale file edit), attempt autofix or retry
6. Return control to the UI for tool confirmation or user input

The loop is **not autonomous** — it pauses for user confirmation on tool calls (except read-only tools which skip confirmation). This is a deliberate UX choice, not a security boundary.

### Tool system

Tools are defined with TypeScript schemas (using the `structural` library for runtime validation). The tool set is similar to Claude Code's: read, list, shell (bash), edit, create, append, prepend, rewrite, glob, fetch, web-search, mcp, skill.

Key security-relevant behaviors:
- `shell` always requires user permission
- `read`, `list`, `glob`, `skill`, `web-search` skip confirmation
- File edits require the file to have been read first (file tracker prevents stale writes)
- No capability restrictions beyond the confirmation dialog

### Skills system

Implements the [Agent Skills spec](https://agentskills.io/) — discovers `SKILL.md` files with YAML frontmatter (name, description) and markdown instructions. Skills are loaded from `~/.config/agents/skills/` and `.agents/skills/` relative to cwd, plus custom paths from config.

### Instruction file hierarchy

Searches for `OCTO.md` > `CLAUDE.md` > `AGENTS.md` per directory, walking from cwd up to home. Takes the first found per directory, merges all into the system prompt. Compatible with Claude Code's instruction file convention.

## Points of agreement with Tidegate's model

- **Docker as containment boundary** — Octofriend validates the idea that Docker-based sandboxing is practical for agent filesystem/shell isolation
- **Transport abstraction** — clean separation of "where operations execute" from "what operations the agent performs"
- **Tool confirmation as a control point** — Octofriend's UI-level tool approval is analogous to Tidegate's interceptor concept, though implemented at a much lighter level

## Points of disagreement / gaps

- **No data-flow enforcement** — The Docker sandbox prevents file damage but doesn't prevent data exfiltration. The agent can read sensitive files and send their contents through fetch, web-search, or MCP tools without any taint tracking or egress control
- **MCP on host** — MCP servers run on the host, outside the Docker boundary. A malicious or confused agent can use MCP tools to access host resources even when "sandboxed"
- **Fetch on host** — HTTP requests originate from the host, not the container, bypassing the sandbox for network operations
- **No privilege separation** — Single-agent architecture with no orchestrator/subagent split. The same agent that reads files also executes shell commands and makes network requests
- **Confirmation is UX, not security** — Tool confirmation relies on user attention, not enforcement. The `--unchained` flag disables all confirmation, and there's no programmatic policy enforcement

## Gaps in the source

- No threat model documentation
- No security policy or vulnerability reporting process
- The `--unchained` flag (skip all tool confirmation) has no guardrails
- Auth credential handling stores keys in `~/.config/octofriend/keys.json5` with mode 0o600 — reasonable but no encryption
- The Docker transport's `writeFile` uses base64 encoding via shell, which could be fragile with very large files
