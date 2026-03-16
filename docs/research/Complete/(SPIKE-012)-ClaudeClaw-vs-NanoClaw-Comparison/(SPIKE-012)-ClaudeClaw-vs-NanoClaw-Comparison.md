---
artifact: SPIKE-012
title: "ClaudeClaw vs NanoClaw Comparison"
status: Complete
author: cristos
created: 2026-02-25
last-updated: 2026-03-09
question: "Is ClaudeClaw a viable alternative or complement to NanoClaw for Tidegate's agent runtime?"
parent-vision: VISION-001
gate: Pre-MVP
risks-addressed: []
depends-on: []
linked-artifacts:
  - ADR-003
---
# ClaudeClaw vs NanoClaw — Agent-Container Runtime Comparison

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Active | 2026-02-25 | 0ec6eb8 | Spike started; claudeclaw source pulled at 198 commits / 162 stars |
| Complete | 2026-03-09 | 1458121 | NanoClaw confirmed; ClaudeClaw rejected (no process boundary) |

## Purpose

Evaluate [ClaudeClaw](https://github.com/moazbuilds/claudeclaw) as an alternative or complement to NanoClaw for Tidegate's agent-container runtime. The prior agent-selection spike (completed 2026-02-24) compared NanoClaw to OpenClaw and selected NanoClaw; this spike adds ClaudeClaw to that analysis.

## Context

Tidegate's wrapping contract (ADR-003): **give us a container image, we run it with enforced constraints.** The runtime must have a process boundary between the agent and the control plane for Tidegate to wrap at the tool-call level.

---

## ClaudeClaw Architecture (from source, `moazbuilds/claudeclaw` @ master)

### What it is

A Claude Code **plugin** (~2.5K LOC TypeScript, Bun runtime) that turns Claude Code into a persistent background daemon. Runs scheduled prompts (heartbeat, cron jobs), accepts Telegram messages, and serves a web dashboard. Installed via the Claude Code plugin marketplace.

### Execution model

**No containers. No process boundary.** ClaudeClaw spawns Claude Code CLI as a child process:

```typescript
// runner.ts:75-86
const proc = Bun.spawn(args, {
  stdout: "pipe",
  stderr: "pipe",
  env: buildChildEnv(baseEnv, model, api),
});
```

The daemon (`start.ts`) runs as a single Bun process on the host. Each agent invocation is a `claude -p <prompt> --dangerously-skip-permissions` subprocess:

```typescript
// runner.ts:228
const args = ["claude", "-p", prompt, "--output-format", outputFormat, ...securityArgs];
```

The `--dangerously-skip-permissions` flag is always passed (line 148). Session continuity via `--resume <sessionId>`.

### Security model

Four "security levels" — all application-level, enforced via CLI flags and system prompt instructions:

| Level | Effect |
|---|---|
| `locked` | `--tools Read,Grep,Glob` (read-only tools only) |
| `strict` | `--disallowedTools Bash,WebSearch,WebFetch` |
| `moderate` | All tools, directory scoping via system prompt |
| `unrestricted` | All tools, no restrictions |

**Directory scoping** (the primary isolation mechanism for `moderate` level) is a system prompt instruction:

```typescript
// runner.ts:96-101
const DIR_SCOPE_PROMPT = [
  `CRITICAL SECURITY CONSTRAINT: You are scoped to the project directory: ${PROJECT_DIR}`,
  "You MUST NOT read, write, edit, or delete any file outside this directory.",
  // ...
].join("\n");
```

This is **prompt-based enforcement only**. The Claude Code subprocess has full host filesystem access, full network access, and runs as the user's own UID. There is no OS-level isolation whatsoever.

### IPC model

CLI subprocess with piped stdout/stderr. Session state in `.claude/claudeclaw/session.json`. Jobs as markdown files with YAML frontmatter in `.claude/claudeclaw/jobs/`. Settings in `.claude/claudeclaw/settings.json`.

### Communication channels

- **Telegram** — Long-polling bot API (zero-dep, raw `fetch`). Text, images, voice (Whisper transcription via `ogg-opus-decoder`).
- **Web dashboard** — Built-in Bun HTTP server for monitoring, job editing, log viewing.
- **Heartbeat** — Configurable periodic prompts with quiet hours and exclude windows.

### Dependencies

Minimal: `ogg-opus-decoder` is the only runtime dependency. Bun as the runtime. Claude Code CLI as the agent.

### Plugin ecosystem

Installs Claude Code plugins automatically on startup (`preflight.ts`): `dev-browser`, `claude-mem`, `superpowers-marketplace`, and cherry-picks from `claude-plugins-official` (ralph-loop, hookify, code-review, etc.).

---

## NanoClaw Architecture (from prior spike + source in `completed/agent-selection/nanoclaw-main/`)

### What it is

A personal Claude assistant (~5K LOC TypeScript, Node.js) that spawns ephemeral Docker containers for each agent session. Communication via WhatsApp (baileys), with skills-based customization. Claude Agent SDK as the runtime.

### Execution model

**Container-isolated agents.** Host process spawns Docker containers via `child_process.spawn('docker', ['run', '-i', '--rm', ...])`. Agent containers run `agent-runner/index.ts` which calls Claude Agent SDK `query()` with `bypassPermissions`.

```
HOST (Node.js) → docker run → CONTAINER (agent-runner + Claude Agent SDK)
```

Each group gets its own container with isolated filesystem, sessions, and IPC.

### Security model

Container isolation as the primary boundary:
- **Filesystem isolation** — Only explicitly mounted directories visible
- **Per-group isolation** — Separate containers, sessions, IPC directories
- **Non-root user** — Container runs as `node` (uid 1000)
- **Mount allowlist** — External config at `~/.config/nanoclaw/mount-allowlist.json` (outside project root, never mounted into containers)
- **Read-only project root** — Main group's source mounted `:ro`
- **Blocked patterns** — `.ssh`, `.gnupg`, `.aws`, `.env`, credentials, private keys

**Key gaps** (identified in prior spike): unrestricted network egress, API keys present in container env, no seccomp/AppArmor, no capability drops.

### IPC model

All agent↔host communication is filesystem-based:
- Host→Agent: JSON files in `data/ipc/{group}/input/`, `_close` sentinel
- Agent→Host: JSON files in `data/ipc/{group}/messages/` and `tasks/`
- MCP server (`ipc-mcp-stdio.ts`) inside container writes IPC files

### Communication channels

- **WhatsApp** (baileys WebSocket) — Primary channel
- **Telegram, Discord, Slack, Signal** — Via skills (`/add-telegram`, etc.)
- **Agent Swarms** — Teams of agents that collaborate

### Dependencies

Node.js 20+, Docker or Apple Container, Claude Code CLI (for Agent SDK), SQLite (better-sqlite3), baileys (WhatsApp).

---

## Comparison Matrix

| Dimension | ClaudeClaw | NanoClaw |
|---|---|---|
| **Agent isolation** | **None.** Subprocess on host, same UID, full filesystem/network | **Container.** Docker/Apple Container per session |
| **Process boundary** | No — CLI subprocess inherits host | Yes — Docker container boundary |
| **Filesystem isolation** | Prompt-based only ("don't go outside project dir") | OS-level mount isolation |
| **Network isolation** | None — full host network | None by default, but Docker network is configurable |
| **Credential exposure** | Full host env accessible to subprocess | API keys in container env (acknowledged gap) |
| **MCP support** | None native; plugins add tools | Built-in MCP server for IPC (`ipc-mcp-stdio.ts`) |
| **Tidegate wrappability** | **Cannot wrap at tool-call level** — no container, no MCP routing seam | **Can wrap at tool-call level** — container on `agent-net`, MCP through tg-gateway |
| **Egress control** | Not possible without host-level firewall | Docker network + proxy routing feasible |
| **Scanning seam** | None — tool calls are in-process function calls within Claude Code | All MCP calls route through gateway |
| **Host↔agent IPC** | Piped stdout/stderr on CLI subprocess | Filesystem JSON + volume mounts |
| **Session model** | Single global session, `--resume` | Per-group sessions, Agent SDK `resume` |
| **Codebase size** | ~2.5K LOC | ~5K LOC |
| **Runtime** | Bun | Node.js |
| **Messaging** | Telegram (built-in) | WhatsApp (built-in), others via skills |
| **Scheduling** | Heartbeat + cron jobs (markdown files) | Scheduler + cron (SQLite + MCP tools) |
| **Web UI** | Built-in dashboard | None (AI-native: "ask Claude") |
| **Installation** | Plugin marketplace + one command | `git clone` + `/setup` skill |
| **Customization model** | Edit code / settings.json | Skills (code transformations via `git merge-file`) |

---

## Tidegate Integration Assessment

### ClaudeClaw: Does not fit as an agent-container runtime

ClaudeClaw fails Tidegate's fundamental requirement: **a process boundary between the agent and the control plane.**

1. **No container boundary.** The agent runs as a `claude` CLI subprocess on the host with the user's full UID, filesystem, and network access. There is nothing to wrap.

2. **No MCP routing seam.** Tool calls happen inside the Claude Code process. There is no point where Tidegate can intercept, scan, or deny individual tool calls. The only "scanning" would be at the network level (same as the OpenClaw analysis in ADR-003).

3. **`--dangerously-skip-permissions` is always on.** Every invocation bypasses Claude Code's built-in permission system. Combined with no container isolation, the agent has unrestricted access to anything the host user can access.

4. **Security is prompt-based.** The "moderate" security level asks Claude via system prompt not to access files outside the project directory. This is trivially bypassed by prompt injection — exactly the threat model Tidegate exists to defend against.

5. **Credential exposure is total.** The subprocess inherits `process.env` (minus `CLAUDECODE`). Unlike NanoClaw, which at least restricts env vars to `CLAUDE_CODE_OAUTH_TOKEN` and `ANTHROPIC_API_KEY`, ClaudeClaw exposes the full host environment.

ClaudeClaw is architecturally equivalent to OpenClaw for Tidegate's purposes: a single-trust-boundary system where the agent IS the host process. The same conclusion from ADR-003 applies: it could only be wrapped at the network level (coarser-grained, monitoring-based enforcement), not at the tool-call level.

### NanoClaw: Fits (confirmed by prior spike + ADR-003)

NanoClaw provides the container boundary Tidegate needs. The prior design spike produced a viable integration architecture:
- Agent containers on `agent-net` (internal)
- All MCP tool calls through `tg-gateway` (L1/L2/L3 scanning)
- Credential isolation (API keys in MCP server containers, not agent containers)
- Egress through `egress-proxy` (domain allowlisting)
- Filesystem IPC only (no network between host and agents)
- Read-only source mounts enforced by `tg-pipeline`

NanoClaw's existing gaps (unrestricted egress, API keys in env, no seccomp) are exactly what Tidegate addresses.

---

## What ClaudeClaw does well (that NanoClaw doesn't)

Despite being unsuitable as a Tidegate agent runtime, ClaudeClaw has features worth noting:

1. **Zero-infrastructure deployment.** Plugin marketplace install → one command → running daemon. No Docker, no container builds, no compose files.

2. **Web dashboard.** Real-time monitoring of runs, job editing, log viewing. NanoClaw's "AI-native" approach (ask Claude what's happening) is philosophically interesting but less practical for ops.

3. **Heartbeat with quiet hours.** Configurable exclude windows with day-of-week granularity. NanoClaw's scheduler is more capable overall, but the quiet hours UX is cleaner.

4. **Model fallback.** Primary model rate-limited → automatic fallback to secondary model/API. Useful for subscription-based usage.

5. **Plugin preflight.** Auto-installs useful Claude Code plugins on startup. Nice DX.

---

## Verdict

**NanoClaw remains the correct choice for Tidegate's agent-container runtime.** ClaudeClaw's lack of any container or process boundary makes it fundamentally incompatible with Tidegate's wrapping model.

The comparison reinforces ADR-003's key insight: Tidegate needs a **process boundary between the agent and the control plane**. Systems that embed the agent in the host process (OpenClaw, ClaudeClaw) can only be wrapped at the network level. Systems that containerize the agent (NanoClaw) enable the full enforcement stack: per-tool-call scanning, credential isolation, egress control, and taint tracking.

### Recommendation

No changes to ADR-003. ClaudeClaw falls into the same category as OpenClaw (network-level wrapping only, coarser-grained enforcement). If ClaudeClaw users want Tidegate's protections, the path would be:
1. Run the ClaudeClaw daemon inside a container (treating the whole daemon as untrusted, like OpenClaw)
2. Route all egress through egress-proxy
3. Accept that tool-call-level scanning is not possible

This is a viable but significantly weaker security posture than the NanoClaw integration.

## Source material

- ClaudeClaw source: `claudeclaw-master/` (cloned from `moazbuilds/claudeclaw` at 198 commits, 162 stars, 2 contributors)
- NanoClaw source: `../completed/agent-selection/nanoclaw-main/`
- Prior spike: `../completed/agent-selection/nanoclaw-tidegate-design-spike.md`
- ADR-003: `../../adr/proposed/003-agent-runtime-selection.md`
