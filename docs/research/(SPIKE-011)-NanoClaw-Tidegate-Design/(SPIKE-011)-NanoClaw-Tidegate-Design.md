# NanoClaw × Tidegate Integration — Design Spike

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Complete | 2026-02-24 | 6749250 | NanoClaw selected as first agent runtime; informed ADR-003 |

## Purpose
Design the access layer and deployment architecture for Tidegate (AI agent security framework) using NanoClaw (personal Claude assistant) as the agent runtime, targeting a fully containerized homelab deployment.

## Context
- Tidegate enforces egress control, credential isolation, and syscall interception on AI agent containers
- NanoClaw is a ~5K-line TypeScript orchestrator that spawns Claude Code agents in Docker containers, communicating via filesystem IPC
- Deployment target: Proxmox homelab, everything compose-managed, nothing on bare metal except Docker daemon

## NanoClaw Codebase Analysis (from uploaded source)

**Architecture:** Single Node.js host process (WhatsApp via baileys, SQLite, IPC watcher, task scheduler, GroupQueue) spawns ephemeral Docker containers via `child_process.spawn('docker', ['run', '-i', '--rm', ...])`. Agent containers run `agent-runner/index.ts` which calls Claude Agent SDK `query()` with `bypassPermissions`.

**IPC model:** All agent↔host communication is filesystem-based:
- Host→Agent: JSON files in `data/ipc/{group}/input/`, `_close` sentinel, stdin (initial prompt)
- Agent→Host: JSON files in `data/ipc/{group}/messages/` and `tasks/`, stdout markers (streaming results)
- MCP server (`ipc-mcp-stdio.ts`) inside container writes IPC files for `send_message`, `schedule_task`, etc.

**Security model:** Container isolation is primary boundary. Per-group filesystem/session/IPC isolation. Mount allowlist stored outside project root. Non-root user. Read-only project root for main group. IPC authorization (non-main groups restricted). **Key gaps:** unrestricted network egress, API keys present in container env, no seccomp/AppArmor, no capability drops.

**Code touchpoints for integration:** `container-runner.ts` (spawn logic, mount building), `container-runtime.ts` (Docker CLI calls), `agent-runner/index.ts` (stdin reading, stdout markers).

## Design Decisions

### 1. Containerize NanoClaw Host
NanoClaw host process runs in a container (not bare metal). Requires decoupling from Docker CLI — host container cannot have Docker socket.

### 2. Pipeline Architecture (tg-pipeline)
Introduced `tg-pipeline` container as sole Docker-socket holder. Acts as CI/CD-style pipeline: validates compose specs against security policy, then executes them. Separated from data path.

### 3. Filesystem Job Queue
NanoClaw and tg-pipeline communicate via shared volume with lifecycle directories:

```
/var/run/tidegate/jobs/
├── start/        NanoClaw drops compose specs
├── validating/   Pipeline picks up, validates
├── running/      Passed policy, container is up
├── stop/         NanoClaw requests shutdown
├── stopping/     Pipeline stopping container
├── stopped/      Clean exit
├── failed/       Policy violation or crash (.error file with reason)
└── remove/       NanoClaw requests cleanup → pipeline deletes
```

State machine: `start → validating → running → stop → stopping → stopped → remove`, with `failed` as error state from `validating` or `running`.

Atomic `rename()` operations on same filesystem ensure no race conditions.

### 4. Full Filesystem IPC (Drop stdin/stdout)
Eliminated stdin/stdout pipe dependency between host and agent containers. Pipeline spawns containers **detached** (`docker compose up -d`). All communication uses existing IPC volume:

- Initial prompt: NanoClaw writes to `data/ipc/{group}/input/prompt-{ts}.json` + `_meta.json` (session info) **before** dropping compose spec in `start/`
- Results: Agent uses `send_message` MCP tool → writes to `ipc/messages/` → host IPC watcher picks up → sends to WhatsApp
- Session IDs: Agent writes to `ipc/session_id` file
- Follow-ups: Host writes to `ipc/input/*.json` (existing mechanism)
- Shutdown: Host writes `ipc/input/_close` (existing mechanism)

Pipeline never touches prompt/IPC data. Prompt volume and jobs volume are separate concerns.

### 5. Policy Enforcement
`tidegate-policy.yaml` defines mandatory container constraints:
- Required: `networks: [agent-net]`, `cap_drop: [ALL]`, `no-new-privileges`, `user: 1000:1000`, `HTTPS_PROXY` env
- Forbidden: `privileged`, `cap_add`, host networking/PID/IPC, Docker socket mounts, API keys in env
- Allowlisted: images (`nanoclaw-agent:*`), volume prefixes (`/opt/nanoclaw/{groups,data}/`)

Pipeline validates every compose spec against this policy before execution. This is the single enforcement point — NanoClaw cannot bypass it.

### 6. Network Topology

```
agent-net (internal):   agent containers ↔ egress-proxy ↔ tg-gateway
proxy-net:              egress-proxy → internet
mcp-net (internal):     tg-gateway ↔ MCP servers
wg-net:                 wireguard ↔ nanoclaw-host (WebChat access)
```

> **Correction (2026-02-24):** Original design included `control-net` (tg-pipeline ↔ nanoclaw-host) and placed nanoclaw-host on `agent-net`. Both are wrong:
>
> - **`control-net` removed.** tg-pipeline and nanoclaw-host communicate via the filesystem job queue (shared volume + atomic `rename()`), not network. A network between them creates an unnecessary attack surface.
> - **nanoclaw-host removed from `agent-net`.** All host↔agent communication is filesystem IPC (decision #4). The host doesn't need network connectivity to agents. Keeping the host off `agent-net` prevents it from becoming an application-layer bridge between `wg-net` (internet-facing WireGuard tunnel) and `agent-net` (controlled egress only). Any dual-homed container is a potential bypass path — a compromised process can `connect()` out one interface and relay bytes, even without IP forwarding.
>
> The host and agents share **volumes**, not a **network**. This is strictly better: fewer networks, stronger isolation.

### 7. Volume Path Resolution
Dual-path pattern: NanoClaw uses container-local paths (`/app/data/...`) for its own fs operations. Compose specs use host paths (`/opt/nanoclaw/data/...`) for bind mounts interpreted by Docker daemon. `HOST_GROUPS_DIR` / `HOST_DATA_DIR` env vars bridge the two.

### 8. Build/Runtime Separation (added 2026-02-24)

NanoClaw skills are code transformations (`git merge-file` three-way merges) that modify the host source tree. The host mounts agent-runner source writable into containers. This creates a self-modification risk: a compromised agent can modify its own orchestrator's code through the writable mount, and the next agent spawn (or host restart) executes the poisoned code.

**Mitigation:** Skill application is a build step. It produces an immutable container image. tg-pipeline enforces that agent containers mount source paths read-only. IPC directories (`/workspace/ipc/`) are the only writable mount.

```yaml
# tg-pipeline enforces:
volumes:
  - ./agent-runner:/app/src:ro        # source: read-only
  - ./ipc/${GROUP}:/workspace/ipc:rw  # IPC: read-write (scoped)
```

tg-pipeline rejects any compose spec with writable source mounts. The agent runtime's build process (skills, code generation, hand edits) is its own concern. Tidegate's contract: give us an image, we run it with enforced constraints.

## Produced Artifact
`nanoclaw-analysis.md` — deep codebase analysis covering architecture, data flow, security model, code quality, and integration mapping with specific file/function references.
