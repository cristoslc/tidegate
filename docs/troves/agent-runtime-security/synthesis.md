# Synthesis: Agent Runtime Security

Evidence pool `agent-runtime-security` — 14 sources collected 2026-03-15, extended 2026-03-16.

Sources span 7 perspectives: vendor security research [001-003, 006, 010, 013], practitioner/community [008], regulatory/government [007], supply chain audit [004], infrastructure guidance [005, 012], MCP scanning landscape [009, 011], and independent security research [014].

## Key findings

### The "lethal trifecta" is the threat model

Simon Willison [014] provides the canonical definition: the **lethal trifecta** is the combination of (1) **access to private data**, (2) **exposure to untrusted content**, and (3) the **ability to externally communicate**. Any agent combining all three "can let an attacker steal your data." The underlying mechanism is prompt injection — LLMs are unable to reliably distinguish instructions by provenance; everything becomes a flat sequence of tokens.

Willison [014] catalogs 15+ production exfiltration attacks across ChatGPT, Google Bard, Amazon Q, Microsoft Copilot, Slack, GitHub Copilot Chat, xAI's Grok, Anthropic's Claude iOS, and ChatGPT Operator (April 2023 – February 2025). Almost all were fixed by vendors locking down the exfiltration vector — but once users mix and match tools themselves (especially via MCP), "there's nothing those vendors can do to protect you."

Sophos [006] independently names the same pattern and draws the enterprise conclusion: "Anyone who can message the agent is effectively granted the same permissions as the agent itself."

Kaspersky [010] provides the concrete proof: Matvey Kukuy extracted a private key from a running OpenClaw instance by sending a prompt-injected email — the agent read the mail and handed over the key. Microsoft's runtime defense post [013] demonstrates the same pattern in managed environments: crafted SharePoint documents trick agents into reading sensitive files the attacker cannot directly access and emailing them out.

The trifecta is not a theoretical risk. It is actively exploited.

### Guardrails are insufficient — structural enforcement is required

Willison [014] is explicit: "we still don't know how to 100% reliably prevent this from happening." Guardrail products claiming 95% detection rates earn "deep suspicion" because "in web application security 95% is very much a failing grade." He references two promising mitigation directions — the "Design Patterns for Securing LLM Agents against Prompt Injections" paper (key insight: "once an LLM agent has ingested untrusted input, it must be constrained so that it is impossible for that input to trigger any consequential actions") and Google DeepMind's CaMeL — but notes neither helps end users mixing tools today. The only user-side defense is to **avoid the trifecta combination entirely**.

This directly validates Tidegate's architectural thesis: if guardrails can't reliably prevent exfiltration at the application layer, enforcement must be structural — infrastructure-embedded, at the network and VM boundary, making bypass impossible regardless of what the LLM decides to do.

### The security boundary has shifted from application to runtime

All fourteen sources converge on the same structural observation: self-hosted AI agents merge untrusted code execution (skills, extensions) with untrusted instruction processing (prompts, feeds, messages) into a single loop running with durable credentials. Microsoft [001] frames this as "dual supply chain convergence." The new security boundary has three components: **identity** (what tokens the agent holds), **execution** (what tools it can invoke), and **persistence** (how changes survive across runs).

NIST [007] formalizes this as a regulatory question: "What are the unique security threats, risks, or vulnerabilities currently affecting AI agent systems, distinct from those affecting traditional software systems?" The Perplexity response identifies three fundamental challenges: code-data separation collapse, flexible automation without matching security primitives, and existing security mechanisms designed for pre-agent computing.

### Infrastructure-embedded enforcement is the only viable control plane

NVIDIA [002] and Northflank [005] both argue that application-level controls are fundamentally insufficient — once control passes to a subprocess, the application has no visibility. NVIDIA: "OS-level controls, like macOS Seatbelt, work beneath the application layer to cover every process in the sandbox."

Google [012] validates this at cloud scale: "Providing kernel-level isolation for agents that execute code and commands is non-negotiable." Their Agent Sandbox is built on gVisor with Kata Containers support, warm pools for sub-second latency, and is positioned as a new Kubernetes primitive — confirming the industry is converging on VM-grade isolation as baseline infrastructure.

The Reddit thread [008] adds the practitioner dimension: u/AccordingWeight6019 argues "the question is whether the community starts modeling agents around information flow constraints rather than instruction filtering" — independently arriving at Tidegate's data-flow enforcement thesis.

### Three mandatory controls emerge consistently

1. **Network egress restriction** (default-deny outbound) — cited by NVIDIA [002], Northflank [005], Microsoft [001], Sophos [006], Kaspersky [010]. NVIDIA: "Blocking network access to arbitrary sites prevents exfiltration of data or establishing a remote shell." Kaspersky recommends "allowlist only" for open ports and network-level device isolation.

2. **Filesystem write restriction** (workspace-only writes) — NVIDIA [002] mandates blocking writes outside the active workspace at OS level, calling out `~/.zshrc`, `~/.gitconfig`, `~/.curlrc` as high-value targets for persistence and RCE.

3. **Configuration file protection** — NVIDIA [002] mandates that agent configuration files (hooks, MCP configs, `.cursorrules`, `CLAUDE.md`, skills) must be protected from any agent modification, with no user-approval override. "Direct, manual modification by the user is the only acceptable modification mechanism."

### The agent skills supply chain is actively under attack

Snyk [004] provides the broadest data: of 3,984 skills scanned, 36.82% had at least one security flaw, 13.4% had critical issues. 100% of confirmed malicious skills contain malicious code AND 91% simultaneously employ prompt injection — a dual-vector approach that bypasses both AI safety and traditional scanners.

The Hacker News [011] documents the attack ecosystem in detail: 71 malicious skills found by Straiker, Atomic Stealer delivery via SKILL.md files (Trend Micro), agent-to-agent social engineering via Moltbook ("BobVonNeumann"), and comment-based social engineering on ClawHub skill pages. Kaspersky [010] adds: 230+ malicious plugins published in under a week, packaging stealers that exfiltrate macOS Keychain data, crypto wallets, and browser passwords.

The Reddit thread [008] surfaces a chilling meta-observation: flagged skills get removed but reappear under different identities within days. The ecosystem has 6,000+ skills with zero categorization, filtering, or moderation (Kaspersky [010]).

### Real vulnerabilities validate the threat model

The Hacker News [011] catalogs 9 CVEs in OpenClaw (Jan-Feb 2026) covering RCE, command injection, SSRF, auth bypass, and path traversal. The ClawJacked vulnerability is particularly instructive: any website can open a cross-origin WebSocket to localhost, brute-force the gateway password (no rate-limiting), and register as a trusted device without user prompt — full agent takeover from a browser tab.

Kaspersky [010] reports 512 total vulnerabilities found in a single audit, 8 critical. Nearly 1,000 publicly accessible instances running without authentication (Shodan scan). Default localhost trust + reverse proxy misconfiguration = automatic full-access handover.

These are not theoretical — they are exploited in the wild.

### MCP amplifies the trifecta by design

Willison [014] identifies MCP as a structural amplifier: it "encourages users to mix and match tools from different sources that can do different things." A single MCP server can combine all three legs of the trifecta — the GitHub MCP exploit demonstrated exactly this, where one tool could read public issues (untrusted content), access private repos (private data), and create pull requests (external communication/exfiltration).

The MCP landscape [009] has split into three tiers: static scanners (mcp-scan, MCPScan.ai), runtime proxies (Pipelock, Invariant Guardrails), and enterprise gateways (Docker MCP Gateway, MintMCP, Kong, Operant AI). Key capabilities:

- **Pipelock:** 11-layer URL scanning, bidirectional MCP argument/response scanning, rug-pull detection via description hashing
- **Docker MCP Gateway:** `--block-secrets` for payload scanning, container isolation for MCP servers
- **mcp-scan:** Tool poisoning detection, 15+ risk patterns, tool pinning via hashing

**What they all miss:**
- Semantic poisoning (natural language manipulation bypasses pattern matching)
- Compositional attacks (benign tools combining to produce malicious behavior)
- Parameter-name attacks (exfiltration encoded in JSON key names, not values)
- **None enforce at the network layer.** All operate at the application layer. None combine payload scanning with network-level enforcement that makes bypass structurally impossible.

This last gap is precisely what Tidegate addresses.

### The regulatory frame validates the thesis

NIST [007] asked the right questions: what threats are unique to agents, how do they vary by deployment context, and what technical controls exist? The responses converge on a defense-in-depth model where the **deterministic last line of defense** is "allowlists and blocklists for tool invocations, rate limits on sensitive operations, regex or schema validation on tool arguments before execution" — conventional, verifiable code that blocks prohibited actions regardless of LLM output.

This framing maps directly to Tidegate's architecture: the MCP scanning gateway (SPEC-007) is the regex/schema validation layer, the gvproxy egress allowlist (SPEC-005) is the network-level allowlist, and the VM boundary (SPEC-004/006) is what makes the deterministic controls inescapable.

## Points of agreement

All sources agree on:

- **Assume-breach posture is required.** Self-hosted agents will eventually process malicious input. Controls must prioritize containment and recoverability over prevention.
- **Dedicated credentials, not inherited ones.** Agents should use purpose-built, least-privilege, short-lived tokens — never the user's full credential set.
- **VM/microVM isolation is the gold standard.** Shared-kernel solutions are insufficient. Google [012] and Northflank [005] both default to hardware-enforced isolation. NVIDIA [002] recommends full virtualization.
- **Disposable environments.** Microsoft [001]: "Treat the environment as disposable." NVIDIA [002]: ephemeral sandboxes. Google [012]: warm pools with checkpoint/restore.
- **The skills ecosystem mirrors early npm/PyPI** — but with higher stakes because skills inherit agent permissions (Snyk [004], Reddit [008], Kaspersky [010]).
- **Guardrails are probabilistic, not deterministic.** Willison [014] and Sophos [006] agree that application-layer defenses cannot guarantee prevention — only structural enforcement (network, VM) provides a deterministic boundary.

## Points of disagreement

- **Prevention vs. pragmatic risk management.** Microsoft [001] and Cisco [003] lean toward "don't run this." Sophos [006] and Northflank [005] take a pragmatic stance: agentic AI is coming, so manage it. Willison [014] occupies a middle ground: the only user-side defense is avoidance of the trifecta combination, while acknowledging that application developers can use design patterns to mitigate (but not eliminate) the risk. The Reddit thread [008] surfaces real practitioners who have already accepted the risk and are asking how to sandbox effectively.

- **Where enforcement belongs.** NVIDIA [002] advocates OS-level (Seatbelt, AppContainer). Northflank [005] and Google [012] push infrastructure-level (microVMs, Kata, K8s). Microsoft [013] implements it as a cloud webhook (Defender). Willison [014] frames it as an unsolved problem at any layer. These reflect deployment contexts (workstation vs. server vs. cloud) more than philosophical disagreement.

- **Approval caching.** NVIDIA [002] explicitly calls it dangerous: "Allow-once / run-many is not an adequate control." No other source addresses this directly, but the ClawJacked vulnerability [011] demonstrates the consequence: localhost trust (a form of cached approval) enabled full agent takeover.

## Gaps remaining

- **macOS-specific enforcement is underexplored.** NVIDIA [002] mentions Seatbelt but no source details Apple Silicon VM isolation (Tidegate's SPEC-004/SPEC-006 territory).

- **Multi-agent coordination security is barely touched.** The BobVonNeumann agent-to-agent attack [011] hints at this, but no source addresses trust boundaries between cooperating agents systematically.

- **Cost and performance trade-offs of personal-device VM isolation.** Google [012] provides cloud numbers (sub-second warm pools) but no source addresses the developer experience cost of running agents inside VMs on a laptop.

- **No source proposes per-destination egress enforcement with scanning.** All say "restrict egress" but stop at "allowlist known destinations." None propose the gvproxy-level, infrastructure-embedded, per-destination allowlisting that Tidegate implements.
