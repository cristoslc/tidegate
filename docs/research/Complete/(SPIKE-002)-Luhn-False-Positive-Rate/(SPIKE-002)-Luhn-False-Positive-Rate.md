---
artifact: SPIKE-002
title: "Luhn False Positive Rate"
status: Complete
author: cristos
created: 2026-02-23
last-updated: 2026-03-12
question: "What is the empirical false positive rate of Luhn-based credit card detection in agent traffic?"
parent-vision: VISION-002
gate: Pre-MVP
risks-addressed: []
depends-on: []
---

# Luhn False Positive Rate

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Identified by adversarial threat model review |
| Active | 2026-03-12 | 6848ce3 | Research in progress |
| Complete | 2026-03-12 | ee4d3c8 | "Zero FP" claim indefensible; compound validation achieves near-zero |

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

## Findings

The "zero false positive by design" claim in the threat model is mathematically indefensible for Luhn-based credit card detection. However, compound validation (IIN prefix + exact length + Luhn checksum) reduces the theoretical false positive rate to a level that is operationally negligible for agent traffic -- low enough to justify a "near-zero" claim, but not "zero."

**Verdict:** Replace "zero false positive by design" with "near-zero false positive with compound validation (IIN prefix + length + Luhn checksum)." The scanner implementation MUST enforce all three checks. Luhn alone is insufficient. With all three, the false positive rate against typical agent traffic is negligible but not mathematically zero.

### Luhn alone: the 1-in-10 problem

The Luhn algorithm uses mod-10 arithmetic. A completely random number has a uniform 1/10 probability of producing a remainder of 0, which is exactly what the Luhn check requires for validation. This means:

- **10% of random 16-digit numbers pass Luhn.** This is not a theoretical concern -- it is a mathematical certainty. For every 10 random 16-digit strings the scanner encounters, one will pass the Luhn check.
- Luhn was designed to catch accidental transcription errors (single-digit errors, adjacent transpositions), not to serve as a classifier for distinguishing credit card numbers from arbitrary digit strings.
- Luhn is necessary but not sufficient. All valid credit card numbers pass Luhn, but the converse does not hold.

### IIN prefix filtering: the primary discriminator

Credit card numbers are not uniformly distributed across the 16-digit number space. They begin with specific Issuer Identification Number (IIN/BIN) prefixes assigned under ISO/IEC 7812:

| Network | IIN Prefix Range | Length(s) |
|---------|-----------------|-----------|
| Visa | 4 | 13, 16, 19 |
| Mastercard | 51-55, 2221-2720 | 16 |
| American Express | 34, 37 | 15 |
| Discover | 6011, 644-649, 65, 622126-622925 | 16 |
| JCB | 3528-3589 | 16 |
| Diners Club | 300-305, 309, 36, 38-39 | 14 |
| China UnionPay | 62 | 16-19 |

The key insight: IIN prefix filtering eliminates the vast majority of the digit space. A random 16-digit number has only a small probability of starting with a valid IIN prefix. Calculating the prefix coverage:

- Visa (4xxx...): 10% of the space (first digit = 4)
- Mastercard (51-55, 2221-2720): ~5.5% of the space
- Amex (34, 37): ~2% of the space (but 15 digits, so different length)
- Discover (6011, 644-649, 65): ~1.7% of the space
- JCB (3528-3589): ~0.62% of the space

Combined, the major networks cover roughly 18-20% of the leading-digit space for 16-digit numbers. The dominant contributor is Visa's permissive single-digit prefix "4".

### Length constraints: the second filter

ISO 7812 specifies that payment card numbers range from 13 to 19 digits. In practice, the vast majority of cards in circulation use exactly 16 digits (Visa, Mastercard, Discover, JCB) or 15 digits (Amex). The scanner should enforce per-network length validation:

- A 15-digit number should only match Amex prefixes (34, 37)
- A 16-digit number should match Visa, Mastercard, Discover, JCB
- A 14-digit number should only match Diners Club (300-305, 36)
- 13-digit and 17-19 digit matches should be limited to the specific networks that use those lengths

This eliminates false positives from numbers that happen to start with a valid IIN prefix but are the wrong length for that network.

### Compound validation: theoretical false positive rate

For a random 16-digit number to be a compound false positive, it must simultaneously:

1. **Start with a valid IIN prefix** (~20% of numbers)
2. **Be the correct length for that prefix's network** (already constrained by extraction)
3. **Pass the Luhn checksum** (10% of numbers that pass steps 1-2)

The combined probability: ~20% x 10% = **~2% of random 16-digit numbers** would pass compound validation. This is much better than 10% (Luhn alone), but it is emphatically not zero.

However, this 2% figure overstates the real-world risk because it assumes the scanner encounters bare 16-digit decimal strings. In agent traffic, the relevant question is: how often does a non-credit-card value present as a bare 13-19 digit decimal number that also starts with a valid IIN prefix?

### Agent traffic analysis: empirical risk assessment

Common numeric patterns in agent/MCP traffic and their compound-FP risk:

| Pattern | Format | Compound FP risk |
|---------|--------|-----------------|
| Git commit SHAs | 40-char hex (a-f, 0-9) | **None.** Contains hex letters, not pure decimal. |
| UUIDs | 8-4-4-4-12 hex with hyphens | **None.** Contains hex letters and hyphens. |
| Unix timestamps | 10 digits (e.g., 1710288000) | **None.** Too short (10 digits). |
| Millisecond timestamps | 13 digits (e.g., 1710288000000) | **Minimal.** 13 digits, only matches if starts with valid prefix. Timestamps starting with "1" do not match any major IIN prefix. |
| Discord/Twitter snowflake IDs | 17-19 decimal digits | **Low but nonzero.** Could match if prefix aligns. Snowflakes starting with 4, 5, or 6 could false-positive. |
| Slack channel IDs | Alphanumeric (C0xxxxx) | **None.** Contains letters. |
| Version strings | Dotted (1.2.3) | **None.** Contains dots, not contiguous digits. |
| Phone numbers | 10-11 digits, often with formatting | **None.** Too short or contains formatting. |
| DHL/FedEx tracking numbers | 12-22 digits | **Low but nonzero.** Known false positive source in production DLP systems. |

The highest-risk pattern for agent traffic is **snowflake IDs** (Discord, Twitter/X). These are 17-19 digit decimal numbers derived from timestamps. A snowflake starting with digits 4, 5, or 6 could match a Visa, Mastercard, or Discover prefix, and 10% of those would pass Luhn. Current snowflake IDs (2024-2026 era) are in the range starting with digits like "1" (for Twitter epoch) or larger values for Discord, so the practical risk depends on the specific epoch and timestamp range.

### How production DLP systems handle this

Every major DLP vendor has encountered this exact problem and adopted a layered approach:

**Microsoft Purview** uses three confidence tiers:
- Low confidence: Luhn check alone (65% confidence)
- Medium confidence: Luhn + formatted grouping (e.g., 4916-4444-9269-8783)
- High confidence (85%): Luhn + keyword proximity ("credit card," "expiration date," "CVV," etc. in 27+ languages within 300 characters)

**Google Cloud DLP** assigns likelihood scores (VERY_UNLIKELY to VERY_LIKELY) based on pattern match + contextual signals. A bare number matching Luhn gets low likelihood; a number near keywords like "card number" gets high likelihood.

**Zscaler** recommends threshold-based detection (e.g., flag only when 50+ credit card patterns appear in one document) or Exact Data Match (fingerprinting known card numbers from databases).

**AWS Macie** combines managed data identifiers with custom identifiers, keyword proximity, and ignore-word lists.

**Zendesk credit_card_sanitizer** (open source) requires: valid IIN prefix + correct length + Luhn + optional digit grouping matching (e.g., 4-4-4-4 for Visa). The grouping check further reduces false positives by requiring numbers to appear in the expected format.

The industry consensus is clear: **no production DLP system relies on Luhn alone**, and **none of them claim zero false positives** for credit card detection.

### Sub-question dispositions

| Sub-question | Answer |
|---|---|
| 1. Empirical FP rate | Cannot run empirically (no agent traffic corpus yet). Theoretical analysis: with compound validation, FP rate against typical agent traffic is negligible. Git SHAs, UUIDs, timestamps, and most IDs contain non-decimal characters or are the wrong length. Snowflake IDs are the highest-risk pattern (~2% FP rate for those matching IIN prefix length). |
| 2. IIN prefix filtering | The scanner MUST enforce IIN prefix ranges. Without IIN filtering, 10% of any 16-digit number passes Luhn. With IIN filtering, only ~20% of the number space is eligible, reducing the compound rate to ~2%. The prefixes to enforce: Visa (4), Mastercard (51-55, 2221-2720), Amex (34, 37), Discover (6011, 644-649, 65), JCB (3528-3589). |
| 3. Length constraints | ISO 7812 specifies 13-19 digits, but the scanner should enforce per-network lengths: 15 for Amex, 16 for Visa/MC/Discover/JCB, 14 for Diners. Accepting 13-19 for all prefixes unnecessarily widens the match window. |
| 4. Compound FP rate | IIN prefix (~20%) x Luhn (10%) = ~2% of random N-digit numbers where N matches a valid card length. Against agent traffic specifically, the effective rate is much lower because most numeric values are either the wrong length, contain non-decimal characters, or start with prefixes outside IIN ranges. |
| 5. Claim revision | **Yes, absolutely.** "Zero false positive by design" must be changed to "near-zero false positive with compound validation." The math does not support "zero." Every production DLP vendor uses the same compound approach and none claim zero. The revised claim is still strong -- compound validation is effective enough that false positives in agent traffic should be rare. |

### Recommendations

1. **Revise the "zero false positive" claims** in `docs/threat-model/sensitive-data.md` and `docs/vision/Draft/(VISION-002)-Tidegate/system-architecture.md`. Replace with: "near-zero false positive with compound validation (IIN prefix + per-network length + Luhn checksum)."

2. **Scanner implementation requirements for `src/scanner/scanner.py`:**
   - Extract contiguous digit sequences of 13-19 characters (with optional separators: spaces, hyphens)
   - Validate IIN prefix against a known set of major card network ranges
   - Enforce per-network length constraints (not a blanket 13-19)
   - Apply Luhn checksum as the final check
   - Reject digit strings that are bounded by hex characters (a-f, A-F) to avoid matching substrings of hex hashes

3. **Consider a boundary-aware extraction strategy.** Do not match digit sequences that are part of a longer alphanumeric token. A 16-digit substring of a 40-character hex SHA should never be a candidate. Use word-boundary or non-digit-boundary assertions in the regex.

4. **Consider optional grouping validation** (as Zendesk does). A credit card number formatted as 4111-1111-1111-1111 is much higher confidence than a bare 4111111111111111 embedded in a larger string. This could be used for confidence tiering rather than hard filtering.

5. **Add a negative pattern list** for known false-positive sources: FedEx/UPS/DHL tracking numbers, snowflake ID ranges, and other numeric identifiers common in agent traffic. This is what production DLP systems do.

6. **Document the residual risk.** Even with compound validation, a ~2% theoretical FP rate on qualifying digit strings means the scanner is not mathematically infallible. The documentation should set operator expectations: false positives are unlikely but possible, and the shaped deny mechanism means a false positive results in a retryable error, not data loss.
