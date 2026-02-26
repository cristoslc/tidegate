# Tidegate — Roadmap

From current state to `./setup.sh` on Mac, then hardening.

See [architecture overview](vision/(VISION-001)-Secure-AI-Agent-Deployment/architecture-overview.md) for what exists today and [target state](vision/(VISION-001)-Secure-AI-Agent-Deployment/target-state.md) for the end goal.

---

## Overview

```
M1  Gateway mirror+scan refactor     ✅ COMPLETE
M2  Agent container                   ← Claude Code + OpenClaw in Docker
M3  MCP wiring + real servers         ← connect agent to gateway to real MCP servers
M4  Credential plumbing + setup.sh    ← one command to bootstrap
─────────────────────────────────────── ./setup.sh works ───
M5  Agent-proxy (MITM)                ← scan skill HTTP, credential injection
M6  tg-scanner + tidegate-runtime     ← L1 taint tracking (kernel-level)
M7  Skill hardening + Claude hooks    ← SKILL.md rewriting, PreToolUse hooks
```

M1–M4 are the critical path to a working `./setup.sh`. M5–M7 harden the security model.

---

## M1: Gateway mirror+scan refactor

**Status: COMPLETE** (2026-02-23)

**Goal**: The gateway scans all string values in all tool calls without requiring per-field YAML mappings. Adding a new MCP server is: add its URL to `tidegate.yaml`, add the container to `docker-compose.yaml`, done.

**Why this is first**: Every subsequent milestone depends on being able to add real MCP servers without writing per-field YAML. The current model requires classifying every parameter of every tool — impossible to maintain at scale.

### Changes

**`gateway/src/policy.ts`** — Gut and simplify:
- Remove types: `FieldClass`, `FieldMapping`, `ToolMapping` (and their `system_param`/`user_content`/`opaque_credential`/`structured_data` taxonomy)
- Remove functions: `validateField()`, `validateToolCall()`, `getFieldsToScan()`, `stripUnmappedResponseFields()`
- New config schema:
  ```typescript
  interface ServerConfig {
    transport: "http" | "stdio";
    url?: string;
    command?: string;
    args?: string[];
    env?: Record<string, string>;
    allow_tools?: string[];   // optional allowlist; omit to mirror all
  }
  interface TidegateConfig {
    version: string;
    defaults: {
      scan_timeout_ms: number;
      scan_failure_mode: "deny" | "allow";
    };
    servers: Record<string, ServerConfig>;
  }
  ```
- `resolveToolServer()`: still needed — maps tool name to server name
- New `isToolAllowed()`: check against `allow_tools` if present
- Remove hot-reload of field mappings (config is now just URLs and allowlists)

**`gateway/src/router.ts`** — Simplify enforcement pipeline:
- Remove steps 2-4 (field mapping, no extras, system_param validation)
- New pipeline:
  1. Tool allowed? (check `allow_tools` if configured)
  2. Scan all string values in `args` (recursive walk)
  3. Forward to downstream
  4. Scan all text content in response
  5. Return result
- New helper: `scanAllValues(args)` — recursively walks an object, scans every string value through `scanner.scanValue()`. Handles nested objects and arrays.

**`gateway/src/host.ts`** — No changes needed. Already delegates to `router.getFilteredTools()` and `router.handleToolCall()`.

**`gateway/src/servers.ts`** — No changes needed. Already discovers tools via `listTools()` and forwards calls.

**`gateway/src/scanner.ts`** — No changes needed. `scanValue()` already accepts any string.

**`gateway/src/audit.ts`** — Minor: remove `field` from audit entries (no longer field-level). Add `param_path` for "which nested key triggered the deny" if useful.

**`tidegate.yaml`** — Simplify:
```yaml
version: "1"
defaults:
  scan_timeout_ms: 500
  scan_failure_mode: deny
servers:
  echo:
    transport: http
    url: http://echo-server:4200/mcp
  hello-world:
    transport: http
    url: http://hello-world:4300/mcp
```

**`gateway/tidegate.yaml`** (dev config) — Same simplification, pointing to localhost.

### Verification

- `docker compose up --build` still works with echo + hello-world servers
- `curl` a tool call with a clean message → allowed, forwarded, response returned
- `curl` a tool call with `AKIA...` in message → shaped deny (L1)
- `curl` a tool call with a Luhn-valid credit card number → shaped deny (L2)
- Tool calls to unmapped tools → shaped deny (tool not found)
- If `allow_tools` is set, unlisted tools are invisible in `tools/list`

### Completion notes

Completed 2026-02-23. `policy.ts` gutted from 293→65 LOC (removed `FieldClass`, `FieldMapping`, `ToolMapping`, `validateField`, `getFieldsToScan`, `stripUnmappedResponseFields`). `router.ts` rewritten with 5-step pipeline and `extractStringValues()` recursive walker. `resolveToolServer()` moved to `servers.ts`. `tidegate.yaml` simplified from 70→14 lines. `mappings/` directory deleted. All 7 curl verification tests pass.

### Risk

Low. The scanner and downstream client code didn't change. This was a simplification, not a new capability.

---

## M2: Agent container

**Goal**: A Docker container running OpenClaw (persistent daemon) + Claude Code (headless execution engine). Claude Code uses subscription billing via OAuth passthrough from the host.

**Why this is second**: Can't test MCP wiring (M3) without an agent to generate tool calls.

### Changes

**New `agent/Dockerfile`**:
- Base: `node:22-slim` (not Alpine — Claude Code may need glibc)
- Install `@anthropic-ai/claude-code` globally via npm
- Install OpenClaw and its dependencies
- Create non-root user (`agent`) — required for Claude Code headless mode
- Install `git`, `curl`, `sudo` (Claude Code expects these)
- Set `CLAUDE_CONFIG_DIR=/home/agent/.claude`
- Entrypoint: `agent/entrypoint.sh`

**New `agent/entrypoint.sh`**:
- Starts OpenClaw daemon in foreground
- OpenClaw configured to spawn `claude --dangerously-skip-permissions` via PTY
- Claude Code's `--dangerously-skip-permissions` flag suppresses manual approval prompts for headless execution
- Trap SIGTERM for graceful shutdown

**New `agent/.claude/settings.json`** (or equivalent MCP config):
- All MCP servers point to `http://tidegate:4100/mcp`
- This is baked into the image or volume-mounted

### Open questions to resolve during M2

1. **Claude Code headless auth**: Does the mounted `~/.claude/` directory work for PTY-spawned sessions? Does token refresh require a browser? Test this in isolation first: build a minimal container, mount `~/.claude:ro`, run `claude --version` then a simple prompt.

2. **PTY allocation in hardened container**: `read_only: true` + `cap_drop: ALL` may break PTY allocation (`/dev/pts`). May need `tmpfs` mount on `/dev/pts` or specific capabilities.

3. **Claude Code MCP endpoint model**: Claude Code may expect one MCP endpoint per server (separate entries in its config). If so, options:
   - (a) Run one gateway instance per downstream server (simple but heavy)
   - (b) Use the gateway's single endpoint and configure Claude Code to treat it as one server exposing many tools (if supported)
   - (c) Add path-based routing to the gateway (`/mcp/slack`, `/mcp/github`) that filters tools per path

4. **OpenClaw installation**: What's the current install method? npm package? Git clone? Docker-specific setup?

5. **`node:22-slim` vs Alpine**: Claude Code's npm package may include native binaries that need glibc. Alpine uses musl. Test before committing to a base image.

### Verification

- `docker build -f agent/Dockerfile agent/` succeeds
- Container starts with OpenClaw daemon running
- `docker exec -it tidegate-agent claude --version` returns Claude Code version
- Claude Code can authenticate using mounted `~/.claude/` (run a trivial prompt)
- OpenClaw can spawn Claude Code via PTY and get a response

### Risk

**High**. This milestone has the most unknowns. Claude Code headless in Docker is not a documented or officially supported configuration. The OAuth passthrough, PTY allocation, and MCP endpoint model all need empirical validation.

**Recommended approach**: Build a minimal spike container first (just Claude Code, no OpenClaw) and validate auth + PTY before investing in the full Dockerfile.

---

## M3: MCP wiring + real servers

**Goal**: Claude Code inside the agent container calls real MCP tools (Gmail, Slack, GitHub) through the Tidegate gateway. End-to-end: agent → gateway (scan) → MCP server → external API.

**Why this is third**: Requires the refactored gateway (M1) and a running agent (M2).

### Changes

**`tidegate.yaml`** — Add real server configs:
```yaml
servers:
  gmail:
    transport: http
    url: http://gmail-mcp:3000/mcp
  slack:
    transport: http
    url: http://slack-mcp:3000/mcp
  github:
    transport: http
    url: http://github-mcp:3000/mcp
```

Note: some MCP servers use stdio transport (launched as child processes). These can be configured with `transport: stdio` and `command`/`args` fields. The gateway already supports both transports via `servers.ts`.

**`docker-compose.yaml`** — Add real MCP server containers:
```yaml
gmail-mcp:
  image: <gmail-mcp-image>
  networks:
    - mcp-net
  environment:
    GMAIL_CLIENT_ID: ${GMAIL_CLIENT_ID}
    GMAIL_CLIENT_SECRET: ${GMAIL_CLIENT_SECRET}
  read_only: true
  tmpfs: ["/tmp"]
  cap_drop: [ALL]
  security_opt: ["no-new-privileges:true"]

slack-mcp:
  image: <slack-mcp-image>
  networks:
    - mcp-net
  environment:
    SLACK_BOT_TOKEN: ${SLACK_BOT_TOKEN}
  # ... same hardening
```

**Agent MCP config** — Claude Code's settings point to the gateway:
- If Claude Code supports a single multi-tool MCP endpoint: one entry pointing to `http://tidegate:4100/mcp`
- If it requires per-server endpoints: either run multiple gateway instances or add path-based routing (see M2 open question #3)

**`egress-proxy/allowlist.txt`** — Add domains that MCP servers need:
- MCP servers are on `mcp-net` with direct internet access, so they don't need the egress proxy
- The egress proxy only needs LLM API domains (already configured)
- If MCP servers need to be on an internal network with proxied internet access, that's a topology change (deferred)

### Open questions

1. **Which MCP servers to include in MVP?** Start with one well-tested server (e.g., GitHub MCP or Slack MCP) rather than all at once.

2. **MCP server Docker images**: Are official Docker images available for common MCP servers (Gmail, Slack, GitHub)? Or do we need to build our own from npm packages?

3. **stdio MCP servers**: Some MCP servers are designed to run as stdio child processes, not HTTP servers. The gateway supports stdio via `StdioClientTransport`, but running them as child processes inside the gateway container breaks the network isolation model (they'd share the gateway's network namespace). Options:
   - Wrap stdio servers in a thin HTTP adapter container
   - Accept weaker isolation for stdio servers (documented)
   - Only use HTTP-transport MCP servers

### Verification

- Claude Code calls a real MCP tool (e.g., `list_channels` on Slack)
- The call passes through the gateway (visible in audit logs)
- A tool call with an injected credential pattern is blocked
- Claude Code receives the shaped deny and adjusts its behavior
- The MCP server's external API call succeeds (e.g., Slack API returns channels)

### Risk

Medium. Depends on MCP server ecosystem maturity. Community MCP servers may have transport quirks, undocumented parameters, or stability issues.

---

## M4: Credential plumbing + setup.sh

**Goal**: A single `./setup.sh` script that takes a Mac with Docker Desktop from zero to a running Tidegate system.

**Why this is last in the critical path**: Requires all previous milestones. This is packaging, not new capability.

### Changes

**New `setup.sh`**:
```sh
#!/bin/sh
set -e

# ── Prerequisites ───────────────────────────────
# Check Docker version >= 25.0.5
# Check docker compose v2
# Check ~/.claude/ exists (prompt for claude login if not)

# ── Configuration ───────────────────────────────
# Copy .env.example → .env if .env doesn't exist
# Prompt for MCP server API keys
# Or detect op CLI and use op:// references

# ── Build and start ─────────────────────────────
# docker compose up --build --detach
# Wait for health checks (tidegate, agent)
# Timeout after 120s with error

# ── Status ──────────────────────────────────────
# Print container status table
# Print: "Attach: docker exec -it tidegate-agent bash"
# Print: "Logs:   docker compose logs -f"
# Print: "Stop:   docker compose down"
```

**New `.env.example`**:
```
# Tidegate environment configuration
# Copy to .env and fill in values, or use: op run --env-file .env -- docker compose up

# ── MCP Server Credentials ───────────────────────
# Slack
SLACK_BOT_TOKEN=xoxb-your-token-here

# GitHub
GITHUB_TOKEN=ghp_your-token-here

# Gmail (OAuth — may require separate setup)
# GMAIL_CLIENT_ID=
# GMAIL_CLIENT_SECRET=
# GMAIL_REFRESH_TOKEN=
```

**Update `docker-compose.yaml`**:
- Add agent container service (from M2)
- Add real MCP server containers (from M3)
- Reference `${VARIABLE}` names from `.env`

**Update `egress-proxy/allowlist.txt`**:
- Ensure LLM API domains are listed

### Verification

1. Clone repo on a fresh Mac with Docker Desktop
2. Run `claude login` to create `~/.claude/`
3. Run `./setup.sh`
4. System comes up, all health checks pass
5. Claude Code can call MCP tools through the gateway
6. Credential patterns in tool calls are blocked

### Risk

Low. This is integration and packaging. All the hard parts are in M1–M3.

---

## M5: Agent-proxy (MITM) — post-MVP

**Goal**: Replace Squid CONNECT-only proxy with a MITM proxy that scans skill HTTP traffic and injects credentials.

### What it adds

- **LLM API domains**: CONNECT passthrough (unchanged from Squid)
- **Skill-allowed domains**: MITM. Proxy terminates TLS, scans request/response bodies through the scanner, injects `Authorization` headers (credential injection), re-encrypts to upstream.
- **Everything else**: blocked (unchanged from Squid)

Skills never hold API keys. The proxy configuration maps domains to credentials. A skill calls `fetch("https://api.slack.com/...")` and the proxy adds the auth header.

### Changes

- New `agent-proxy/` directory replacing `egress-proxy/`
- Proxy implementation (mitmproxy, custom Go/Rust, or Node.js)
- Domain → credential mapping in proxy config
- Scanner integration (same `{value} → {allow/deny}` interface)
- CA certificate generation and trust in agent container
- Update `docker-compose.yaml` network assignments

### Risk

Medium. MITM proxy is well-understood technology. The main complexity is CA trust management inside the agent container and ensuring credential injection doesn't break MCP servers' expectations.

---

## M6: tg-scanner + tidegate-runtime — post-MVP

**Goal**: L1 journal-based taint tracking. eBPF observes file access in the agent container, scanner daemon analyzes files and tracks taint, seccomp-notify on `connect()` blocks tainted processes from network access.

This is the load-bearing security layer that catches encryption-before-exfiltration.

### What it adds

- **tidegate-runtime**: OCI runtime wrapper (~50 lines). Injects `SCMP_ACT_NOTIFY` for `connect` into the agent container's OCI bundle. Delegates to runc.
- **tg-scanner container**: Go binary using `libseccomp-golang` and `cilium/ebpf`. Three components:
  - **eBPF loader**: Attaches a lightweight eBPF program to `openat`. Logs `{pid, file_path, seq}` to a BPF ring buffer. Non-blocking, nanosecond overhead.
  - **Scanner daemon**: Reads file-open events from the ring buffer, reads file contents from shared read-only workspace volume, runs scanner (`{value} → {allow/deny}`), updates taint table.
  - **Connect enforcer**: Receives seccomp-notify `connect()` notifications, waits for scanner daemon to catch up with pending events for the PID, checks taint table. Tainted → EPERM. Clean → ALLOW.
- **Shared workspace volume**: Agent container mounts `/workspace` read-write. tg-scanner mounts the same volume read-only. tg-scanner reads files independently — the agent cannot influence what tg-scanner reads.

### Changes

- New `tg-scanner/` directory with Go binary
- New `tidegate-runtime/` directory with OCI wrapper
- Scanner subprocess shared between gateway and tg-scanner (same Python code, same protocol)
- `docker-compose.yaml`: add tg-scanner service, shared volume, configure agent container to use tidegate-runtime
- Fallback seccomp-bpf filter: kills agent container if tg-scanner disconnects (fail-closed)

### Requirements

- Linux kernel 5.8+ (BPF ring buffer)
- runc 1.1.0+ (seccomp-notify + `listenerPath`)
- Docker Desktop: LinuxKit kernel 5.15+ (has this)
- Go 1.21+ for `libseccomp-golang` and `cilium/ebpf`

### Risk

**Medium-high**. seccomp-notify on `connect()` has precedent (SocksTrace, force-bind-seccomp) unlike `execve`-gating which had no precedent. eBPF for `openat` observation is well-trodden. Main risks: scanner daemon latency on rapid file access patterns, taint explosion if many workspace files are sensitive, and Docker Desktop's runc configuration for seccomp-notify.

See [ADR-002](adr/proposed/(ADR-002)-Taint-and-Verify-Data-Flow-Model.md) for the full decision record. See [ADR-001 (superseded)](adr/superseded/(ADR-001)-Seccomp-Notify-L1-Interception.md) for the original `execve`-gating design and why it was replaced.

---

## M7: Skill hardening + Claude Code hooks — post-MVP

**Goal**: Harden skills on install and add Claude Code framework-specific scanning hooks.

### What it adds

- **SKILL.md rewriting**: When a user installs a skill, Tidegate rewrites the SKILL.md:
  - Strip `!`command`` preprocessing (executes shell commands at load time, before any hooks)
  - Constrain `allowed-tools` in frontmatter (minimum privilege)
  - Wrap bundled scripts to route through tg-scanner
  - Framework-agnostic: operates on the cross-platform SKILL.md file format

- **Claude Code PreToolUse hooks**: Install hooks that scan tool arguments before execution inside Claude Code. This is a framework-specific bonus — shaped deny back to the LLM before the tool call even reaches the gateway.

### Changes

- New `skill-hardener/` directory with SKILL.md parser and rewriter
- Integration with skill installation workflow (depends on agent framework)
- Claude Code hook configuration in agent container's `.claude/` directory

### Risk

Low-medium. SKILL.md format is documented and stable. Claude Code hooks API is first-party. The main risk is keeping up with SKILL.md format changes across agent frameworks.

---

## Dependency graph

```
M1 (mirror+scan)
  │
  ├──→ M3 (MCP wiring) ──→ M4 (setup.sh)
  │                              │
M2 (agent container) ────────────┘
                                 │
                            ./setup.sh works
                                 │
                    ┌────────────┼────────────┐
                    │            │            │
                    v            v            v
              M5 (proxy)   M6 (taint)    M7 (skills)
```

M1 and M2 can be developed in parallel. M3 depends on both. M4 depends on M3. M5–M7 are independent of each other and can be done in any order after M4.

---

## Risk register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|-----------|-----------|
| Claude Code headless auth doesn't work with mounted `~/.claude/` | Blocks M2 entirely | Medium | Spike early: build minimal container, test auth in isolation before full Dockerfile |
| Claude Code requires per-server MCP endpoints (not single multiplexed endpoint) | Complicates M3 | Medium | Test early. Fallback: path-based routing in gateway or one gateway instance per server |
| PTY allocation fails under `cap_drop: ALL` + `read_only: true` | Blocks M2 | Low-medium | Test with incrementally relaxed constraints. May need `tmpfs` on `/dev/pts` |
| Community MCP server Docker images don't exist | Slows M3 | Medium | Build thin Dockerfiles wrapping npm packages |
| stdio MCP servers break network isolation model | Weakens M3 security | Medium | Prefer HTTP-transport servers. Document weaker isolation for stdio fallback |
| seccomp-notify or eBPF doesn't work in Docker Desktop's LinuxKit VM | Blocks M6 | Low | LinuxKit kernel 5.15 has both features. Test runc config for seccomp-notify on connect(). eBPF fallback: seccomp-notify on openat (slower). Only affects post-MVP |
| OpenClaw installation/configuration is complex | Slows M2 | Unknown | Investigate OpenClaw install early. May need to simplify or fork for container use |
