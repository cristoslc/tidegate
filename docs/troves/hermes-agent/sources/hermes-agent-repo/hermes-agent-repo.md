---
source-id: "hermes-agent-repo"
title: "Hermes Agent Repository"
type: repository
url: "https://github.com/NousResearch/hermes-agent"
fetched: 2026-04-18T15:46:00Z
hash: "c4fb8ffb75e4d371c0d61759cd2ebf3ba18d6825e1180ae49310ac7ef45111e3"
highlights:
  - "AGENTS.md"
  - "SECURITY.md"
  - "README.md"
  - "pyproject.toml"
  - "tools/registry.py"
  - "tools/approval.py"
  - "tools/delegate_tool.py"
  - "agent/redact.py"
  - "tools/mcp_tool.py"
  - "gateway/run.py"
  - "run_agent.py"
  - "Dockerfile"
selective: true
---

# Hermes Agent Repository

**Version:** 0.10.0 (2026.4.16)
**License:** MIT
**Stars:** 98.7k | **Forks:** 13.9k
**Language:** Python 87.5%, TypeScript 8.2%

## Overview

Hermes Agent is a self-improving AI agent by Nous Research. It creates skills from experience, improves them during use, and runs across CLI, messaging platforms (Telegram, Discord, Slack, WhatsApp, Signal), and serverless infrastructure.

## Architecture

```
hermes-agent/
├── run_agent.py          # AIAgent class — core conversation loop
├── model_tools.py        # Tool orchestration, discover_builtin_tools(), handle_function_call()
├── toolsets.py           # Toolset definitions, _HERMES_CORE_TOOLS list
├── cli.py                # HermesCLI class — interactive CLI orchestrator
├── hermes_state.py       # SessionDB — SQLite session store (FTS5 search)
├── agent/                # Agent internals (prompt_builder, context_compressor, redact, etc.)
├── hermes_cli/           # CLI subcommands and setup
├── tools/                # Tool implementations (one file per tool)
│   ├── registry.py       # Central tool registry (schemas, handlers, dispatch)
│   ├── approval.py       # Dangerous command detection
│   ├── delegate_tool.py  # Subagent delegation
│   ├── mcp_tool.py       # MCP client (~2600 lines)
│   └── environments/     # Terminal backends (local, docker, ssh, modal, daytona, singularity)
├── gateway/              # Messaging platform gateway
│   ├── run.py            # Main loop, slash commands, message dispatch
│   └── platforms/        # Adapters: telegram, discord, slack, whatsapp, signal, etc.
├── tui_gateway/          # Python JSON-RPC backend for TUI
├── acp_adapter/          # ACP server (VS Code / Zed / JetBrains integration)
└── ui-tui/               # Ink (React) terminal UI — hermes --tui
```

## Security Model

- **Single-tenant trust:** One trusted operator; gateway callers receive equal trust
- **Approval system** (`tools/approval.py`): gates dangerous commands, configurable mode (on/auto/off)
- **Redaction** (`agent/redact.py`): regex-based secret stripping from all display output
- **MCP sandboxing** (`tools/mcp_tool.py`): filtered environment, OSV malware checking for npx/uvx
- **Code execution sandbox** (`tools/code_execution_tool.py`): API keys stripped from child processes
- **Subagent isolation** (`tools/delegate_tool.py`): no recursive delegation, MAX_DEPTH=2, no memory access

## Key Capabilities

- **Closed learning loop:** agent-curated memory, autonomous skill creation, FTS5 session search
- **Multi-platform gateway:** Telegram, Discord, Slack, WhatsApp, Signal, Matrix, Home Assistant
- **40+ tools** via self-registering tool registry
- **6 terminal backends:** local, Docker, SSH, Daytona, Singularity, Modal
- **MCP integration:** stdio and HTTP transports, OSV safety checks
- **Cron scheduler:** natural-language scheduled tasks with platform delivery
- **Profile support:** multiple isolated instances via HERMES_HOME