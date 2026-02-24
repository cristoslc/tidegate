# Tidegate — Target State

What `./setup.sh` looks like when it works.

## The user experience

```sh
git clone <repo> && cd tidegate
./setup.sh
```

`setup.sh` checks prerequisites, creates a `.env` from the template (prompting for MCP server API keys or detecting 1Password CLI), and runs `docker compose up --build`. When it finishes:

- **Claude Code** is running headless inside the agent container, subscription-billed via OAuth passthrough from the host machine's `~/.claude/`
- **OpenClaw** is running as a persistent Node.js daemon in the same container, invoking Claude Code via PTY for heavy compute tasks, listening to messaging apps (Telegram, Slack), and handling cron-based scheduling
- **All MCP tool calls** from Claude Code go through the Tidegate gateway, which scans every outbound parameter value and every response
- **All skill HTTP traffic** goes through the egress proxy (Squid CONNECT-only for MVP; agent-proxy MITM in hardening phase)
- **API credentials** live in MCP server containers and proxy config, never in the agent container
- The operator can attach to the agent container (`docker exec -it tidegate-agent bash`) or tail logs (`docker compose logs -f`)

## Container topology at target state

```
agent container (agent-net only)
  ├── OpenClaw daemon (persistent, always running)
  │     ├── listens to Telegram, Slack, cron triggers
  │     ├── spawns claude CLI via PTY for tasks
  │     └── manages session lifecycle
  ├── Claude Code (headless, invoked by OpenClaw)
  │     ├── --dangerously-skip-permissions (no manual approval prompts)
  │     ├── MCP config points to http://tidegate:4100/mcp
  │     ├── auth from mounted ~/.claude (read-only)
  │     └── uses subscription billing (not metered API)
  ├── HTTPS_PROXY=http://egress-proxy:3128
  └── workspace mounted at /workspace (read-write)

tidegate gateway (agent-net + mcp-net)
  ├── mirrors all tools from downstream MCP servers
  ├── scans ALL string values in tool call params (no per-field YAML)
  ├── scans ALL text content in tool call responses
  ├── optional tool allowlists per server
  └── shaped denies (isError: false) on scan failures

egress-proxy (agent-net + proxy-net)
  ├── CONNECT-only for LLM API domains (passthrough, no MITM)
  └── blocks everything else

MCP servers (mcp-net only, each holds its own credentials)
  ├── gmail-mcp (GMAIL_* env vars)
  ├── slack-mcp (SLACK_BOT_TOKEN env var)
  ├── github-mcp (GITHUB_TOKEN env var)
  └── ... (user adds servers to compose)
```

## What changes in each component

### Gateway: mirror+scan model

The gateway no longer requires per-field YAML mappings. Configuration becomes:

```yaml
version: "1"
defaults:
  scan_timeout_ms: 500
  scan_failure_mode: deny

servers:
  gmail:
    transport: http
    url: http://gmail-mcp:3000/mcp

  slack:
    transport: http
    url: http://slack-mcp:3000/mcp
    # Optional: restrict which tools are visible to the agent
    # allow_tools: [post_message, list_channels]

  github:
    transport: http
    url: http://github-mcp:3000/mcp
```

No `tools:` block, no `params:`, no `class:`, no `scan:` directives. The gateway connects to each downstream server, discovers its tools via `listTools()`, mirrors them to the agent, and scans every string value in every tool call.

**Code changes required**:
- `policy.ts`: Drop `FieldClass`, `FieldMapping`, `ToolMapping` types. Replace with server URL + optional `allow_tools` list. `getConfig()` returns the simplified schema. Remove `validateField()`, `validateToolCall()`, `getFieldsToScan()`.
- `router.ts`: Replace field-level scan logic with "scan every string value in `args`". Walk the args object recursively — scan any value that is a string (or stringify and scan objects). Remove field-level validation steps. Keep tool resolution and shaped deny construction.
- `tidegate.yaml`: Simplify to server URLs and optional allowlists.

**What stays the same**: `host.ts`, `servers.ts`, `scanner.ts`, `audit.ts` — unchanged or trivially adapted. The scanner interface (`scanValue()`) already accepts any string.

### Agent container (new)

**`agent/Dockerfile`**:
```
FROM node:22-slim
# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code
# Install OpenClaw
# ... (OpenClaw installation steps)
# Non-root user for Claude Code headless requirements
RUN useradd -m -s /bin/bash agent
USER agent
WORKDIR /home/agent
```

**`agent/entrypoint.sh`**:
- Starts OpenClaw daemon (foreground)
- OpenClaw spawns `claude --dangerously-skip-permissions` via PTY when tasks arrive
- Claude Code's MCP config (`~/.claude/settings.json` or equivalent) points all MCP servers at `http://tidegate:4100/mcp`

**Volume mounts**:
- `~/.claude:/home/agent/.claude:ro` — OAuth passthrough (subscription auth)
- `./workspace:/workspace` — shared workspace for agent tasks

**Environment**:
- `HTTPS_PROXY=http://egress-proxy:3128` — all HTTP traffic through proxy
- `CLAUDE_CONFIG_DIR=/home/agent/.claude`

### Docker Compose updates

Add to `docker-compose.yaml`:

```yaml
agent:
  build: agent/
  networks:
    - agent-net
  volumes:
    - ~/.claude:/home/agent/.claude:ro
    - ./workspace:/workspace
  environment:
    HTTPS_PROXY: http://egress-proxy:3128
  depends_on:
    tidegate:
      condition: service_healthy
    egress-proxy:
      condition: service_started
  read_only: true
  tmpfs:
    - /tmp
    - /home/agent/.npm
    - /home/agent/.cache
  cap_drop:
    - ALL
  security_opt:
    - no-new-privileges:true
```

Add real MCP server containers:

```yaml
gmail-mcp:
  image: <gmail-mcp-image>
  networks:
    - mcp-net
  environment:
    GMAIL_CLIENT_ID: ${GMAIL_CLIENT_ID}
    GMAIL_CLIENT_SECRET: ${GMAIL_CLIENT_SECRET}
    # ... (credential env vars)
```

### setup.sh

```sh
#!/bin/sh
set -e

# 1. Prerequisites
#    - Docker >= 25.0.5
#    - docker compose v2
#    - ~/.claude directory exists (claude login completed on host)

# 2. Configuration
#    - Copy .env.example → .env (if not exists)
#    - Prompt for MCP server API keys (or detect op CLI)

# 3. Build and start
#    - docker compose up --build
#    - Wait for health checks (tidegate, agent)

# 4. Status output
#    - Print container status
#    - Print attach command
#    - Print log command
```

### Credential flow

```
Host machine
  └── claude login (one-time, opens browser)
        └── ~/.claude/auth.json (OAuth tokens)

setup.sh
  ├── mounts ~/.claude:ro into agent container (Claude Code auth)
  ├── reads .env (or op run resolves op:// refs)
  └── passes MCP server credentials via compose environment: directives

Agent container
  ├── Claude Code reads ~/.claude/auth.json → subscription-billed API
  ├── NO API keys for MCP servers
  └── NO tokens for Slack, Gmail, GitHub, etc.

MCP server containers
  ├── gmail-mcp: GMAIL_* from .env
  ├── slack-mcp: SLACK_BOT_TOKEN from .env
  └── github-mcp: GITHUB_TOKEN from .env
```

## What's explicitly deferred (post-MVP hardening)

These are not needed for `./setup.sh` to work. They strengthen the security model.

| Component | What it adds | Depends on |
|-----------|-------------|-----------|
| **Agent-proxy (MITM)** | Replace Squid. Scan skill HTTP bodies. Inject credentials (skills never hold API keys). | Proxy implementation (mitmproxy or custom) |
| **tg-scanner + tidegate-runtime** | L1 taint tracking. eBPF `openat` observation + seccomp-notify `connect()` enforcement. Catch encryption-before-exfiltration via runtime taint, not static analysis. | Go binary + eBPF program + OCI runtime wrapper |
| **Skill hardening** | Rewrite SKILL.md on install. Strip `!command` preprocessing. Constrain `allowed-tools`. | SKILL.md format analysis |
| **Claude Code PreToolUse hooks** | Framework-specific bonus. Scan tool args before execution inside Claude Code. | Claude Code hooks API |

## Validation criteria

`./setup.sh` is done when:

1. Running `./setup.sh` on a Mac with Docker Desktop and `~/.claude/` produces a running system
2. Claude Code inside the container can call MCP tools (verified by sending a message via Slack MCP or similar)
3. Tool calls containing credential patterns (e.g., `AKIA...` in a message body) are blocked with a shaped deny
4. Tool calls containing credit card numbers (Luhn-valid) are blocked
5. The agent container cannot reach the internet directly (only through egress-proxy)
6. The agent container cannot reach MCP servers directly (only through tidegate gateway)
7. `docker compose logs tidegate` shows audit entries for every tool call
8. OpenClaw receives a message (Telegram/Slack) and delegates to Claude Code, which completes the task through the scanned gateway
