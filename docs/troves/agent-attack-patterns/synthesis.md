# Synthesis: Agent Attack Patterns

Distillation of 16 sources covering attack techniques and CVEs against LLM-powered agents, spanning academic research, industry telemetry, CVE analysis, practitioner guides, and supply chain incident reports. Sources range from November 2025 to March 2026.

## Key Findings

### 1. Prompt Injection Remains the Dominant Attack Vector — But Has Evolved

Every source identifies prompt injection as the primary threat. The 2025-2026 landscape shows three distinct generations:

- **Direct injection** (jailbreaking): Stylistic variation alone defeats safety training. Adversarial poetry achieves 62% ASR across 25 frontier models, with some exceeding 90% — a universal single-turn bypass requiring no technical sophistication (arxiv-adversarial-poetry-jailbreak). The arxiv-coding-assistant-injection meta-analysis confirms >85% success rates against state-of-the-art defenses when adaptive strategies are used.

- **Indirect injection (IDPI)**: Now observed in the wild at scale. Unit 42 documented 22 distinct payload engineering techniques used in real attacks, including visual concealment (zero-sizing, CSS suppression), obfuscation (XML/SVG encapsulation, Base64), and semantic tricks (multilingual, JSON injection) (unit42-web-idpi-wild). Lakera's Q4 2025 telemetry confirms indirect attacks require fewer attempts than direct injection (lakera-q4-2025-agent-attacks). EchoLeak (CVE-2025-32711, CVSS 9.3) demonstrated zero-click exfiltration from M365 Copilot by bypassing XPIA classifiers and CSP (lares-owasp-agentic-wild).

- **Protocol-layer injection**: Attacks now target the infrastructure connecting agents to tools. Tool poisoning via metadata/descriptions, orchestration injection through tool name collision, and rug-pull redefinitions after approval are all documented in production (elastic-mcp-tools-attack-defense, heyuan-mcp-30-cves).

### 2. The Attack Surface Is the Agent Architecture Itself

The unified threat model from arxiv-prompt-to-protocol-exploits catalogs 30+ techniques across four domains: Input Manipulation, Model Compromise, System & Privacy Attacks, and Protocol Vulnerabilities. The key insight shared across sources:

- **Tool call hijacking** propagates a single injection to every downstream tool in the chain (repello-agentic-threats-2026)
- **Memory poisoning** persists across sessions without needing re-injection (repello-agentic-threats-2026)
- **Rug-pull redefinitions** change tool behavior after initial approval (elastic-mcp-tools-attack-defense)
- **Implicit tool calls** allow one tool to silently influence another without explicit invocation (elastic-mcp-tools-attack-defense)

The arxiv-coding-assistant-injection three-dimensional taxonomy (delivery vectors x attack modalities x propagation behaviors) captures this: attacks can be direct/indirect/protocol-level, text/semantic/multimodal, and single-shot/persistent/viral.

### 3. MCP Is a High-Value Attack Surface with Systemic Vulnerabilities

The MCP CVE catalog (heyuan-mcp-30-cves) documents 30 CVEs in 60 days (Jan-Feb 2026), with breakdown:
- 43% exec/shell injection
- 20% tooling infrastructure
- 13% auth bypass
- 10% path traversal

Critical CVEs include:
- **CVE-2025-49596** (CVSS 9.4): MCP Inspector accepts unauthenticated connections from any IP
- **CVE-2025-6514** (CVSS 10.0): mcp-remote command injection affecting 437K downloads
- **CVE-2025-54136**: Cursor MCPoison tool poisoning
- **CVE-2025-68143/68144/68145**: Anthropic Git MCP server — path traversal, argument injection, repo scoping bypass -> RCE via prompt injection alone (cyberdesserts-agent-security-2026)

Of 2,614 scanned implementations, 38-41% lack authentication and 82% have path-traversal-prone file operations (heyuan-mcp-30-cves). 8,000+ MCP servers are on the public internet with 492 having zero authentication (cyberdesserts-agent-security-2026).

### 4. IDE and Coding Assistant CVEs Reveal Configuration as Attack Surface

The IDEsaster research (tigran-idesaster-vulnerabilities) disclosed 24+ CVEs across VS Code, JetBrains, Zed, Cursor, and Windsurf. Three dominant attack patterns:

- **Config file manipulation**: Prompt injection edits IDE settings to enable auto-approve modes or set malicious executable paths. Copilot "YOLO mode" (CVE-2025-53773) and Cursor (CVE-2025-54130) both exploitable via `.vscode/settings.json` edits (lares-owasp-agentic-wild, tigran-idesaster-vulnerabilities).

- **AGENTS.MD / workspace hijacking**: VS Code Chat auto-includes `AGENTS.MD` in every request (CVE-2025-64660, CVE-2025-61590). Attackers embed instructions in workspace files that the agent treats as authoritative (tigran-idesaster-vulnerabilities).

- **JSON schema exfiltration**: Agents write JSON files with remote `$schema` URLs, causing the IDE to leak file contents via GET request to attacker-controlled domains (tigran-idesaster-vulnerabilities).

Claude Code specifically: CVE-2025-59536 (CVSS 8.7) enables RCE via malicious hooks in `.claude/settings.json` that execute before the trust dialog. CVE-2026-21852 redirects API requests (including plaintext API keys) to attacker endpoints via `ANTHROPIC_BASE_URL` override. A third vulnerability bypasses user consent entirely for new directory hooks (checkpoint-claude-code-cves).

### 5. Supply Chain Attacks Are Multi-Stage and Target the AI Toolchain Specifically

The March 2026 Trivy/LiteLLM incident chain demonstrates a new pattern: **supply chain attacks propagating through the AI toolchain itself**, where compromising one security tool creates a blast radius across dependent AI infrastructure.

**The Trivy attack** (aquasec-trivy-supply-chain): Attackers exploited a misconfiguration in Trivy's GitHub Actions to extract a privileged access token. After an initial disclosure and incomplete credential rotation, the attacker retained residual access and force-pushed 76 of 77 version tags in `aquasecurity/trivy-action` to malicious commits — a technique that weaponizes the common practice of pinning to mutable version tags instead of commit SHAs. The malicious payload executed before legitimate scanning logic, exfiltrating credentials silently while CI/CD appeared to pass normally. Novel aspects include ICP blockchain-hosted C2 infrastructure (resistant to standard domain takedowns) and attacker reestablishing access after initial containment.

**The LiteLLM attack** (litellm-pypi-supply-chain): A downstream consequence of the Trivy compromise. Stolen credentials were used to upload malicious litellm v1.82.7 and v1.82.8 to PyPI, containing credential stealers in `proxy_server.py` and `litellm_init.pth`. The payload harvested environment variables, SSH keys, cloud credentials, K8s tokens, and database passwords, exfiltrating to a typosquatted domain (`models.litellm[.]cloud`). The attack window was narrow (~5.5 hours on March 24, 2026) but the blast radius is amplified by transitive dependencies — AI agent frameworks, MCP servers, and LLM orchestration tools that depend on litellm as an unpinned dependency.

Combined with earlier findings:
- **Malicious MCP servers**: First in-the-wild malicious MCP server discovered September 2025 — an npm package impersonating Postmark's email service, silently BCC-ing all agent-sent emails to attacker (bleepingcomputer-owasp-real-attacks).

- **Skill/plugin marketplaces**: 1,184 malicious skills found on ClawHub (~1 in 5 packages). 824+ confirmed malicious by Bitdefender. Organized actors like `smp_170` mass-produce malicious skills (cyberdesserts-agent-security-2026).

- **Slopsquatting**: PhantomRaven campaign created 126 npm packages exploiting hallucinated dependency names — when an LLM suggests a package that doesn't exist, attackers register it (bleepingcomputer-owasp-real-attacks).

- **Framework-level vulnerabilities**: LangGrinch (CVE-2025-68664, CVSS 9.3) is a serialization injection in langchain-core itself — not a plugin. Prompt injection causes the LLM to produce structured output with the reserved `lc` key, which the deserializer treats as a legitimate LangChain object, extracting secrets. 847M total downloads affected (cyata-langgrinch-langchain).

### 6. Defenses Are Losing the Arms Race

Multiple sources converge on defense inadequacy:

- All 6 evaluated detection systems in the coding assistant meta-analysis were bypassed at 78-93% rates with adaptive attacks (arxiv-coding-assistant-injection)
- Safety training is fundamentally limited — stylistic variation (poetry) defeats it universally (arxiv-adversarial-poetry-jailbreak)
- Point-in-time assessments cannot keep pace with dynamic attack surfaces (repello-agentic-threats-2026)
- Pattern-matching defenses fail against semantic-level attacks (unit42-web-idpi-wild)
- Traditional SAST tools cannot identify issues in LLM-to-tool communication flows, conversation state management, or agent-specific trust boundaries (cyberdesserts-agent-security-2026)
- HITL defense improves OpenClaw's defense rate from baseline to 19-92%, but cannot achieve reliable coverage alone (referenced in lares-owasp-agentic-wild)
- Even security scanning tools in CI/CD can become the attack vector — the Trivy incident shows that running a vulnerability scanner introduced the vulnerability (aquasec-trivy-supply-chain)

### 7. Real-World Exploitation Is Already Happening

This is no longer theoretical:

- 90+ organizations compromised via AI prompt injection in 2025 (repello-agentic-threats-2026)
- First real-world IDPI bypass of AI ad review system documented December 2025 (unit42-web-idpi-wild)
- WhatsApp MCP tool poisoning exfiltrated entire chat histories (heyuan-mcp-30-cves)
- GitHub MCP prompt injection via public Issues exfiltrated private code (heyuan-mcp-30-cves)
- Amazon Q poisoned via malicious PR with `--trust-all-tools --no-interactive` flags, affecting 1M+ developers (bleepingcomputer-owasp-real-attacks)
- Claude Desktop extensions (Chrome, iMessage, Apple Notes) had CVSS 8.9 RCE via unsanitized AppleScript command injection — indirect prompt injection kill chain from web search to code execution (bleepingcomputer-owasp-real-attacks)
- Lakera Q4 telemetry shows structured attacker reconnaissance becoming a standard tactic (lakera-q4-2025-agent-attacks)
- Trivy supply chain attack compromised CI/CD runners across unknown number of organizations, with attacker re-establishing access after containment — an ongoing campaign, not a contained incident (aquasec-trivy-supply-chain)
- LiteLLM PyPI compromise exposed credentials from any environment that ran `pip install litellm` without version pinning during a 5.5-hour window, with transitive dependency exposure amplifying reach (litellm-pypi-supply-chain)

## Points of Agreement

All sources agree on:

1. **The lethal trifecta is real**: Private data + untrusted content + external communication = exploitable system. Most deployed agents have all three.
2. **Input filtering is insufficient**: Attacks operate at semantic, stylistic, and protocol levels that pattern matching cannot catch.
3. **Agent permissions are the blast radius**: A compromised agent inherits all its permissions at machine speed.
4. **Defense must be architectural**: Runtime monitoring, sandboxing, least privilege, and human-in-the-loop gates — not just input validation.
5. **The attack surface grows with every tool**: Each MCP server, each skill, each data source widens what an attacker can reach.
6. **Configuration files are now attack vectors**: Repository-defined configs (.claude/settings.json, .vscode/settings.json, AGENTS.MD, .mcp.json) execute with developer privileges and can be poisoned through version control.
7. **Mutable references are a supply chain weakness**: Version tags, unpinned dependencies, and floating references enable silent substitution attacks across the AI toolchain (aquasec-trivy-supply-chain, litellm-pypi-supply-chain).

## Points of Disagreement

- **Detectability**: Unit 42 proposes that intent analysis and behavioral correlation can detect IDPI in the wild, while the academic sources (arxiv-coding-assistant-injection) show 78-93% bypass rates against detection, suggesting a more pessimistic outlook.
- **Defense layer priority**: Elastic emphasizes client-side sandboxing and tool inspection; Repello emphasizes continuous automated red teaming at the inference layer; the academic papers favor cryptographic identity and capability scoping; Check Point's analysis suggests the trust dialog itself is the critical control point. These are complementary but reflect different priorities.
- **Severity framing**: Industry sources (Repello, Lakera) frame this as an active crisis requiring immediate action. Academic papers frame it as a systematic research challenge with fundamental limitations. Practitioner guides (cyberdesserts) bridge both, offering operational playbooks.
- **Human-in-the-loop viability**: The OpenClaw HITL study shows defense rates of 19-92%, while real-world data (Amazon Q, Copilot YOLO) shows users routinely disable or bypass approval workflows. The human gate is only effective if it's actually used.

## Gaps

1. **Multi-agent attack chains**: Most sources focus on single-agent exploitation. The arxiv-prompt-to-protocol-exploits paper touches on agent-to-agent protocol attacks, but real-world examples of chained multi-agent exploitation are scarce.
2. **Defense effectiveness in production**: Lab results show defenses failing, but there's limited data on what works in real deployments at scale.
3. **Supply chain depth**: The MCP CVE catalog covers first-party servers, but the transitive dependency attack surface (MCP servers depending on other MCP servers) is unexplored. The LiteLLM incident demonstrates how transitive unpinned dependencies amplify blast radius — AI agent frameworks pulling in litellm as a dependency were unknowingly exposed — but systematic study of this propagation pattern is absent.
4. **Egress enforcement as defense**: None of the 16 sources evaluate network-level egress control (e.g., allowlist-based proxy) as a mitigation for data exfiltration — a gap directly relevant to Tidegate's architecture. Every exfiltration CVE documented assumes the agent has unrestricted outbound network access. The Trivy exfiltration to `scan.aquasecurtiy[.]org`, ICP blockchain C2, and LiteLLM exfiltration to `models.litellm[.]cloud` would all be blocked by allowlist-based egress enforcement. Cross-referencing the trove against Tidegate's enforcement model initially appeared to reveal a blind spot (PID 1 laundering data through argv to clean children on allowlisted domains), but this is already resolved by the privilege separation model from SPIKE-014: the orchestrator has network access but no workspace access, subagents have workspace access but no network access, and an interceptor scans all IPC between them.
5. **Cost-benefit for attackers**: Limited data on attacker economics — how much effort per successful exploitation, and what makes agents more or less attractive targets versus traditional systems.
6. **CI/CD pipeline as attack vector**: The Trivy/LiteLLM chain demonstrates that CI/CD security tooling itself is a high-value target, and that incomplete credential rotation after an incident creates persistent access. The PromptPwnd research (tigran-idesaster-vulnerabilities) shows GitHub Actions patterns vulnerable to injection, but systematic study of agent exploitation via CI/CD is still emerging.
7. **Credential rotation and revocation**: Multiple CVEs involve stolen API keys (Claude Code, MCP servers), and the Trivy incident shows incomplete rotation enabling re-compromise. No source addresses how quickly stolen credentials are used or whether rotation policies mitigate damage in practice. The Trivy case demonstrates that partial rotation is worse than no rotation — it provides false confidence while the attacker retains access.
8. **Immutable release infrastructure**: The Trivy attack exploited mutable Git tags — a practice GitHub's immutable releases feature was designed to prevent (v0.35.0 was the only unaffected tag). Adoption of immutable release practices, commit-SHA pinning, and provenance attestation across the AI toolchain is not studied.

## CVE Index by Runtime

| Runtime | CVEs | Highest CVSS |
|---------|------|-------------|
| **Claude Code** | CVE-2025-59536, CVE-2026-21852, + consent bypass | 8.7 |
| **GitHub Copilot** | CVE-2025-53773, CVE-2025-64660 | 7.8 |
| **Cursor** | CVE-2025-49150, CVE-2025-54130, CVE-2025-54135, CVE-2025-54136 | — |
| **OpenClaw** | CVE-2026-25253 | 8.8 |
| **MCP Inspector** | CVE-2025-49596 | 9.4 |
| **mcp-remote** | CVE-2025-6514 | 10.0 |
| **Anthropic Git MCP** | CVE-2025-68143, CVE-2025-68144, CVE-2025-68145 | — |
| **LangChain** | CVE-2025-68664, CVE-2025-68665 | 9.3 |
| **Langflow** | CVE-2025-34291 | — |
| **VS Code** | CVE-2025-55319, CVE-2025-64660, CVE-2025-61590 | — |
| **M365 Copilot** | CVE-2025-32711 (EchoLeak) | 9.3 |
| **Roo Code** | CVE-2025-53097, CVE-2025-53536, CVE-2025-58372 | — |
| **OpenAI Codex CLI** | CVE-2025-61260 | — |
| **Zed.dev** | CVE-2025-55012 | — |
| **Trivy** | GHSA-cxm3-wv7p-598c | — |

## Supply Chain Incident Index

| Incident | Vector | Blast Radius | Date |
|----------|--------|-------------|------|
| Postmark MCP npm impersonation | Malicious MCP server package | Agent email exfiltration | Sep 2025 |
| ClawHub malicious skills | Skill marketplace poisoning | 1,184 malicious skills (~1 in 5) | 2025-2026 |
| PhantomRaven slopsquatting | Hallucinated dependency registration | 126 npm packages | 2025-2026 |
| LangGrinch (CVE-2025-68664) | Framework serialization injection | 847M downloads | 2025 |
| Trivy CI/CD compromise | GitHub Actions token theft -> tag poisoning | Unknown CI/CD runners, downstream LiteLLM | Mar 19, 2026 |
| LiteLLM PyPI poisoning | Stolen credentials -> malicious PyPI upload | Users installing litellm during 5.5hr window + transitive deps | Mar 24, 2026 |
