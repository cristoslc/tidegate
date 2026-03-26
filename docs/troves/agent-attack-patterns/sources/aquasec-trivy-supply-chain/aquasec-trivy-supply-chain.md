---
source-id: "aquasec-trivy-supply-chain"
title: "Trivy Supply Chain Attack: What You Need to Know — Aqua Security"
type: web
url: "https://www.aquasec.com/blog/trivy-supply-chain-attack-what-you-need-to-know/"
fetched: 2026-03-25T00:00:00Z
hash: "31243b85cf958f076942be5c638382d54843729107187a0aace4f5db2fde5e5e"
---

# Update: Ongoing Investigation and Continued Remediation

**Aqua Security**, March 22-25, 2026

## Attack Summary

On March 19, 2026, a threat actor used compromised credentials to publish malicious releases of **Trivy version 0.69.4**, along with **trivy-action** and **setup-trivy**. This was the result of a broader, multi-stage supply chain attack that began weeks earlier.

## Attack Timeline

- **Late February 2026**: Attackers exploited a misconfiguration in Trivy's GitHub Actions environment, extracting a privileged access token and establishing a foothold into repository automation and release processes.
- **March 1, 2026**: The Trivy team disclosed the earlier incident and executed credential rotation. Subsequent investigation revealed the rotation was **not fully comprehensive**, allowing the threat actor to retain residual access via still-valid credentials.
- **March 19, 2026 (~17:43 UTC)**: The attacker force-pushed 76 of 77 version tags in the `aquasecurity/trivy-action` repository and all 7 tags in `aquasecurity/setup-trivy`, redirecting trusted references to malicious commits. Simultaneously, the compromised `aqua-bot` service account triggered release automation to publish a malicious Trivy binary designated v0.69.4.
- **March 19, 2026 (~20:38 UTC)**: The Trivy team identified and contained the attack, removing malicious artifacts from distribution channels.
- **March 20, 2026**: Safe versions, user guidance, and indicators of compromise published.
- **March 22, 2026**: Additional suspicious activity identified — unauthorized changes and repository tampering, consistent with attacker reestablishing access.
- **March 23-24, 2026**: Sygnia engaged for forensic investigation. Multi-stage nature confirmed: initial credential compromise, incomplete early containment, subsequent reuse of access.
- **March 25, 2026**: Remediation and documentation phase. No material changes to prior findings.

## Attack Technique

Rather than introducing a clearly malicious new version, the attackers used a sophisticated approach: **modifying existing version tags** associated with `trivy-action` to inject malicious code into workflows organizations were already running. Because many CI/CD pipelines rely on version tags rather than pinned commits, these pipelines continued to execute without any indication that the underlying code had changed.

The payload executed **prior** to legitimate Trivy scanning logic, so compromised workflows appeared to complete normally while silently exfiltrating data.

## What Was Affected

- **Trivy binary release:** v0.69.4
- **GitHub Action `aquasecurity/trivy-action`:** 76 of 77 version tags force-pushed to malicious commits (only v0.35.0 unaffected — protected by GitHub's immutable releases feature)
- **GitHub Action `aquasecurity/setup-trivy`:** multiple version tags compromised

**Affected windows:**
- Trivy v0.69.4: ~18:22 UTC to ~21:42 UTC on March 19, 2026
- trivy-action v0.69.4: ~17:43 UTC March 19 to ~05:40 UTC March 20, 2026
- setup-trivy: ~17:43 UTC to ~21:44 UTC on March 19, 2026

## Credential Exfiltration Targets

The malware collected:
- API tokens
- Cloud credentials (AWS, GCP, Azure)
- SSH keys
- Kubernetes tokens
- Docker configuration files
- Git credentials
- Other secrets available within CI/CD systems

Exfiltration occurred via two pathways (see IOCs).

## Downstream Impact — LiteLLM

The Trivy compromise served as the initial vector for the LiteLLM PyPI supply chain attack. Stolen credentials from the Trivy CI/CD compromise were reportedly used to gain unauthorized access to the LiteLLM publishing pipeline, resulting in malicious litellm packages v1.82.7 and v1.82.8 on PyPI.

## Enterprise Environment Isolation

Aqua's commercial products were **not** impacted:
- Built and operated entirely separate from GitHub
- No shared repositories, CI/CD infrastructure, secrets, or signing systems
- Dedicated pipelines and access controls (SSO, IP whitelisting, ZTNA)
- Controlled integration process where the commercial fork lags open-source releases

## Indicators of Compromise (IOCs)

| Type | Value | Action |
|------|-------|--------|
| Network C2 | `scan.aquasecurtiy[.]org` | Block at perimeter; hunt DNS logs |
| Network IP | `45.148.10.212` | Block at firewall; hunt NetFlow |
| Secondary C2 | `plug-tab-protective-relay.trycloudflare.com` | Search DNS logs |
| GitHub Exfil Repo | Repository named `tpcp-docs` | Search org for unauthorized repo creation |
| Compromised Binary | Trivy v0.69.4 | Search registries and CI caches |
| ICP Blockchain C2 | `tdtqy-oyaaa-aaaae-af2dq-cai.raw.icp0.io` | Block egress to `icp0.io` — standard domain takedowns do not apply to ICP-hosted C2 |

## Remediation Actions by Aqua

- All malicious releases removed from GitHub Releases, Docker Hub, GHCR, and ECR
- All compromised version tags deleted or repointed to known-safe commits
- Comprehensive credential lockdown executed
- Sygnia engaged for forensic investigation
- Implementing immutable release verification and provenance attestations
- NPM publish tokens treated as actively compromised — stolen tokens being weaponized across NPM ecosystem

## Safe Versions

| Component | Safe Version |
|-----------|-------------|
| Trivy binary | v0.69.2–v0.69.3 |
| trivy-action | v0.35.0 |
| setup-trivy | v0.2.6 |

## Key Lesson: Pin to Commit SHA, Not Tags

```yaml
# UNSAFE — mutable tag, can be silently redirected to malicious code
uses: aquasecurity/trivy-action@0.35.0

# SAFE — pinned to an immutable commit SHA
uses: aquasecurity/trivy-action@57a97c7e7821a5776cebc9bb87c984fa69cba8f1
```

GitHub Security Advisory: GHSA-cxm3-wv7p-598c
Ongoing updates: https://github.com/aquasecurity/trivy/discussions/10425
