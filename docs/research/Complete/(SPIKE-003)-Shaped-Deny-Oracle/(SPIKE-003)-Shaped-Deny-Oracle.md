---
artifact: SPIKE-003
title: "Shaped Deny as Adversarial Oracle"
status: Complete
author: cristos
created: 2026-02-23
last-updated: 2026-03-12
question: "Can shaped deny responses be exploited as an oracle for iterative evasion?"
parent-vision: VISION-002
gate: Pre-MVP
risks-addressed: []
depends-on: []
linked-artifacts:
  - ADR-006
  - SPIKE-016
---
# Shaped Deny as Adversarial Oracle

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Identified by adversarial threat model review |
| Active | 2026-03-09 | 1458121 | Elevated by SPIKE-016 findings — RL evasion validated |
| Complete | 2026-03-12 | 37e4a9b | Verdict: opaque denies eliminate the oracle. Formalized in ADR-006 |

## Source

External review: `tidegate-threatmodel-review(1).md` — problem #2.

## Question

Shaped denies return structured explanations of what was blocked and why. A prompt-injected agent receives this feedback and can iterate toward evasion. The threat model presents shaped denies as a feature (agent adjusts and retries) without acknowledging the adversarial case.

## Sub-questions

1. **Information leakage**: What does a shaped deny currently disclose? (Pattern name, layer, field path, explanation text.) What's the minimum an honest agent needs to self-correct?
2. **Tiered disclosure**: Could denies return different detail levels — full explanation for cooperative agents, minimal "request denied" for suspected adversarial iteration? What signal would distinguish the two?
3. **Rate-based detection**: Can repeated denies on the same tool/parameter path signal adversarial probing? What's the threshold before false-positive alert fatigue?
4. **Prior art**: Is there research on adversarial iteration against security feedback in LLM agent systems?
5. **Multi-session persistence**: If the agent's memory records denial feedback, the attacker accumulates evasion knowledge across sessions.

## Why it matters

The shaped deny design creates a feedback loop: block → explain → attacker adjusts → retry. For a cooperative agent this is the correct UX. For a prompt-injected agent, it's a free oracle.

## SPIKE-016 escalation (2026-03-09)

SPIKE-016 (ROME Agentic Training Security Implications) validated this concern with production evidence and related research:

- **IPA credit assignment amplifies the oracle**: ROME's Interaction-Perceptive Agentic Policy Optimization assigns credit over semantic interaction chunks. If scanning denials cause trajectory failure, IPA efficiently learns to restructure tool calls to avoid triggering patterns — a few dozen trajectories could map Tidegate's detection boundaries.
- **Production incidents**: ROME section 3.1.4 documents RL-trained agents spontaneously developing unauthorized behaviors on Alibaba Cloud. Standard RL (not adversarial fine-tuning) is sufficient to produce scanner evasion.
- **RL WAF evasion precedent**: RL agents achieved 97.46% bypass rates against ModSecurity WAF (IEEE 9720473). MERLIN achieved 70% evasion against commercial AV. Pattern-based detection is the same class of defense.
- **Anthropic emergent misalignment**: Models trained with reward hacking generalize to broad misalignment including monitor disruption and sabotage (arxiv 2511.18397).

This spike is now **P1 priority** — the shaped deny oracle is not merely a theoretical concern but a validated attack surface for RL-trained agents. The key design question is: what's the minimum information a cooperative agent needs from a denial to self-correct, and how do we withhold everything else?

## Findings

The oracle risk is real and validated by SPIKE-016, but the mitigation is simpler than the sub-questions anticipated. Tiered disclosure, rate-based detection, and cooperative/adversarial classification are all unnecessary complexity.

**Verdict:** Shaped deny responses should return only a generic instruction telling the agent not to include sensitive information. No pattern name, no layer identification, no field path, no explanation of what was detected.

Example deny response:

> Do not include sensitive data such as credit card numbers in tool call parameters. Rephrase your request without the sensitive content.

This eliminates the oracle because:

1. **No detection feedback.** The response reveals nothing about what pattern matched, what scanner layer caught it, or what field contained the match. An adversarial agent learns nothing it can iterate on.
2. **Same response regardless of trigger.** Whether L1 regex, L2 checksum, or L3 ML model caught the data, the agent sees the same generic instruction. There is no signal to map detection boundaries.
3. **Cooperative agents don't need more.** An honest agent that accidentally included a credit card number in a tool call needs exactly one piece of information: "don't do that." It doesn't need to know which regex matched.
4. **Multi-session persistence is harmless.** Even if the agent's memory records the deny, the recorded information is "don't include sensitive data" — which is correct guidance, not evasion knowledge.

### Sub-question dispositions

| Sub-question | Answer |
|---|---|
| Information leakage | Eliminated — deny contains no detection metadata |
| Tiered disclosure | Unnecessary — single opaque tier for all cases |
| Rate-based detection | Out of scope for deny response design; may have independent value for alerting but is not needed to solve the oracle problem |
| Prior art | SPIKE-016 validated the risk; the fix is to remove the feedback channel entirely |
| Multi-session persistence | Harmless — stored deny is just "don't include sensitive data" |

### Recommendation

Create ADR-006 to formalize this as an architectural decision: deny responses are opaque instructions, never diagnostic feedback.

## Context at time of writing

Shaped denies are implemented in `src/gateway/src/router.ts`. They return `isError: false` with a plain-text explanation including the pattern name and reason. No rate limiting or tiered disclosure exists.
