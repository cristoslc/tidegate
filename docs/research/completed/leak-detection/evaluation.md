# Leak Detection for AI Agent Traffic — Secret Detection Tools

## Context

Lobster-pot's mitmproxy addon inspects HTTP request/response bodies passing through an AI agent's forward proxy. The traffic contains code snippets, JSON payloads, base64-encoded data, numeric IDs, hex hashes, version strings, and structured data.

This evaluation covers **secret detection** (API keys, tokens, credentials) — one half of the leak detection problem. PII detection (names, addresses, phone numbers, financial data) is covered in a separate evaluation (`pii-detection-evaluation.md`) and in the Presidio deep-dive (`presidio-pii-evaluation.md`).

## Scope: this document

**Secret detection** (API keys, tokens, passwords, private keys): Purpose-built tools exist using format-specific regex (e.g., `sk-...`, `ghp_...`, `AKIA...`), entropy analysis, and sometimes live verification. Low false positive rate on code because they match specific vendor prefixes, not generic numeric patterns.

**Not covered here**: PII detection (names, SSNs, credit cards, addresses, phone numbers, health data). See companion documents. Both are primary concerns for lobster-pot — the agent handles user data that includes PII as part of normal operation, and exfiltration of either secrets or PII is a data breach.

---

## Candidate 1: detect-secrets (Yelp)

**Repository**: https://github.com/Yelp/detect-secrets
**Language**: Python
**License**: Apache-2.0
**Latest release**: v1.5.0 (May 6, 2024)
**Stars**: ~3.7k

### What it detects

26 built-in plugins covering:

- **Vendor-specific formats**: AWS keys (`AKIA...`), GitHub tokens (`ghp_...`, `gho_...`), GitLab tokens, Stripe keys (`sk_live_...`), Slack tokens, Twilio keys, SendGrid, Mailchimp, Discord, Telegram, OpenAI (`sk-...`), PyPI tokens, npm tokens, Artifactory, Azure Storage, IBM Cloud, Cloudant, SoftLayer, Square OAuth
- **Structural patterns**: JWT (`eyJ...`), private keys (`-----BEGIN RSA PRIVATE KEY-----`), basic auth in URLs
- **Generic detection**: Base64 high-entropy strings (threshold 4.5), hex high-entropy strings (threshold 3.0), keyword-based detection (scans for variable names like `password`, `secret`, `api_key`)

### False positive filtering

Strong. Multiple layers:

1. **Baseline files**: `.secrets.baseline` tracks known findings; subsequent scans only report new secrets
2. **Inline allowlisting**: `# pragma: allowlist secret` comments
3. **CLI filters**: `--exclude-lines`, `--exclude-files`, `--exclude-secrets` with regex patterns
4. **Custom filter plugins**: Python functions injected into the filter pipeline
5. **Numeric string penalty**: The HexHighEntropyString plugin applies a mathematical penalty to all-digit strings, explicitly acknowledging that numeric sequences produce excessive false positives
6. **Quoted string requirement**: High entropy detection requires strings to be inside quotes by default, reducing noise from arbitrary text

### Python library usage

Yes, first-class support:

```python
from detect_secrets.core.scan import scan_line
from detect_secrets.settings import default_settings

with default_settings():
    secrets = scan_line("api_key = 'AKIAIOSFODNN7EXAMPLE'")
    for secret in secrets:
        print(secret.type, secret.secret_value)
```

The `scan_line()` function is purpose-built for scanning arbitrary strings (not files). It disables file-validation filters since there is no filename context. The `SecretsCollection` API also supports `scan_file()` and `scan_diff()`.

### False positive behavior on code-like data

| Input type | Behavior |
|---|---|
| Version numbers (e.g., `3.12.1`) | Low risk: hex entropy detector has numeric penalty, base64 detector requires sufficient length/entropy |
| Port numbers (e.g., `8080`, `443`) | Low risk: too short to trigger entropy detectors |
| Numeric IDs (e.g., `1234567890`) | Low risk: numeric penalty in hex entropy detector |
| Base64 encoded data | MODERATE risk: Base64HighEntropyString will fire on high-entropy base64 regardless of whether it is a secret. This is the main false positive source. |
| Hex hashes (SHA-256, etc.) | MODERATE risk: HexHighEntropyString will fire on long hex strings above entropy threshold 3.0 |
| Variable names like `password` | HIGH risk: KeywordDetector fires on any line containing `password =`, `secret:`, etc., regardless of value. This plugin should be disabled for proxy use. |
| JWT tokens | Correctly detected: JwtTokenDetector matches the `eyJ` prefix structure |

### Performance

- No published benchmarks, but architecture is lightweight: regex + Shannon entropy calculation per line
- `scan_line()` processes a single string through the plugin pipeline — expected sub-millisecond for short strings, low single-digit milliseconds for large payloads
- Pure Python: no native dependencies required (optional `pyahocorasick` for keyword optimization)
- Memory: minimal — no models loaded, just compiled regex patterns

### Maintenance assessment

- Last release 9 months ago (May 2024) — moderately active
- Release cadence: roughly every 6-12 months
- 1,449 commits, 90 open issues
- Yelp-maintained, production-quality code
- Risk: not abandoned, but not rapidly evolving either. Vendor-specific detectors may lag behind new API key formats.

### Integration with mitmproxy

Excellent. Both are Python. The addon would:

1. `pip install detect-secrets` in the mitmproxy Docker image
2. Import `scan_line` and `default_settings`
3. Call `scan_line()` on request/response body strings within the `request()`/`response()` hooks
4. Disable the KeywordDetector plugin (too noisy for code) and potentially lower entropy thresholds

### Verdict

**Strong candidate for the proxy use case.** The `scan_line()` API is exactly what is needed. Vendor-specific detectors have low false positive rates. The main concern is entropy-based detection on base64/hex data (tunable) and the KeywordDetector (disable it). Python-native makes integration trivial.

---

## Candidate 2: TruffleHog (Trufflehog Security)

**Repository**: https://github.com/trufflesecurity/trufflehog
**Language**: Go
**License**: AGPL-3.0
**Latest release**: v3.93.4 (February 19, 2025)
**Stars**: ~24.6k

### What it detects

879 detectors covering cloud platforms, CI/CD, payment services, dev tools, AI/ML services, cryptocurrency exchanges, and more. Significantly broader coverage than detect-secrets.

### Secret verification

Unique feature: TruffleHog can **verify** detected secrets by attempting authentication against the real service. For example, if it finds an AWS key, it can call AWS STS to check if the key is active. This eliminates false positives entirely for verified secrets. Results are categorized as `verified`, `unverified`, or `false_positive`.

### False positive filtering

Multiple layers:

1. **Known false positive dictionary**: Predefined set of placeholder strings (`example`, `xxxxxx`, `abcde`, `00000`, `sample`, `*****`)
2. **Aho-Corasick word list matching**: Checks against English word lists, programming book terminology, known UUIDs, and common bad patterns
3. **UTF-8 validation**: Rejects invalid sequences
4. **Entropy filtering**: Shannon entropy threshold for unverified results
5. **CustomFalsePositiveChecker interface**: Per-detector custom logic
6. **Verification itself**: If a secret is verified as inactive, it can be deprioritized

### Can it scan arbitrary text?

**Yes, via stdin**: `trufflehog stdin` reads from standard input.

**No clean Go library API for raw strings**: The internal engine exposes `ScanChunk()` which accepts a `sources.Chunk` struct, but this is not a documented public API. The filesystem source cannot read from memory buffers — only from file paths. To scan arbitrary text programmatically in Go, you would construct a `Chunk` manually and call `ScanChunk()`, but this is undocumented and could break between versions.

**For Python/mitmproxy integration**: Would need to either:
- Shell out to `trufflehog stdin` via subprocess (adds ~100-500ms startup overhead per invocation)
- Run trufflehog as a sidecar service and pipe data to it
- Write data to a temp file and scan with `trufflehog filesystem`

All of these add significant latency compared to an in-process Python library call.

### False positive behavior on code-like data

| Input type | Behavior |
|---|---|
| Version numbers | Low risk: detectors are format-specific, not entropy-based |
| Port numbers | Low risk: too short, no detector matches |
| Numeric IDs | Low risk: detectors match specific vendor prefixes |
| Base64 encoded data | Low risk IF format-specific detectors only; MODERATE risk if generic detector is active |
| Hex hashes | Low risk: no generic hex entropy detector (unlike detect-secrets) |
| JWT tokens | Correctly detected by JWT detector |
| Generic high-entropy strings | Lower risk than detect-secrets because TruffleHog relies primarily on format-specific regex, not entropy thresholds |

### Performance

- No published benchmarks for per-string scanning
- Go binary: faster than Python for CPU-bound work
- BUT: process startup overhead makes it unsuitable for per-request subprocess invocation
- 879 detectors with Aho-Corasick pre-filtering: keyword match is fast, but running 879 regex patterns on every request body could be expensive
- Verification (calling external APIs) adds seconds of latency — must be disabled for proxy use

### Maintenance assessment

- Extremely active: releases every 1-3 days
- 4,335 commits, 24.6k stars
- Backed by Trufflehog Security (commercial entity)
- No risk of abandonment

### Integration with mitmproxy

Poor. Go binary cannot be imported as a Python library. Options:

1. **Subprocess**: `echo $body | trufflehog stdin --json` — adds 100-500ms startup per call, unacceptable for per-request proxy latency
2. **Long-running sidecar**: Run trufflehog as a service, pipe data via stdin — complex, fragile
3. **HTTP wrapper**: Write a small Go HTTP server around trufflehog's engine — adds another service to the Docker Compose stack

### License concern

**AGPL-3.0**: If lobster-pot links to or derives from trufflehog code, the entire project must be AGPL-licensed. Running it as a separate process (subprocess/sidecar) avoids this, but adds the integration overhead described above.

### Verdict

**Best detection quality, worst integration story.** 879 verified detectors with live verification is unmatched. But Go + AGPL + no clean library API + subprocess latency makes it a poor fit for a Python mitmproxy addon doing per-request inline scanning. Better suited for batch scanning of transcripts after the fact than for real-time proxy interception.

---

## Candidate 3: Gitleaks

**Repository**: https://github.com/gitleaks/gitleaks
**Language**: Go
**License**: MIT
**Latest release**: v8.30.0 (November 26, 2025)
**Stars**: ~19k+

### What it detects

Comprehensive regex-based rules covering:

- 1Password, Adafruit, Adobe, Airtable, Algolia, Anthropic, AWS (access tokens, Bedrock), Azure AD
- Coinbase, Cloudflare, Databricks, Datadog, DigitalOcean, Discord
- GitHub (PATs, OAuth, app tokens, refresh tokens, fine-grained), GitLab (PATs, CI/CD, runner tokens)
- Grafana, Heroku, Hugging Face, JWT, Looker, Mailchimp, npm, NuGet
- OpenAI, PayPal, Postman, Pulumi, PyPI, RubyGems, SendGrid, Shopify, Slack, Stripe, Telegram, Terraform, Twilio, Vault
- Generic API key patterns, generic passwords

### Arbitrary text scanning

**Yes, three modes**: `git` (repo scanning), `dir` (directory/file scanning), `stdin` (pipe from standard input).

**Go library API**: Exposes `DetectString(content string)` and `DetectBytes([]byte)` — clean programmatic API for scanning arbitrary text.

### False positive handling

- **Allowlists**: Global and per-rule, with AND/OR condition logic
- **Stopwords**: Filter findings containing specified terms
- **Path filtering**: Ignore findings in file patterns
- **Entropy thresholds**: Per-rule configurable
- **Recursive decoding**: Handles base64-encoded secrets up to configurable depth
- **TOML configuration**: Fully customizable rule definitions

### False positive behavior on code-like data

| Input type | Behavior |
|---|---|
| Version numbers | Low risk: rules match specific vendor prefixes, not generic numbers |
| Port numbers | Low risk: too short for any rule |
| Numeric IDs | Low risk: prefix-based matching |
| Base64 encoded data | Low risk for format-specific rules; entropy detection can be tuned per-rule |
| Hex hashes | Low risk: no generic hex entropy rule by default |
| JWT tokens | Correctly detected |
| Generic high-entropy strings | Low risk: default config focuses on vendor-specific patterns, not generic entropy |

### Performance

- Go binary: fast regex execution
- Aho-Corasick keyword pre-filtering reduces unnecessary regex evaluation
- Configurable limits: `--max-target-megabytes`, `--timeout`
- BUT same subprocess overhead problem as trufflehog for Python integration

### Maintenance assessment

- Active: releases every 1-3 months, last release November 2025
- 1,266 commits, MIT licensed (no AGPL concerns)
- Strong community (19k+ stars)

### Integration with mitmproxy

Same problem as TruffleHog — Go binary, not a Python library. Options:

1. **Subprocess**: `echo $body | gitleaks stdin --no-git --report-format json` — 50-200ms startup overhead
2. **Long-running sidecar with HTTP wrapper**: Extra service, extra complexity
3. **Port the TOML rules to Python**: The rules are just regex — could extract them and run in Python directly

Option 3 is interesting: gitleaks' rule definitions are declarative TOML. You could parse the TOML config and run the regex patterns in Python without gitleaks itself. This gives you gitleaks' pattern library with Python-native performance and no subprocess overhead.

### Verdict

**Good detection quality, MIT license, but same Go integration problem.** The TOML rule format is a useful reference even if gitleaks itself is not used. `DetectString()` API is clean for Go projects but not for Python. Consider extracting its regex patterns for a Python implementation.

---

## Candidate 4: Nightfall DLP

**Website**: https://nightfall.ai
**Type**: Commercial SaaS

### Assessment

Nightfall is **SaaS-only**. There is no open-source version, no self-hosted option, no Docker image, and no offline capability. The product requires API calls to Nightfall's cloud service for every scan.

This is disqualified for lobster-pot because:

1. **Latency**: Every scan adds a network round-trip to an external API
2. **Privacy**: Agent traffic (potentially containing the secrets we are trying to protect) would be sent to a third-party service
3. **Availability**: Proxy functionality depends on Nightfall's uptime
4. **Cost**: Per-scan pricing on high-volume proxy traffic
5. **No self-hosted option**: Cannot run inside the Docker Compose stack

### Verdict

**Disqualified. SaaS-only, cannot be self-hosted, sends sensitive data to a third party.**

---

## Candidate 5: Simple Regex Approach

### Concept

A focused set of 15-25 regexes targeting known API key formats with vendor-specific prefixes. No entropy analysis, no keyword detection, no external dependencies.

### Example pattern set

```
# AWS Access Key ID
AKIA[0-9A-Z]{16}

# AWS Secret Key (context-dependent)
(?i)aws_secret_access_key\s*[=:]\s*[A-Za-z0-9/+=]{40}

# GitHub tokens
gh[pous]_[A-Za-z0-9_]{36,255}
github_pat_[A-Za-z0-9_]{22,255}

# GitLab tokens
glpat-[A-Za-z0-9\-_]{20,}

# Anthropic API keys
sk-ant-[A-Za-z0-9\-_]{90,}

# OpenAI API keys
sk-[A-Za-z0-9]{20,}

# Stripe keys
[sr]k_(live|test)_[A-Za-z0-9]{24,}

# Slack tokens
xox[bpas]-[A-Za-z0-9\-]{10,}

# Twilio
SK[0-9a-fA-F]{32}

# SendGrid
SG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}

# Private keys
-----BEGIN\s+(RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----

# JWT (detect only, high confidence)
eyJ[A-Za-z0-9_-]*\.eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*

# Bearer tokens in headers
(?i)authorization:\s*bearer\s+[A-Za-z0-9\-._~+/]+=*

# Generic hex secret with context (requires keyword)
(?i)(api[_-]?key|secret|token|password)\s*[=:]\s*["\']?[A-Fa-f0-9]{32,}["\']?

# Base64 with context (requires keyword)
(?i)(api[_-]?key|secret|token|password)\s*[=:]\s*["\']?[A-Za-z0-9+/]{40,}={0,2}["\']?
```

### False positive behavior on code-like data

| Input type | Behavior |
|---|---|
| Version numbers | Zero risk: no pattern matches `3.12.1` |
| Port numbers | Zero risk: no pattern matches `8080` |
| Numeric IDs | Zero risk: vendor prefixes required |
| Base64 encoded data | Zero risk for prefix-based patterns; LOW risk for context-dependent patterns (require keyword like `api_key =`) |
| Hex hashes | Zero risk for prefix-based; LOW risk for context-dependent (require keyword) |
| JWT tokens | Correctly detected (high-confidence pattern) |
| SHA-256 hashes | Zero risk: no pattern matches bare hex without context keyword |

### Tradeoffs

**Advantages**:
- Near-zero false positives on code-like data (prefix-based matching is unambiguous)
- Sub-millisecond performance (15-25 compiled regex patterns)
- Zero dependencies
- Trivially debuggable — every detection maps to an obvious pattern
- Easy to extend: new vendor format = new regex line
- No license concerns

**Disadvantages**:
- No entropy-based detection: misses secrets that lack a known prefix
- Coverage limited to explicitly coded patterns
- No verification: cannot confirm if a detected key is actually live
- Must manually track new API key formats from vendors
- Misses generic passwords (e.g., `my_password = "hunter2"`) unless keyword+context patterns are included

### Performance

- 15-25 compiled Python regex patterns: ~0.01-0.1ms per scan on typical HTTP body
- Negligible memory: just the compiled pattern objects
- Can be pre-compiled at addon load time

### Verdict

**Highest precision, lowest recall.** Perfect for the immediate use case of catching the most dangerous leaks (vendor API keys with known prefixes) with essentially zero false positives. Does not catch novel or generic secrets. Can be supplemented later.

---

## Comparison Matrix

| Criterion | detect-secrets | TruffleHog | Gitleaks | Nightfall | Simple Regex |
|---|---|---|---|---|---|
| **Secret pattern coverage** | 26 plugins | 879 detectors | ~100+ rules | Unknown (SaaS) | 15-25 patterns |
| **Vendor prefix detection** | Good | Excellent | Very good | N/A | Good (manual) |
| **Entropy detection** | Yes (base64 + hex) | Minimal (per-detector) | Yes (per-rule) | N/A | No |
| **Secret verification** | No | Yes (live API calls) | No | Yes (SaaS) | No |
| **False positive rate on code** | Moderate (entropy + keyword noise) | Low (format-specific) | Low (format-specific) | N/A | Very low |
| **Python library API** | Yes (`scan_line()`) | No | No | No (SaaS API) | N/A (inline code) |
| **mitmproxy integration** | Excellent (in-process) | Poor (subprocess/sidecar) | Poor (subprocess/sidecar) | Disqualified | Excellent (inline) |
| **Per-scan latency** | ~1-5ms | 100-500ms (subprocess) | 50-200ms (subprocess) | 50-200ms (network) | ~0.01-0.1ms |
| **Dependencies** | `detect-secrets` pip package | Go binary | Go binary | SaaS account | None |
| **License** | Apache-2.0 | AGPL-3.0 | MIT | Commercial | N/A |
| **Maintenance** | Moderate (6-12mo releases) | Excellent (daily releases) | Good (monthly releases) | N/A | Self-maintained |
| **Self-hosted** | Yes | Yes | Yes | No | Yes |
| **PII detection** | No (secrets only) | No (secrets only) | No (secrets only) | Yes | No |
| **Docker size impact** | ~5-10 MB pip install | ~100 MB Go binary | ~50 MB Go binary | N/A | 0 MB |

---

## Recommendation

### Short-term: Simple regex set (ship first)

For the initial lobster-pot implementation, use a focused regex set of 15-25 patterns targeting known vendor API key formats. Rationale:

1. **Zero false positives** on code-like data — the #1 concern
2. **Sub-millisecond latency** — no impact on proxy throughput
3. **Zero dependencies** — nothing to install, nothing to break
4. **Trivial to debug** — every detection maps to an obvious regex
5. **Catches the most dangerous leaks** — AWS keys, GitHub tokens, Stripe keys, etc. are the primary threat in agent traffic

This is a **fail-open-on-unknown** approach: it will not catch novel or generic secrets, but it will not produce false positives that desensitize operators or break agent workflows.

### Medium-term: Add detect-secrets (expand coverage)

Once the proxy is working with the regex set, layer in detect-secrets with a tuned configuration:

1. **Disable KeywordDetector** — too noisy on code-like data
2. **Raise entropy thresholds or disable entropy plugins** initially, enable cautiously with allowlists
3. **Use `scan_line()` API** — in-process Python, no subprocess overhead
4. **Add custom filter plugins** to suppress known false positive patterns in agent traffic
5. **Maintain a baseline** of known false positives, tuned against real agent transcripts

This gives broader coverage (26 vendor-specific detectors) with manageable false positives once tuned.

### Do not use for real-time proxy scanning:

- **TruffleHog**: Best detection quality but Go binary, AGPL license, subprocess overhead makes it unsuitable for per-request inline scanning in a Python mitmproxy addon. Excellent for periodic batch scanning of stored transcripts as a second-pass audit.
- **Gitleaks**: Similar Go integration problem, though MIT license is better. Its TOML rule definitions are a useful reference for building the regex set.
- **Nightfall**: SaaS-only, disqualified.

### On the Presidio question

Presidio should **not** be replaced — it should be **supplemented**. The tools address different concerns:

| Concern | Tool |
|---|---|
| Secret leakage (API keys, tokens) | Simple regex set, then detect-secrets |
| PII leakage (names, addresses, SSNs) | Presidio (with tuning per UNKNOWNS.md item 2) |

The secret detection tools have near-zero false positive rates on code because they match specific vendor prefixes. Presidio's PII detection will always have higher false positive rates on code, but that is a separate problem to solve separately. Do not conflate the two.

### Architecture in the mitmproxy addon

```
response() hook:
  body = flow.response.text

  # Layer 1: Fast regex check (always on, ~0.01ms)
  secrets = regex_scan(body)

  # Layer 2: detect-secrets check (optional, ~1-5ms)
  if ENABLE_DETECT_SECRETS:
      secrets += detect_secrets_scan(body)

  # Layer 3: Presidio PII check (optional, ~50-200ms)
  if ENABLE_PII_SCAN:
      pii = presidio_scan(body)

  if secrets:
      report_to_monitor(secrets)
      # Could escalate threat level, alert, or deny
```

The layered approach allows each detection method to be enabled/disabled independently and lets the fast regex check handle the common case without adding latency.

---

## Key finding for UNKNOWNS.md item 2

The original concern about Presidio's false positive rate on agent transcripts is valid but conflates two separate detection problems. Secret detection (API keys, tokens) and PII detection (names, phone numbers) require different tools with different precision/recall tradeoffs.

For secret detection specifically, the false positive problem is largely solved: vendor-specific prefix matching produces near-zero false positives on code. The remaining question is whether Presidio's PII detection can be tuned to acceptable false positive rates on code-heavy traffic — that question stands but is now scoped to PII only, not secrets.
