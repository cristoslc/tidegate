# Sensitive Data Categories

## Detectable with high confidence (pattern-based)

These have structural signatures that regex + algorithmic validation match reliably. All scanning runs on all outbound values — no field-level classification needed.

| Category | Examples | Detection method | Why it matters |
|---|---|---|---|
| **Credentials** | API keys, tokens, passwords | Vendor-prefix regex (AWS `AKIA`, Slack `xoxb-`, GitHub `ghp_`, etc.) | Account compromise |
| **Financial instruments** | Credit card numbers, IBANs | Regex + Luhn/mod-97 checksum (zero false positives) | Direct financial harm |
| **Government identifiers** | SSNs, EINs (with context keywords) | Regex + area validation + required context | Identity theft |

L2 patterns (Luhn, IBAN, SSN) are **zero false-positive by design** — they use mathematical checksums. This is why blob scanning works: running these checks on every outbound value, including channel IDs and commit SHAs, produces no spurious alerts.

## Detectable with low confidence

| Category | Examples | Why detection is unreliable |
|---|---|---|
| **Phone numbers** | US/international formats | Port numbers, version strings, numeric IDs trigger false positives |
| **Email addresses** | user@domain.com | Legitimate in almost every API call — accurate but not actionable |
| **Person names** | First/last names | NER fires on CamelCase code identifiers |

## Not detectable by pattern matching

| Category | Examples | Why it's undetectable |
|---|---|---|
| **Proprietary code** | Source code from workspace files | No pattern distinguishes proprietary from public code |
| **Private conversation content** | User messages, discussion history | Free-form natural language, no structural marker |
| **Personal documents** | Tax returns, medical records (text content) | Unstructured text |
| **Internal infrastructure** | Hostnames, network topology, configs | Varies too widely for pattern matching |
