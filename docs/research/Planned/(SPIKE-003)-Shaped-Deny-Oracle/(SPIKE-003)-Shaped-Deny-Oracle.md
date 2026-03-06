---
artifact: SPIKE-003
title: "Shaped Deny as Adversarial Oracle"
status: Planned
author: cristos
created: 2026-02-23
last-updated: 2026-02-23
question: "Can shaped deny responses be exploited as an oracle for iterative evasion?"
parent-vision: VISION-001
gate: Pre-MVP
risks-addressed: []
depends-on: []
---

# Shaped Deny as Adversarial Oracle

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-23 | 138d920 | Identified by adversarial threat model review |

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

## Context at time of writing

Shaped denies are implemented in `src/gateway/src/router.ts`. They return `isError: false` with a plain-text explanation including the pattern name and reason. No rate limiting or tiered disclosure exists.
