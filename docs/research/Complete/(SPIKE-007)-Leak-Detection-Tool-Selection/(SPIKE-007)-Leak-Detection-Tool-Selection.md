---
artifact: SPIKE-007
title: "Leak Detection Tool Selection"
status: Complete
author: cristos
created: 2026-02-21
last-updated: 2026-02-21
question: "Which tools should the gateway use to detect leaked secrets and PII in agent traffic?"
parent-vision: VISION-001
gate: Pre-MVP
risks-addressed: []
depends-on: []
---

# Leak Detection Tool Selection

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Complete | 2026-02-21 | db146de | Shipped with initial commit; informed L1 scanner design |

## Question

Which tools should the gateway use to detect leaked secrets and PII in agent traffic? What are the false positive tradeoffs for real-time inline scanning of code-heavy HTTP bodies?

## Outcome

**Secrets:** Simple vendor-prefix regex (15-25 patterns) for L1, with detect-secrets as a future L2 layer. TruffleHog and Gitleaks have best detection quality but Go binaries with subprocess overhead make them unsuitable for inline scanning. Nightfall disqualified (SaaS-only).

**PII:** Presidio is the recommended engine, supplemented by standalone NER for entity types Presidio handles weakly. PII detection inherently has higher false positive rates on code than secret detection — these are fundamentally different problems requiring different tools.

## Supporting docs

- [secret-detection-evaluation.md](secret-detection-evaluation.md) — detect-secrets, TruffleHog, Gitleaks, Nightfall, simple regex comparison
- [pii-detection-evaluation.md](pii-detection-evaluation.md) — PII detection tool landscape and recommendation
- [presidio-pii-evaluation.md](presidio-pii-evaluation.md) — Microsoft Presidio deep-dive (all 50 recognizers)
- [ner-standalone-evaluation.md](ner-standalone-evaluation.md) — spaCy, GLiNER, Flair, Stanza, DataFog comparison
- [pii-regex-evaluation.md](pii-regex-evaluation.md) — PII regex pattern evaluation
