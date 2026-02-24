# Regex and Heuristic-Based PII Detection — Evaluation for AI Agent Traffic

## Context

This evaluation answers the question: can we build a lightweight, high-precision PII detection layer using regex + checksums + heuristics (without NER/ML), analogous to how vendor-prefix regex solved the secret detection problem?

The companion documents cover secret detection (`evaluation.md`) and Presidio's full PII scanning capability (`presidio-pii-evaluation.md`). This document focuses specifically on the regex/checksum/heuristic layer for **structured PII** — data types with known formats that can be validated algorithmically.

**Traffic characteristics**: AI agent HTTP bodies containing code snippets, JSON payloads, base64 data, numeric IDs (build numbers, commit hashes, port numbers, timestamps), hex strings, version strings (`1.2.3.4`), and intermixed natural language.

---

## 1. Checksum-Validated Patterns (High Precision)

These patterns combine format regex with algorithmic validation. The checksum eliminates most false positives that would otherwise arise from coincidental numeric matches.

### 1A. Credit Card Numbers — Luhn Checksum

**Regex pattern** (covers Visa, Mastercard, Amex, Discover, JCB, Diners):

```python
# Match 13-19 digit sequences that could be card numbers
# Requires word boundaries to avoid matching within larger numbers
CC_PATTERN = re.compile(
    r'\b'
    r'(?:'
    r'4[0-9]{12}(?:[0-9]{3})?'        # Visa: 13 or 16 digits, starts with 4
    r'|5[1-5][0-9]{14}'                # Mastercard: 16 digits, 51-55
    r'|2(?:2[2-9][1-9]|2[3-9]\d|[3-6]\d{2}|7[01]\d|720)[0-9]{12}'  # Mastercard 2-series
    r'|3[47][0-9]{13}'                 # Amex: 15 digits, 34 or 37
    r'|6(?:011|5[0-9]{2})[0-9]{12}'    # Discover: 16 digits
    r'|3(?:0[0-5]|[68][0-9])[0-9]{11}' # Diners: 14 digits
    r'|(?:2131|1800|35\d{3})\d{11}'    # JCB: 15 or 16 digits
    r')'
    r'\b'
)

# Also match with separators (spaces or hyphens between groups)
CC_SEPARATED_PATTERN = re.compile(
    r'\b'
    r'(?:4[0-9]{3}|5[1-5][0-9]{2}|3[47][0-9]{2}|6(?:011|5[0-9]{2}))'
    r'[- ]?[0-9]{4}[- ]?[0-9]{4}[- ]?[0-9]{1,4}'
    r'\b'
)
```

**Validation logic**:

```python
def luhn_check(number: str) -> bool:
    """Luhn mod-10 checksum. Returns True if valid."""
    digits = [int(d) for d in number if d.isdigit()]
    if len(digits) < 13 or len(digits) > 19:
        return False
    checksum = 0
    for i, d in enumerate(reversed(digits)):
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        checksum += d
    return checksum % 10 == 0
```

**False positive analysis on code-heavy text**:

- Luhn checksum has a ~10% pass rate on random digit sequences (1 in 10 random numbers will pass mod-10). This is the theoretical floor.
- However, combining prefix validation (must start with 4, 5, 34, 37, 6011, 65, etc.) with Luhn on a 13-19 digit number reduces the effective FP rate dramatically.
- **Key risk**: Unix timestamps (10 digits) are too short to match 13+ digit patterns. Build numbers, commit counters, and database IDs are typically shorter. The 13-digit minimum length is a strong filter.
- **Remaining FP sources**: Long numeric strings in API responses (order IDs, tracking numbers, phone numbers) that happen to be 13-19 digits AND start with a valid prefix AND pass Luhn. FedEx tracking numbers are a known false positive (16 digits, some pass Luhn). Zendesk's `credit_card_sanitizer` gem documents this.
- **Mitigation**: Check digit grouping. Real card numbers appear as `XXXX XXXX XXXX XXXX` or `XXXX-XXXX-XXXX-XXXX`. Ungrouped 16-digit numbers in code (e.g., `ORDER_ID = "4532015112830366"`) are ambiguous — Luhn alone cannot distinguish. Context keywords (`card`, `visa`, `credit`, `payment`) help.

**Estimated FP rate on agent traffic**: Very low (<0.1%) for formatted card numbers with separators. Low but nonzero (~0.5-1%) for bare digit sequences that happen to be 16 digits + valid prefix + Luhn pass. Context checking reduces further.

**Library support**: `python-stdnum` provides `stdnum.luhn.validate()` — pure Python, no dependencies, LGPL-2.1+, latest release v2.2 (January 2026). Alternatively, Luhn is trivial to implement inline (10 lines).

### 1B. Social Security Numbers (US SSN) — Format + Area Validation

**Regex pattern**:

```python
SSN_PATTERN = re.compile(
    r'\b'
    r'(?!000|666|9\d{2})'   # Area: not 000, 666, or 900-999
    r'[0-9]{3}'
    r'[- ]?'
    r'(?!00)[0-9]{2}'        # Group: not 00
    r'[- ]?'
    r'(?!0000)[0-9]{4}'      # Serial: not 0000
    r'\b'
)
```

**Validation logic**:

```python
def validate_ssn(digits: str) -> bool:
    """Validate SSN area/group/serial rules."""
    clean = digits.replace('-', '').replace(' ', '')
    if len(clean) != 9 or not clean.isdigit():
        return False
    area = int(clean[:3])
    group = int(clean[3:5])
    serial = int(clean[5:])
    # Invalid areas
    if area == 0 or area == 666 or area >= 900:
        return False
    if group == 0:
        return False
    if serial == 0:
        return False
    return True
```

**Invalid area numbers**: 000, 666, 900-999 are never assigned. Prior to June 25, 2011, area numbers were geographically assigned and many ranges were unallocated, but the SSA's randomization since 2011 means the valid range is now 001-665 and 667-899.

**False positive analysis on code-heavy text**:

- **This is the hardest pattern.** A 9-digit number is extremely common in code: build numbers, commit counters, database IDs, Unix timestamps (10 digits but truncated versions exist), zip+4 codes, numeric identifiers.
- The area/group/serial validation eliminates approximately 12% of random 9-digit numbers (those starting with 000, 666, 900-999, having 00 group or 0000 serial).
- **Without context, FP rate is catastrophic.** Any 9-digit number `XXX-XX-XXXX` or bare `XXXXXXXXX` that passes the area/group/serial check will match.
- **Context is essential**: Require a context keyword (`ssn`, `social security`, `social_security`, `ss#`, `ss_number`, `taxpayer`) within N tokens of the match. Without context, bare SSN regex should NOT fire, or should fire at a very low confidence score (< 0.1).
- **Formatted vs bare**: `XXX-XX-XXXX` with hyphens is more suspicious than bare 9 digits — fewer things in code use that exact grouping. Even so, date-like patterns `202-50-1234` or ID-like patterns exist.

**Estimated FP rate on agent traffic**:
- With hyphens + context keywords: Low (~1-2%)
- With hyphens, no context: Moderate (~5-10%)
- Bare 9 digits, no context: Unacceptably high (>30%)
- Bare 9 digits + context: Moderate (~3-5%)

**Recommendation**: SSN detection MUST require context keywords. Bare 9-digit matching without context should be disabled entirely or scored at near-zero confidence.

### 1C. IBANs — Country Code + Check Digits + Length

**Regex pattern**:

```python
IBAN_PATTERN = re.compile(
    r'\b'
    r'[A-Z]{2}'              # Country code (2 uppercase letters)
    r'[0-9]{2}'              # Check digits
    r'[A-Z0-9]{11,30}'       # BBAN (Basic Bank Account Number)
    r'\b'
)
```

**Validation logic** (ISO 7064 Mod 97-10):

```python
def validate_iban(iban: str) -> bool:
    """Validate IBAN using mod-97 check digits."""
    clean = iban.replace(' ', '').replace('-', '').upper()
    if len(clean) < 15 or len(clean) > 34:
        return False
    # Country code must be valid ISO 3166-1 alpha-2
    country = clean[:2]
    if country not in VALID_COUNTRY_CODES:
        return False
    # Move first 4 chars to end, convert letters to numbers
    rearranged = clean[4:] + clean[:4]
    numeric = ''
    for char in rearranged:
        if char.isdigit():
            numeric += char
        else:
            numeric += str(ord(char) - ord('A') + 10)
    return int(numeric) % 97 == 1
```

**False positive analysis on code-heavy text**:

- Mod-97 checksum reduces FP rate to ~1% of random alphanumeric strings that happen to match the format.
- The country code validation further restricts: only valid 2-letter ISO country codes pass.
- Country-specific length validation (e.g., DE = 22, GB = 22, FR = 27) narrows further.
- **Risk in code**: Variable names, class names, or identifiers starting with valid country codes followed by digits could match the initial regex. But the mod-97 check eliminates nearly all of these.
- **Estimated FP rate**: Very low (<0.1%) after full validation.

**Library support**: `python-stdnum.iban` provides `validate()` with country-specific format checking. Also `schwifty` (LGPL-3.0) and `ibans` packages on PyPI.

### 1D. US EINs (Employer Identification Numbers)

**Regex pattern**:

```python
EIN_PATTERN = re.compile(
    r'\b'
    r'(?:0[1-6]|1[0-6]|2[0-7]|[345]\d|[68][0-8]|7[1-7]|9[0-58-9])'  # Valid prefix
    r'-?'
    r'\d{7}'
    r'\b'
)
```

**Validation logic**: EIN validation is prefix-only. The IRS publishes a list of valid 2-digit prefixes. There is no checksum. The valid prefixes are: 01-06, 10-16, 20-27, 30-39, 40-49, 50-59, 60-68, 70-77, 80-88, 90-95, 98-99.

**False positive analysis on code-heavy text**:

- EINs are 9 digits, same as SSNs. The same FP concerns apply: build numbers, timestamps, numeric IDs.
- The prefix validation is weaker than SSN area validation — most 2-digit prefixes are valid.
- The `XX-XXXXXXX` hyphenated format is the primary discriminator. Without the hyphen, an EIN is indistinguishable from any 9-digit number.
- **Without context, essentially useless.** Context keywords: `ein`, `employer identification`, `tax id`, `fein`, `federal employer`.

**Estimated FP rate on agent traffic**:
- With hyphen + context: Low (~2-3%)
- Without context: Unacceptably high (>40%)

**Recommendation**: EIN detection should require BOTH the hyphenated format AND context keywords.

### 1E. Passport Numbers

**Assessment**: Passport numbers are country-specific with no universal format and no checksum (except for the Machine Readable Zone, which is rarely transmitted in API traffic).

**Examples**:
- US: 9 digits (no checksum) — indistinguishable from SSN/EIN without context
- UK: 9 digits (no checksum)
- India: 1 letter + 1 digit (1-9) + 5 digits + 1 digit (1-9), e.g., `A1234567`
- Germany: varies, alphanumeric

**Verdict**: Passport number detection via regex alone is NOT feasible for most countries. The formats are too generic (9 digits for US/UK) or too varied (country-specific alphanumeric patterns). Only worthwhile for countries with highly structured formats (India) and only with context keywords (`passport`, `travel document`).

**Recommendation**: Skip passport detection in the regex layer. Defer to NER if needed.

---

## 2. Format-Validated Patterns (Medium Precision)

### 2A. Email Addresses

**Practical regex** (simpler than RFC 5322, catches 99.9% of real emails):

```python
EMAIL_PATTERN = re.compile(
    r'\b'
    r'[a-zA-Z0-9._%+-]+'
    r'@'
    r'[a-zA-Z0-9.-]+'
    r'\.[a-zA-Z]{2,}'
    r'\b'
)
```

**Full RFC 5322 regex**: The complete RFC 5322 regex is enormous and matches edge cases (quoted local parts, IP address domains) that are irrelevant for PII detection. The simplified pattern above is universally recommended.

**False positive analysis on code-heavy text**:

- **Git metadata**: Commit messages contain `author <user@example.com>` — these are real emails, whether they are PII depends on context.
- **package.json / pyproject.toml**: Maintainer email addresses.
- **Import paths**: Python/Java import paths do not contain `@`, so no risk.
- **Code comments**: `// Contact: admin@example.com` — real email, legitimate detection.
- **Test fixtures**: `test@example.com`, `user@test.local` — false positives in test data. Mitigate with allow list for `@example.com`, `@test.local`, `@localhost`.
- **noreply addresses**: `noreply@github.com` — legitimate detection but low PII risk.

**FP rate**: Low for non-email patterns. The `@` + valid TLD requirement is a strong discriminator. The real question is whether detected emails are PII vs. functional data — this is a classification problem, not a FP problem.

**Enhancement**: Use `tldextract` to validate that the domain has a real TLD. This eliminates `user@internal-host`, `var@module.name`.

### 2B. Phone Numbers

**Raw regex approach**:

```python
# US NANP format
US_PHONE_PATTERN = re.compile(
    r'\b'
    r'(?:\+?1[- .]?)?\(?[2-9]\d{2}\)?[- .]?\d{3}[- .]?\d{4}'
    r'\b'
)

# E.164 international
E164_PATTERN = re.compile(
    r'\+[1-9]\d{6,14}\b'
)
```

**FP analysis for raw regex**: Very high on code-heavy text. `"port": 8080`, `localhost:3000`, version strings `1.2.3.4`, timestamps, build numbers — phone regex matches aggressively on digit sequences.

**Google libphonenumber / Python `phonenumbers` library**:

The Python `phonenumbers` library (port of Google's libphonenumber) provides `PhoneNumberMatcher` for text scanning with validation:

```python
import phonenumbers

text = "Call me at (415) 555-1234 or +44 20 7946 0958"
for match in phonenumbers.PhoneNumberMatcher(text, "US"):
    number = match.number
    if phonenumbers.is_valid_number(number):
        print(f"Found: {phonenumbers.format_number(number, phonenumbers.PhoneNumberFormat.E164)}")
```

**PhoneNumberMatcher features**:

- **Leniency levels** (POSSIBLE, VALID, STRICT_GROUPING, EXACT_GROUPING): Higher leniency = more results = more FP. `VALID` or stricter recommended.
- **Built-in FP protection**: Rejects matches surrounded by Latin letters, rejects date-like patterns (e.g., `211-227 (2003)`), rejects timestamp patterns, checks bracket matching.
- **Context validation**: At VALID leniency or stricter, rejects numbers preceded by currency symbols, percent signs, and other non-phone punctuation.
- **Region-aware**: `phonenumbers.parse()` validates against country-specific numbering plans.

**How does it handle code-like input?**

| Input | PhoneNumberMatcher result (US region, VALID leniency) |
|---|---|
| `"port": 8080` | NOT matched — 4 digits too short for any valid number |
| `"version": "3.14.1"` | NOT matched — dots between single/double digits not a valid phone format |
| `localhost:3000` | NOT matched — colon after non-digit text |
| `1234567890` | POSSIBLE match as US number — depends on leniency. At VALID, may match if it forms a valid US number. |
| `(415) 555-1234` | Matched correctly — standard US format |
| `+44 20 7946 0958` | Matched correctly — valid UK number |
| `BUILD_NUMBER=2024021501` | NOT matched — 13 digits, no valid country interpretation |
| `id: 5551234567` | POSSIBLE match — 10 digits starting with 555. At STRICT_GROUPING, rejected (not formatted). |

**Performance**: `phonenumbers.parse()` is ~0.1-0.5ms per candidate. `PhoneNumberMatcher` iterating over text is ~1-10ms depending on text length and number of candidates. Acceptable for per-request scanning.

**Recommendation**: Use `phonenumbers.PhoneNumberMatcher` with VALID or STRICT_GROUPING leniency instead of raw regex. It provides dramatically better FP rates than regex alone. The library is actively maintained (latest release February 2026), pure Python, Apache-2.0 licensed, ~10MB installed.

### 2C. Physical Addresses

**Assessment**: Regex-based address detection is NOT feasible for general text.

- US street addresses have vast format variation: `123 Main St`, `123 Main Street`, `123 Main St.`, `123 Main Street, Apt 4`, `PO Box 123`, `One World Trade Center`.
- ZIP code patterns (`\b\d{5}(-\d{4})?\b`) match far too many 5-digit numbers in code (port numbers, error codes, quantities, pagination offsets).
- State abbreviation + ZIP (`CA 94105`) is slightly more discriminating but still matches code comments, configuration values.
- International address formats are completely different.

The comparison between regex and NER for address parsing is well-documented: regex handles validation of known-format addresses (structured data, form fields) but fails on extraction from unstructured text. NER models like spaCy, libpostal, or usaddress handle the extraction problem.

**Verdict**: Physical address detection belongs in the NER layer, not the regex layer. The only regex-viable component is ZIP code + state abbreviation WITH context keywords (`address`, `ship to`, `deliver`, `location`).

### 2D. Dates of Birth

**Assessment**: Regex-based DOB detection is NOT feasible.

Date patterns are ubiquitous in code-heavy text: timestamps, log entries, version dates, release dates, expiration dates, build dates. The format `MM/DD/YYYY` or `YYYY-MM-DD` matches thousands of non-DOB dates in typical API traffic.

The only discriminator is context keywords (`birthday`, `date of birth`, `dob`, `born`, `age`). Even with context, date regex fires on metadata like `"created_at": "1990-05-15"` which could be a DOB or a creation timestamp.

**Verdict**: DOB detection should only fire when explicit context keywords are present AND the detected date is plausibly a human birth date (year between 1920 and current_year - 13). Even then, FP rate is moderate. Better suited for JSON key-name heuristics (section 3) than raw text regex.

---

## 3. Context-Aware Heuristics

### 3A. Surrounding Text Context

Context keywords within N tokens of a candidate match dramatically reduce false positives. The approach:

```python
CONTEXT_WINDOWS = {
    "SSN": {
        "keywords": ["ssn", "social security", "social_security", "ss#", "ss_number", "taxpayer"],
        "window": 50,  # characters before/after
        "boost": 0.5,  # score boost when context found
    },
    "CREDIT_CARD": {
        "keywords": ["card", "credit", "visa", "mastercard", "amex", "payment", "cc", "cvv"],
        "window": 80,
        "boost": 0.3,
    },
    "PHONE": {
        "keywords": ["phone", "call", "mobile", "cell", "tel", "fax", "contact", "dial"],
        "window": 50,
        "boost": 0.4,
    },
    "EIN": {
        "keywords": ["ein", "employer identification", "tax id", "fein", "federal employer"],
        "window": 50,
        "boost": 0.5,
    },
}

def check_context(text: str, match_start: int, match_end: int, pii_type: str) -> float:
    """Return context boost score (0.0 if no context found)."""
    config = CONTEXT_WINDOWS[pii_type]
    window_start = max(0, match_start - config["window"])
    window_end = min(len(text), match_end + config["window"])
    window_text = text[window_start:window_end].lower()
    for keyword in config["keywords"]:
        if keyword in window_text:
            return config["boost"]
    return 0.0
```

### 3B. JSON Key Name Heuristics

JSON is the dominant format in agent HTTP traffic. Key names provide extremely high-signal context:

```python
import json

HIGH_SIGNAL_KEYS = {
    "ssn": "SSN",
    "social_security": "SSN",
    "social_security_number": "SSN",
    "credit_card": "CREDIT_CARD",
    "card_number": "CREDIT_CARD",
    "cc_number": "CREDIT_CARD",
    "phone": "PHONE",
    "phone_number": "PHONE",
    "mobile": "PHONE",
    "telephone": "PHONE",
    "email": "EMAIL",
    "email_address": "EMAIL",
    "iban": "IBAN",
    "bank_account": "IBAN",
    "ein": "EIN",
    "tax_id": "EIN",
    "date_of_birth": "DOB",
    "dob": "DOB",
    "birthday": "DOB",
    "passport": "PASSPORT",
    "passport_number": "PASSPORT",
    "address": "ADDRESS",
    "street_address": "ADDRESS",
    "mailing_address": "ADDRESS",
    "home_address": "ADDRESS",
}

def scan_json_keys(data: dict, path: str = "") -> list:
    """Recursively scan JSON for PII-indicative key names."""
    findings = []
    for key, value in data.items():
        key_lower = key.lower().replace("-", "_")
        if key_lower in HIGH_SIGNAL_KEYS:
            pii_type = HIGH_SIGNAL_KEYS[key_lower]
            findings.append({
                "type": pii_type,
                "key": f"{path}.{key}" if path else key,
                "value": value,
                "confidence": 0.8,  # High confidence from key name alone
            })
        if isinstance(value, dict):
            findings.extend(scan_json_keys(value, f"{path}.{key}" if path else key))
        elif isinstance(value, list):
            for i, item in enumerate(value):
                if isinstance(item, dict):
                    findings.extend(scan_json_keys(item, f"{path}.{key}[{i}]"))
    return findings
```

**Why this works well for agent traffic**: AI agents call tool APIs that return structured JSON. The API responses often include PII fields with descriptive key names. A JSON payload like `{"customer": {"phone": "4155551234", "ssn": "123-45-6789"}}` is trivially detected by key-name scanning, with near-zero FP risk.

**Limitations**: Obfuscated key names (`"f1": "4155551234"`), base64-encoded values, nested strings (JSON inside a string value).

### 3C. Negative Context (FP Suppression)

Suppress matches when certain anti-context patterns are present:

```python
NEGATIVE_CONTEXT = {
    "PHONE": ["port", "pid", "process", "version", "build", "code", "status", "error", "id:", "ref:"],
    "SSN": ["build", "commit", "version", "id", "hash", "code", "order", "ref", "ticket"],
    "CREDIT_CARD": ["order_id", "tracking", "reference", "transaction_id", "fedex", "ups"],
}

def check_negative_context(text: str, match_start: int, match_end: int, pii_type: str) -> bool:
    """Return True if negative context suggests this is NOT PII."""
    if pii_type not in NEGATIVE_CONTEXT:
        return False
    window_start = max(0, match_start - 40)
    window_end = min(len(text), match_end + 20)
    window_text = text[window_start:window_end].lower()
    for anti_keyword in NEGATIVE_CONTEXT[pii_type]:
        if anti_keyword in window_text:
            return True
    return False
```

This is the mechanism Presidio lacks. Presidio's context enhancement only boosts scores for positive context — it never reduces scores for negative context. A custom layer can do both.

### 3D. Existing Context-Aware Libraries

**Microsoft Presidio** (discussed in companion doc): Has context words that boost confidence, but no negative context. Requires spaCy for lemmatization in its default context enhancer. Can be used in regex-only mode but loses context enhancement unless you build a custom `ContextAwareEnhancer`.

**scrubadub** (v2.0.1, maintenance status: mixed signals — LeapBeyond says active, Snyk says inactive): Regex-based detectors for credit cards, SSNs, emails, phones, URLs. `RegexDetector` base class for custom patterns. No context awareness. ~40K weekly PyPI downloads. MIT license. Lightweight but no smarter than bare regex.

**detect-secrets** (Yelp): Secret-focused, not PII-focused. But its filter pipeline architecture (baseline, inline allowlist, exclude patterns, custom filters) is an excellent model for building false positive suppression in a PII detector.

---

## 4. Existing Lightweight PII Regex Libraries

### 4A. commonregex-improved

- **Repository**: https://github.com/brootware/commonregex-improved
- **PyPI**: `commonregex-improved`
- **Last commit**: December 2022 (inactive)
- **License**: MIT
- **What it detects**: Dates, times, phone numbers, links, emails, IPv4/IPv6, hex colors, credit cards, Bitcoin addresses, SSNs, ISBN, street addresses, ZIP codes, PO boxes, MD5/SHA1/SHA256 hashes, MAC addresses, IBANs, git repos, prices
- **API**: `crim.CommonRegex(text)` returns object with `.credit_cards`, `.ssn_numbers`, `.emails`, `.phones`, etc.
- **FP behavior on code**: No validation beyond regex. No Luhn for credit cards. No area validation for SSNs. No mod-97 for IBANs. Will produce high FP rates on any numeric-heavy text.
- **Verdict**: Useful as a regex pattern reference but NOT suitable for production PII detection. No checksum validation, no context awareness, no maintenance. Use its patterns as a starting point, add your own validation.

### 4B. pii-codex

- **Repository**: https://github.com/EdyVision/pii-codex
- **PyPI**: `pii-codex` (v0.4.6)
- **Published in**: Journal of Open Source Software (academic)
- **What it does**: PII detection + severity categorization. Built on Microsoft Presidio under the hood. Also supports Azure Cognitive Services and AWS Comprehend as detection backends.
- **License**: MIT
- **FP behavior**: Inherits Presidio's FP characteristics. The library adds severity scoring (Non-Identifiable / Semi-Identifiable / Identifiable) but does not improve precision.
- **Verdict**: A Presidio wrapper with severity classification. Does not solve the FP problem — it inherits it. Not useful for a lightweight regex-only approach since it pulls in Presidio as a dependency.

### 4C. piicatcher

- **Repository**: https://github.com/tokern/piicatcher
- **PyPI**: `piicatcher` (v0.20.2, December 2024)
- **What it does**: Scans databases and data warehouses for PII. Uses two methods: regex matching against column names AND NLP-based analysis of sample data via spaCy.
- **Supported sources**: PostgreSQL, MySQL, SQLite, Redshift, Athena, Snowflake, BigQuery.
- **License**: Apache-2.0
- **Verdict**: **Database-focused, not general text.** Scans column names and sample values from database tables. Not designed for HTTP body scanning. Architecture is wrong for our use case.

### 4D. piiregex

- **Repository**: https://github.com/Poogles/piiregex
- **PyPI**: `piiregex`
- **What it detects**: Emails, phones (US/UK), credit cards, Bitcoin, dates, times, IPv4/IPv6, street addresses, postcodes
- **API**: `parsed = PiiRegex(text); parsed.emails; parsed.phones`
- **Maintenance**: Very low activity (6 commits total, no recent releases)
- **FP behavior**: Same as commonregex — regex only, no validation.
- **Verdict**: Essentially a fork of commonregex focused on PII. No validation, no maintenance. Not suitable.

### 4E. scrubadub

- **Repository**: https://github.com/LeapBeyond/scrubadub
- **PyPI**: `scrubadub` (v2.0.1)
- **License**: MIT
- **What it detects (regex-only, no extra packages)**: Credentials, credit cards, driver licenses, emails, national insurance numbers (UK), phones, postal codes, SSNs, tax references, Twitter handles, URLs, vehicle license plates
- **Architecture**: Modular — `Filth` objects (detected PII), `Detector` objects (detection logic), `PostProcessor` objects (alteration). `RegexDetector` base class makes custom patterns easy.
- **Maintenance**: Unclear — LeapBeyond claims active support, Snyk classifies as inactive. ~40K weekly downloads.
- **FP behavior on code**: Similar to commonregex for most detectors. CreditCardDetector does NOT do Luhn validation by default. PhoneDetector uses regex, not libphonenumber.
- **Optional packages**: `scrubadub_spacy` (NER), `scrubadub_address` (address detection via libpostal).
- **Verdict**: Better architecture than commonregex (modular, extensible) but still no checksum validation. The `RegexDetector` base class is a decent starting point for custom detectors with validation. Not production-ready without significant augmentation.

### 4F. pii-extract-plg-regex (PIISA project)

- **Repository**: https://github.com/piisa/pii-extract-plg-regex
- **PyPI**: `pii-extract-plg-regex`
- **What it does**: Regex-based PII detection plugin for the PIISA framework. Detection tasks organized by language and country. Uses `python-stdnum` and `python-phonenumbers` as validation backends.
- **Architecture**: Plugin, not standalone. Requires `pii-extract-base` framework.
- **Verdict**: Most sophisticated regex-based PII library found. Actually uses `python-stdnum` for checksum validation and `python-phonenumbers` for phone validation — exactly the composite approach we are evaluating. However, locked into the PIISA framework with no standalone API.

### 4G. Summary table

| Library | Checksum validation | Context awareness | Phone validation | Maintained | Standalone API | Verdict |
|---|---|---|---|---|---|---|
| commonregex-improved | No | No | No | No (2022) | Yes | Pattern reference only |
| pii-codex | Via Presidio | Via Presidio | Via Presidio | Moderate | Yes | Presidio wrapper |
| piicatcher | N/A | N/A | N/A | Yes | Yes | Database-only |
| piiregex | No | No | No | No | Yes | Not suitable |
| scrubadub | No | No | No | Unclear | Yes | Extensible base |
| pii-extract-plg-regex | Yes (stdnum) | Yes | Yes (phonenumbers) | Moderate | No (framework plugin) | Best approach, wrong interface |

**Key finding**: No existing lightweight library combines regex + checksum validation + context awareness + phone number validation in a standalone package with a simple API. The closest is `pii-extract-plg-regex` but it requires the PIISA framework. We need to build our own composite, using the validation backends (`python-stdnum`, `phonenumbers`) directly.

---

## 5. The Google libphonenumber Question

### Can `phonenumbers` be used as a phone number scanner on full text?

**Yes.** `PhoneNumberMatcher` is specifically designed for this:

```python
import phonenumbers

text = "Call (415) 555-1234 or reach me at +44 20 7946 0958. Server on port 8080."
for match in phonenumbers.PhoneNumberMatcher(text, "US"):
    print(f"Found: {match.raw_string} -> valid={phonenumbers.is_valid_number(match.number)}")
```

### False positive behavior

`PhoneNumberMatcher` with VALID leniency has good built-in FP protection:

- Rejects matches preceded by Latin letters (catches variable names ending in digits)
- Rejects date/timestamp patterns
- Rejects numbers with currency symbols or percent signs nearby
- Validates against country-specific numbering plans

However, it is NOT perfect:

- A bare 10-digit US number like `4155551234` in JSON may match if it forms a valid US number
- The leniency parameter controls the trade-off: VALID catches most real numbers, STRICT_GROUPING requires proper formatting (parentheses, dashes, spaces)

### Performance

- `PhoneNumberMatcher` on a 1KB text: ~1-5ms
- `phonenumbers.parse()` per candidate: ~0.1-0.5ms
- `phonenumbers.is_valid_number()`: ~0.01ms (cached metadata lookup)
- Memory: ~10-15MB for the metadata tables

### Practical scanner approach

Two-stage: fast regex to extract candidates, then `phonenumbers` to validate:

```python
import re
import phonenumbers

# Stage 1: Fast candidate extraction via regex
PHONE_CANDIDATE = re.compile(
    r'(?:\+\d{1,3}[- ]?)?\(?\d{2,4}\)?[- .]?\d{3,4}[- .]?\d{3,4}(?:\s*(?:ext|x|extension)\s*\d{1,5})?'
)

def scan_phones(text: str, default_region: str = "US") -> list:
    """Two-stage phone detection: regex candidates -> libphonenumber validation."""
    findings = []
    for candidate in PHONE_CANDIDATE.finditer(text):
        raw = candidate.group()
        try:
            parsed = phonenumbers.parse(raw, default_region)
            if phonenumbers.is_valid_number(parsed):
                # Additional FP check: verify it is not just a port or ID
                prefix = text[max(0, candidate.start()-20):candidate.start()].lower()
                if any(anti in prefix for anti in ["port", "pid", "code", "status", "error"]):
                    continue
                findings.append({
                    "raw": raw,
                    "e164": phonenumbers.format_number(parsed, phonenumbers.PhoneNumberFormat.E164),
                    "start": candidate.start(),
                    "end": candidate.end(),
                })
        except phonenumbers.NumberParseException:
            continue  # Not a valid number
    return findings
```

Or simply use `PhoneNumberMatcher` directly — it already does the candidate extraction internally:

```python
def scan_phones_matcher(text: str, region: str = "US", leniency=phonenumbers.Leniency.VALID) -> list:
    findings = []
    for match in phonenumbers.PhoneNumberMatcher(text, region, leniency=leniency):
        if phonenumbers.is_valid_number(match.number):
            findings.append({
                "raw": match.raw_string,
                "e164": phonenumbers.format_number(match.number, phonenumbers.PhoneNumberFormat.E164),
                "start": match.start,
                "end": match.end,
            })
    return findings
```

**Recommendation**: Use `PhoneNumberMatcher` directly with VALID leniency. It handles the hard cases better than a custom regex + parse pipeline. Add negative context checking on top for agent-specific FP patterns (port numbers, build IDs).

---

## 6. Composite Approach Assessment

### The layered architecture

```
Input: HTTP request/response body (string)

Layer 0: Content-type check
  - If JSON, parse and use key-name heuristics (section 3B)
  - Extract string values for scanning

Layer 1: Checksum-validated patterns (HIGH confidence, ~0.1ms)
  - Credit cards: regex + Luhn validation
  - IBANs: regex + mod-97 validation
  - Crypto addresses: regex + Base58Check / Bech32 validation

Layer 2: Format + context-validated patterns (~1-5ms)
  - SSNs: regex + area validation + REQUIRED context keywords
  - EINs: regex + prefix validation + REQUIRED context keywords
  - Emails: simplified RFC 5322 regex + TLD validation
  - Phones: phonenumbers.PhoneNumberMatcher (VALID leniency) + negative context

Layer 3: JSON key-name heuristics (if JSON, ~0.1ms)
  - Scan key names for PII-indicative terms
  - Flag values under suspicious keys regardless of format

Layer 4: Negative context suppression (post-filter)
  - Remove findings near anti-keywords (port, version, build, pid, etc.)
  - Remove findings in known-safe patterns (localhost, 0.0.0.0, test fixtures)
```

### Expected FP rates per category

| PII Type | Detection Method | Estimated FP Rate on Agent Traffic | Confidence |
|---|---|---|---|
| Credit cards | Regex + Luhn + prefix | <0.1% (formatted), ~1% (bare digits) | High |
| IBANs | Regex + mod-97 + country | <0.1% | High |
| SSNs | Regex + area validation + context REQUIRED | ~2-5% (with context), unacceptable (without) | Medium |
| EINs | Regex + prefix + context REQUIRED | ~3-5% (with context) | Medium |
| Emails | Simplified regex + TLD | <1% (for matching), high for classification | High |
| Phones | libphonenumber VALID + negative context | ~2-5% | Medium |
| DOB (dates) | Context keywords only | ~5-10% | Low |
| Addresses | NOT FEASIBLE via regex | N/A | N/A |
| Names | NOT FEASIBLE via regex | N/A | N/A |

### What this approach MISSES entirely

These PII categories **cannot be detected by regex/heuristics** and require NER or ML:

1. **Personal names** — No format, no checksum, no reliable pattern. "Baker" is a name or a code reference. "Jackson" is a person or a library.
2. **Physical addresses** — Too much format variation. ZIP codes alone are useless without context that NER provides.
3. **Health/medical data** — Diagnosis codes (ICD-10) have format but are domain-specific. Medical narratives require NER.
4. **Biometric data** — No textual pattern.
5. **Racial/ethnic data** — Requires NER/classification.
6. **Religious/political data** — Requires NER/classification.
7. **Generic identifiers** — Account numbers, policy numbers, and other institution-specific IDs have no universal format.

### The "regex for structured PII, NER for unstructured PII" architecture

**Yes, this is the right split.** The reasoning:

**Regex/checksum layer handles**:
- Data types with KNOWN FORMATS (credit cards, SSNs, IBANs, emails, phone numbers)
- Data types with ALGORITHMIC VALIDATION (Luhn, mod-97, numbering plans)
- Runs in <5ms, no model loading, no GPU, no heavy dependencies
- FP rate controllable via checksum + context + negative context
- Deterministic and debuggable

**NER/ML layer handles**:
- Data types with NO FORMAT (names, addresses, health data)
- Data that requires SEMANTIC UNDERSTANDING (is "Baker" a name or a variable?)
- Runs in 50-1000ms+ depending on model, requires spaCy or similar
- FP rate dependent on model quality and training data
- Probabilistic and harder to debug

**The practical implication for lobster-pot**:

- Ship with regex/checksum layer for structured PII (Layer 1-3 above)
- Make NER layer (Presidio with spaCy, or standalone spaCy) optional
- The regex layer catches the most dangerous structured PII (financial data, government IDs) with high precision
- The NER layer catches names and addresses with lower precision but higher recall
- Users who need name/address detection opt into the NER layer and accept its FP characteristics

### Recommended validation backend libraries

| Purpose | Library | License | Size | Notes |
|---|---|---|---|---|
| Luhn checksum | `python-stdnum` | LGPL-2.1+ | <1MB | Also validates IBAN, EIN, and 200+ other formats |
| Phone validation | `phonenumbers` | Apache-2.0 | ~10MB | Google libphonenumber port, gold standard |
| TLD validation | `tldextract` | BSD-3 | <1MB | Already a Presidio dependency |
| IBAN validation | `python-stdnum` | LGPL-2.1+ | (same package) | mod-97 + country-specific format |
| All of the above | Custom ~200 lines | N/A | N/A | Thin wrapper over the above libraries |

### Total dependency footprint

- `python-stdnum`: ~1MB, pure Python, no native deps
- `phonenumbers` (or `phonenumberslite`): ~10MB, pure Python, no native deps
- `tldextract`: ~1MB, pure Python

Total: ~12MB. Compare to Presidio + spaCy `en_core_web_lg`: ~700MB+.

---

## Key Findings Summary

1. **Checksum-validated patterns (credit cards, IBANs) achieve <0.1% FP rate.** Luhn and mod-97 are the secret weapons. These should always be in the detection pipeline.

2. **SSNs and EINs REQUIRE context keywords.** Without context, 9-digit number matching is catastrophic on code-heavy text. With context, FP rates drop to 2-5%.

3. **Phone detection REQUIRES libphonenumber, not raw regex.** The `phonenumbers` library's `PhoneNumberMatcher` with VALID leniency provides dramatically better precision than regex alone. Worth the ~10MB dependency.

4. **JSON key-name scanning is high-signal and nearly free.** Agent traffic is JSON-heavy. A lookup table of PII-indicative key names catches structured PII that format-based scanning might miss.

5. **Negative context is as important as positive context.** Suppressing matches near "port", "version", "build", "pid" reduces FP rates significantly. This is something Presidio does not do.

6. **No existing library does this well in a standalone package.** The closest is `pii-extract-plg-regex` (uses stdnum + phonenumbers) but it requires the PIISA framework. We need to build ~200 lines of composite detection code using the validation libraries directly.

7. **Names, addresses, and health data CANNOT be detected this way.** These require NER/ML and should remain in the optional Presidio/spaCy layer.

8. **The total dependency footprint is ~12MB** vs ~700MB+ for Presidio + spaCy. The regex layer is 50-100x smaller and 10-100x faster.

9. **This is the "vendor-prefix regex" equivalent for PII**: just as secret detection achieved near-zero FP by matching specific vendor prefixes (AKIA, ghp_, sk-), PII detection can achieve low FP by matching specific formats with algorithmic validation. The analogy holds for structured PII but breaks down for unstructured PII (names, addresses).
