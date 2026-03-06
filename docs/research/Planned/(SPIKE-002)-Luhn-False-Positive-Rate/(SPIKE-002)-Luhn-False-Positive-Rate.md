---
artifact: SPIKE-002
title: "Luhn False Positive Rate"
status: Planned
author: cristos
created: 2026-02-23
last-updated: 2026-02-23
question: "What is the empirical false positive rate of Luhn-based credit card detection in agent traffic?"
parent-vision: VISION-001
gate: Pre-MVP
risks-addressed: []
depends-on: []
---

# Luhn False Positive Rate

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Identified by adversarial threat model review |

## Source

External review: `tidegate-threatmodel-review(1).md` — problem #6.

## Question

The threat model claims L2 patterns are "zero false positive by design." ~10% of random 16-digit numbers pass the Luhn checksum. The current scanner uses prefix + length + Luhn, but the "zero false positive" claim is stronger than the math supports.

## Sub-questions

1. **Empirical FP rate**: Run the current scanner against realistic agent traffic — commit SHAs, channel IDs, timestamps, UUIDs, version strings. How many false positives per 1000 tool calls?
2. **IIN prefix filtering**: Credit card numbers start with specific Issuer Identification Numbers (4 for Visa, 51-55 for Mastercard, etc.). Does the current regex enforce IIN ranges? If not, how much does adding IIN filtering reduce the FP rate?
3. **Length constraints**: ISO 7812 specifies 13-19 digits. Does the current regex enforce this precisely?
4. **Compound validation**: What's the theoretical FP rate of IIN prefix + length range + Luhn combined? (Much lower than Luhn alone.)
5. **Claim revision**: Should the docs say "near-zero with prefix + length + checksum" instead of "zero by design"?

## Why it matters

Overstating precision undermines trust. If an operator sees a false positive after reading "zero false positives," they lose confidence in the entire scanning system. Accurate claims let operators calibrate expectations.

## Context at time of writing

Scanner is implemented in `src/scanner/scanner.py`. L2 Luhn check exists but the exact regex/prefix constraints need to be audited. The "zero false positive" claim appears in the threat model and CLAUDE.md.
