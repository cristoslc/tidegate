# AGENTS.md — Tidegate

Reference architecture for an MCP gateway that sits between an agent and downstream MCP servers, scans all string values in tool call parameters and responses for sensitive data, and returns shaped denies on policy violations. Plus Squid egress proxy and Docker packaging.

See `docs/vision/` for product vision, `docs/threat-model/` for threat model.

## Directory structure

```
src/
├── gateway/               # TypeScript MCP gateway
│   ├── src/
│   │   ├── index.ts       # Entry: load config → connect downstream → start host
│   │   ├── host.ts        # Streamable HTTP server (agent-facing, port 4100)
│   │   ├── router.ts      # Enforcement pipeline + extractStringValues()
│   │   ├── policy.ts      # Config loading + tool allowlists
│   │   ├── scanner.ts     # L1 in-process + L2/L3 Python subprocess
│   │   ├── servers.ts     # Downstream MCP client connections
│   │   └── audit.ts       # NDJSON structured logging
│   ├── test-echo-server.ts
│   ├── tidegate.yaml      # Dev config (localhost URLs)
│   └── Dockerfile
├── scanner/               # Python L2/L3 subprocess
│   └── scanner.py         # Stateless: {value} → {allow/deny}
├── egress-proxy/          # Squid CONNECT-only proxy
├── hello-world/           # Demo MCP server
└── test/echo-server/      # Docker echo server for compose testing

docs/
├── vision/                # Product vision (VISION-NNN)
├── persona/               # User personas (PERSONA-NNN)
├── adr/                   # Architecture Decision Records (ADR-NNN)
├── research/              # Research spikes (SPIKE-NNN)
├── threat-model/
└── testing.md
```

Root: `tidegate.yaml` (runtime config), `docker-compose.yaml`.

## Running

```sh
# Dev (no Docker)
cd src/gateway
npx tsx test-echo-server.ts &    # echo server on :4200
npm run dev                       # gateway on :4100

# Docker
docker compose up --build
```

## Conventions

**TypeScript** (gateway): strict mode, no `any`. MCP SDK from `@modelcontextprotocol/sdk`.

**Python** (scanner): stateless, no framework deps. `python-stdnum` for checksums. L2 patterns must have zero mathematical false positives.

**MCP SDK pattern**: per-request `Server` + `StreamableHTTPServerTransport` pair. `Server.connect()` is one-shot — fresh `Server` per request.

**Module boundaries**: `servers.ts` has zero knowledge of policy or scanning. `router.ts` only calls `servers.forward()` on the pass path. `scanner.ts` has no knowledge of tool names or field names.

**Docker**: pin base image versions, `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, non-root user, `HEALTHCHECK` in every Dockerfile.

**Security**: never commit secrets. Fail-closed on all error paths. Credentials only in MCP server containers, never in agent/gateway containers.

**Shell**: POSIX sh, not bash. Must work in Alpine.

## Key files for common tasks

| Task | Start here |
|---|---|
| Add a scanning pattern | `src/gateway/src/scanner.ts` (L1) or `src/scanner/scanner.py` (L2/L3) |
| Change enforcement pipeline | `src/gateway/src/router.ts` |
| Change config schema | `src/gateway/src/policy.ts` |
| Add transport support | `src/gateway/src/servers.ts` |
| Modify HTTP handling | `src/gateway/src/host.ts` |
| Change audit format | `src/gateway/src/audit.ts` |
| Docker topology | `docker-compose.yaml` |

<!-- swain governance — do not edit this block manually -->

## Skill routing

When the user wants to create, plan, write, update, transition, or review any documentation artifact (Vision, Journey, Epic, Story, Agent Spec, Spike, ADR, Persona, Runbook, Bug) or their supporting docs (architecture overviews, competitive analyses, journey maps), **always invoke the swain-design skill**. This includes requests like "write a spec", "let's plan the next feature", "create an ADR for this decision", "move the spike to Active", "add a user story", "create a runbook", "file a bug", or "update the architecture overview." The skill contains the artifact types, lifecycle phases, folder structure conventions, relationship rules, and validation procedures — do not improvise artifact creation outside the skill.

**For all task tracking and execution progress**, use the **swain-do** skill instead of any built-in todo or task system. This applies whether tasks originate from swain-design (implementation plans) or from standalone work. The swain-do skill bootstraps and operates the external task backend — it will install the CLI if missing, manage fallback if installation fails, and translate abstract operations (create plan, add task, set dependency) into concrete commands. Do not use built-in agent todos when this skill is available.

## Pre-implementation protocol (MANDATORY)

Implementation of any SPEC artifact (Epic, Story, Agent Spec, Spike) requires a swain-do plan **before** writing code. Invoke the swain-design skill — it enforces the full workflow.

## Issue Tracking

This project uses **bd (beads)** for all issue tracking. Do NOT use markdown TODOs or task lists. Invoke the **swain-do** skill for all bd operations — it provides the full command reference and workflow.

<!-- end swain governance -->
