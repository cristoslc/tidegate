---
source-id: "011"
title: "ClawJacked Flaw Lets Malicious Sites Hijack Local OpenClaw AI Agents via WebSocket"
type: web
url: "https://thehackernews.com/2026/02/clawjacked-flaw-lets-malicious-sites.html"
fetched: 2026-03-15T00:00:00Z
hash: "sha256:pending"
---

# ClawJacked Flaw Lets Malicious Sites Hijack Local OpenClaw AI Agents via WebSocket

**Published:** 2026-02-28 (modified 2026-03-02)
**Author:** Ravie Lakshmanan
**Source:** The Hacker News

## ClawJacked vulnerability (Oasis Security)

A high-severity flaw in OpenClaw's core gateway WebSocket server. The attack:

1. Malicious JavaScript on a web page opens a WebSocket connection to localhost on the OpenClaw gateway port
2. Script brute-forces the gateway password (no rate-limiting for localhost connections)
3. After authentication, registers as a trusted device -- auto-approved by gateway without user prompt (localhost connections bypass this check)
4. Attacker gains complete control: interaction with agent, config dump, node enumeration, log access

"Any website you visit can open [a WebSocket] to your localhost. Unlike regular HTTP requests, the browser doesn't block these cross-origin connections." -- Oasis Security

**Fixed:** OpenClaw 2026.2.25 (February 26, 2026), patched within 24 hours of disclosure.

## Log poisoning vulnerability (Eye Security)

Publicly accessible WebSocket on TCP port 18789 allowed writing malicious content to log files. Since the agent reads its own logs to troubleshoot tasks, this enabled indirect prompt injection through log entries.

"If the injected text is interpreted as meaningful operational information rather than untrusted input, it could influence decisions, suggestions, or automated actions." -- Eye Security

**Impact:** Manipulation of agent reasoning, influencing troubleshooting steps, potential data disclosure, indirect misuse of connected integrations.

**Fixed:** OpenClaw 2026.2.13 (February 14, 2026).

## CVE roundup (7 additional CVEs)

| CVE | Impact | Fixed in |
|-----|--------|----------|
| CVE-2026-25593 | RCE | 2026.2.14 |
| CVE-2026-24763 | Command injection | 2026.1.29 |
| CVE-2026-25157 | Command injection | 2026.1.29 |
| CVE-2026-25475 | SSRF | 2026.2.1 |
| CVE-2026-26319 | Auth bypass | 2026.2.2 |
| CVE-2026-26322 | Path traversal | 2026.2.2 |
| CVE-2026-26329 | Various | 2026.2.14 |

"As AI agent frameworks become more prevalent in enterprise environments, security analysis must evolve to address both traditional vulnerabilities and AI-specific attack surfaces." -- Endor Labs

## ClawHub marketplace attacks

- **Atomic Stealer delivery:** Trend Micro found malicious skills delivering Atomic Stealer (macOS infostealer from Cookie Spider). Infection chain: SKILL.md installs a prerequisite, directs user to website ("openclawcli.vercel[.]app") with malicious download command from C2 at 91.92.242[.]30.
- **71 malicious skills:** Straiker analyzed 3,505 ClawHub skills, found 71 malicious -- including cryptocurrency-redirecting scams.
- **Agent-to-agent attack:** Threat actor "BobVonNeumann" used the Moltbook social network to promote malicious skills to other agents. The bob-p2p-beta skill instructs agents to store Solana wallet private keys in plaintext and route payments through attacker infrastructure.
- **Social engineering via comments:** @liuhui1010 leaves comments on legitimate skill pages urging users to run malicious Terminal commands if skills "don't work on macOS."
- **CNCERT warning:** Chinese authorities restricted OpenClaw on government systems and state-run enterprises. Ban extends to families of military personnel.
