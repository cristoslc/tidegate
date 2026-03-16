---
source-id: "010"
title: "Don't get pinched: the OpenClaw vulnerabilities"
type: web
url: "https://www.kaspersky.com/blog/openclaw-vulnerabilities-exposed/55263/"
fetched: 2026-03-15T00:00:00Z
hash: "sha256:pending"
---

# Don't get pinched: the OpenClaw vulnerabilities

**Published:** 2026-02-10
**Author:** Tom Fosters
**Source:** Kaspersky official blog

## Context

OpenClaw (originally Clawdbot/Moltbot) is an open-source AI agent that transforms a computer into a self-learning home server. Over 20,000 GitHub stars in 24 hours; triggered a Mac mini shortage in US stores. Created by Austrian developer Peter Steinberger (PSPDFKit founder). Architecture described as "self-hackable": stores configuration, long-term memory, and skills in local Markdown files, allowing self-improvement. Around 6,000 skills in ClawHub at time of writing, with zero categorization, filtering, or moderation.

## Authentication failures

Researcher @fmdz387 ran a Shodan scan discovering nearly 1,000 publicly accessible OpenClaw installations running without any authentication. Researcher Jamieson O'Reilly gained access to Anthropic API keys, Telegram bot tokens, Slack accounts, months of complete chat histories, sent messages on behalf of users, and executed commands with full admin privileges.

**Root cause:** By default, OpenClaw trusts connections from 127.0.0.1/localhost and grants full access without authentication. Behind an improperly configured reverse proxy, all external requests are forwarded to 127.0.0.1. The system perceives them as local traffic and hands over the keys.

## Credential exfiltration demo

Matvey Kukuy, CEO of Archestra.AI, demonstrated private key extraction from a computer running OpenClaw. He sent an email containing a prompt injection to the linked inbox, then asked the bot to check mail. The agent handed over the private key from the compromised machine.

Reddit user William Peltomaki sent an email to himself with instructions that caused the bot to "leak" emails from the "victim" to the "attacker" with neither prompts nor confirmations.

In another test, a user asked the bot to run `find ~`, and the bot dumped the contents of the home directory into a group chat, exposing sensitive information.

## Malicious skills

From January 27 to February 1, over 230 malicious script plugins were published on ClawHub and GitHub. These scripts mimicked trading bots, financial assistants, and content services, packaging a stealer under the guise of a utility called "AuthTool". Once installed, the malware exfiltrated files, crypto-wallet browser extensions, seed phrases, macOS Keychain data, browser passwords, and cloud service credentials.

Attackers used the ClickFix technique -- victims infect themselves by following an "installation guide" and manually running malicious software.

## Vulnerability audit

A security audit in late January 2026 identified **512 vulnerabilities, 8 classified as critical**.

## Practical recommendations

- Use a dedicated spare computer or VPS -- never your primary machine
- **When choosing an LLM, go with Claude Opus 4.5** as it's currently the best at spotting prompt injections
- **Practice an "allowlist only" approach for open ports** and **isolate the device at the network level**
- **Set up burner accounts** for any messaging apps connected to OpenClaw
- Regularly audit security status: `security audit --deep`

## Cost reality

Running OpenClaw requires paid AI subscriptions; token counts easily hit millions per day. Journalist Federico Viticci burned through 180 million tokens during experiments, with costs far exceeding utility.
