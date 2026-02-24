# PII Detection for AI Agent Traffic — Tool Landscape and Recommendation

## Context

This evaluation covers PII detection tools and approaches for lobster-pot's mitmproxy addon, where HTTP request/response bodies must be scanned in real-time for personally identifiable information.

The companion documents cover:
- `evaluation.md` — Secret detection (API keys, tokens): solved with vendor-prefix regex
- `presidio-pii-evaluation.md` — Microsoft Presidio deep-dive: all 50 recognizers, scoring, configuration
- `ner-standalone-evaluation.md` — Standalone NER libraries (spaCy, GLiNER, Flair, Stanza, DataFog)
- `pii-regex-evaluation.md` — Regex + checksum + heuristic approaches for structured PII

## The Problem

The agent legitimately handles user PII: conversation history (names, addresses, medical details), workspace files (financial data, documents), tool call results (API responses with user records), and persistent memory. Aquaman protects credentials, but all other sensitive data flows through the agent and can be included in outbound requests.

Detection must work on **agent traffic**, which is fundamentally different from business documents:
- 50-70% code, JSON, base64, hex strings, numeric IDs
- 30-50% natural language (tool results, conversation fragments)
- Payloads from 1KB to 50KB
- 2-second total budget for all proxy checks (allowlist + rate limit + leak scan + monitor callout)

## Tools Evaluated

### General-purpose PII libraries

| Tool | Architecture | Strengths | Fatal weakness for lobster-pot |
|---|---|---|---|
| **Microsoft Presidio** | Regex + NER (spaCy) + context scoring | Confidence scores, 50+ recognizers, structured data support, actively maintained | 25-1,250ms with NER; 7 recognizers high-FP on code |
| **scrubadub** | Regex-based with optional spaCy/Stanford | Simple API, modular detectors | No confidence scores, no checksum validation, unmaintained (last release Sep 2023), ReDoS vulnerabilities |

### NER-only libraries (for name/address detection)

| Tool | NER F1 | 10KB Latency (CPU) | Memory | Fits budget? |
|---|---|---|---|---|
| **spaCy en_core_web_sm** | ~83 | ~100-150ms | 100-250MB | YES |
| **spaCy en_core_web_lg** | 85.5 | ~150ms | 700-900MB | YES (latency) / NO (memory) |
| **GLiNER PII (base)** | 81 | 5-15 sec | 330-500MB | NO (100-300x too slow) |
| **Flair ner-english-fast** | 92.9 | ~9 sec | 500MB-1GB | NO (20x too slow) |
| **Stanza** | 92.1 | 5-15 sec | 500MB-1GB | NO |
| **DataFog** | N/A (wrapper) | Varies | Varies | Depends on engine |

### Regex/checksum libraries

| Tool | Checksum validation | Context awareness | Phone validation | Standalone? | Maintained? |
|---|---|---|---|---|---|
| **python-stdnum** | YES (Luhn, mod-97, 200+ formats) | No | No | YES | YES (Jan 2026) |
| **phonenumbers** | N/A | Built-in FP protection | YES (gold standard) | YES | YES (Feb 2026) |
| **commonregex-improved** | No | No | No | YES | No (2022) |
| **pii-extract-plg-regex** | YES (stdnum + phonenumbers) | YES | YES | No (PIISA framework) | Moderate |
| **scrubadub** | No | No | No | YES | No (Sep 2023) |

## Key Findings

### 1. PII detection splits into structured vs. unstructured

| Category | Examples | Detection method | Precision on code-heavy text |
|---|---|---|---|
| **Structured PII** | Credit cards, SSNs, IBANs, emails, phones | Regex + checksum + context | High (with validation) |
| **Unstructured PII** | Person names, physical addresses, health data | NER / ML | Low-moderate (FP on code identifiers) |

This mirrors the secret detection split: vendor-prefix regex for known formats, broader tools for unknown formats.

### 2. Checksum validation is the key FP reducer for structured PII

- Credit cards + Luhn: **<0.1% FP** on formatted numbers
- IBANs + mod-97: **<0.1% FP**
- SSNs require context keywords (bare 9-digit matching is **>30% FP** on code)
- Phone numbers require libphonenumber validation (raw regex is **>30% FP** on code)

### 3. Only spaCy meets latency requirements for NER

All transformer-based NER (GLiNER, Flair, Stanza) is 10-300x slower than spaCy on CPU. For a proxy with a 2-second budget, only spaCy's CNN-based models are viable:

- **en_core_web_sm**: ~10-15ms/1KB, ~100-150ms/10KB, 100-250MB RAM
- **en_core_web_lg**: ~15ms/1KB, ~150ms/10KB, 700-900MB RAM

### 4. NER adds value for exactly one PII category: person names

Everything else (SSNs, credit cards, phones, emails, IBANs) is better detected by regex + validation. Physical addresses need NER but are lower priority than names. Health data detection is beyond current NER capabilities for code-heavy text.

### 5. spaCy has a known FP problem on code

CamelCase identifiers (`Jackson`, `Baker`, `Austin`) get tagged as PERSON/GPE. Mitigations:
- Filter to PERSON entities only
- Post-processing heuristics: reject if starts lowercase, contains underscore, is ALL_CAPS, contains digits
- JSON-aware scanning: only run NER on string values, not on full JSON
- Allow-list known code identifiers that trigger FP

### 6. JSON key-name scanning is high-signal and nearly free

Agent traffic is JSON-heavy. A lookup table of PII-indicative key names (`"ssn"`, `"phone"`, `"email"`, `"credit_card"`) provides near-zero FP detection at ~0.1ms cost.

### 7. Negative context suppression is critical and Presidio doesn't do it

Checking for anti-keywords (`"port"`, `"version"`, `"build"`, `"pid"`) near matches and suppressing them is the biggest FP reducer after checksums. Presidio only boosts scores for positive context — it never suppresses for negative context.

### 8. scrubadub is not viable

No confidence scores, no checksum validation, no JSON awareness, unmaintained since Sep 2023, known ReDoS vulnerabilities. Presidio is better in every dimension for general PII. For regex-only detection, building a custom layer with `python-stdnum` + `phonenumbers` is both lighter and more precise.

### 9. GLiNER PII models are architecturally ideal but CPU-impractical

`knowledgator/gliner-pii-base-v1.0` detects 60+ PII types via zero-shot, achieving 81% F1. But CPU inference is 100-300x slower than spaCy. Viable only with GPU-backed infrastructure, which is outside lobster-pot's Docker Compose model. Worth revisiting if lobster-pot adds a GPU analysis service.

## Recommendation: 3-Layer Detection Architecture

> **Scope revision**: The original 4-layer recommendation included NER for person names (Layer 3), phone detection via libphonenumber, and email detection. These have been dropped after further analysis of what's actually *actionable* in agent traffic. See `THREAT_MODEL.md` for the full sensitive data taxonomy that drove this scoping.
>
> **What was dropped and why**:
> - **Person names (NER)**: Names flow through every tool call as normal operation. spaCy fires on CamelCase code identifiers. Not actionable — you can't block requests containing names.
> - **Phone numbers**: Good precision via libphonenumber, but not actionable — phone numbers appear in legitimate API calls.
> - **Email addresses**: Accurate detection, but emails are in virtually every API response.
> - **Unstructured data** (code, conversations, documents): No structural pattern exists. Allowlisting is the defense.
>
> The research evaluating these tools remains valid and is preserved in the companion documents for future reference.

### Layer 1: JSON key-name heuristics (~0.1ms)
If the body is JSON, parse it and scan key names against a sensitive-data lookup table. Flag values under keys like `"ssn"`, `"credit_card"`, `"iban"`, `"ein"`. This is nearly free and catches structured sensitive data in API responses with near-zero FP.

### Layer 2: Checksum-validated patterns (~0.1ms)
High-confidence detection with algorithmic validation:
- Credit cards: issuer-prefix regex + Luhn (`python-stdnum`)
- IBANs: country code + length + mod-97 (`python-stdnum`)

These fire only on validated matches. FP rate <0.1%.

### Layer 3: Format + context-validated patterns (~1-5ms)
Medium-confidence detection requiring context keywords:
- SSNs: area/group/serial validation + REQUIRED context keywords (`ssn`, `social security`, etc.)
- EINs: prefix validation + REQUIRED context keywords

Without context keywords, 9-digit number matching is >30% FP on code. Context is mandatory.

### What this catches vs. what it misses

| Data Category | Detected? | Method | Confidence |
|---|---|---|---|
| Credit card numbers | YES | Regex + Luhn | High |
| IBANs | YES | Regex + mod-97 | High |
| SSNs (with context) | YES | Regex + area validation + context | Medium |
| EINs (with context) | YES | Regex + prefix + context | Medium |
| Credentials (backup) | YES | Vendor-prefix regex | High |
| Proprietary code | NO | No structural pattern | N/A |
| Conversation content | NO | No structural pattern | N/A |
| Person names | NO | Not actionable in agent traffic | N/A |
| Phone numbers | NO | Not actionable | N/A |
| Email addresses | NO | Not actionable | N/A |

### Dependency footprint

| Configuration | Dependencies | Size | Latency (10KB) |
|---|---|---|---|
| Recommended (Layers 1-3) | `python-stdnum` | ~1MB | <5ms |
| Presidio (for comparison) | `presidio-analyzer`, `spacy`, `en_core_web_lg` | ~800MB+ | 25-1,250ms |

### Performance budget

| Check | Estimated Latency | Notes |
|---|---|---|
| Vendor-prefix secret regex | ~0.01ms | From evaluation.md |
| Layer 1: JSON key scan | ~0.1ms | |
| Layer 2: Checksum patterns | ~0.1ms | |
| Layer 3: Format + context | ~1-5ms | |
| Monitor HTTP callout | ~50-200ms | Network round-trip (dominates) |
| **Total** | **~55-210ms** | **Well within 2-second budget** |

## What Remains Unknown

1. **Actual FP rates on real agent traffic**: All estimates above are from documentation analysis. Testing against captured agent transcripts is needed.

2. **JSON key-name coverage**: The lookup table needs to be populated from real API schemas used by the agent's tools.

3. **`python-stdnum` LGPL-2.1+ license compatibility**: Verify for the project's distribution model.

## Comparison: Presidio vs. Custom Layered Approach

| Dimension | Presidio | Custom 3-layer |
|---|---|---|
| Checksum validation | Luhn for credit cards, limited others | Luhn, mod-97 (IBAN), area validation (SSN) via python-stdnum |
| Negative context | NOT supported | Built-in FP suppression |
| JSON awareness | Via presidio-structured (separate package) | Built-in JSON key-name scanning |
| Memory footprint | 200MB-1.2GB | ~1MB |
| Latency (10KB) | 14-1,250ms (config-dependent) | <5ms |
| Maintenance | Microsoft-backed, active | Custom — we own it |
| Configuration complexity | High (50 recognizers to tune) | Low (3 layers, independently toggleable) |
| Coverage breadth | 50+ entity types | Financial instruments + government IDs + credentials |

**Verdict**: For lobster-pot's specific use case (code-heavy agent traffic, real-time proxy, Docker container), the custom layered approach is the right fit. It is lighter (1MB vs 800MB+), faster (<5ms vs 25-1,250ms), and targets only the data categories where pattern-based detection is both reliable and actionable. Broader PII coverage (names, addresses, health data) requires NER, which is too noisy and too slow for inline proxy use on code-heavy traffic — and the categories it catches aren't actionable anyway.
