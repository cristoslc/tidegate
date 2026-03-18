---
source-id: 017-docker-agent
type: web
url: https://docs.docker.com/ai/docker-agent/
fetched: 2026-03-17T00:00:00Z
title: "Docker Agent"
author: Docker Inc.
tags: [docker, agent-framework, multi-agent, mcp, oci-distribution, tool-execution]
provenance: "Official Docker documentation for Docker Agent, an open-source framework for building multi-agent AI systems. Integrates with Docker MCP Gateway for tool execution."
---

# Docker Agent

Docker Agent is an open-source framework for building teams of specialized AI agents that collaborate through hierarchical delegation. Rather than relying on a single generalist model, it coordinates multiple focused agents — each with specific roles, models, and tool access.

## Architecture

### Hierarchical delegation

Users interact with a root agent, which delegates tasks to sub-agents defined in configuration. Each agent maintains independent context and can have its own sub-agents for deeper hierarchies.

Key properties:
- **Agent independence**: each agent operates with its own model, parameters, and isolated context
- **Delegation system**: root agent delegates to sub-agents based on task specialization
- **Hierarchical structure**: sub-agents can spawn their own sub-agents for complex workflows

### Configuration

Agents are defined in YAML files:

```yaml
model: provider/model-name
description: Role summary
instruction: Detailed agent directives
sub_agents:
  - path: ./sub-agent-dir
toolsets:
  - name: tool-name
```

Essential fields: `model`, `description`, `instruction`, `sub_agents`, `toolsets`.

## Tool integration and MCP

Docker Agent connects to external tools via MCP (Model Context Protocol) servers through the **Docker MCP Gateway**. Built-in tools include:
- Filesystem access
- Shell execution
- Todo lists
- Memory management

The Docker MCP Gateway provides the bridge between agents and MCP tool servers, enabling containerized tool execution with Docker's security model applied.

## Distribution

Agent configurations are packaged as OCI artifacts — push and pull them like container images using Docker Hub or compatible registries. This enables team sharing and versioning of agent configurations.

## Installation

Available through:
- Docker Desktop (4.63+)
- Homebrew
- Winget
- Pre-built binaries (placed in `~/.docker/cli-plugins`)

## Relevance to agent security

Docker Agent's multi-agent architecture means each sub-agent can have different tool access and permissions. Combined with Docker Sandboxes [016], this enables per-agent isolation — each agent runs in its own microVM with only the tools and credentials it needs. The Docker MCP Gateway mediates tool access, providing a scanning/filtering point analogous to Tidegate's tg-mcp gateway (SPEC-007).
