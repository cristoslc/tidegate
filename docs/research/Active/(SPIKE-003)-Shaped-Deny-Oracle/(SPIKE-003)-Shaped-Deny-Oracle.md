---
artifact: SPIKE-003
title: "Shaped Deny as Adversarial Oracle"
status: Active
author: cristos
created: 2026-02-23
last-updated: 2026-03-09
question: "Can shaped deny responses be exploited as an oracle for iterative evasion?"
parent-vision: VISION-002
gate: Pre-MVP
risks-addressed: []
depends-on: []
---

# Shaped Deny as Adversarial Oracle

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Identified by adversarial threat model review |
| Active | 2026-03-09 | 1458121 | Elevated by SPIKE-016 findings — RL evasion validated |

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

## Context at time of writing

Shaped denies are implemented in `src/gateway/src/router.ts`. They return `isError: false` with a plain-text explanation including the pattern name and reason. No rate limiting or tiered disclosure exists.
