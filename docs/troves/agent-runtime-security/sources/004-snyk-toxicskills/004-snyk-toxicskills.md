---
source-id: "004"
title: "ToxicSkills: Malicious AI Agent Skills Supply Chain Compromise"
type: web
url: "https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/"
fetched: 2026-03-15T00:00:00Z
hash: "sha256:pending"
---

# ToxicSkills: Malicious AI Agent Skills Supply Chain Compromise

**Published:** 2026-02-05
**Authors:** Luca Beurer-Kellner, Aleksei Kudrinskii, Marco Milanta, Kristian Bonde Nielsen, Hemang Sarkar, Liran Tal
**Source:** Snyk Security Blog

The first comprehensive security audit of the Agent Skills ecosystem reveals malware, credential theft, and prompt injection attacks targeting OpenClaw, Claude Code, and Cursor users.

## Core findings

Snyk scanned 3,984 skills from ClawHub and skills.sh (as of Feb 5, 2026):

- **534 skills (13.4%)** contain at least one CRITICAL-level security issue (malware distribution, prompt injection, exposed secrets)
- **1,467 skills (36.82%)** have at least one security flaw at any severity
- **76 confirmed malicious payloads** through human-in-the-loop review (credential theft, backdoor installation, data exfiltration)
- **8 malicious skills remained live on ClawHub** at time of publication

## Threat taxonomy

| Category | Risk Level | ClawHub Rate |
|---|---|---|
| Prompt Injection | CRITICAL | 2.6% |
| Malicious Code | CRITICAL | 5.3% |
| Suspicious Download | CRITICAL | 10.9% |
| Credential Handling | HIGH | 7.1% |
| Secret Detection | HIGH | 10.9% |
| Third-Party Content Exposure | MEDIUM | 17.7% |
| Unverifiable Dependencies | MEDIUM | 2.9% |
| Direct Money Access | MEDIUM | 8.7% |

## Three primary attack techniques

1. **External malware distribution** -- Installation instructions link to external platforms hosting malware (password-protected ZIPs to evade scanners)
2. **Obfuscated data exfiltration** -- Base64-encoded or Unicode-obfuscated commands that exfiltrate credentials (e.g., `cat ~/.aws/credentials | base64` piped to attacker endpoints)
3. **Security disablement and destructive intent** -- Modifying systemctl services, deleting system files, DAN-style jailbreaks

## Key convergence finding

100% of confirmed malicious skills contain malicious code patterns, while 91% simultaneously employ prompt injection techniques -- a dual-vector approach that bypasses both AI safety mechanisms and traditional code scanners.

## "Insecure by design" problems

- **10.9% secrets exposure rate** -- Hardcoded API keys in skills (both accidental and deliberate)
- **17.7% third-party content exposure** -- Fetching untrusted content creates indirect prompt injection surfaces even in legitimate skills
- **2.9% unverifiable dependencies** -- `curl | bash` patterns and remote instruction loading (21% of malicious samples use this)

## Supply chain context

Unlike traditional package ecosystems (npm, PyPI), Agent Skills are more dangerous because they inherit the full permissions of the AI agent -- shell access, filesystem read/write, credential access, and persistent memory. The barrier to publishing: a SKILL.md file and a GitHub account one week old.

The ecosystem is experiencing hypergrowth: daily submissions jumped from under 50 in mid-January to over 500 by early February 2026, a 10x increase in weeks. In February 2026, security researchers documented the first coordinated malware campaign targeting Claude Code and OpenClaw users, using 30+ malicious skills distributed via ClawHub.

## IOCs

Threat actor `zaycv` responsible for 40+ skills via automated malware generation. GitHub user `aztr0nutzs` maintains ready-to-deploy malicious skills. Skills from authors `Aslaep123`, `moonshine-100rze`, `pepe276` also flagged.
