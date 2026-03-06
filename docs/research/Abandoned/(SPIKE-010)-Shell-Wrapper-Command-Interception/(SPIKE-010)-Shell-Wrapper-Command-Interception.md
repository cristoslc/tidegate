---
artifact: SPIKE-010
title: "Shell Wrapper Command Interception"
status: Abandoned
author: cristos
created: 2026-02-22
last-updated: 2026-02-23
question: "Can a shell wrapper binary intercept every command to prevent encryption-before-exfiltration?"
parent-vision: VISION-001
gate: Pre-MVP
risks-addressed: []
depends-on: []
---

# Shell Wrapper Command Interception

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-22 | 138d920 | Research brief drafted |
| Active | 2026-02-22 | 138d920 | Full research across 6 question areas |
| Complete | 2026-02-22 | 138d920 | Findings documented |
| Abandoned | 2026-03-06 | 8575371 | Shell wrapper approach dropped; seccomp-notify (ADR-001) and journal-based taint tracking (ADR-002) superseded this approach |

## Question

Can a shell wrapper binary (replacing `/bin/sh` in the agent container) intercept every command before execution to prevent encryption-before-exfiltration attacks?

## Outcome

Research validated the approach technically (Go binary with mvdan/sh parser, layered with LD_PRELOAD and seccomp-BPF). However, static analysis of Turing-complete scripts is fundamentally limited (halting problem), and the approach was superseded by ADR-002's journal-based taint tracking model which handles the encryption gap through observation + correlation rather than command interception.

## Supporting docs

- [brief.md](brief.md) — research questions
- [findings.md](findings.md) — full findings across all 6 question areas
