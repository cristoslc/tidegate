# Shell Wrapper Command Interception

## Lifecycle

| Phase | Date | Commit | Notes |
|-------|------|--------|-------|
| Planned | 2026-02-22 | 138d920 | Research brief drafted |
| Active | 2026-02-22 | 138d920 | Full research across 6 question areas |
| Complete | 2026-02-22 | 138d920 | Findings documented |
| Superseded | 2026-02-23 | 138d920 | ADR-001 adopted seccomp-notify; shell wrapper approach dropped in favor of journal-based taint tracking (ADR-002) |

## Question

Can a shell wrapper binary (replacing `/bin/sh` in the agent container) intercept every command before execution to prevent encryption-before-exfiltration attacks?

## Outcome

Research validated the approach technically (Go binary with mvdan/sh parser, layered with LD_PRELOAD and seccomp-BPF). However, static analysis of Turing-complete scripts is fundamentally limited (halting problem), and the approach was superseded by ADR-002's journal-based taint tracking model which handles the encryption gap through observation + correlation rather than command interception.

## Supporting docs

- [brief.md](brief.md) — research questions
- [findings.md](findings.md) — full findings across all 6 question areas
