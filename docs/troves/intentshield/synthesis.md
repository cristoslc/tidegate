# Synthesis: IntentShield

Evidence pool `intentshield` — 1 source (full repository) collected 2026-03-17.

## What it is

IntentShield is a pre-execution intent verification library for AI agents. Rather than filtering what an LLM *says*, it audits what the LLM is about to *do* — the actual shell command, file write, URL, or API call proposed as a tool invocation. Pure Python stdlib, zero dependencies, v1.1.1, BSL-1.1 license.

Built and battle-tested inside KAIROS, an autonomous AI agent running 24/7 in production (per the author).

## Key findings

### Application-layer guardrails with deterministic enforcement

IntentShield represents the "deterministic guardrail" approach: every safety decision is regex and string matching — no ML model in the safety path. This makes it fast, predictable, and auditable. The three-layer architecture (CoreSafety rules, Conscience ethics, ActionParser parsing) processes every proposed action before execution.

The `FrozenNamespace` metaclass makes safety constants immutable in memory at the Python level — `__setattr__` and `__delattr__` raise `TypeError`. SHA-256 hash sealing detects source file tampering, with `os._exit(1)` on mismatch (unkillable, unlike `sys.exit`). These are real engineering choices that resist casual bypass.

### What it covers well

- **Technical action blocking**: shell execution, file deletion, restricted domains, credential-bearing URLs, localhost/file:// access, code injection patterns (XSS, SQL, reverse shells, fork bombs, eval/import smuggling)
- **Ethical/behavioral blocking**: deception verbs (22+ patterns), harm keywords (24+ patterns), fake tool injection, security evasion attempts, source code/system prompt extraction
- **Action hallucination detection**: catches LLMs claiming they "analyzed an image" or "processed data" in text responses without actually invoking a tool
- **Self-modification prevention**: blocks writes to its own source directory and integrity-sealed files
- **HITL workflow**: cryptographic parameter binding prevents substitution attacks (approving action A then executing action B with the same approval ID)
- **SIEM integration**: structured CEF/JSON logging compatible with enterprise SIEM platforms

### What it does NOT cover — and why this matters for Tidegate

IntentShield operates entirely at the **application layer, inside the agent process**. This means:

1. **No network-level enforcement.** IntentShield can block a `BROWSE` action to a restricted domain, but if the LLM generates code that makes an HTTP request directly (via `urllib`, `requests`, a subprocess `curl`), IntentShield never sees it. The exfiltration bypasses the audit entirely.

2. **No filesystem-level enforcement.** It blocks `WRITE_FILE` to `.exe` paths, but can't prevent a subprocess from writing anywhere. File extension allowlisting is easily circumvented (write a `.txt` that's actually a shell script).

3. **Bypassable by design.** The library runs in the same Python process as the agent. An attacker who achieves code execution (the very thing IntentShield tries to prevent) can:
   - Monkeypatch the `_STATE` dict (mutable, not protected by `FrozenNamespace`)
   - Import `os` directly and call `os.system()` without going through the audit
   - Overwrite the lockfile and re-seal with a tampered hash
   - Set `rate_limit_interval=0` on every call

4. **Pattern matching is inherently incomplete.** The malicious syntax list is a fixed blocklist. Novel payloads, obfuscated code, polyglot injections, and semantic attacks (natural language social engineering) will pass through. The author's own "nuclear scanner" fallback demonstrates the fragility — it brute-force searches for tool names in raw text.

5. **The Willison gap applies directly.** IntentShield audits one leg of the lethal trifecta (the "ability to externally communicate") at the application layer, but cannot enforce it structurally. An MCP tool that reads email (untrusted content) and has network access (exfiltration vector) can still combine all three trifecta elements, and IntentShield's regex checks become the probabilistic guardrail that Willison [agent-runtime-security/014] calls "very much a failing grade."

### Interesting design patterns worth noting

- **Hash-sealed integrity verification** — The self-hashing pattern (hash own source, write to lockfile, verify on startup) is a lightweight tamper-detection mechanism. It's not cryptographically secure against a determined attacker (they can just regenerate the lockfile), but it catches accidental modification and unsophisticated tampering.

- **FrozenNamespace metaclass** — Making safety constants immutable via Python's metaclass protocol is a clean pattern for in-process safety rails. The `__delattr__` addition in v1.1.1 closed a real bypass vector.

- **Cryptographic parameter binding in HITL** — Hashing `action_type|payload` and verifying at execution time prevents a substitution attack where an attacker gets approval for a benign action then swaps the payload. This is a genuine security property.

- **Killswitch file** — A simple out-of-band shutdown mechanism (create a `KILLSWITCH` file to halt the agent) that doesn't depend on any API or network connectivity.

## Relevance to Tidegate

IntentShield is a **complementary but insufficient** layer for Tidegate's architecture:

| Tidegate concern | IntentShield coverage |
|---|---|
| Network egress enforcement | None — application-layer URL checks only |
| VM/process isolation | None — runs in-process |
| MCP payload scanning | Partial — regex-based action content scanning |
| Lethal trifecta prevention | Partial — audits actions but cannot enforce structurally |
| HITL approval workflow | Strong — cryptographic parameter binding |
| SIEM/audit logging | Strong — CEF/JSON structured events |
| Deterministic safety layer | Strong — no ML in safety path |

IntentShield validates the *need* for Tidegate: its limitations are precisely the gaps that infrastructure-embedded enforcement (gvproxy egress, VM boundary, MCP gateway) is designed to fill. A defense-in-depth deployment could run IntentShield *inside* the VM as an application-layer first line, with Tidegate's infrastructure layers as the deterministic backstop that IntentShield's regex cannot provide.

## Gaps

- **No test coverage for bypass scenarios.** The 53 tests verify that known-bad patterns are caught, but don't test evasion (obfuscated payloads, encoding tricks, indirect execution).
- **No documentation of threat model.** The README lists attack vectors but doesn't articulate what IntentShield does and does not defend against — making it easy to over-rely on.
- **BSL-1.1 license.** Free for non-production use only. Commercial license required for production. Converts to Apache 2.0 in 2036. This limits adoption and integration.
- **Single-author project.** No evidence of external security audit or review beyond the author's own v1.1.1 "security audit patch."
