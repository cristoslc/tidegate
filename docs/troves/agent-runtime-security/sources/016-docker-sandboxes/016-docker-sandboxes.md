---
source-id: 016-docker-sandboxes
type: documentation-site
url: https://docs.docker.com/ai/sandboxes/
fetched: 2026-03-17T00:00:00Z
title: "Docker Sandboxes"
author: Docker Inc.
tags: [docker, sandboxes, microvm, agent-isolation, credential-injection, container-isolation]
provenance: "Official Docker documentation for the Sandboxes feature. Combines the overview page and architecture subpage. Docker Sandboxes is a first-party product from Docker for running AI coding agents in isolated microVMs."
---

# Docker Sandboxes

Docker Sandboxes provides isolated execution environments for AI coding agents. Each sandbox runs in a lightweight microVM with a private Docker daemon, fully separated from the host system.

## Architecture

### Hypervisor

- **macOS**: Apple's virtualization.framework
- **Windows**: Hyper-V (experimental)

Provides hypervisor-level isolation between the sandbox and the host.

### Isolation model

Unlike containers (which share the host kernel), each sandbox runs a separate kernel instance. The agent cannot access host resources outside defined boundaries.

```
Host system (Docker Desktop)
  ├── Your containers and images
  │
  ├── Sandbox VM 1
  │   ├── Docker daemon (isolated)
  │   ├── Agent container
  │   └── Other containers (created by agent)
  │
  └── Sandbox VM 2
      ├── Docker daemon (isolated)
      └── Agent container
```

Each sandbox has:
- Its own Docker daemon (isolated from the host daemon)
- Its own storage for VM disk images, Docker layers, and containers
- No shared images or layers between sandboxes

Sandboxes don't appear in `docker ps` — they're VMs, not containers. Use `docker sandbox ls`.

### Network architecture

- **Outbound access**: routed through the host's network via an HTTP/HTTPS filtering proxy at `host.docker.internal:3128`
- **Inter-sandbox isolation**: sandboxes cannot communicate with each other; each VM has its own private network namespace
- **Host access restrictions**: sandboxes are blocked from accessing localhost services on the host

### Filesystem

Bidirectional file copying (not volume mounting) preserves absolute paths:
- Host: `/Users/alice/projects/myapp`
- Sandbox: `/Users/alice/projects/myapp`

Files are copied between host and VM. This approach works across different filesystems. File paths in error messages match between environments.

### Credential handling

**Credentials remain on the host system.** The agent makes API requests without credentials, and the proxy injects them transparently. Supported providers: OpenAI, Anthropic, Google, GitHub.

This is the phantom token pattern (see [015]) implemented at the infrastructure level: the agent never sees real API keys. The filtering proxy strips outbound requests and injects credentials before forwarding upstream.

## Agent support

- **Claude Code**: production-ready
- **Codex, Copilot, Gemini, Docker Agent, Kiro**: in development

Basic usage:

```console
$ docker sandbox run claude ~/my-project
```

Agents can install tools, run containers, and modify their environment inside the sandbox without affecting the host. "YOLO mode by default" — agents work without asking permission within the isolated environment.

## Security properties

- Prevents agents from accessing host files, processes, or network without explicit permission
- Agents can spin up test containers inside the sandbox without host impact
- Private Docker daemon means the agent's Docker operations (pull, run, build) are contained
- Network filtering proxy controls outbound access and injects credentials

## Platform requirements

- macOS or Windows (experimental) for microVM-based sandboxes
- Linux: legacy container-based sandboxes with Docker Desktop 4.57+

## Comparison to alternatives

Docker provides a comparison across: Sandboxes (microVM), container socket mounting, Docker-in-Docker, and host execution — evaluating isolation level, agent Docker access, host impact, and use cases. Sandboxes provide the strongest isolation.
