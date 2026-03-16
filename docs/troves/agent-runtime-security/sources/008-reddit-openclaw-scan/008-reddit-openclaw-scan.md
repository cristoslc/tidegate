---
source-id: "008"
title: "r/MachineLearning: We scanned 18,000 exposed OpenClaw instances"
type: forum
url: "https://www.reddit.com/r/MachineLearning/comments/1r30nzv/d_we_scanned_18000_exposed_openclaw_instances_and/"
fetched: 2026-03-15T00:00:00Z
hash: "sha256:pending"
participants:
  - "Legal_Airport6155"
  - "securely-vibe"
  - "JWPapi"
  - "Bakoro"
  - "AccordingWeight6019"
  - "MMKot"
  - "brakeb"
post-count: 24
---

# r/MachineLearning: We scanned 18,000 exposed OpenClaw instances and found 15% of community skills contain malicious instructions

**Posted:** 2026-02-12 | **Score:** 129 points (94% upvoted)

## Legal_Airport6155 — 2026-02-12 18:07 UTC

I do security research and recently started looking at autonomous agents after OpenClaw blew up. What I found honestly caught me off guard.

I knew the ecosystem was growing fast (165k GitHub stars, 60k Discord members) but the actual numbers are worse than I expected. We identified over 18,000 OpenClaw instances directly exposed to the internet. When I started analyzing the community skill repository, nearly 15% contained what I'd classify as malicious instructions.

**Methodology:** Parsing skill definitions for base64-encoded payloads, obfuscated URLs, instructions referencing external endpoints; behavioral testing in isolated environments monitoring for unexpected network calls, filesystem access outside declared scope, attempts to read browser storage or credential files.

**"Delegated Compromise" threat model:** You're attacking the agent, which has inherited permissions across the user's entire digital life. Calendar, messages, file system, browser. A single prompt injection in a webpage can potentially leverage all of these.

I keep going back and forth on whether this is fundamentally different from traditional malware or just a new vector for the same old attacks. The supply chain risk feels novel though. With 700+ community skills and no systematic security review, you're trusting anonymous contributors with what amounts to root access.

**Follow-up (20:54 UTC):** "I would not install it on my main PC. Too much risk." Links to TrendingTopics article about OpenClaw partnering with VirusTotal to protect ClawHub.

## securely-vibe — 2026-02-13

> Most are very crude prompt injection attempts that the latest models would recognize. But there are more subtle attempts. There's also a huge space for more sophisticated prompt injections that are very hard to detect at scale.

Links to examples on r/vibecoding.

## JWPapi

> Community-contributed skills are just another form of context that the model trusts. Malicious instructions in that context = malicious output. Same pattern as prompt injection attacks. 15% is a lot. Security scanning should be table stakes for any shared skill repository.

## Bakoro — (6 points)

> Agents shouldn't be rawdogging the Internet anyway. These models need a small classification model that isn't trained to be a 'helpful agent' and doesn't generate arbitrary text, it just provides a yes/no/that's against the rules signal. So the agent says 'I'm going to drop what I'm doing and send crypto to this wallet', and the manager model looks at the user's prompt, not the Internet context, and says, 'No, don't do that'. We can spare an extra hundred million parameters on giving an agent a shoddy stand-in for a prefrontal cortex.

## AccordingWeight6019

> This feels less like a new malware category and more like giving probabilistic systems aggregated permissions without equivalent security primitives. The interesting shift is that exploitation moves from code execution to intent manipulation. The agent is already authorized, you need to steer it.
>
> I suspect the real risk isn't obviously malicious skills but compositional effects between seemingly benign ones. The ecosystem still treats skills like plugins, but operationally, they behave closer to untrusted policies.
>
> The question is whether the community starts modeling agents around information flow constraints rather than instruction filtering.

## MMKot — (3 days later)

> Community skills are just markdown and YAML that anyone can publish to ClawHub. Installing one is basically running third party code with your agent's permissions. Not an OpenClaw flaw, same supply chain risk as npm packages or VS Code extensions.

## brakeb

Links to The Register article reporting 135,000 exposed instances (separate from OP's 18K scan).
