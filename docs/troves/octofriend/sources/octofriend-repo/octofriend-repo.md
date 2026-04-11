---
source-id: "octofriend-repo"
title: "Octofriend - Zero-telemetry coding assistant CLI"
type: repository
url: "https://github.com/synthetic-lab/octofriend"
fetched: 2026-04-11T00:00:00Z
hash: "--"
selective: true
highlights:
  - "source/agent/trajectory-arc.ts"
  - "source/compilers/run.ts"
  - "source/compilers/compiler-interface.ts"
  - "source/prompts/system-prompt.ts"
  - "source/tools/index.ts"
  - "source/tools/tool-defs/index.ts"
  - "source/transports/transport-common.ts"
  - "source/transports/docker.ts"
  - "source/skills/skills.ts"
  - "source/config.ts"
  - "source/state.ts"
  - "source/cli.tsx"
  - "OCTO.md"
---

# Octofriend - Zero-telemetry coding assistant CLI

**Version:** 0.0.53  
**License:** MIT (Synthetic Lab, Co.)  
**Language:** TypeScript (Babel + TSC)  
**Runtime:** Node.js >= 16  
**UI:** Ink (React for CLI)  
**State:** Zustand  

## Overview

Octofriend (alias: `octo`) is an open-source, zero-telemetry CLI coding assistant built by Synthetic Lab. It works with any OpenAI-compatible or Anthropic-compatible LLM API and supports mid-conversation model switching. It features custom-trained open-source autofix models for handling tool call and code edit failures.

## Architecture

### Core layers

1. **CLI entry** (`cli.tsx`) - Commander-based CLI with subcommands: interactive mode, docker sandboxing, benchmarking, prompting, version/changelog
2. **App** (`app.tsx`) - Ink/React TUI application, renders the main UI
3. **State** (`state.ts`) - Zustand store managing conversation history, UI mode (input/responding/tool-request/menu/error states), model overrides
4. **Agent loop** (`agent/trajectory-arc.ts`) - Core agent trajectory: runs LLM, handles autocompaction, validates tool calls, retries on errors, autofixes malformed edits
5. **Compilers** (`compilers/`) - LLM integration layer with pluggable backends: standard (OpenAI-compatible), anthropic, openai-responses. Includes autocompaction and autofix subsystems
6. **Tools** (`tools/`) - Tool definitions: read, list, shell, edit, create, fetch, append, prepend, rewrite, glob, mcp, web-search, skill
7. **Transports** (`transports/`) - Filesystem/shell abstraction: LocalTransport (native) and DockerTransport (runs inside containers)
8. **Skills** (`skills/`) - Agent Skills spec implementation: discovers SKILL.md files, validates, exposes to LLM via XML
9. **IR** (`ir/`) - Intermediate representation for LLM messages, decoupled from specific provider formats
10. **Prompts** (`prompts/`) - System prompt, compaction prompt, autofix prompts

### Key design decisions

- **Transport abstraction** separates filesystem/shell operations from the agent, enabling Docker sandboxing without code changes
- **Compiler interface** is model-agnostic: same trajectory code works with OpenAI, Anthropic, and compatible APIs
- **Autocompaction** at 90% context window automatically summarizes history to stay within limits
- **Autofix** uses custom-trained models (diff-apply, fix-json) to recover from malformed tool calls
- **File tracker** prevents stale edits by requiring files to be read before modification
- **Zero telemetry** - no data collection, works with privacy-focused providers

### Tool system

Tools are defined as TypeScript schemas using the `structural` library. Each tool has a Schema (validated input), a run function, and a validate function. Some tools skip confirmation (read, list, skill, web-search, glob), while shell always requires permission.

### MCP integration

Octofriend connects to MCP servers defined in config, lists their tools at boot, and proxies tool calls through the `mcp` tool definition.

### Skills system

Compatible with the Agent Skills spec (agentskills.io). Discovers SKILL.md files from `~/.config/agents/skills/` and `.agents/skills/`. Skills are exposed to the LLM as XML with name, description, and location.

### Docker sandboxing

Built-in Docker support via `DockerTransport`: can attach to existing containers or launch new ones. All file/shell operations execute inside the container. MCP servers and HTTP fetch remain on the host.

### Instruction file hierarchy

Searches for OCTO.md > CLAUDE.md > AGENTS.md (first found wins per directory), walking from cwd up to home. Merges all found instruction files from general to specific.
