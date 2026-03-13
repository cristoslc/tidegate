# Spike Lifecycle Index

Dashboard mirroring lifecycle data from individual Spike artifacts. Source of truth is each artifact's own lifecycle table. Numbered in intended execution order.

## Planned

_No planned spikes._

## Active

| ID | Title | Date | Commit |
|----|-------|------|--------|
| SPIKE-017 | [Validate libkrun virtio-net on macOS](./Active/(SPIKE-017)-Validate-libkrun-virtio-net-macOS/(SPIKE-017)-Validate-libkrun-virtio-net-macOS.md) | 2026-03-12 | 9a7d681 |

## Complete

| ID | Title | Date | Commit | Notes |
|----|-------|------|--------|-------|
| SPIKE-001 | [MCP Protocol Abuse Resistance](./Complete/(SPIKE-001)-MCP-Protocol-Abuse-Resistance/(SPIKE-001)-MCP-Protocol-Abuse-Resistance.md) | 2026-03-12 | d1cdb60 | Four hardening layers: body size cap, JSON depth limit, rate limiting, JSON-RPC error responses |
| SPIKE-002 | [Luhn False Positive Rate](./Complete/(SPIKE-002)-Luhn-False-Positive-Rate/(SPIKE-002)-Luhn-False-Positive-Rate.md) | 2026-03-12 | ee4d3c8 | "Zero FP" claim indefensible; compound validation achieves near-zero |
| SPIKE-003 | [Shaped Deny Oracle](./Complete/(SPIKE-003)-Shaped-Deny-Oracle/(SPIKE-003)-Shaped-Deny-Oracle.md) | 2026-03-12 | 37e4a9b | Verdict: opaque denies. Formalized in ADR-006 |
| SPIKE-004 | [L1 Fail-Open Behavior](./Complete/(SPIKE-004)-L1-Fail-Open-Behavior/(SPIKE-004)-L1-Fail-Open-Behavior.md) | 2026-03-12 | cdd85b1 | GO: fail-closed via watchdog sidecar + fd-dup; fallback filter impossible |
| SPIKE-005 | [Workspace Volume TOCTOU](./Complete/(SPIKE-005)-Workspace-Volume-TOCTOU/(SPIKE-005)-Workspace-Volume-TOCTOU.md) | 2026-03-12 | e3372ce | High severity; overlayfs isolation recommended as primary mitigation |
| SPIKE-006 | [Agent Memory Exfiltration](./Complete/(SPIKE-006)-Agent-Memory-Exfiltration/(SPIKE-006)-Agent-Memory-Exfiltration.md) | 2026-03-12 | a8fa47f | Confirmed risk; ADR-006 mitigates feedback channel; memory outside scanning seam |
| SPIKE-007 | [Leak Detection Tool Selection](./Complete/(SPIKE-007)-Leak-Detection-Tool-Selection/(SPIKE-007)-Leak-Detection-Tool-Selection.md) | 2026-02-21 | db146de | Informed L1 scanner design |
| SPIKE-008 | [L1 Interpreter Coverage Gap](./Complete/(SPIKE-008)-L1-Interpreter-Coverage-Gap/(SPIKE-008)-L1-Interpreter-Coverage-Gap.md) | 2026-02-23 | 138d920 | Fed ADR-002 |
| SPIKE-009 | [Data Flow Taint Model](./Complete/(SPIKE-009)-Data-Flow-Taint-Model/(SPIKE-009)-Data-Flow-Taint-Model.md) | 2026-02-23 | 138d920 | Became ADR-002 |
| SPIKE-011 | [NanoClaw Tidegate Design](./Complete/(SPIKE-011)-NanoClaw-Tidegate-Design/(SPIKE-011)-NanoClaw-Tidegate-Design.md) | 2026-02-24 | 6749250 | Informed ADR-003 |
| SPIKE-012 | [ClaudeClaw vs NanoClaw Comparison](./Complete/(SPIKE-012)-ClaudeClaw-vs-NanoClaw-Comparison/(SPIKE-012)-ClaudeClaw-vs-NanoClaw-Comparison.md) | 2026-03-09 | 1458121 | NanoClaw confirmed; ClaudeClaw rejected (no process boundary) |
| SPIKE-013 | [Tideclaw Architecture](./Complete/(SPIKE-013)-Tideclaw-Architecture/(SPIKE-013)-Tideclaw-Architecture.md) | 2026-03-11 | 30fbbc9 | Findings formalized in ADR-004 and ADR-005 |
| SPIKE-014 | [Tideclaw IPC Orchestrator Scanning](./Complete/(SPIKE-014)-Tideclaw-IPC-Orchestrator-Scanning/(SPIKE-014)-Tideclaw-IPC-Orchestrator-Scanning.md) | 2026-03-11 | 30fbbc9 | Gate: GO; findings in ADR-004; latency benchmarks deferred |
| SPIKE-015 | [Evaluate VM Isolation for Agent Container](./Complete/(SPIKE-015)-Evaluate-VM-Isolation-for-Agent-Container/(SPIKE-015)-Evaluate-VM-Isolation-for-Agent-Container.md) | 2026-03-12 | 9a37d1a | GO: Cloud Hypervisor (Linux) + Apple Containerization (macOS 26+); <2s achievable |
| SPIKE-016 | [ROME Agentic Training Security Implications](./Complete/(SPIKE-016)-ROME-Agentic-Training-Security-Implications/(SPIKE-016)-ROME-Agentic-Training-Security-Implications.md) | 2026-03-08 | d503211 | GO: RL-trained agents pose validated risks to DLP scanning |

## Abandoned

| ID | Title | Date | Commit | Notes |
|----|-------|------|--------|-------|
| SPIKE-010 | [Shell Wrapper Command Interception](./Abandoned/(SPIKE-010)-Shell-Wrapper-Command-Interception/(SPIKE-010)-Shell-Wrapper-Command-Interception.md) | 2026-03-06 | 8575371 | Shell wrapper approach dropped in favor of seccomp-notify and journal-based taint tracking |
