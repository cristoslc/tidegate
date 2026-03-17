---
source-id: "intentshield-repo"
title: "IntentShield — Pre-execution intent verification for AI agents"
type: repository
url: "https://github.com/mattijsmoens/intentshield"
fetched: 2026-03-17T00:00:00Z
hash: "c030a29e1dbf3f7adb140afdc40ff3db9a213e49239e412c3e1a9e88d7c245f9"
highlights:
  - "intentshield/shield.py"
  - "intentshield/core_safety.py"
  - "intentshield/conscience.py"
  - "intentshield/hitl.py"
  - "README.md"
selective: false
---

# IntentShield

Pre-execution intent verification for AI agents. Checks what an AI agent is about to *do* — the actual shell command, file write, or URL — rather than what it *says*. v1.1.1, by Mattijs Moens. BSL-1.1 license (converts to Apache 2.0 in 2036).

## Architecture

Three deterministic layers, no LLM in the safety path:

1. **CoreSafety** (`core_safety.py`) — Deterministic rules via `FrozenNamespace` metaclass (immutable constants). SHA-256 hash-sealed integrity verification. Blocks: shell execution, file deletion, restricted domains (darkweb, localhost), credential exfiltration via URL params, code injection (XSS, SQL, reverse shells), self-modification, action hallucination detection, malware syntax patterns. Rate limiting and daily budget control.

2. **Conscience** (`conscience.py`) — Ethical evaluation via pre-compiled regex. Detects: 22+ manipulation verbs (lie, fabricate, pretend, roleplay, gaslight), 24+ harm keywords, fake tool injection, security evasion attempts, self-deletion, IP/source code extraction. Also hash-sealed.

3. **ActionParser** (`action_parser.py`) — LLM output parser with 3-layer fallback: line-by-line extraction, regex pattern matching, nuclear scanner brute-force. Enforces SUBCONSCIOUS/ACTION format with tool whitelist validation.

Optional layers:
- **HITLApproval** (`hitl.py`) — Human-in-the-loop for high-impact actions. Cryptographic parameter binding (SHA-256 hash of action+payload) prevents substitution attacks. TTL-based approval expiry. Persistent ledger. AISVS C9.2, C14.2.
- **SIEMLogger** (`siem_logger.py`) — CEF/JSON structured event logging for Splunk/Elastic/QRadar/Sentinel. AISVS C13.2.2.

## Key design decisions

- **Frozen namespace metaclass** — Safety constants physically cannot be modified at runtime
- **Hash-sealed integrity** — SHA-256 of source files locked to disk on first boot; tampering triggers `os._exit(1)`
- **No ML in the safety path** — All decisions are deterministic string matching and regex
- **Zero dependencies** — Pure Python stdlib, no supply chain risk
- **Fail-closed** — Conscience initialization failure terminates the process

## File tree

```
intentshield/
  __init__.py           # v1.1.1, re-exports all public classes
  shield.py             # Unified API — orchestrates all layers
  core_safety.py        # Layer 1: deterministic safety rules
  conscience.py         # Layer 2: ethical evaluation
  action_parser.py      # Layer 3: LLM output parser
  hitl.py               # Optional: human-in-the-loop approval
  siem_logger.py        # Optional: SIEM event logging
tests/
  test_intentshield.py  # 53 test cases across all layers
examples/
  basic_usage.py        # Quick-start example
demo.py                 # 30+ attack vector demo with color output
setup.py                # PyPI package config
LICENSE                 # BSL 1.1
```
