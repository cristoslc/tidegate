# Standalone NER Libraries for PII Detection — Evaluation for AI Agent Traffic

## Context

This evaluation assesses standalone Named Entity Recognition (NER) libraries as alternatives or supplements to Microsoft Presidio's NER layer (SpacyRecognizer) for PII detection inside lobster-pot's mitmproxy addon. The companion documents cover secret detection (`evaluation.md`) and Presidio's full PII stack (`presidio-pii-evaluation.md`).

The key problem identified in the Presidio evaluation: spaCy NER within Presidio fires PERSON and LOCATION tags on code identifiers (variable names, class names, package names that resemble proper nouns). This evaluation asks whether a different NER approach could solve that problem while maintaining acceptable latency for real-time proxy use.

**Traffic profile**: 50-70% code/JSON/structured data, 30-50% natural language. Payloads range from 1KB to 50KB. The proxy has a 2-second total budget for all checks.

**Sources**: All findings below are derived from official documentation, GitHub repositories, PyPI pages, and HuggingFace model cards. Specific sources are cited inline.

---

## Candidate 1: spaCy Standalone (without Presidio)

**Repository**: https://github.com/explosion/spaCy
**License**: MIT
**Latest version**: 3.x (actively maintained, regular releases)
**PyPI**: `pip install spacy`

### Entity Types

All spaCy English models are trained on the OntoNotes 5.0 corpus and recognize 18 entity types:

| Entity Type | Description | PII Relevance |
|---|---|---|
| PERSON | People, including fictional | **HIGH** — names are PII |
| ORG | Companies, agencies, institutions | MODERATE — can indicate employer |
| GPE | Countries, cities, states | MODERATE — location data |
| LOC | Non-GPE locations (mountains, rivers) | LOW |
| FAC | Buildings, airports, highways | LOW |
| NORP | Nationalities, religious/political groups | LOW |
| PRODUCT | Objects, vehicles, foods | LOW |
| EVENT | Named events (hurricanes, battles) | LOW |
| WORK_OF_ART | Titles of books, songs | LOW |
| LAW | Named legal documents | LOW |
| LANGUAGE | Any named language | LOW |
| DATE | Absolute or relative dates | MODERATE — birth dates are PII |
| TIME | Times smaller than a day | LOW |
| MONEY | Monetary values | LOW |
| PERCENT | Percentage values | LOW |
| QUANTITY | Measurements | LOW |
| ORDINAL | "first", "second", etc. | LOW |
| CARDINAL | Numerals | LOW |

For PII detection, only PERSON, GPE, and DATE are directly useful. ORG is secondary. The other 14 types are noise for this use case.

### Model Variants

| Model | Download Size | Installed Size | NER F1 (OntoNotes) | Speed (CPU, WPS) | Architecture |
|---|---|---|---|---|---|
| en_core_web_sm | 12 MB | ~50 MB | ~83 | ~10,000+ | CNN + hash embeddings |
| en_core_web_md | 43 MB | ~90 MB | ~84 | ~10,000 | CNN + word vectors (300d) |
| en_core_web_lg | 741 MB | ~780 MB | 85.5 | ~10,014 | CNN + word vectors (685k) |
| en_core_web_trf | 438 MB | ~500 MB | 89.8 | ~684 | RoBERTa-base transformer |

Sources: [spaCy Models](https://spacy.io/models/en), [spaCy Facts & Figures](https://spacy.io/usage/facts-figures/)

### Performance Estimates for Lobster-Pot

spaCy's en_core_web_lg achieves approximately 10,014 words per second on CPU. For typical payloads:

| Payload Size | Approx Words | Estimated Latency (en_core_web_lg) | Estimated Latency (en_core_web_trf) |
|---|---|---|---|
| 1 KB | ~150 words | ~15 ms | ~220 ms |
| 10 KB | ~1,500 words | ~150 ms | ~2,200 ms (EXCEEDS BUDGET) |
| 50 KB | ~7,500 words | ~750 ms | ~11,000 ms (WAY OVER) |

These are full-pipeline speeds. With NER-only (disabling parser, tagger, lemmatizer), speedup is modest for sm/md/lg models (NER is independent of parser in non-transformer models), but significant for trf models since the transformer component still runs.

**NER-only optimization**:
```python
nlp = spacy.load("en_core_web_sm", disable=["tagger", "parser", "lemmatizer"])
# or at call time:
for doc in nlp.pipe(texts, disable=["tagger", "parser"]):
    print(doc.ents)
```

This can roughly double throughput for sm/md/lg models by avoiding parser/tagger computation.

### Memory Footprint

| Model | Loaded RAM | Acceptable for Docker? |
|---|---|---|
| en_core_web_sm | ~100-250 MB | YES |
| en_core_web_md | ~200-350 MB | YES |
| en_core_web_lg | ~700-900 MB | MARGINAL (over 500 MB target) |
| en_core_web_trf | ~800-1200 MB | NO |

Source: [spaCy memory discussion](https://github.com/explosion/spaCy/discussions/13194)

### False Positive Behavior on Code

This is the critical weakness. spaCy NER models are trained on news/web text, not on code or JSON. Known problems:

1. **CamelCase identifiers**: `Jackson`, `Austin`, `Baker`, `Marshall` in code (variable names, package names) get tagged as PERSON or GPE. This is inherent to the model -- it sees title-cased words and assumes they are proper nouns.

2. **Package/module names**: `django.contrib.auth.models.User` -- spaCy may tag `User` or fragments as entities.

3. **JSON keys with proper-noun-like values**: `{"city": "Springfield", "manager": "Jenkins"}` -- both values get tagged, which is correct if they are PII but a false positive if they are configuration data.

4. **Case sensitivity**: spaCy's models are **case-sensitive in practice**. Fully lowercase names (`jackson`) are NOT recognized. Fully uppercase (`JACKSON`) may or may not be recognized depending on the model. Title case (`Jackson`) is recognized. This actually helps with code since most code identifiers use `camelCase` or `snake_case` rather than `Title Case`.

5. **From official issue tracker**: Users report "a lot of false positives" in non-standard text domains. The recommended mitigation is to add negative training examples, which requires custom model training.

Source: [spaCy NER false positives issue #1892](https://github.com/explosion/spaCy/issues/1892), [Discussion #11131](https://github.com/explosion/spaCy/discussions/11131)

### Combining spaCy NER with Regex

Yes, straightforward. spaCy handles names/locations/dates, regex handles structured PII:

```python
import spacy
import re

nlp = spacy.load("en_core_web_sm", disable=["tagger", "parser", "lemmatizer"])

SSN_PATTERN = re.compile(r'\b\d{3}-\d{2}-\d{4}\b')
CC_PATTERN = re.compile(r'\b\d{4}[- ]?\d{4}[- ]?\d{4}[- ]?\d{4}\b')
PHONE_PATTERN = re.compile(r'\b\d{3}[-.]?\d{3}[-.]?\d{4}\b')
EMAIL_PATTERN = re.compile(r'\b[\w.-]+@[\w.-]+\.\w{2,}\b')

def detect_pii(text):
    findings = []

    # Regex pass (fast, high precision)
    for match in SSN_PATTERN.finditer(text):
        findings.append(("SSN", match.group(), match.start(), match.end()))
    for match in CC_PATTERN.finditer(text):
        findings.append(("CREDIT_CARD", match.group(), match.start(), match.end()))
    for match in PHONE_PATTERN.finditer(text):
        findings.append(("PHONE", match.group(), match.start(), match.end()))
    for match in EMAIL_PATTERN.finditer(text):
        findings.append(("EMAIL", match.group(), match.start(), match.end()))

    # NER pass (slower, catches names)
    doc = nlp(text)
    for ent in doc.ents:
        if ent.label_ == "PERSON":
            findings.append(("PERSON", ent.text, ent.start_char, ent.end_char))

    return findings
```

### Minimal Viable spaCy Setup

For PII-relevant entity extraction only:

```python
import spacy
nlp = spacy.load("en_core_web_sm", disable=["tagger", "parser", "lemmatizer"])
# Only extract PERSON entities (the one NER provides that regex cannot)
doc = nlp(text)
names = [(ent.text, ent.start_char, ent.end_char) for ent in doc.ents if ent.label_ == "PERSON"]
```

This uses the smallest model, disables unnecessary components, and filters to only PERSON entities. Everything else (SSN, credit cards, phones, emails) is better handled by regex.

### Verdict

**spaCy is the baseline choice: fast, well-understood, good ecosystem, but the false positive problem on code is real and unsolved without custom training.** The sm model fits the latency and memory budgets. The NER accuracy is adequate but not outstanding (F1 ~83 on OntoNotes). The killer problem is that it will tag code identifiers that look like proper nouns as PERSON/GPE entities. Filtering to PERSON-only and combining with regex for structured PII is the practical approach.

---

## Candidate 2: GLiNER

**Repository**: https://github.com/urchade/GLiNER
**License**: Apache 2.0
**Latest version**: 0.2.25 (February 2026)
**PyPI**: `pip install gliner`
**Paper**: NAACL 2024

### What It Is

GLiNER (Generalist and Lightweight Named Entity Recognition) is a zero-shot NER model based on a bidirectional transformer encoder (BERT-like). Unlike spaCy, which recognizes a fixed set of entity types, GLiNER accepts entity type labels as input at inference time. You specify what you want to find -- "person name", "phone number", "social security number" -- and the model tries to find them.

This is fundamentally different from spaCy's approach: spaCy maps text spans to predefined categories. GLiNER matches text spans against arbitrary natural language descriptions of entity types.

### Model Variants

| Model | Parameters | Download Size | Architecture |
|---|---|---|---|
| gliner_small-v2.1 | ~166M | ~330 MB (FP16) / ~197 MB (UINT8) | DeBERTa-small |
| gliner_medium-v2.1 | ~209M | ~400 MB (FP16) | DeBERTa-base |
| gliner_large-v2.1 | ~459M | ~900 MB (FP16) | DeBERTa-large |

Source: [GLiNER GitHub](https://github.com/urchade/GLiNER), [HuggingFace model cards](https://huggingface.co/urchade/gliner_medium-v2.1)

### PII-Specific Models (Knowledgator)

A dedicated PII variant exists, fine-tuned for privacy detection:

| Model | F1 Score | Precision | Recall | Size (UINT8) |
|---|---|---|---|---|
| gliner-pii-edge-v1.0 | 75.5% | 79.0% | 72.3% | 197 MB |
| gliner-pii-small-v1.0 | 76.8% | 79.0% | 74.8% | 197 MB |
| gliner-pii-base-v1.0 | 81.0% | 79.3% | 82.8% | 330 MB |
| gliner-pii-large-v1.0 | 83.3% | — | — | ~900 MB |

These models detect 60+ PII categories including: name, first name, last name, DOB, email address, phone number, SSN, credit card, CVV, account number, routing number, passport number, driver license, IP address, URL, physical address, medical records, and more.

Source: [knowledgator/gliner-pii-base-v1.0](https://huggingface.co/knowledgator/gliner-pii-base-v1.0)

### API Usage

```python
from gliner import GLiNER

model = GLiNER.from_pretrained("knowledgator/gliner-pii-base-v1.0")

text = "John Smith called from 415-555-1234 to discuss account 12345678."
labels = ["person name", "phone number", "account number"]

entities = model.predict_entities(text, labels, threshold=0.3)
for ent in entities:
    print(ent["text"], ent["label"], ent["score"])
```

### Performance: THE DEALBREAKER

**GLiNER is catastrophically slow on CPU.** This is the single most important finding about GLiNER for this use case.

Reported CPU performance:

- **gliner-spacy integration**: ~6.5 minutes for 25 text chunks (~15.6 seconds per chunk). By comparison, spaCy en_core_web_lg processed the same batch in under 1 second. This is **300x slower than spaCy**.
- **Standalone GLiNER medium**: Users report 18-20 minutes for a paragraph of text on initial runs (likely including model loading). With optimization, ~0.8 seconds for a single short text.
- **With sequence length limits (384 tokens)**: 65-69 milliseconds per call — but this limits input to ~300 words, requiring chunking for larger payloads.
- **ONNX conversion**: Does NOT reliably help. One user reported ONNX was 50% slower than PyTorch for GLiNER.

Source: [gliner-spacy Discussion #28](https://github.com/theirstory/gliner-spacy/discussions/28), [GLiNER Issue #155](https://github.com/urchade/GLiNER/issues/155), [GLiNER Issue #88](https://github.com/urchade/GLiNER/issues/88)

**For lobster-pot's use case** (1KB-50KB payloads, 2-second budget):

| Payload Size | Estimated GLiNER Latency (CPU) | Within Budget? |
|---|---|---|
| 1 KB (~150 words) | 65-800 ms (highly variable) | MAYBE |
| 10 KB (~1,500 words) | 5-15 seconds | NO |
| 50 KB (~7,500 words) | 30-90 seconds | ABSOLUTELY NOT |

### False Positive Behavior on Code

GLiNER's zero-shot approach is theoretically better for code contexts because you can specify precise entity types rather than relying on general-purpose NER categories. If you ask for "social security number" rather than "CARDINAL", you should get fewer false positives from numeric code values.

However, there is no published evaluation of GLiNER's false positive rate on code/JSON text specifically. The model is trained on natural language, and CamelCase identifiers may still confuse it when searching for "person name" entities.

The **threshold parameter** provides tuning ability: higher thresholds (0.5+) reduce false positives at the cost of recall.

### Maintenance and Maturity

- Active development: 671 commits, last commit February 2026
- Apache 2.0 license
- Growing ecosystem: Presidio integration exists, spaCy wrapper exists, PII-specific fine-tuned models exist
- Paper published at NAACL 2024 — academically validated

### Verdict

**GLiNER is an excellent concept with a fatal performance problem for real-time proxy use on CPU.** The zero-shot PII detection approach is ideal in theory — you specify exactly what PII types to find. The dedicated PII models (knowledgator) achieve 81% F1 on PII benchmarks, which is competitive. But CPU inference is 100-300x slower than spaCy, making it unusable for per-request scanning in a proxy with a 2-second budget. GLiNER would require a GPU (not available in a Docker Compose deployment) or significant architectural changes (async scanning, batch processing, separate service with GPU).

---

## Candidate 3: Flair NLP

**Repository**: https://github.com/flairNLP/flair
**License**: MIT
**Latest version**: 0.15.1 (February 2025)
**PyPI**: `pip install flair` (requires Python 3.9+)

### NER Models

Flair provides two families of English NER models:

**4-class models (CoNLL-03 trained)**:

| Model | Entity Types | F1 Score | Architecture | Speed Profile |
|---|---|---|---|---|
| ner-english | PER, LOC, ORG, MISC | 94.09 | Flair embeddings + LSTM-CRF | Slow on CPU |
| ner-english-fast | PER, LOC, ORG, MISC | 92.92 | Fast Flair embeddings + LSTM-CRF | 3-6x faster |
| ner-english-large | PER, LOC, ORG, MISC | 94.36 | XLM-R large + FLERT | Very slow on CPU |

**18-class models (OntoNotes trained)**:

| Model | Entity Types | F1 Score | Architecture | Speed Profile |
|---|---|---|---|---|
| ner-english-ontonotes | 18 types (same as spaCy) | 90.93 | Flair embeddings + LSTM-CRF | Slow on CPU |
| ner-english-ontonotes-fast | 18 types | 89.3 | Fast Flair embeddings + LSTM-CRF | Faster |
| ner-english-ontonotes-large | 18 types | 90.93 | XLM-R large + FLERT | Very slow on CPU |

The 18-class OntoNotes models detect: PERSON, NORP, FAC, ORG, GPE, LOC, PRODUCT, EVENT, WORK_OF_ART, LAW, LANGUAGE, DATE, TIME, PERCENT, MONEY, QUANTITY, ORDINAL, CARDINAL.

Source: [flair/ner-english-fast (HuggingFace)](https://huggingface.co/flair/ner-english-fast), [flair/ner-english-large (HuggingFace)](https://huggingface.co/flair/ner-english-large), [flair/ner-english-ontonotes-fast (HuggingFace)](https://huggingface.co/flair/ner-english-ontonotes-fast)

### Performance on CPU

**This is Flair's critical weakness for this use case.**

Reported CPU performance:

- **Standard ner-english model**: ~11 seconds for 500 words on CPU
- **ner-english-fast model**: ~3 seconds for 500 words on CPU
- Flair is generally reported to be **20x slower than spaCy** on CPU

Source: [Flair Issue #29 (fast CPU inference)](https://github.com/flairNLP/flair/issues/29), [Flair Issue #1474](https://github.com/flairNLP/flair/issues/1474)

**For lobster-pot's use case**:

| Payload Size | Approx Words | ner-english-fast Latency (CPU) | Within Budget? |
|---|---|---|---|
| 1 KB | ~150 words | ~1 second | MARGINAL |
| 10 KB | ~1,500 words | ~9 seconds | NO |
| 50 KB | ~7,500 words | ~45 seconds | ABSOLUTELY NOT |

Even the "fast" model exceeds the 2-second budget for anything above ~300 words.

### Memory Footprint

- Standard ner-english: ~1-2 GB when loaded (Flair embeddings + PyTorch LSTM)
- ner-english-fast: ~500 MB-1 GB (smaller embeddings but still PyTorch)
- ner-english-large: ~2-3 GB (XLM-R large)

All variants exceed the 500 MB target. PyTorch is a mandatory dependency (~700 MB installed), which dominates the image size.

Source: [Flair Issue #1574 (extreme memory usage)](https://github.com/flairNLP/flair/issues/1574)

### False Positive Behavior on Code

No published data on code/JSON false positive rates. Flair's models are trained on the same CoNLL-03 and OntoNotes datasets as spaCy, so the same class of false positives (proper-noun-like identifiers tagged as PER/LOC) applies. Flair's higher accuracy (94.09 vs spaCy's ~83-85 F1) might mean slightly fewer false positives on standard text, but code is a fundamentally out-of-distribution input for both.

### NER Accuracy

Flair's accuracy is notably higher than spaCy's statistical models:

- Flair ner-english: 94.09 F1 vs spaCy en_core_web_lg: 85.5 F1
- Flair ner-english-ontonotes: 90.93 F1 vs spaCy en_core_web_lg: 85.5 F1

This accuracy advantage comes at a significant speed cost.

### API Usage

```python
from flair.data import Sentence
from flair.models import SequenceTagger

tagger = SequenceTagger.load("flair/ner-english-fast")
sentence = Sentence("John Smith lives in Austin, Texas.")
tagger.predict(sentence)

for entity in sentence.get_spans("ner"):
    print(entity.text, entity.get_label("ner").value, entity.get_label("ner").score)
```

### Verdict

**Flair offers the best NER accuracy among traditional NLP tools but is too slow and too heavy for real-time proxy use on CPU.** Even the "fast" model takes ~3 seconds for 500 words, and memory usage starts at 500MB+. The accuracy advantage over spaCy (94 vs 85 F1) is meaningful but irrelevant if it cannot meet latency requirements. Flair is better suited for offline batch analysis of captured transcripts.

---

## Candidate 4: Stanza (Stanford NLP)

**Repository**: https://github.com/stanfordnlp/stanza
**License**: Apache 2.0
**Latest version**: 1.10.1 (2025)
**PyPI**: `pip install stanza`

### NER Models for English

| Model | Entity Types | F1 Score | Training Data |
|---|---|---|---|
| CoNLL03 | PER, LOC, ORG, MISC (4 types) | 92.1 | CoNLL-03 |
| OntoNotes | 18 types (same as spaCy) | 88.8 | OntoNotes |

Source: [Stanza NER Models](https://stanfordnlp.github.io/stanza/ner_models.html), [Stanza NER](https://stanfordnlp.github.io/stanza/ner.html)

### Performance

Stanza is known for being slower than spaCy on CPU. From a 2025 benchmark study comparing NER tools:

- Stanza achieved F1 0.806 (averaged across entity types on an ambiguous entity benchmark)
- spaCy achieved F1 0.741 on the same benchmark
- However, Stanza is described as "much slower when running on CPU alone"

The Stanza documentation itself emphasizes that batch processing is essential: "running a for loop on one sentence at a time will be very slow."

Source: [Stanza performance](https://stanfordnlp.github.io/stanza/performance.html), [2025 NER benchmark (arxiv)](https://arxiv.org/html/2509.12098v1)

**Estimated performance for lobster-pot**: Comparable to or slower than Flair. Stanza uses BiLSTM-CRF or similar deep learning architectures that require PyTorch. Expected latency of 1-5 seconds for 500 words on CPU.

### Memory Footprint

- Requires PyTorch (~700 MB installed)
- Model download: ~100-200 MB per model
- Loaded RAM: ~500 MB-1 GB
- Exceeds the 500 MB target

### API Quality

Clean and Pythonic:

```python
import stanza
nlp = stanza.Pipeline(lang='en', processors='tokenize,ner')
doc = nlp("Chris Manning teaches at Stanford University.")
for ent in doc.ents:
    print(ent.text, ent.type)
```

### False Positive Behavior on Code

The 2025 benchmark study found that Stanza was more consistent than spaCy on structured tags (LOCATION, DATE), achieving F1 0.857 on LOCATION and 0.857 on DATE. Stanza's PERSON detection (F1 0.870) was significantly better than spaCy's (F1 0.471) on ambiguous entities. This suggests Stanza might produce fewer false positives on code-like identifiers that could be mistaken for person names, but this has not been tested on code/JSON text specifically.

### Maintenance

- Actively maintained: regular releases in 2025
- Stanford NLP group backing
- Apache 2.0 license
- Good academic credentials

### Verdict

**Stanza offers better NER accuracy than spaCy (especially for PERSON entities) but shares the same fundamental problems: too slow on CPU, too memory-heavy for a Docker proxy.** It requires PyTorch, has multi-second latency per document on CPU, and has not been evaluated on code/JSON text. The only scenario where Stanza is preferable to spaCy is if NER accuracy on natural language portions matters more than latency, and if running as a separate GPU-backed service.

---

## Candidate 5: DataFog

**Repository**: https://github.com/DataFog/datafog-python
**License**: MIT
**Latest version**: 4.3.0 (February 2026)
**PyPI**: `pip install datafog`

### What It Is

DataFog is a lightweight Python library specifically designed for PII detection and redaction. It combines multiple detection engines in a cascading architecture:

| Engine | Install | PII Types | Speed |
|---|---|---|---|
| regex | `pip install datafog` (core) | EMAIL, PHONE, SSN, CREDIT_CARD, IP_ADDRESS, DATE, ZIP_CODE | Very fast |
| spacy | `pip install datafog[nlp]` | Above + PERSON, ORG (via spaCy NER) | Moderate |
| gliner | `pip install datafog[nlp-advanced]` | Arbitrary types via zero-shot | Slow on CPU |
| smart | `pip install datafog` | Cascades regex first, then NER if available | Adaptive |

Source: [DataFog GitHub](https://github.com/DataFog/datafog-python)

### API Usage

```python
import datafog
clean = datafog.sanitize("Contact john@example.com or call 555-123-4567", engine="regex")
# "Contact [EMAIL_1] or call [PHONE_1]"
```

### Assessment

DataFog is essentially a convenience wrapper around the same underlying tools (regex + spaCy + GLiNER). It does not solve the fundamental problems identified above:

- The regex engine is equivalent to writing your own regex patterns
- The spaCy engine has the same false positive problems
- The GLiNER engine has the same CPU latency problems
- The "smart" cascade is a good architectural pattern but does not improve the underlying tools

DataFog is potentially useful as an integration layer if you want to use multiple backends, but for lobster-pot's specific needs, building a custom pipeline gives more control.

### Verdict

**DataFog is a convenience wrapper, not a new capability.** It packages the same tools (regex, spaCy, GLiNER) with a simpler API. The "smart" cascading pattern is worth emulating, but the library itself does not solve the core problems of NER false positives on code or NER latency on CPU.

---

## Comparison Matrix

| Criterion | spaCy (sm) | spaCy (lg) | GLiNER PII | Flair (fast) | Stanza | DataFog |
|---|---|---|---|---|---|---|
| **PII entity types (NER)** | PERSON, GPE, DATE + 15 others | Same | 60+ PII-specific | PER, LOC, ORG, MISC (4-class) or 18-class | 4-class or 18-class | Depends on engine |
| **NER F1 score** | ~83 | 85.5 | 81 (PII benchmark) | 92.9 (4-class) / 89.3 (18-class fast) | 92.1 (4-class) / 88.8 (18-class) | N/A (wrapper) |
| **Latency: 1KB (~150 words, CPU)** | ~10-15 ms | ~15 ms | 65-800 ms | ~1,000 ms | ~500-2,000 ms | Varies by engine |
| **Latency: 10KB (~1500 words, CPU)** | ~100-150 ms | ~150 ms | 5-15 sec | ~9 sec | ~5-15 sec | Varies |
| **Latency: 50KB (~7500 words, CPU)** | ~500-750 ms | ~750 ms | 30-90 sec | ~45 sec | ~30-60 sec | Varies |
| **Memory (loaded)** | 100-250 MB | 700-900 MB | 330-500 MB (base) | 500 MB-1 GB | 500 MB-1 GB | Varies |
| **Download size** | 12 MB | 741 MB | 197-330 MB | ~200-400 MB | ~100-200 MB | Negligible (wrapper) |
| **False positives on code** | HIGH (CamelCase identifiers) | HIGH | UNKNOWN (likely moderate) | HIGH (same training data) | MODERATE (better on ambiguous entities) | Depends on engine |
| **Regex PII support** | No (NER only) | No | Yes (zero-shot) | No (NER only) | No (NER only) | Yes (built-in) |
| **Custom entity types** | Requires training | Requires training | Yes (zero-shot labels) | Requires training | Requires training | Via GLiNER engine |
| **Python-native** | Yes | Yes | Yes | Yes (PyTorch dep) | Yes (PyTorch dep) | Yes |
| **PyTorch required** | No (sm/md/lg) | No | Yes | Yes | Yes | Depends on engine |
| **License** | MIT | MIT | Apache 2.0 | MIT | Apache 2.0 | MIT |
| **Actively maintained** | Yes (Explosion) | Yes | Yes | Yes (Zalando) | Yes (Stanford) | Yes |
| **Fits 2-sec budget (10KB)?** | YES | YES | NO | NO | NO | Depends |
| **Fits 500MB RAM target?** | YES | NO | MARGINAL | NO | NO | Depends |

---

## Key Findings

### 1. Only spaCy meets the latency requirements

For real-time proxy scanning on CPU, spaCy is the only NER library that fits within the 2-second budget for realistic payload sizes (1KB-10KB). All transformer-based alternatives (GLiNER, Flair, Stanza) are 10-300x slower on CPU.

| Library | 10KB Latency (CPU) | Fits Budget? |
|---|---|---|
| spaCy en_core_web_sm | ~100-150 ms | YES |
| spaCy en_core_web_lg | ~150 ms | YES |
| GLiNER PII base | 5-15 seconds | NO |
| Flair ner-english-fast | ~9 seconds | NO |
| Stanza | 5-15 seconds | NO |

### 2. No NER library solves the false positive problem on code

All NER libraries are trained on natural language corpora (news, web text). None have been specifically evaluated or optimized for code/JSON/structured data. The false positive problem (CamelCase identifiers tagged as PERSON) is inherent to the training data, not to any specific library's architecture.

GLiNER's zero-shot approach theoretically reduces this problem (you ask for "person name" rather than getting generic PERSON tags), but there is no published evaluation on code text, and the latency makes it impractical.

### 3. NER adds value only for person name detection

For lobster-pot's PII detection needs, NER provides value for exactly one thing: **detecting person names**. Everything else is better handled by regex:

| PII Type | Best Detection Method | Why |
|---|---|---|
| Person names | NER (spaCy PERSON) | No reliable regex pattern exists for names |
| Phone numbers | Regex + validation library | Structured format, regex is precise |
| SSNs | Regex + validation | XXX-XX-XXXX format, checksum possible |
| Credit card numbers | Regex + Luhn checksum | Structured format, checksum eliminates FPs |
| Email addresses | Regex + TLD validation | Structured format |
| Physical addresses | NER (GPE/LOC) + regex | Mixed -- street names need NER, ZIP codes need regex |
| Dates of birth | Regex | ISO 8601, MM/DD/YYYY, etc. |

### 4. The practical architecture is: regex for structured PII + spaCy sm for names

The only NER capability worth the overhead in a real-time proxy is PERSON name detection via spaCy en_core_web_sm. Everything else should use regex patterns (which are already recommended in `evaluation.md` and `presidio-pii-evaluation.md`).

---

## Recommendation

### Use spaCy en_core_web_sm for PERSON name detection, combined with regex for everything else

```python
import spacy
import re

# Load once at addon startup
nlp = spacy.load("en_core_web_sm", disable=["tagger", "parser", "lemmatizer"])

# Regex patterns for structured PII (from evaluation.md)
PII_PATTERNS = {
    "SSN": re.compile(r'\b\d{3}-\d{2}-\d{4}\b'),
    "CREDIT_CARD": re.compile(r'\b(?:\d{4}[- ]?){3}\d{4}\b'),
    "PHONE": re.compile(r'\b(?:\+?1[-.]?)?\(?\d{3}\)?[-.]?\d{3}[-.]?\d{4}\b'),
    "EMAIL": re.compile(r'\b[\w.-]+@[\w.-]+\.\w{2,}\b'),
}

def scan_pii(text: str) -> list:
    findings = []

    # Layer 1: Regex patterns (sub-millisecond)
    for pii_type, pattern in PII_PATTERNS.items():
        for match in pattern.finditer(text):
            findings.append({
                "type": pii_type,
                "text": match.group(),
                "start": match.start(),
                "end": match.end(),
                "method": "regex",
            })

    # Layer 2: spaCy NER for names (~10-150ms for 1-10KB)
    doc = nlp(text)
    for ent in doc.ents:
        if ent.label_ == "PERSON":
            findings.append({
                "type": "PERSON",
                "text": ent.text,
                "start": ent.start_char,
                "end": ent.end_char,
                "method": "ner",
            })

    return findings
```

### Why en_core_web_sm and not a larger model

| Factor | en_core_web_sm | en_core_web_lg |
|---|---|---|
| Download size | 12 MB | 741 MB |
| Memory when loaded | ~100-250 MB | ~700-900 MB |
| NER F1 | ~83 | 85.5 |
| Speed | ~10,000+ WPS | ~10,000 WPS |
| Docker image impact | Negligible | Adds ~750 MB |

The 2.5% F1 improvement from sm to lg does not justify 6x the memory and 60x the download size. For a proxy that only needs to catch obvious person names (not edge cases), sm is sufficient.

### Why not GLiNER despite its PII-specific models

The knowledgator/gliner-pii-base-v1.0 model is architecturally ideal for this use case (60+ PII types, zero-shot, Apache 2.0). But CPU inference is 100-300x slower than spaCy. Until GLiNER achieves spaCy-comparable CPU latency (which would likely require distillation or a fundamentally different architecture), it is not viable for real-time proxy use without a GPU.

**Future consideration**: If lobster-pot ever runs a GPU-backed analysis service (separate from the proxy), GLiNER PII models should be the first choice for that service. The zero-shot PII detection approach is genuinely superior to spaCy's general-purpose NER.

### Why not Flair despite its higher accuracy

Flair's 94.09 F1 (vs spaCy's ~83) comes at the cost of 20-100x slower CPU inference. For a real-time proxy, catching 83% of person names in 15ms is far more useful than catching 94% in 3 seconds.

### Mitigating spaCy false positives on code

Since spaCy is the recommended choice and its false positive problem on code is known, here are specific mitigations:

1. **Filter to PERSON only**: Ignore GPE, LOC, ORG, and all other entity types. Only PERSON is reliably useful for PII detection and cannot be replaced by regex.

2. **Post-processing heuristics**: Filter out PERSON entities that match common code patterns:
   ```python
   import re
   CODE_NAME_PATTERNS = [
       re.compile(r'^[a-z]'),           # starts lowercase (variable names)
       re.compile(r'_'),                  # contains underscore (snake_case)
       re.compile(r'^[A-Z]{2,}$'),       # ALL CAPS (constants)
       re.compile(r'\d'),                 # contains digits
       re.compile(r'^(True|False|None|null|undefined|NaN)$'),  # language keywords
       re.compile(r'\.(com|org|net|io)$'),  # domain-like
   ]

   def is_likely_code_identifier(text: str) -> bool:
       return any(p.search(text) for p in CODE_NAME_PATTERNS)
   ```

3. **Context-aware scanning**: If the payload is parseable as JSON, only run NER on string values, not on keys or the full JSON structure.

4. **Confidence threshold**: spaCy entities have no explicit confidence score in sm/md/lg models, but you can use entity length as a proxy (single-word PERSON entities are more likely to be false positives than multi-word names like "John Smith").

5. **Allow list**: Maintain a list of known code identifiers that trigger false positives in your specific agent ecosystem (e.g., `Jackson`, `Jenkins`, `Maven`, `Hadoop`).

### Performance budget allocation

Within the 2-second total budget:

| Check | Estimated Latency | Notes |
|---|---|---|
| Regex secret scan | ~0.01 ms | From evaluation.md |
| detect-secrets | ~1-5 ms | From evaluation.md |
| Regex PII scan | ~0.1 ms | SSN, CC, phone, email patterns |
| spaCy NER (en_core_web_sm) | ~10-150 ms | Depends on payload size |
| Monitor callout | ~50-200 ms | Network round-trip |
| **Total** | **~60-360 ms** | **Well within 2-second budget** |

This leaves ample headroom for larger payloads and network variance.

### What remains unknown

1. **Actual false positive rate of spaCy en_core_web_sm on real agent traffic**: Needs testing against captured transcripts. The post-processing heuristics above are educated guesses that need validation.

2. **Whether PERSON detection is worth the overhead at all**: If false positives on code are too high even with filtering, the pragmatic choice might be to skip NER entirely and rely solely on regex for PII detection. This misses person names but eliminates all NER-related false positives and latency.

3. **GLiNER with ONNX quantization on modern CPUs**: The 65-69ms figure for 384-token sequences with ONNX is tantalizing. If this can be reproduced reliably, GLiNER edge/small models might become viable for short texts. Needs benchmarking.

4. **Whether a small fine-tuned spaCy model could reduce code false positives**: Training a custom spaCy NER model with negative examples from code/JSON text could significantly reduce false positives. This is a meaningful investment (requires labeled data and training infrastructure) but could be the long-term solution.

---

## Summary Table

| Tool | Recommended For | Not Recommended For | Key Limitation |
|---|---|---|---|
| **spaCy en_core_web_sm** | Real-time PERSON name detection in proxy | High-accuracy NER, code-heavy text without post-processing | False positives on code identifiers |
| **GLiNER PII models** | Offline/GPU-backed PII analysis service | Real-time CPU proxy scanning | 100-300x slower than spaCy on CPU |
| **Flair** | Offline batch analysis where accuracy matters most | Real-time anything on CPU | 20x slower than spaCy, 500MB+ memory |
| **Stanza** | Academic NER benchmarks, multilingual NER | Real-time proxy use | Similar speed/memory issues as Flair |
| **DataFog** | Quick prototyping with multiple engines | Production proxy (it is a wrapper) | No new capability over underlying tools |
| **Regex patterns** | SSN, CC, phone, email, structured PII | Person name detection | Cannot detect names |
