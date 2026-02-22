# Research Index

Research investigations for Tidegate. Each subdirectory is a self-contained research topic with its own evaluation, findings, and recommendation.

## `leak-detection/` — Leak Detection Tool Selection

**Status**: Resolved — architecture selected, remaining questions are empirical (FP testing on real traffic)

**Question**: What tools should Tidegate use to detect sensitive data in agent tool call parameters with acceptable false positive rates on code-heavy content?

**Answer**: 3-layer detection architecture scoped to data with structural signatures AND direct harm potential. Applied to `user_content` fields in MCP tool calls only — field classification eliminates false positives on `system_param` values entirely.

1. **L1: JSON key-name heuristics** (~0.1ms) — scan for keys like `"ssn"`, `"credit_card"`, `"iban"` in structured data
2. **L2: Checksum-validated patterns** (~0.1ms) — credit cards via Luhn, IBANs via mod-97, vendor-prefix credential regex
3. **L3: Format + context validation** (~1-5ms) — SSNs with required context keywords, encoding detection, entropy anomaly

Dependency: `python-stdnum` (~1MB). Not Presidio (800MB+, 25-1,250ms) and not NER (names not actionable, FP on code identifiers).

**Files**:
- `pii-detection-evaluation.md` — Synthesis: tool landscape, 3-layer architecture recommendation
- `evaluation.md` — Secret detection: 5-tool comparison (detect-secrets, TruffleHog, Gitleaks, Nightfall, simple regex)
- `presidio-pii-evaluation.md` — Deep Presidio analysis (evaluated, not selected)
- `ner-standalone-evaluation.md` — NER tools: spaCy, GLiNER, Flair, Stanza, DataFog (evaluated, not selected)
- `pii-regex-evaluation.md` — Regex + checksum + heuristic PII detection (selected approach)

See `THREAT_MODEL.md` for the full sensitive data taxonomy.
