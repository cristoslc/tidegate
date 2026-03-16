---
source-id: "012"
title: "Introducing Agent Sandbox: Strong guardrails for agentic AI on Kubernetes and GKE"
type: web
url: "https://cloud.google.com/blog/products/containers-kubernetes/agentic-ai-on-kubernetes-and-gke"
fetched: 2026-03-15T00:00:00Z
hash: "sha256:pending"
---

# Introducing Agent Sandbox: Strong guardrails for agentic AI on Kubernetes and GKE

**Published:** 2025-11-11 (KubeCon NA 2025)
**Author:** Brandon Royal, Senior Product Manager (Google Cloud)
**Source:** Google Cloud Blog

## What Agent Sandbox is

A new Kubernetes primitive purpose-built for agentic AI code execution and computer-use scenarios. Developed as a CNCF project within the Kubernetes community (k8s-sigs/agent-sandbox).

**Core rationale:** "Providing kernel-level isolation for agents that execute code and commands is non-negotiable."

**Architecture:**
- Foundationally built on **gVisor** with additional **Kata Containers** support for runtime isolation
- Provides a secure boundary to reduce risk of data loss, exfiltration, or damage to production systems
- Designed to orchestrate thousands of sandboxes as ephemeral environments, rapidly creating and deleting them

## Key features

### Warm pools for sub-second latency

Administrators can configure pre-warmed pools of sandboxes. Delivers **sub-second latency** for fully isolated agent workloads -- up to **90% improvement** over cold starts.

### Pod Snapshots (GKE-exclusive)

Full checkpoint and restore of running pods. Cuts sandbox startup from minutes to seconds. Supports both CPU and GPU workloads. Idle sandboxes can be snapshotted and suspended, saving compute with minimal disruption.

### Python SDK for AI engineers

```python
from agentic_sandbox import Sandbox

with Sandbox(template_name="python3-template", namespace="ai-agents") as sandbox:
    result = sandbox.run("print('Hello from inside the sandbox!')")
```

AI engineers manage sandbox lifecycles without Kubernetes YAML expertise.

## Why Kubernetes

"With its maturity, security, and scalability, we believe Kubernetes provides the most suitable foundation for running AI agents."

However: "it still needs to evolve to meet the needs of agent code execution and computer use scenarios. Agent Sandbox is a powerful first step in that direction."

## Relevance to Tidegate

Agent Sandbox validates the architectural pattern of VM-grade isolation for agent workloads at the infrastructure level. Key differences from Tidegate's approach:

- **Server-side, not personal-device:** Designed for cloud Kubernetes clusters, not local macOS/Linux workstations
- **Isolation without egress enforcement:** Mentions "limited network access" but no equivalent of gvproxy-level per-destination egress allowlisting
- **No MCP scanning:** Isolation primitive only -- does not inspect what crosses the boundary
- **Scale-oriented:** Designed for thousands of concurrent sandboxes, not single-user enforcement

Confirms that the industry is converging on "microVM/gVisor isolation is non-negotiable for agent workloads" -- the same conclusion Tidegate reached via SPIKE-015.
