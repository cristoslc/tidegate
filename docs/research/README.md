# Research

Spikes and exploratory investigations for Tidegate. Organized by lifecycle:

- **`planning/`** — Questions identified but not yet investigated
- **`active/`** — Ongoing investigation
- **`completed/`** — Resolved research that informed implementation decisions
- **`superseded/`** — Research replaced by newer approaches (kept for context)

Each research item tracks lifecycle transitions with the commit where each stage change happened. This gives you the project state at the time of each transition — `git show <commit>` to see what existed, what didn't, what assumptions were in play.

Architecture Decision Records live in `../adr/`, not here. A spike may produce an ADR as its output.

## Convention

Each research item has a lifecycle table at the top:

```markdown
## Lifecycle

| Stage | Commit | Date | Notes |
|---|---|---|---|
| planning | `abc1234` | 2026-02-20 | Question identified during X |
| active | `def5678` | 2026-02-21 | Started investigation |
| completed | `ghi9012` | 2026-02-23 | Findings in findings.md; informed ADR-002 |
```

## Active

### `claudeclaw-vs-nanoclaw/` — ClaudeClaw vs NanoClaw as Agent-Container Runtime

Evaluates [ClaudeClaw](https://github.com/moazbuilds/claudeclaw) as an alternative to NanoClaw for Tidegate's agent runtime. ClaudeClaw is a Claude Code plugin (~2.5K LOC) that runs agents as CLI subprocesses on the host with no container isolation. Finding: no process boundary, no container, prompt-based security only — cannot be wrapped at tool-call level. Same category as OpenClaw (network-level wrapping only). Reinforces ADR-003.

| Stage | Commit | Date | Notes |
|---|---|---|---|
| active | — | 2026-02-25 | Source pulled, comparison written |

## Planning

All items below identified at `138d920` (2026-02-23) from an adversarial threat model review, except protocol-abuse-resistance which predates the review.

### `shaped-deny-oracle.md` — Shaped Deny as Adversarial Oracle

Shaped denies return structured explanations. A prompt-injected agent receives the feedback and iterates toward evasion. Missing adversary profile: adaptive attacker using denial feedback.

### `workspace-volume-toctou.md` — Workspace Volume TOCTOU

tg-scanner scans a file, approves the command, file changes before the command reads it. Larger window than the `/proc/mem` TOCTOU already listed as residual risk.

### `l1-fail-open-behavior.md` — L1 Fail-Open Behavior

tg-scanner crash → `ENOSYS` → unrestricted `execve`. A "hard boundary" that fails open on component crash isn't a hard boundary.

### `luhn-false-positive-rate.md` — Luhn False Positive Rate

"Zero false positives by design" is stronger than the math. ~10% of random 16-digit numbers pass Luhn. Need empirical testing with prefix + length constraints.

### `agent-memory-exfiltration.md` — Agent Memory as Exfiltration Vector

Memory poisoning creates durable cross-session exfiltration. Distinct from one-shot prompt injection. Compounds with the shaped-deny oracle over multiple sessions.

### `protocol-abuse-resistance.md` — MCP Protocol Abuse Resistance

How should the gateway handle malformed, oversized, or adversarial MCP messages? Planning since `db146de` (2026-02-21).

## Completed

### `data-flow-taint-model.md` — Data Flow Taint Model → [ADR-002](../adr/proposed/002-taint-and-verify-data-flow-model.md)

Enumerated all acquisition channels (8), exfiltration channels (8), and mapped which layer covers which input→output pair. Key finding: each layer is PRIMARY for different data flows — L1 inspects the source before transformation, L2/L3 scan at protocol boundaries. Semantic propagation through the LLM defeats all layers (fundamental limit). Produced the **taint-and-verify** rule: tainted data may leave if the output is inspectable and passes scanning; opaque output from tainted processes is blocked.

| Stage | Commit | Date | Notes |
|---|---|---|---|
| planning | `138d920` | 2026-02-23 | Input/output channels first enumerated during L1 spike |
| active | — | 2026-02-23 | Promoted from L1 spike; recognized as foundational |
| completed | — | 2026-02-23 | Formalized as ADR-002 |

### `l1-interpreter-coverage-gap.md` — L1 Coverage Gap (In-Process Interpreter Execution) → informed [ADR-002](../adr/proposed/002-taint-and-verify-data-flow-model.md)

Adversarial review claimed seccomp-notify misses in-process encoding. Investigation confirmed seccomp-notify IS the correct enforcement mechanism — tg-scanner needs userspace capabilities (file I/O, pattern matching) that eBPF can't provide. eBPF serves as lightweight observation (not enforcement). Static analysis of scripts was later dropped (ADR-001 superseded by ADR-002) in favor of runtime taint tracking via eBPF `openat` observation. Findings absorbed into ADR-002's journal-based taint architecture.

| Stage | Commit | Date | Notes |
|---|---|---|---|
| planning | `138d920` | 2026-02-23 | Identified by adversarial threat model review |
| active | `138d920` | 2026-02-23 | Execution model audit + Falco/eBPF research |
| completed | — | 2026-02-23 | ADR-001 validated; findings into ADR-002 |

### `agent-selection/` — Agent Runtime Selection → [ADR-003](../adr/proposed/003-agent-runtime-selection.md)

Compared NanoClaw and OpenClaw as agent runtimes. NanoClaw's container isolation provides the process boundary Tidegate needs; OpenClaw's monolithic Gateway has no boundary to wrap. Design spike produced pipeline architecture (tg-pipeline, filesystem job queue, detached containers, full filesystem IPC) and security policies.

| Stage | Commit | Date | Notes |
|---|---|---|---|
| active | — | 2026-02-24 | NanoClaw + OpenClaw source pulled, analyzed |
| completed | — | 2026-02-24 | Produced ADR-003 + design spike |

### `leak-detection/` — Leak Detection Tool Selection

Evaluated 25+ tools. Selected 3-layer architecture: L1 key-name heuristics, L2 checksum-validated patterns (Luhn, mod-97), L3 format+context validation. Dependency: `python-stdnum`. Not Presidio (800MB+), not NER (FP on code).

| Stage | Commit | Date | Notes |
|---|---|---|---|
| completed | `db146de` | 2026-02-21 | Shipped with initial commit; research predates repo |

## Superseded

### `shell-wrapper/` — Shell Wrapper for Command Interception

Superseded by seccomp-notify ([ADR-001](../adr/superseded/001-seccomp-notify-l1-interception.md)). Shell wrappers are bypassable via direct `execve()` from scripting runtimes.

| Stage | Commit | Date | Notes |
|---|---|---|---|
| completed | `138d920` | 2026-02-22 | Research completed |
| superseded | `138d920` | 2026-02-22 | ADR-001 adopted seccomp-notify instead |
