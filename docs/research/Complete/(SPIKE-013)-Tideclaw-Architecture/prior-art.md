# Tideclaw — Prior Art: Agent Sandboxing Solutions

> Supporting document for [(SPIKE-013) Tideclaw Architecture](./(SPIKE-013)-Tideclaw-Architecture.md).

---

## Isolation Tier Hierarchy

| Tier | Technology | Isolation Strength | Startup Time | Example |
|------|-----------|-------------------|-------------|---------|
| **MicroVMs** | Firecracker, Kata, libkrun | Strongest (dedicated kernel, KVM) | ~125ms | E2B, microsandbox |
| **gVisor** | User-space kernel | Strong (syscall interception) | Fast | Modal, GKE Agent Sandbox |
| **Hardened containers** | Docker + seccomp/AppArmor | Moderate (shared host kernel) | Fastest | Tideclaw, Docker MCP |
| **OS-native** | Landlock + seccomp, bubblewrap | Moderate (process-level) | Zero overhead | Codex CLI, Claude Code |
| **Prompt-based** | System prompt instructions | None | N/A | ClaudeClaw |

NVIDIA's AI Red Team recommends fully virtualized environments (VMs, unikernels, Kata Containers) isolated from the host kernel for production untrusted code execution.

## E2B (e2b.dev)
- **Mechanism**: Firecracker microVMs backed by KVM hardware virtualization. Each sandbox gets its own Linux kernel. Companion "jailer" process provides second layer via cgroups + namespaces. Same technology as AWS Lambda/Fargate.
- **Performance**: Boot <125ms. Memory <5 MiB per VM. Pre-warmed snapshots eliminate cold starts (<200ms full provision).
- **Network**: Global `allowInternetAccess` boolean (default: true). Fine-grained `allowOut`/`denyOut` lists (IP/CIDR). Domain filtering via HTTP Host header (port 80) and TLS SNI (port 443). No UDP/QUIC domain filtering. Firecracker rate limiter constrains bandwidth/IOPS per VM.
- **Credential management**: App-level injection. Isolation guarantee: sandbox escape can't reach other tenants.
- **Deployment**: Managed cloud (default) or BYOC in AWS/GCP/Azure/on-premises.
- **Relevance**: Strongest isolation tier. If Docker containers aren't enough for Tideclaw's threat model, Firecracker is the upgrade path. E2B's template system (Dockerfiles → snapshotted VM images) could inspire Tideclaw's image build process.

## Daytona
- **Mechanism**: Tiered isolation — default Docker (shared kernel), optional Kata Containers (full VM), Sysbox (rootless). **Critical**: security posture depends entirely on backend choice. Default Docker is weakest.
- **Performance**: Sub-90ms sandbox creation (container mode). Faster than E2B because containers only need namespaces + mount.
- **Network**: `networkAllowList` (up to 5 CIDR blocks), `networkBlockAll`. Tier-gated — lower billing tiers have restricted network.
- **Stateful**: Unlike E2B (ephemeral by default), supports snapshot/restore for long-running agent tasks.
- **Relevance**: Workspace model similar to Tideclaw but without security scanning layers. Kata Containers backend worth considering if Tideclaw upgrades past Docker.

## Pipelock — Most Architecturally Similar to Tideclaw
[Pipelock](https://github.com/luckyPipewrench/pipelock) is a single Go binary sitting between AI agents and the outside world. **The closest existing analog to Tideclaw's architecture.**

- **Capability separation**: Agent (has secrets, no network) vs. fetch proxy (has network, no secrets) — directly maps to Tideclaw's `agent-net` vs `mcp-net` split.
- **9-layer scanner pipeline**: Domain blocklist, SSRF protection, DLP patterns (regex for API keys/tokens/secrets), env variable leak detection (raw + base64, values ≥16 chars with entropy > 3.0), path entropy analysis (Shannon), subdomain entropy analysis.
- **MCP server scanning**: Wraps any MCP server as stdio proxy. Scans both directions: client requests for DLP leaks and injection in tool arguments; server responses for prompt injection; `tools/list` responses for poisoned descriptions and rug-pull definition changes.
- **Docker integration**: Generated compose creates two containers — pipelock (fetch proxy with internet) and agent (internal-only network).
- **Actions**: block, strip (redact), warn (log and pass), ask (terminal prompt with timeout).
- **Relevance**: Validates Tideclaw's architecture. Key differences: Pipelock is a single binary (proxy+scanner), Tideclaw separates gateway from proxy. Pipelock does MCP tool description scanning (tool poisoning defense) that Tideclaw doesn't yet. Pipelock lacks taint tracking (ADR-002).

## Docker MCP Gateway (Open Source)
[docker/mcp-gateway](https://github.com/docker/mcp-gateway) — **The closest commercial analog to Tideclaw's gateway.**

- **Architecture**: Sits between agents and MCP servers as middleware. Manages server lifecycles — starts containers on demand, injects credentials, applies security restrictions, forwards requests.
- **Interceptor framework**: Custom scripts/plugins inspect, modify, or block requests in real time:
  - "Before" interceptors: argument/type checks, safety classifiers, session enforcement
  - "After" interceptors: response logging, secret masking, PII scrubbing
- **Policy enforcement**: `--verify-signatures` (image provenance), `--block-secrets` (payload scanning), `--log-calls` (audit).
- **Credential management**: Docker Desktop integration. OAuth flows. Credentials injected by gateway, never passed by agent.
- **Docker Sandboxes**: MicroVM-based isolation for coding agents. Supports Claude Code, Codex CLI, Copilot CLI, Gemini CLI, Kiro. Domain allow/deny lists.
- **Relevance**: Docker's gateway validates the interceptor pattern. Tideclaw's gateway does deeper content scanning (L1/L2/L3 vs Docker's regex `--block-secrets`). Docker's microVM sandboxes for coding agents are a competitive offering. Tideclaw differentiates via taint tracking, shaped denies, and self-hosted operation.

## Claude Code sandbox-runtime
[anthropic-experimental/sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) — Open-source, reusable sandbox for arbitrary processes, agents, and MCP servers.

- **Linux**: bubblewrap + seccomp BPF. Network namespaces (`CLONE_NEWNET` + `CLONE_NEWPID`). Only loopback device. Traffic forced through proxy via Unix domain sockets (bridged by `socat`). Pre-compiled BPF programs for x64 and arm64.
- **macOS**: Seatbelt profiles.
- **Filesystem**: Read/write restricted to CWD. Mandatory deny paths for sensitive locations. ripgrep scans write paths for dangerous files.
- **Relevance**: Could be used inside Tideclaw's agent container to sandbox individual tool executions. Also usable for sandboxing downstream MCP servers on `mcp-net`. Reduces permission prompts by 84%.

## Codex CLI's Sandbox (detailed)
- **Linux**: Landlock + seccomp-BPF (NOT Docker on local). Helper binary `codex-linux-sandbox` applies restrictions before `execvp`. Landlock grants read everywhere, restricts writes to workspace + `/dev/null`. seccomp blocks `connect()`, `accept()`, `bind()` but preserves `recvfrom`. Also strips `LD_PRELOAD`, disables ptrace, zeros core files.
- **macOS (Seatbelt)**: Runtime-generated profiles. `.git` and `.codex` kept read-only. Binary network on/off.
- **Windows**: AppContainer with restricted tokens + job objects.
- **Cloud two-phase model**: Setup phase (network + secrets available for dependency installation) → Agent phase (network disabled by default, secrets removed). This is the cleanest credential isolation pattern in the industry.
- **Gap for Tideclaw**: Codex handles local process isolation well. What it doesn't do: scan tool call/shell command contents for sensitive data, isolate third-party API credentials from the agent process, provide domain-level egress control, or track data flow via taint analysis. These are Tideclaw's additions.

## Kubernetes Agent Sandbox (kubernetes-sigs)
[kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) — Declarative CRD API for sandboxed agent workloads.

- **Backend-agnostic**: gVisor (default) or Kata Containers.
- **CRDs**: `Sandbox`, `SandboxTemplate` (blueprints), `SandboxClaim` (for LangChain, ADK, etc.).
- **Performance**: Pre-warmed pools deliver sub-second latency (90% improvement over cold starts).
- **Relevance**: Kubernetes-native. If Tideclaw targets k8s deployment, these CRDs are the integration point.

## microsandbox (zerocore-ai)
[zerocore-ai/microsandbox](https://github.com/zerocore-ai/microsandbox) — Self-hosted microVMs via libkrun.

- **Isolation**: KVM-based hardware virtualization. Each sandbox gets own kernel and memory.
- **Performance**: Under 200ms boot. OCI-compatible (runs standard container images).
- **Key difference from E2B**: Entirely self-hosted. No managed cloud dependency.
- **Relevance**: If Tideclaw needs stronger isolation than Docker but must stay self-hosted, microsandbox is the upgrade path.
