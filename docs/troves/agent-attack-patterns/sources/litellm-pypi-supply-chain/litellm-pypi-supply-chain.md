---
source-id: "litellm-pypi-supply-chain"
title: "Security Update: Suspected Supply Chain Incident — LiteLLM"
type: web
url: "https://docs.litellm.ai/blog/security-update-march-2026"
fetched: 2026-03-25T00:00:00Z
hash: "c5f4ed8ccda2c664f03e939f563022d2d3196e5676ad22b23f14af49bf951c95"
---

# Security Update: Suspected Supply Chain Incident

March 24, 2026

**Authors:** Krrish Dholakia (CEO, LiteLLM), Ishaan Jaff (CTO, LiteLLM)

> **Status:** Active investigation
> **Last updated:** March 25, 2026

## TLDR

- The compromised PyPI packages were **litellm==1.82.7** and **litellm==1.82.8**. Those packages have now been removed from PyPI.
- The compromise originated from the Trivy dependency used in LiteLLM's CI/CD security scanning workflow.
- Customers running the official LiteLLM Proxy Docker image were not impacted. That deployment path pins dependencies in requirements.txt and does not rely on the compromised PyPI packages.
- New LiteLLM releases are paused until a broader supply-chain review is complete.

## Overview

LiteLLM AI Gateway is investigating a suspected supply chain attack involving unauthorized PyPI package publishes. Current evidence suggests a maintainer's PyPI account may have been compromised and used to distribute malicious code.

The incident may be linked to the broader Trivy security compromise, in which stolen credentials were reportedly used to gain unauthorized access to the LiteLLM publishing pipeline.

## Confirmed Affected Versions

- **v1.82.7**: contained a malicious payload in the LiteLLM AI Gateway `proxy_server.py`
- **v1.82.8**: contained `litellm_init.pth` and a malicious payload in the LiteLLM AI Gateway `proxy_server.py`

Both versions have been removed from PyPI.

## What Happened

The attacker bypassed official CI/CD workflows and uploaded malicious packages directly to PyPI.

These compromised versions included a credential stealer designed to:

- Harvest secrets by scanning for:
  - Environment variables
  - SSH keys
  - Cloud provider credentials (AWS, GCP, Azure)
  - Kubernetes tokens
  - Database passwords
- Encrypt and exfiltrate data via a `POST` request to `models.litellm.cloud` (NOT an official BerriAI/LiteLLM domain)

## Who Is Affected

Affected if any of the following are true:

- Installed or upgraded LiteLLM via `pip` on **March 24, 2026**, between **10:39 UTC and 16:00 UTC**
- Ran `pip install litellm` without pinning a version and received v1.82.7 or v1.82.8
- Built a Docker image during this window that included `pip install litellm` without a pinned version
- A dependency pulled in LiteLLM as a transitive, unpinned dependency (e.g., through AI agent frameworks, MCP servers, or LLM orchestration tools)

**Not affected** if:

- Using **LiteLLM Cloud**
- Using the official LiteLLM AI Gateway Docker image: `ghcr.io/berriai/litellm`
- On **v1.82.6 or earlier** without upgrading during the affected window
- Installed LiteLLM from source via the GitHub repository (which was **not** compromised)

## Indicators of Compromise (IoCs)

- `litellm_init.pth` present in `site-packages`
- Outbound traffic or requests to `models.litellm[.]cloud`

## Immediate Actions for Affected Users

### 1. Rotate All Secrets

Treat any credentials present on affected systems as compromised: API keys, cloud access keys, database passwords, SSH keys, Kubernetes tokens, any secrets stored in environment variables or configuration files.

### 2. Inspect Filesystem

Check `site-packages` for `litellm_init.pth`:

```bash
find /usr/lib/python3.13/site-packages/ -name "litellm_init.pth"
```

### 3. Audit Version History

Review local environments, CI/CD pipelines, Docker builds, and deployment logs for v1.82.7 or v1.82.8. Pin to a known safe version (v1.82.6 or earlier).

## CI/CD Scanning Scripts

Community-contributed scripts (by Zach Fury) scan GitHub Actions and GitLab CI pipelines for compromised versions. Both scripts search job logs for `litellm==1.82.7` or `litellm==1.82.8` within a configurable time window. Available in the original blog post.

## Response and Remediation

LiteLLM team actions:

- Removed compromised packages from PyPI
- Rotated maintainer credentials and established new authorized maintainers
- Engaged Google's Mandiant security team for forensic analysis of the build and publishing chain
