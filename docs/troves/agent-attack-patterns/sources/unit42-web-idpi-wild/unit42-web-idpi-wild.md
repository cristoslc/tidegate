---
source-id: "unit42-web-idpi-wild"
title: "Fooling AI Agents: Web-Based Indirect Prompt Injection Observed in the Wild"
type: web
url: "https://unit42.paloaltonetworks.com/ai-agent-prompt-injection/"
fetched: 2026-03-17T00:00:00Z
hash: "sha256:c031ec83df371531434d3e3e1e9c7e8b031da9043098e1c0bd480f24b45633fd"
---

# Fooling AI Agents: Web-Based Indirect Prompt Injection Observed in the Wild

**Authors:** Beliz Kaleli, Shehroze Farooqi, Oleksii Starov, Nabeel Mohamed
**Published:** 2026-03-03
**Source:** Palo Alto Networks Unit 42

## Executive Summary

Large language models (LLMs) and AI agents are becoming deeply integrated into web browsers, search engines and automated content-processing pipelines. While these integrations expand functionality, they also introduce a new and largely underexplored attack surface. One particularly concerning class of threats is indirect prompt injection (IDPI), in which adversaries embed hidden or manipulated instructions within website content that is later ingested by an LLM.

Instead of interacting directly with the model, attackers exploit benign features like webpage summarization or content analysis. This causes the LLM to unknowingly execute attacker-controlled prompts, with the impact scaling based on the sensitivity and privileges of the affected AI system.

Prior research on IDPI has largely focused on theoretical risks, demonstrating proof-of-concept (PoC) attacks or low-impact real-world detections. In contrast, this analysis of large-scale real-world telemetry shows that IDPI is no longer merely theoretical but is being actively weaponized.

The research identified **22 distinct techniques** attackers used in the wild to construct payloads, some novel in their application to web-based IDPI. From these observations, the authors derive a concrete taxonomy of attacker intents and payload engineering techniques.

Documented attacker intents include:

- First observed case of AI-based ad review evasion
- SEO manipulation promoting a phishing site impersonating a well-known betting platform
- Data destruction
- Denial of service
- Unauthorized transactions
- Sensitive information leakage
- System prompt leakage

## Web-Based IDPI Attack Technique

### What Is Web-Based IDPI?

Web-based IDPI is an attack technique in which adversaries embed hidden or manipulated instructions within content that is later consumed by an LLM that interprets the hidden instructions as commands, leading to unauthorized actions. Instructions are typically embedded in benign web content including HTML pages, user-generated text, metadata or comments, and are processed during routine LLM tasks such as summarization, content analysis, translation or automated decision-making.

### How IDPI Differs from Direct Prompt Injection

Unlike direct prompt injection where an attacker explicitly submits malicious input, IDPI exploits modern LLM-based tools' ability to consume a larger volume of untrusted web content as part of their normal operation. When an LLM processes this content, it may inadvertently interpret attacker-controlled text as executable instructions.

### Amplified Threat from Agentic AI Adoption

Browsers, search engines, developer tools, customer-support bots, security scanners, agentic crawlers and autonomous agents routinely fetch, parse and reason over web content at scale. A single malicious webpage can influence downstream LLM behavior across multiple users or systems, with potential impact scaling alongside the privileges and capabilities of the affected AI application.

### Real-World Consequences and Attack Surface

As LLM-based tools become more autonomous and tightly coupled with web workflows, the web itself effectively becomes an LLM prompt delivery mechanism. This creates a broad attack surface where attackers can leverage common web features to inject instructions, conceal them using obfuscation techniques and target high-value AI systems indirectly. These attacks can result in:

- Leaking credentials and payment information
- Compromising decision-making pipelines
- Executing malicious actions through a benign user

### Prior Work: PoCs vs. Real-World Incidents

Prior research primarily highlighted theoretical risks through PoC attacks. Real-world cases to date have largely involved low-impact or anecdotal cases such as "hire me" prompts embedded in resumes, anti-scraping messages, attempts to promote websites, or review manipulation for academic papers. The findings in this report suggest a gap between the severity of theoretically demonstrated attacks and the more limited, opportunistic manipulation previously observed in practice.

## The First Real-World AI Ad Review Bypass with IDPI

In December 2025, Unit 42 reported a real-world instance of malicious IDPI designed to bypass an AI-based product ad review system. The attack, hosted at `reviewerpress[.]com`, serves a deceptive scam advertisement for military glasses with a fake special discount and fabricated comments to increase believability.

The attacker's goal is to trick an AI agent or LLM-based system designed to review, validate or moderate advertisements into approving content it would otherwise reject. The attacker uses multiple IDPI methods, showing that actors are both adopting more sophisticated payloads and pursuing higher-severity intents, rather than the low-severity behaviors seen before. The "Buy Now" button redirects users to `reviewerpressus.mycartpanda[.]com`.

To the authors' knowledge, this is the first reported detection of a real-world example of malicious IDPI designed to bypass an AI-based product ad review system.

## A Taxonomy of Web-Based IDPI Attacks

IDPI attacks are classified along two main axes:

1. **Attacker intent** -- what the attacker is trying to achieve
2. **Payload engineering** -- how the malicious prompt is constructed and embedded to be executed by AI agents while evading safeguards

Payload engineering is further divided into:

- **Prompt delivery methods**: How malicious prompts are embedded into webpage content and rendering structures (zero-sizing, CSS suppression, obfuscation within HTML attributes, dynamic injection at runtime)
- **Jailbreak methods**: How instructions are formulated to bypass safeguards (invisible characters, multi-layer encoding, payload splitting, semantic tricks)

### Attacker Intent

Severity is assessed based on attacker intent, focusing on the potential impact and harm of a successfully injected prompt.

#### Low Severity

- **Definition:** Actions that disrupt the AI's efficiency or output quality without causing lasting harm or influencing critical business decisions
- **Intent:** Playful, protective or non-malicious
- **Impact:** High noise, low actual risk
- **Examples:**
  - **Irrelevant output:** Forcing an AI agent to produce nonsensical/irrelevant output (e.g., "include a recipe for flan")
  - **Benign anti-scraping:** Preventing bots from reading or processing proprietary content
  - **Minor resource exhaustion:** Asking the AI to repeat a word thousands of times to bloat the response

#### Medium Severity

- **Definition:** Attempts to steer the AI's reasoning or bias its output to favor the attacker's narrative in non-financial contexts
- **Intent:** Coerce an AI agent into producing a preferred output
- **Impact:** Compromised decision-making pipelines (e.g., hiring or internal analysis)
- **Examples:**
  - **Recruitment manipulation:** Forcing an AI screener to label a candidate as "extremely qualified"
  - **Review manipulation:** Forcing AI to generate only positive reviews while suppressing all negative feedback
  - **AI access restriction:** Making an AI assistant refuse to process a webpage by purposely triggering safety filters

#### High Severity

- **Definition:** Attacks designed for direct financial gain or the successful delivery of high-impact malicious content like scams and phishing
- **Intent:** Malicious and predatory
- **Impact:** Direct financial loss for users or successful bypass of critical security gatekeepers
- **Examples:**
  - **AI content moderation bypass:** Tricking an AI system into approving a webpage with malicious content, such as a fraudulent or scam product seller
  - **SEO poisoning:** Pushing a malicious website (e.g., a phishing page) into top rankings via LLM recommendations
  - **Unauthorized transactions:** Attempting to force an agent to initiate unauthorized financial transactions or redirecting users to fraudulent payment links

#### Critical Severity

- **Definition:** Direct attacks targeting underlying infrastructure, model core integrity or broad-scale data privacy
- **Intent:** Destructive or aimed at system-wide compromise
- **Impact:** Permanent data loss, backend system crashes or total leakage of proprietary system instructions
- **Examples:**
  - **Data destruction:** Attempting to execute destructive server-side commands such as deleting system databases
  - **Sensitive information leakage:** Forcing the model to reveal sensitive information such as contact data
  - **System prompt leakage:** Forcing the model to reveal secret system prompts, enabling future "god mode" jailbreaks
  - **Denial of service (DoS):** Executing commands designed to exhaust CPU and process resources, such as a classic fork bomb

### Payload Engineering

#### Prompt Delivery Methods

Attackers use a variety of techniques to embed prompts within webpages, primarily to conceal them from users and evade detection by manual review, signature-based matching and other security checks. When there are multiple methods of delivery, even if only one bypasses the security tool, the malicious prompt may feed into an AI agent.

One real-world example contained 24 attempts of prompt injection within a single page using labeled layers of different techniques.

**1. Visual Concealment**

Hiding injected text visually so it remains in the DOM but is invisible to human viewers:

- **Zero-sizing:** Setting `font-size: 0px` and `line-height: 0` to shrink text until it physically disappears; setting container `height: 0` combined with `overflow: hidden` to collapse the element
- **Off-screen positioning:** Using `position: absolute` with extreme negative coordinates (e.g., `left: -9999px; top: -9999px;`) to push content outside the visible viewport
- **CSS rendering suppression:** Using `display: none` to remove the element from visual document flow; using `visibility: hidden` to make the element invisible; placing prompts inside `<textarea>` tags hidden via CSS
- **Transparency:** Setting `opacity: 0` to make text fully transparent while it technically remains in the DOM
- **Camouflage:** Using the same colors for text and background (e.g., `color: #ffffff; background-color: #ffffff;`)

**2. Obfuscation**

Embedding prompts within structured markup so they appear non-executable or semantically irrelevant to traditional parsers while remaining visible to language models:

- **XML/SVG encapsulation:** Placing text inside CDATA sections within SVG image files; XML parsers ignore the text as markup, but LLMs often ingest raw text content regardless of tag structure
- **HTML attribute cloaking:** Placing the prompt as the value of HTML attributes such as `data-*` attributes

**3. Runtime Assembly (Dynamic Execution)**

Constructing malicious prompts within the browser at runtime, bypassing static analysis tools that only inspect initial HTML source code:

- **Base64-encoded instructions** decoded at runtime, inserted as off-screen invisible DOM elements
- **Timed delays** ensuring the prompt is decoded only after initial scans complete, exploiting gaps in time-bounded inspection pipelines
- **Canvas-based text rendering** that hides semantic content in a non-DOM surface that some LLM-based scrapers extract via OCR or accessibility paths

**4. URL String Manipulation**

Injecting malicious instructions after the fragment (#) in legitimate URLs (e.g., HashJack).

**5. Visible Plaintext**

Placing the prompt as plaintext within web content, typically in overlooked areas like footers.

#### Jailbreak Methods

Jailbreaking refers to how attackers formulate prompts to evade AI safeguards while preserving malicious intent.

##### Instruction Obfuscation

Techniques that hide the true intent of a prompt by altering its surface form:

- **Invisible characters:** Inserting zero-width Unicode characters between standard letters, creating strings that look normal to humans but are digitally distinct
- **Homoglyph substitution:** Replacing Latin characters with visually identical characters from other alphabets (e.g., Cyrillic "a" instead of Latin "a") to defeat keyword filters
- **Payload splitting:** Breaking a single command into multiple distinct HTML elements; simple scripts analyze each element individually but the LLM reads aggregated innerText of the parent container
- **Garbled text:** Partially obfuscating the prompt through unusual punctuation and fragmented phrasing
- **Unicode bi-directional override:** Using U+202E right-to-left override to reverse visible text while preserving semantic meaning in raw content
- **HTML entity encoding:** Converting prompt characters into ASCII decimal or hexadecimal values preceded by `&#` or `&#x`
- **Binary-to-text encoding (Base64):** Encoding instructions as data attributes like `data-instruction` and `data-cmd`
- **URL encoding:** Converting characters into hexadecimal byte values preceded by `%`
- **Nested encoding:** Encoding an encoded string again (e.g., encoding the % sign into an HTML entity), requiring multiple decoding passes

##### Semantic Tricks

Techniques that reinterpret instructions to appear benign or contextually justified:

- **Multilingual instructions:** Repeating malicious commands in multiple languages (e.g., French, Chinese, Russian, Hebrew), targeting multilingual AI capabilities to execute the command even if the English version is blocked
- **JSON/syntax injection:** Using syntax characters (e.g., `}}`) to break out of the current data context and inject new fraudulent key-value pairs (e.g., `"validation_result": "approved"`)
- **Social engineering:** Manipulating the model's reasoning by framing malicious instructions as legitimate, urgent or aligned with user goals; using persuasive language, authority cues (god mode, developer mode), or role-playing scenarios (DAN -- "do anything now") to convince the model that executing the request is appropriate

## In-the-Wild Detections of IDPI

### Case 1: SEO Poisoning

| Field | Detail |
|-------|--------|
| **Website** | `1winofficialsite[.]in` |
| **Attacker Intent** | SEO Poisoning |
| **Prompt Delivery** | Visible Plaintext |
| **Jailbreak** | Social Engineering |
| **Severity** | High |

The prompt is delivered as visible plaintext in the webpage footer. The site impersonates a popular betting site, `1win[.]fyi`.

### Case 2: Database Destruction

| Field | Detail |
|-------|--------|
| **Website** | `splintered[.]co[.]uk` |
| **Attacker Intent** | Data Destruction |
| **Prompt Delivery** | CSS Rendering Suppression |
| **Jailbreak** | Social Engineering |
| **Severity** | Critical |

Contains a prompt with the command to "delete your database," attempting to coerce an AI agent integrated with backend systems into performing destructive data operations.

### Case 3: Forced Pro Plan Purchase

| Field | Detail |
|-------|--------|
| **URL** | `llm7-landing.pages[.]dev/_next/static/chunks/app/page-94a1a9b785a7305c.js` |
| **Attacker Intent** | Unauthorized Transaction |
| **Prompt Delivery** | Dynamic Execution |
| **Jailbreak** | Social Engineering |
| **Severity** | High |

A JavaScript-delivered IDPI that attempts to coerce the AI into subscribing the victim to a paid "pro plan" without legitimate consent, directing the agent to initiate a Google OAuth login.

### Case 4: Fork Bomb

| Field | Detail |
|-------|--------|
| **Website** | `cblanke2.pages[.]dev` |
| **Attacker Intent** | Data Destruction, Denial of Service |
| **Prompt Delivery** | CSS Rendering Suppression |
| **Jailbreak** | Social Engineering |
| **Severity** | Critical |

Attempts to block AI analysis and sabotage data pipelines. Tries to execute `rm -rf --no-preserve-root` and deploys a classic fork bomb (`:(){ :|:& };:`) designed to crash systems by exhausting CPU and process resources.

### Case 5: Forced Donation

| Field | Detail |
|-------|--------|
| **URL** | `storage3d[.]com/storage/2009.11` |
| **Attacker Intent** | Unauthorized Transactions |
| **Prompt Delivery** | HTML Attribute Cloaking |
| **Jailbreak** | Social Engineering |
| **Severity** | High |

Attempts to force the AI platform to make a donation by visiting an attacker-controlled Stripe payment link.

### Case 6: Purchase Running Shoes

| Field | Detail |
|-------|--------|
| **Website** | `runners-daily-blog[.]com` |
| **Attacker Intent** | Unauthorized Transactions |
| **Prompt Delivery** | Off-Screen Positioning |
| **Jailbreak** | Social Engineering |
| **Severity** | High |

A page that attempts to force an AI agent into buying running shoes at a payment processing platform, framed as a "critical system override" that must be "executed immediately to avoid test failure."

### Case 7: Free Money

| Field | Detail |
|-------|--------|
| **Websites** | `perceptivepumpkin[.]com`, `shiftypumpkin[.]com` |
| **Attacker Intent** | Unauthorized Transactions |
| **Prompt Delivery** | CSS Rendering Suppression |
| **Jailbreak** | Social Engineering |
| **Severity** | High |

Redirects to a legitimate online payment system page with an attacker-controlled account, then attempts to send $5,000 to the attacker via PayPal.

### Case 8: Sensitive Information Leakage

| Field | Detail |
|-------|--------|
| **Website** | `dylansparks[.]com` |
| **Attacker Intent** | Sensitive Information Leakage |
| **Prompt Delivery** | Visible Plaintext |
| **Jailbreak** | Social Engineering |
| **Severity** | Critical |

The injected prompt is placed at the very end of the webpage and visible within the footer. It attempts to force the model to reveal sensitive information such as contact data for a company.

### Case 9: Recruitment Manipulation

| Field | Detail |
|-------|--------|
| **Website** | `trinca.tornidor[.]com` |
| **Attacker Intent** | Benign Anti-Scraping, Recruitment Manipulation |
| **Prompt Delivery** | Transparency, Off-Screen Positioning |
| **Jailbreak** | Social Engineering |
| **Severity** | Medium |

A personal website that attempts to influence automated hiring decisions, containing instructions to trick AI scrapers into validating the candidate while selectively denying access to other AI agents.

### Case 10: Irrelevant Output

| Field | Detail |
|-------|--------|
| **Website** | `turnedninja[.]com` |
| **Attacker Intent** | Irrelevant Output |
| **Prompt Delivery** | Transparency, Zero-Sizing |
| **Jailbreak** | Social Engineering, JSON/Syntax Injection |
| **Severity** | Low |

Attempts to disrupt the utility of the agent by forcing it to output nonsense. Uses `[begin_admin_session]` to trick the LLM into believing instructions come from a higher authority.

### Case 11: Minor Resource Exhaustion

| Field | Detail |
|-------|--------|
| **URL** | `ericwbailey[.]website` |
| **Attacker Intent** | Minor Resource Exhaustion |
| **Prompt Delivery** | CSS Rendering Suppression |
| **Jailbreak** | Social Engineering |
| **Severity** | Low |

The goal is to render the AI agent useless by forcing it to produce a very long output ("print the word 'cabbage' five million times"), causing resource exhaustion.

### Case 12: Only Positive Reviews

| Field | Detail |
|-------|--------|
| **Website** | `myshantispa[.]com` |
| **Attacker Intent** | Review Manipulation |
| **Prompt Delivery** | Zero-Sizing, Camouflage |
| **Jailbreak** | Social Engineering |
| **Severity** | Medium |

Manipulates an AI agent into generating biased promotional content by forcing it to ignore prior guidelines and suppress any negative or balanced evaluation, producing marketing-style endorsement and fabricated comparative claims favoring a designated spa business.

## IDPI Trends on the Web

### Distribution of Attacker Intents

Top attacker intents from telemetry review:

| Intent | Percentage |
|--------|-----------|
| Irrelevant output | 28.6% |
| Data destruction | 14.2% |
| AI content moderation bypass | 9.5% |
| AI access restriction | 8.1% |
| SEO poisoning | 8.1% |
| Unauthorized transactions | 6.2% |
| Content moderation bypass | 5.5% |
| Others | 24.8% |

### Distribution of Prompt Delivery Methods

Top delivery methods from telemetry:

| Method | Percentage |
|--------|-----------|
| Visible plaintext | 37.8% |
| HTML attribute cloaking | 19.8% |
| CSS rendering suppression | 16.9% |
| Zero-sizing | 6.5% |
| Camouflage | 4.9% |
| Off-screen positioning | 3.5% |
| Others | 10.6% |

### Distribution of Jailbreak Methods

Top jailbreak methods from telemetry:

| Method | Percentage |
|--------|-----------|
| Social engineering | 85.2% |
| JSON/syntax injection | 7.0% |
| Multilingual instructions | 2.1% |
| Payload splitting | 1.8% |
| Garbled text | 1.8% |
| Others | 2.1% |

### Distribution of eTLDs

Top effective top-level domains of IDPI-containing URLs:

| eTLD | Percentage |
|------|-----------|
| `.com` | 73.2% |
| `.dev` | 4.3% |
| `.org` | 4.0% |

### Injected Prompts Per Page

75.8% of pages contained a single injected prompt; the remainder contained more than one.

## Defenses Against IDPI

A key cause for LLM susceptibility to IDPI is that LLMs cannot distinguish instructions from data inside a single context stream. Several defense approaches have been developed:

- **Spotlighting** -- an early prompt engineering technique where untrusted text (web content) is separated from trusted instruction
- **Instruction hierarchy** -- newer LLMs are hardened with techniques to reduce known prompt injection threats
- **Adversarial training** -- training models specifically to resist prompt injection patterns
- **Design-level defenses** -- recommended as defense-in-depth to further raise the bar for adversaries

Detection systems (web crawlers, network analyzers, in-browser solutions) must evolve beyond simple pattern matching to incorporate intent analysis, prompt visibility assessment and behavioral correlation across telemetry sources.

## Conclusion

IDPI represents a fundamental shift in how attackers can influence AI systems -- from direct exploitation of software vulnerabilities to manipulation of the data and content AI models consume. Attackers are already experimenting with diverse and creative techniques to exploit this attack surface, often blending social engineering, search manipulation and technical evasion strategies.

The emergence of novel prompt delivery methods and previously undocumented attacker intents highlights how adversaries are rapidly adapting to AI-enabled ecosystems, treating LLMs and AI agents as high-value targets that can amplify the reach and impact of malicious campaigns.

Defending against IDPI attacks will require security approaches that operate at scale, considering both the content and context in which prompts are delivered.

## Indicators of Compromise

### Websites and URLs Containing IDPI

- `1winofficialsite[.]in`
- `cblanke2.pages[.]dev`
- `dylansparks[.]com`
- `ericwbailey[.]website`
- `leroibear[.]com`
- `llm7-landing.pages[.]dev`
- `myshantispa[.]com`
- `perceptivepumpkin[.]com`
- `reviewerpress[.]com`
- `reviewerpressus.mycartpanda[.]com`
- `runners-daily-blog[.]com`
- `shiftypumpkin[.]com`
- `splintered[.]co[.]uk`
- `storage3d[.]com`
- `trinca.tornidor[.]com`
- `turnedninja[.]com`

### Payment Processing URLs Used by IDPI Sites

- `buy.stripe[.]com/7sY4gsbMKdZwfx39Sq0oM00`
- `buy.stripe[.]com/9B600jaQo3QC4rU3beg7e02`
- `paypal[.]me/shiftypumpkin`

## Additional Resources

- [LLM Prompt Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/LLM_Prompt_Injection_Prevention_Cheat_Sheet.html) -- OWASP
- [How Prompt Attacks Exploit GenAI and How to Fight Back](https://unit42.paloaltonetworks.com/new-frontier-of-genai-threats-a-comprehensive-guide-to-prompt-attacks/) -- Unit 42
- [The Risks of Code Assistant LLMs](https://unit42.paloaltonetworks.com/code-assistant-llms/) -- Unit 42
