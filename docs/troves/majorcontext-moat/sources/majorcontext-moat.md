---
source-id: "majorcontext-moat"
title: "Moat - Agent Sandboxing and Credential Injection"
type: web
url: "https://majorcontext.com/moat/"
fetched: 2026-04-07T00:00:00Z
hash: "8b9ea97817039a2abe5f650b42e857949523ad33b245b64424d10db61129f001"
---

# Moat - Agent Sandboxing and Credential Injection

## Let agents break things safely

Moat runs AI agents in isolated containers. Credentials flow through the network, not the environment — so agents can act without seeing secrets.

**Works with Claude, Codex, and Gemini.**  
Credential injection for GitHub, GitLab, AWS, OpenAI, npm, SSH, 1Password, and more.

```
# Install
$ brew tap majorcontext/tap
$ brew install moat

# Grant credentials and run Claude safely
$ moat grant anthropic
$ moat grant github
$ moat claude .
```

## Safety

### Sandboxed Execution

Every agent runs in an isolated container—Docker, Apple containers, or gVisor. No host access.

### Network-Layer Credentials

OAuth tokens and API keys are injected at the proxy layer. Agents never see raw secrets.

### Network Policies

Permissive or strict firewall mode. Whitelist allowed hosts, block everything else.

### Tamper-Proof Audit

Hash-chained audit logs with cryptographic verification. Export proof bundles for compliance.

## Developer Experience

### Declarative Config

One agent.yaml defines runtime, credentials, services, and network policy.

### Service Dependencies

PostgreSQL, MySQL, and Redis sidecars auto-provisioned with injected credentials.

### Snapshots & Recovery

Automatic workspace snapshots on commits, builds, and idle. Point-in-time restore without stopping.

### Parallel Worktrees

Run multiple agents on separate git branches simultaneously. No workspace conflicts.

## Why This Exists

AI coding agents need access to credentials—GitHub tokens for pushing code, API keys for external services, SSH keys for deployment. The standard approach is to pass these as environment variables, but this means the agent can read, log, or exfiltrate them. If the agent's behavior is compromised or simply buggy, your credentials are exposed.

Moat solves this by injecting credentials at the network layer through a TLS-intercepting proxy. The agent's code never sees the tokens; they're added to outgoing HTTP requests transparently. This means you can run untrusted or experimental agent code without risking credential leakage.

## Get Started

- **Introduction** — Learn about Moat's core concepts and architecture
- **Installation** — Platform-specific installation instructions
- **Quick Start** — Guided walkthrough of your first Moat run

Moat is open source and in active development. APIs and configuration formats may change. View [github.com/majorcontext/moat](https://github.com/majorcontext/moat) for the latest updates.
