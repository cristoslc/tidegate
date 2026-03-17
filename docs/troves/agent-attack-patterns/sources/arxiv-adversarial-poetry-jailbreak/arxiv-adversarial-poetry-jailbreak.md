---
source-id: "arxiv-adversarial-poetry-jailbreak"
title: "Adversarial Poetry as a Universal Single-Turn Jailbreak Mechanism in Large Language Models"
type: web
url: "https://arxiv.org/abs/2511.15304v1"
fetched: 2026-03-17T00:00:00Z
hash: "f4b18ec8195b642ed905138e551ab9d3f25dca0171220f490f293296681c7526"
---

# Adversarial Poetry as a Universal Single-Turn Jailbreak Mechanism in Large Language Models

**Authors:** Piercosma Bisconti, Matteo Prandi, Federico Pierucci, Francesco Giarrusso, Marcantonio Bracale, Marcello Galisai, Vincenzo Suriani, Olga Sorokoletova, Federico Sartore, Daniele Nardi

**Submitted:** 19 Nov 2025 (v1), latest version 16 Jan 2026 (v3)

**arXiv:** 2511.15304 [cs.CL]

## Abstract

We present evidence that adversarial poetry functions as a universal single-turn jailbreak technique for large language models (LLMs). Across 25 frontier proprietary and open-weight models, curated poetic prompts yielded high attack-success rates (ASR), with some providers exceeding 90%. Mapping prompts to MLCommons and EU CoP risk taxonomies shows that poetic attacks transfer across CBRN, manipulation, cyber-offence, and loss-of-control domains. Converting 1,200 MLCommons harmful prompts into verse via a standardized meta-prompt produced ASRs up to 18 times higher than their prose baselines. Outputs are evaluated using an ensemble of open-weight judge models and a human-validated stratified subset (with double-annotations to measure agreement). Disagreements were manually resolved. Poetic framing achieved an average jailbreak success rate of 62% for hand-crafted poems and approximately 43% for meta-prompt conversions (compared to non-poetic baselines), substantially outperforming non-poetic baselines and revealing a systematic vulnerability across model families and safety training approaches. These findings demonstrate that stylistic variation alone can circumvent contemporary safety mechanisms, suggesting fundamental limitations in current alignment methods and evaluation protocols.

## Key Findings

### Universal Effectiveness Across Models

- Tested against 25 frontier LLMs (both proprietary and open-weight)
- Some providers exceeded 90% attack success rate (ASR)
- Hand-crafted poems: average 62% jailbreak success rate
- Meta-prompt automated conversions: approximately 43% success rate
- ASRs up to 18x higher than prose baselines

### Cross-Domain Transferability

Attack effectiveness transfers across multiple risk domains mapped to MLCommons and EU Code of Practice taxonomies:

- **CBRN** (chemical, biological, radiological, nuclear)
- **Manipulation** (social engineering, deception)
- **Cyber-offence** (hacking, exploit development)
- **Loss-of-control** (autonomous action beyond intended scope)

### Methodology

- 1,200 MLCommons harmful prompts converted to verse via standardized meta-prompt
- Evaluation ensemble of open-weight judge models
- Human-validated stratified subset with double-annotations for agreement measurement
- Disagreements manually resolved

### Implications for Safety

- **Stylistic variation alone** can circumvent contemporary safety mechanisms
- Suggests **fundamental limitations** in current alignment methods — not just gaps in training data
- Safety training approaches are systematically vulnerable to register/style shifts
- Evaluation protocols need to account for non-standard linguistic framing
- Single-turn attacks (no multi-step manipulation needed) make this particularly dangerous

## Relevance to Agent Security

This paper demonstrates that jailbreak attacks need not be technically sophisticated — poetic framing operates at the semantic level, bypassing pattern-matching defenses. For agentic AI systems:

- **Indirect prompt injection** payloads could use poetic framing to evade detection
- Content embedded in documents, emails, or web pages processed by agents could exploit this vector
- Defense-in-depth cannot rely solely on input filtering if stylistic variation defeats it
- The 62% success rate for hand-crafted attacks represents a reliable exploitation primitive
