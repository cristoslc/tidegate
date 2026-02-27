# Microsoft Presidio PII Detection — Evaluation for AI Agent Traffic

## Context

This evaluation assesses Microsoft Presidio's suitability as a PII detection engine inside lobster-pot's mitmproxy addon. The traffic being inspected is AI agent HTTP request/response bodies containing code, JSON, base64, numeric IDs, structured data, and natural language mixed together.

The companion document (`evaluation.md`) already covers secret detection (API keys, tokens). This document focuses exclusively on Presidio's PII detection capabilities and its false positive characteristics on code-like data.

**Sources**: All findings below come from the official Presidio documentation at https://microsoft.github.io/presidio/ and the source code at https://github.com/microsoft/presidio (main branch, as of 2026-02-21). Presidio is at version 2.2.361 (released 2026-02-12), actively maintained with 159 contributors, 7,000 stars, and 55 open issues.

---

## 1. Built-in Recognizers — Complete Inventory

Presidio ships with approximately 50 recognizers across four categories. Each recognizer reports a confidence score between 0.0 and 1.0.

### 1A. Generic Recognizers (enabled by default, all languages)

| Recognizer | Entity Type | Method | Base Score | Validation | Context Words | False Positive Risk on Code/JSON |
|---|---|---|---|---|---|---|
| **CreditCardRecognizer** | CREDIT_CARD | Regex + Luhn checksum | 0.3 | Luhn algorithm (digit sum mod 10) | credit, card, visa, mastercard, cc, amex, discover (16 words) | **LOW** — Luhn checksum eliminates most random numbers. Unix timestamps and numeric IDs rarely pass Luhn. Documented false positive on some timestamps per GitHub issues. |
| **CryptoRecognizer** | CRYPTO | Regex + checksum | 0.5 | Double SHA256 (P2PKH/P2SH) or Bech32 polymod | wallet, btc, bitcoin, crypto | **LOW** — Regex requires `bc1`, `1`, or `3` prefix + 25-59 chars of Base58. Checksum eliminates most noise. |
| **DateRecognizer** | DATE_TIME | Regex (13 patterns) | 0.1-0.8 | None | date, birthday | **HIGH** — Fires on ISO 8601 timestamps (score 0.8), date strings in JSON (`"2024-01-15"`), date formats in code. Every JSON payload with dates will trigger this. |
| **EmailRecognizer** | EMAIL_ADDRESS | Regex + TLD validation | 0.5 | `tldextract` validates FQDN | email | **MODERATE** — Will correctly detect real email addresses in JSON. The TLD validation prevents `user@localhost` from matching. Risk: fires on every email address in API responses, which may be functional data, not PII leakage. |
| **IbanRecognizer** | IBAN_CODE | Regex + mod-97 checksum | 0.5 | IBAN mod-97 algorithm | iban | **LOW** — Mod-97 checksum eliminates most random alphanumeric strings. |
| **IpRecognizer** | IP_ADDRESS | Regex + `ipaddress` stdlib validation | 0.6 (IPv4), 0.1 (::) | Python `ipaddress.ip_address()` | ip | **HIGH** — Matches ANY valid IPv4 address including version strings like `1.2.3.4`, Docker subnet configs like `172.17.0.1`, localhost `127.0.0.1`. Word boundary `\b` is the only guard. Every JSON with IP addresses or version numbers in dotted-quad format will trigger. |
| **MacAddressRecognizer** | MAC_ADDRESS | Regex (colon/hyphen + Cisco dot format) | 0.6 | Hex length + broadcast/null rejection | mac, address | **LOW** — Requires specific separator patterns (colons, hyphens, dots between hex pairs). Bare hex strings do not match. |
| **PhoneRecognizer** | PHONE_NUMBER | `python-phonenumbers` library | 0.4 | Region-specific parsing via `phonenumbers.parse()` | phone, number, telephone, cell, cellphone, mobile, call | **HIGH** — The `phonenumbers` library is aggressive. Depending on leniency setting (0-3, where 0 is most lenient), it can match bare 10-digit numbers as US phone numbers. Port combinations, numeric IDs, and timestamps can trigger. Leniency defaults vary by region. |
| **UrlRecognizer** | URL | Regex (4 patterns) + TLD validation | 0.5-0.6 | Checks for valid FQDN via `tldextract` | url, website, link | **HIGH** — Fires on every URL in JSON responses, API endpoint strings, webhook URLs. GitHub issues confirm false positives on code snippets. Quoted URL patterns explicitly target strings in JSON. |
| **MedicalLicenseRecognizer** | MEDICAL_LICENSE | Regex + Luhn checksum | 0.4 | Luhn checksum on DEA certificate numbers | medical, license | **LOW** — Narrow pattern (specific letter prefix + 7 digits) plus checksum. |

### 1B. NER/NLP-Based Recognizers (enabled by default, require spaCy model)

| Recognizer | Entity Types | Method | Score Source | False Positive Risk on Code/JSON |
|---|---|---|---|---|
| **SpacyRecognizer** | PERSON, LOCATION, NRP, DATE_TIME, ORGANIZATION | spaCy NER model (`en_core_web_lg`) | Directly from spaCy confidence | **HIGH** — spaCy NER is trained on natural language. On code/JSON content: variable names that look like proper nouns (`Jackson`, `Austin`, `Jenkins`) get flagged as PERSON or LOCATION. City/state names in address fields of API responses get flagged. CamelCase identifiers can trigger. Class names like `HttpClient` will not trigger, but something like `Baker` or `Marshall` in code easily could. |

### 1C. US-Specific Recognizers (enabled by default, English only)

| Recognizer | Entity Type | Method | Base Score | Validation | False Positive Risk on Code/JSON |
|---|---|---|---|---|---|
| **UsSsnRecognizer** | US_SSN | Regex (5 patterns) | 0.05 (bare digits) to 0.5 (formatted) | Rejects all-zeros, all-same-digit, known invalid prefixes (000, 666, etc.) | **HIGH** — Pattern `\b[0-9]{9}\b` matches ANY 9-digit number at score 0.05. Even formatted pattern `XXX-XX-XXXX` could match numeric IDs with hyphens. The very low base score (0.05) means it is filtered by any reasonable threshold, but if threshold is set low it becomes noisy. |
| **UsItinRecognizer** | US_ITIN | Regex | 0.05-0.5 | Context words: itin, taxpayer, tax | **LOW-MODERATE** — Requires specific digit patterns starting with 9. Context words reduce noise. |
| **UsLicenseRecognizer** | US_DRIVER_LICENSE | Regex | Varies | State-specific patterns | **MODERATE** — State driver license formats vary widely. Some are just digit sequences. |
| **UsPassportRecognizer** | US_PASSPORT | Regex | Varies | Context words | **LOW** — Narrow format. |
| **UsBankRecognizer** | US_BANK_NUMBER | Regex | Varies | Context words | **LOW-MODERATE** |
| **AbaRoutingRecognizer** | ABA_ROUTING_NUMBER | Regex + checksum | Varies | ABA routing checksum | **LOW** — Checksum validation. |

### 1D. UK-Specific Recognizers (enabled by default, English only)

| Recognizer | Entity Type | False Positive Risk on Code/JSON |
|---|---|---|
| **NhsRecognizer** | UK_NHS | **LOW** — Specific 10-digit format with checksum |

### 1E. Disabled by Default (19 recognizers)

These are NOT loaded unless explicitly enabled in config:

- UsMbiRecognizer, UkNinoRecognizer, UkPostcodeRecognizer
- SgFinRecognizer (Singapore)
- Australian: AuAbnRecognizer, AuAcnRecognizer, AuTfnRecognizer, AuMedicareRecognizer
- Indian: InPanRecognizer, InAadhaarRecognizer, InVehicleRegistrationRecognizer, InPassportRecognizer, InVoterRecognizer, InGstinRecognizer
- Korean: KrBrnRecognizer, KrRrnRecognizer, KrDriverLicenseRecognizer, KrFrnRecognizer
- Thai: ThTninRecognizer
- HuggingFaceNerRecognizer, BasicLangExtractRecognizer

**Notable**: GitHub issues report that InPanRecognizer (when enabled) matches "every 10 character alphanumeric string" — including identifiers like `JavaScript` being flagged as an Indian PAN number.

### Summary: High false-positive risk recognizers for code/JSON traffic

1. **DateRecognizer** — fires on every date string
2. **IpRecognizer** — fires on version numbers, Docker IPs, localhost
3. **PhoneRecognizer** — fires on 10+ digit numbers depending on leniency
4. **UrlRecognizer** — fires on every URL in JSON
5. **SpacyRecognizer** (PERSON/LOCATION) — fires on proper-noun-like identifiers
6. **UsSsnRecognizer** — fires on 9-digit numbers (but at very low score 0.05)
7. **EmailRecognizer** — fires on every email address in API data

---

## 2. Selective Enable/Disable

### Per-call entity filtering

The `analyze()` method (both Python API and REST) accepts an `entities` parameter:

```python
results = analyzer.analyze(
    text="...",
    language="en",
    entities=["CREDIT_CARD", "US_SSN", "PHONE_NUMBER"]  # only detect these
)
```

When `entities` is `None`, all entity types are searched. When specified, only recognizers supporting those entity types are invoked. This is **per-call filtering**.

### Global recognizer configuration via YAML

The `RecognizerRegistryProvider` loads from a YAML config file where each recognizer has an `enabled: true/false` flag:

```yaml
recognizers:
  - name: CreditCardRecognizer
    type: predefined
    enabled: true
  - name: DateRecognizer
    type: predefined
    enabled: false  # disable entirely
  - name: IpRecognizer
    type: predefined
    enabled: false  # disable entirely
```

This is **global configuration** — disabled recognizers are never loaded.

### Programmatic add/remove

```python
from presidio_analyzer import AnalyzerEngine
from presidio_analyzer.recognizer_registry import RecognizerRegistry

registry = RecognizerRegistry()
registry.load_predefined_recognizers()

# Remove a specific recognizer by name
registry.remove_recognizer("DateRecognizer")
registry.remove_recognizer("IpRecognizer")
registry.remove_recognizer("UrlRecognizer")

analyzer = AnalyzerEngine(registry=registry)
```

### Empty registry approach (most selective)

```python
registry = RecognizerRegistry()
# Do NOT call load_predefined_recognizers()
# Add only what you want:
registry.add_recognizer(CreditCardRecognizer())
registry.add_recognizer(UsSsnRecognizer())
analyzer = AnalyzerEngine(registry=registry)
```

**Verdict**: Full control. You can run Presidio with exactly the recognizers you want, either via YAML config (global) or `entities` parameter (per-call). Both approaches work.

---

## 3. Threshold/Scoring

### Confidence scores

Every `RecognizerResult` includes a `score` field (0.0 to 1.0). Scores come from multiple sources:

1. **Base pattern score**: Each regex pattern has a hardcoded base score (e.g., 0.3 for credit card, 0.05 for SSN bare digits, 0.6 for IP addresses)
2. **Validation boost**: If `validate_result()` passes (e.g., Luhn checksum), score jumps to `MAX_SCORE` (1.0). If validation fails, score drops to `MIN_SCORE` (0.0) and the result is discarded.
3. **Context enhancement**: If context words are found near the match, the `LemmaContextAwareEnhancer` adds `context_similarity_factor` (default 0.35) to the score, with a minimum of `min_score_with_context_similarity` (default 0.4) and a maximum of 1.0.
4. **NER scores**: For spaCy-based recognizers, the score comes directly from spaCy's NER confidence.

### Score threshold parameter

The `analyze()` method accepts `score_threshold`:

```python
results = analyzer.analyze(
    text="...",
    language="en",
    score_threshold=0.5  # only return results with score >= 0.5
)
```

The REST API also accepts `score_threshold` in the JSON body.

Results below the threshold are filtered out by `__remove_low_scores()` internally.

### Practical threshold values

| Threshold | Effect |
|---|---|
| 0.0 | Everything (includes 0.05 bare-digit SSN matches, very noisy) |
| 0.3 | Filters bare-digit SSN (0.05), low-confidence dates (0.1-0.2). Still gets unvalidated credit cards (0.3), phones (0.4). |
| 0.5 | Filters most unvalidated regex matches. Gets validated matches (checksummed credit cards = 1.0), context-boosted results (0.4+0.35 = 0.75), IP addresses (0.6). |
| 0.7 | Only high-confidence: validated checksums (1.0), context-boosted results, high-confidence NER. Misses bare IP addresses (0.6), bare emails (0.5). |
| 0.85 | Only very high confidence: validated credit cards, strong NER matches. Very few results but very low false positive rate. |

**Verdict**: Yes, fine-grained threshold control exists. A threshold of 0.5-0.7 eliminates most low-confidence noise. Combined with selective recognizer enabling, this gives good control.

---

## 4. Deny/Allow Lists

### Allow list (analyze-time)

The `analyze()` method accepts an `allow_list` parameter:

```python
results = analyzer.analyze(
    text="Call 127.0.0.1 or admin@example.com",
    language="en",
    allow_list=["127.0.0.1", "admin@example.com"],
    allow_list_match="exact"  # or "regex"
)
```

- `allow_list`: List of strings to ignore in results
- `allow_list_match`: `"exact"` for literal string matching, `"regex"` for regex pattern matching

When a detected entity's text matches an allow list entry, that result is removed from the output.

This is **per-call** — you can pass different allow lists for different requests.

### Allow list via REST API

The REST API `/analyze` endpoint accepts the same parameters:

```json
{
    "text": "...",
    "language": "en",
    "allow_list": ["127.0.0.1", "localhost"],
    "allow_list_match": "exact"
}
```

### Deny list (recognizer-level)

The `PatternRecognizer` class supports deny lists — curated word lists that always trigger detection:

```python
titles_recognizer = PatternRecognizer(
    supported_entity="TITLE",
    deny_list=["Mr.", "Mrs.", "Miss"],
    deny_list_score=1.0
)
```

Deny lists are converted to regex patterns internally: `(?:^|(?<=\W))(term1|term2)(?:(?=\W)|$)`.

### Allow list for specific domains or patterns

There is no built-in "domain allow list" feature. However, you can achieve this with regex allow lists:

```python
results = analyzer.analyze(
    text="...",
    language="en",
    allow_list=[r"api\.anthropic\.com", r"api\.openai\.com", r"github\.com"],
    allow_list_match="regex"
)
```

**Verdict**: Allow lists work per-call with exact or regex matching. Deny lists work at the recognizer level. No built-in concept of "safe domains" but regex allow lists can approximate it. For lobster-pot, you would pass a regex allow list of known-safe patterns (localhost IPs, internal domain names, etc.) on every `analyze()` call.

---

## 5. Context-Aware Detection

### How it works

Presidio uses a `LemmaContextAwareEnhancer` (enabled by default) that:

1. **Extracts a context window** around each detected entity: 5 words before (configurable via `context_prefix_count`) and 0 words after (configurable via `context_suffix_count`)
2. **Lemmatizes** the context words using spaCy
3. **Compares** lemmatized context against the recognizer's predefined context word list
4. **Boosts** the score by `context_similarity_factor` (default 0.35) if a match is found
5. **Enforces** a minimum boosted score of `min_score_with_context_similarity` (default 0.4)

### Example: "call me at 555-1234" vs "port 5551234"

- "call me at 555-1234": The phone recognizer's context words include `call`, `phone`, `mobile`. The word `call` appears in the 5-word window before the match. Score boost: 0.4 + 0.35 = 0.75.
- "port 5551234": None of the phone recognizer's context words (`phone`, `number`, `telephone`, `cell`, `cellphone`, `mobile`, `call`) appear in the window. Score remains at base (0.4).

### Context words are per-recognizer

Each built-in recognizer defines its own context word list. These are the words that trigger a score boost:

- **CreditCardRecognizer**: credit, card, visa, mastercard, cc, amex, discover, diners, carte, dci, jcb, instapayment, laser, maestro, uatp, elan
- **PhoneRecognizer**: phone, number, telephone, cell, cellphone, mobile, call
- **EmailRecognizer**: email
- **IpRecognizer**: ip
- **UrlRecognizer**: url, website, link
- **DateRecognizer**: date, birthday

### Context matching modes

- **Substring mode** (default, backward-compatible): `card` matches `creditcard`
- **Whole-word mode**: requires exact case-insensitive match only

### Configuring context enhancement

```python
from presidio_analyzer.context_aware_enhancers import LemmaContextAwareEnhancer

context_enhancer = LemmaContextAwareEnhancer(
    context_similarity_factor=0.35,     # how much to boost
    min_score_with_context_similarity=0.4,  # minimum after boost
    context_prefix_count=5,              # words before match
    context_suffix_count=0               # words after match
)

analyzer = AnalyzerEngine(context_aware_enhancer=context_enhancer)
```

### Limitation for code/JSON content

Context enhancement helps with natural language but has limited value for structured data. In JSON like `{"phone": "5551234567"}`, the key `"phone"` would appear in the context window and boost the score. But in `{"port": 5551234567}`, the key `"port"` would not boost it. This is actually beneficial — the JSON key name provides real semantic context.

However, in code like `const port = 5551234567`, the word `port` is not in the phone recognizer's context list, so no boost occurs. But the recognizer might still match at base score (0.4) depending on the `phonenumbers` library's leniency.

**Verdict**: Context awareness provides meaningful disambiguation in natural language and somewhat in structured JSON (where keys act as context). It does NOT actively suppress false positives — it only boosts true positives. There is no "anti-context" mechanism that says "if the word `port` is nearby, reduce the score." A bare match without context still gets its base score.

---

## 6. Custom Recognizers

### Difficulty: Low to moderate

Three approaches, from simplest to most complex:

### Approach 1: PatternRecognizer (simplest, no code file needed)

```python
from presidio_analyzer import Pattern, PatternRecognizer

aws_key_recognizer = PatternRecognizer(
    supported_entity="AWS_ACCESS_KEY",
    patterns=[
        Pattern("aws_access_key", r"AKIA[0-9A-Z]{16}", 0.9)
    ],
    context=["aws", "access", "key", "amazon"]
)

github_token_recognizer = PatternRecognizer(
    supported_entity="GITHUB_TOKEN",
    patterns=[
        Pattern("github_pat", r"gh[pous]_[A-Za-z0-9_]{36,255}", 0.9),
        Pattern("github_fine_grained", r"github_pat_[A-Za-z0-9_]{22,255}", 0.9)
    ],
    context=["github", "token", "pat"]
)

# Register
analyzer.registry.add_recognizer(aws_key_recognizer)
analyzer.registry.add_recognizer(github_token_recognizer)
```

### Approach 2: YAML config (no code at all)

```yaml
recognizers:
  - name: AwsAccessKeyRecognizer
    supported_entity: AWS_ACCESS_KEY
    patterns:
      - name: aws_access_key
        regex: "AKIA[0-9A-Z]{16}"
        score: 0.9
    supported_languages:
      - language: en
        context:
          - aws
          - access
          - key
```

Load with:
```python
registry = RecognizerRegistry()
registry.add_recognizers_from_yaml("custom_recognizers.yaml")
```

### Approach 3: Custom EntityRecognizer class (most flexible)

```python
from presidio_analyzer import LocalRecognizer, RecognizerResult

class SecretPatternRecognizer(LocalRecognizer):
    ENTITIES = ["SECRET_KEY"]
    NAME = "Secret Pattern Recognizer"

    def load(self):
        # compile regex patterns at init
        pass

    def analyze(self, text, entities, nlp_artifacts=None):
        results = []
        # custom detection logic here
        # can use any Python library, call external services, etc.
        return results
```

### Ad-hoc recognizers (per-call, no registration)

```python
ad_hoc = PatternRecognizer(
    supported_entity="TEMP_PATTERN",
    patterns=[Pattern("temp", r"sk-ant-[A-Za-z0-9\-_]{90,}", 0.95)]
)

results = analyzer.analyze(
    text="...",
    language="en",
    ad_hoc_recognizers=[ad_hoc]
)
```

### Could we skip generic PII and use only custom secret recognizers?

**Yes, absolutely.** Create an empty registry, add only your custom secret-pattern recognizers, and skip all built-in PII recognizers:

```python
registry = RecognizerRegistry()
# Don't call load_predefined_recognizers()
# Add only secret recognizers
registry.add_recognizer(aws_key_recognizer)
registry.add_recognizer(github_token_recognizer)
# ... more vendor patterns

analyzer = AnalyzerEngine(registry=registry)
```

This would use Presidio purely as a regex execution framework with structured output, scoring, context enhancement, and a REST API. No PII detection overhead, no spaCy model, no NER.

However, this raises the question: if you are only using Presidio for regex matching with no NLP, is the overhead of the Presidio framework justified compared to running the regexes directly? See the tradeoffs in the recommendation section.

**Verdict**: Custom recognizers are straightforward. PatternRecognizer covers most secret patterns in 5-10 lines per vendor. YAML config allows no-code definition. You can absolutely build a "secret pattern recognizer" and skip generic PII. The question is whether Presidio's framework overhead is worth it compared to bare regex.

---

## 7. Built-in Support for Code Context / False Positive Reduction

### Short answer: None

Presidio has **no built-in awareness of code, JSON, or technical content**. There is no:

- Code-context mode that suppresses detection in code blocks
- JSON-aware parsing that treats keys vs values differently
- Programming language detection
- Technical content classifier
- Pre-built allow list for common code patterns (localhost, version strings, etc.)

### What exists for false positive reduction

1. **Score thresholds** — filter low-confidence matches (generic, not code-specific)
2. **Allow lists** — per-call string/regex exclusions (manual, you build the list)
3. **Context enhancement** — boosts true positives when context words present (does not suppress false positives)
4. **Checksum validation** — credit cards (Luhn), IBAN (mod-97), crypto addresses, medical licenses. This is the most effective false positive filter and happens automatically.
5. **Selective recognizer enable/disable** — turn off noisy recognizers globally

### GitHub issues confirm the gap

Open and closed GitHub issues report:
- URL recognizer producing "many false positives when analyzing code snippets"
- IN_PAN recognizer matching "every 10 character alphanumeric string" (including `JavaScript`)
- Credit card recognizer matching Unix timestamps
- Numbers classified as PERSON entities
- Datetime values misidentified as LOCATION
- Context enhancement triggering even without context words in vicinity

### What you would need to build yourself

For acceptable false positive rates on agent traffic, you would need to implement:

1. **Pre-processing**: Strip or classify content before sending to Presidio. For example, detect JSON structure and only scan string values, not keys or numeric values.
2. **Code-aware allow lists**: Maintain a regex allow list covering `127.0.0.1`, `0.0.0.0`, `localhost`, `*.example.com`, version-number patterns, common port numbers, Docker subnet ranges, etc.
3. **Post-processing**: Filter Presidio results by removing matches that fall within code blocks, JSON keys, or known technical patterns.
4. **Tuned recognizer configuration**: Disable DateRecognizer, IpRecognizer, UrlRecognizer for code-heavy traffic, or raise the score threshold high enough to filter their output.

---

## Deployment Details

### Docker image

```
docker pull mcr.microsoft.com/presidio-analyzer
docker run -d -p 5002:3000 mcr.microsoft.com/presidio-analyzer:latest
```

- Base image: `python:3.12-slim`
- Includes spaCy `en_core_web_lg` model by default
- Estimated image size: 500MB-2GB depending on NLP model (the `en_core_web_lg` model alone is ~560MB)
- REST API on port 3000

### Python library (in-process)

```
pip install presidio_analyzer
python -m spacy download en_core_web_lg
```

For the mitmproxy addon, in-process usage avoids HTTP overhead:

```python
from presidio_analyzer import AnalyzerEngine
analyzer = AnalyzerEngine()
results = analyzer.analyze(text=body, language="en", score_threshold=0.5)
```

### Without NLP model (regex-only mode)

If you disable all NER-based recognizers and use only regex/pattern recognizers, you do NOT need the spaCy model. This dramatically reduces image size and startup time:

```python
from presidio_analyzer import AnalyzerEngine
from presidio_analyzer.recognizer_registry import RecognizerRegistry

registry = RecognizerRegistry()
registry.load_predefined_recognizers(nlp_engine=None)
# Remove NER-based recognizers
registry.remove_recognizer("SpacyRecognizer")
analyzer = AnalyzerEngine(registry=registry, nlp_engine=None)
```

**Note**: Without the NLP engine, PERSON, LOCATION, NRP, and ORGANIZATION entities will not be detected. DATE_TIME detection falls back to regex only (no NER).

### Performance

The Presidio docs state a guideline: "Anything above 100ms per request with 100 tokens is probably not good enough." This suggests expected performance of under 100ms for typical text.

- **With NLP model**: spaCy `en_core_web_lg` adds 50-200ms per call for NER inference
- **Regex-only mode**: Sub-millisecond for pattern matching, plus context enhancement overhead
- **Batch mode**: `BatchAnalyzerEngine` supports batch processing with NLP batching for throughput

---

## Recommendation for Lobster-Pot

### Do NOT use Presidio as a general PII scanner on agent traffic (yet)

Running Presidio with all default recognizers on agent HTTP bodies will produce an unacceptable false positive rate. The combination of DateRecognizer, IpRecognizer, UrlRecognizer, PhoneRecognizer, and SpacyRecognizer (PERSON/LOCATION) will flag enormous amounts of normal technical content.

### Presidio IS viable under specific configurations

There are two viable approaches:

#### Option A: Presidio as a secret-pattern framework (replaces simple regex)

Use Presidio's `PatternRecognizer` infrastructure with only custom secret-pattern recognizers. No built-in PII recognizers, no spaCy model.

**Advantages over bare regex**:
- Structured `RecognizerResult` output with entity type, score, start/end offsets
- Context enhancement (score boost when context words appear near match)
- YAML configuration (add new patterns without code changes)
- REST API built in (if running as a sidecar service)
- Allow list support per call
- Score threshold filtering
- Decision tracing (`return_decision_process=True` explains why each entity was detected)

**Disadvantages vs bare regex**:
- ~500MB Docker image overhead (even without spaCy, the Python framework is not tiny)
- 5-50ms overhead per call vs sub-millisecond for compiled regex
- Additional dependency to maintain
- Overkill if you only need 15-25 regex patterns

**Verdict**: Not worth it for secret detection alone. The `evaluation.md` recommendation of a simple regex set or detect-secrets is better for that use case.

#### Option B: Presidio for selective PII detection with aggressive tuning

Use Presidio with a carefully curated subset of recognizers and a high score threshold for the subset of PII types that matter for agent safety.

**Recommended configuration**:

```yaml
# Disable high-noise recognizers
recognizers:
  - name: DateRecognizer
    type: predefined
    enabled: false
  - name: IpRecognizer
    type: predefined
    enabled: false
  - name: UrlRecognizer
    type: predefined
    enabled: false
  - name: MacAddressRecognizer
    type: predefined
    enabled: false

  # Keep checksum-validated recognizers (low false positive)
  - name: CreditCardRecognizer
    type: predefined
    enabled: true
  - name: IbanRecognizer
    type: predefined
    enabled: true
  - name: CryptoRecognizer
    type: predefined
    enabled: true

  # Keep US identity recognizers with high threshold
  - name: UsSsnRecognizer
    type: predefined
    enabled: true
  - name: UsItinRecognizer
    type: predefined
    enabled: true

  # Keep email (moderate noise, but useful)
  - name: EmailRecognizer
    type: predefined
    enabled: true

  # Keep phone with high threshold
  - name: PhoneRecognizer
    type: predefined
    enabled: true
```

Then call with:
```python
results = analyzer.analyze(
    text=body,
    language="en",
    score_threshold=0.5,
    allow_list=["127.0.0.1", "0.0.0.0", "localhost", "admin@localhost"]
)
```

This configuration:
- **Keeps**: Credit cards (Luhn-validated), IBANs (checksum-validated), SSNs, ITINs, emails, phones, crypto addresses
- **Drops**: Dates, IPs, URLs, MAC addresses (too noisy on code)
- **Threshold 0.5**: Filters bare-digit SSN matches (0.05), low-confidence date fragments
- **Allow list**: Suppresses known-safe patterns

**Expected false positive rate**: Low for checksum-validated entities, moderate for phones and emails, acceptable if the system is advisory (flagging to the monitor) rather than blocking.

### Recommended architecture

Layer Presidio as Layer 3 behind the secret-detection layers from `evaluation.md`:

```
response() hook:
  body = flow.response.text

  # Layer 1: Fast regex check for known secrets (~0.01ms)
  secrets = regex_scan(body)

  # Layer 2: detect-secrets for broader secret coverage (~1-5ms)
  if ENABLE_DETECT_SECRETS:
      secrets += detect_secrets_scan(body)

  # Layer 3: Presidio for PII (optional, ~50-200ms)
  if ENABLE_PII_SCAN:
      pii = presidio_scan(body)  # tuned config, high threshold

  # Report all findings to monitor
  if secrets or pii:
      report_to_monitor(secrets, pii)
```

Presidio adds the most latency (50-200ms with spaCy, 5-50ms regex-only). It should be optional and off by default until tuned against real agent traffic.

### Open questions

1. **What is the actual false positive rate on representative agent traffic?** This can only be answered by running Presidio on captured transcripts with the recommended config and manually reviewing results. This is the essential next step before enabling it in the proxy.
2. **Is spaCy NER worth the 500MB+ image overhead?** PERSON and LOCATION detection via NER is high-value (catches names being leaked) but also the highest false-positive source on code. Could start with regex-only mode and add NER later.
3. **Should Presidio run in-process or as a sidecar?** In-process avoids HTTP overhead but increases the mitmproxy addon's memory footprint. Sidecar is cleaner architecturally but adds network latency.
4. **How does `phonenumbers` library leniency interact with agent traffic?** The default leniency setting needs testing against real data. A leniency of 3 (strictest) might eliminate most phone false positives while still catching formatted numbers.
