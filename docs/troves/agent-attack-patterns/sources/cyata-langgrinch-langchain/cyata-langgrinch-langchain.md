---
source-id: "cyata-langgrinch-langchain"
title: "All I Want for Christmas is Your Secrets: LangGrinch hits LangChain Core (CVE-2025-68664)"
type: web
url: "https://cyata.ai/blog/langgrinch-langchain-core-cve-2025-68664/"
fetched: 2026-03-17T00:00:00Z
hash: "sha256:281cb11ae607070201359d8ddef27bc8ec5007b5ebdb4bee457947fc615312ce"
---

# All I Want for Christmas is Your Secrets: LangGrinch hits LangChain Core (CVE-2025-68664)

**Author:** Yarden Porat (Cyata)
**Published:** December 25, 2025
**Category:** AI Security, Deserialization, LangChain, CVE Disclosure

## Summary

Cyata disclosed a critical serialization injection vulnerability in langchain-core -- **CVE-2025-68664** (GHSA-c67j-w6g6-q2cm), nicknamed "LangGrinch." The flaw allows an attacker to inject crafted dictionaries containing a reserved `lc` key into LangChain's serialization pipeline. When those dictionaries are later deserialized, they are treated as internal LangChain objects instead of plain data, enabling secret extraction from environment variables and unsafe object instantiation. The CNA CVSS score is **9.3 (Critical)**, classified as **CWE-502: Deserialization of Untrusted Data**.

Patches are available in langchain-core versions **1.2.5** and **0.3.81**.

## Why This Vulnerability Deserves Attention

1. **It is in Core.** This is not a plugin bug, not an integration edge-case, and not a community package issue. The vulnerable APIs (`dumps()` / `dumpd()`) live in **langchain-core itself**.

2. **The blast radius is scale.** By download volume, langchain is one of the most widely deployed AI framework components globally. As of late December 2025, public package telemetry shows **~847M total downloads** (pepy.tech) and **~98M downloads in the last month** (pypistats).

3. **One prompt can trigger a lot of machinery.** The most common real-world path is not "attacker sends you a serialized blob and you call `load()`." It is subtler: LLM outputs can influence fields like `additional_kwargs` or `response_metadata`, and those fields can be serialized and later deserialized through normal framework features like streaming logs/events. An exploit can be triggered by a single text prompt that cascades into a complex internal pipeline.

## The Short Version of the Bug

LangChain uses a special internal serialization format where dictionaries containing an `lc` marker represent LangChain objects. The vulnerability was that `dumps()` and `dumpd()` **did not properly escape user-controlled dictionaries** that happened to include the reserved `lc` key.

Once an attacker is able to make a LangChain orchestration loop serialize and later deserialize content including an `lc` key, they could instantiate an unsafe arbitrary object, potentially triggering many attacker-friendly paths.

The advisory lists **12 distinct vulnerable flows**, which are extremely common use cases, such as standard event streaming, logging, message history/memory, and caches.

### Most Damaging Outcomes

- **Secret extraction** from environment variables. The advisory notes this happens when deserialization is performed with `secrets_from_env=True`. This was the default until the patch.

- **Object instantiation** within pre-approved namespaces (including `langchain_core`, `langchain_openai`, `langchain_aws`, `langchain_anthropic`, and others), potentially triggering side effects in constructors (network calls, file operations, etc.).

- Under certain conditions LangChain object instantiation may lead to **arbitrary code execution**.

## Research Story: Discovery Path

The research started from a recurring question at Cyata: *Where are the trust boundaries in AI applications, and do developers actually know where those boundaries are?*

Working backwards from interesting sinks, deserialization was an obvious target. There was already extensive research on LangChain tooling and integrations, but very few findings on the core library.

The researcher found that assuming an attacker-controlled deserialization primitive, they could trigger blind SSRF leverageable for environment variable exfiltration. The bug was not a piece of bad code -- it was the absence of code. `dumps()` simply did not escape user-controlled dictionaries containing `lc` keys. A missing escape in the serialization path, not the deserialization.

The investigation then became structured:

1. Identify where **untrusted content** (arbitrary dictionaries) gets serialized -- LLM outputs, prompt injection, user input, external tools, retrieved docs.
2. Identify when that serialized data gets deserialized.
3. Identify what an attacker can achieve from arbitrary object instantiation.

## Technical Deep Dive

### Background: The "lc" Marker and Why It Exists

LangChain serializes certain objects using a structured dict format. The `lc` key is used internally to indicate "this is a LangChain-serialized structure," not just arbitrary user data.

This creates a security invariant: any user-controlled data that could contain `lc` must be treated carefully. Otherwise, an attacker can craft a dict that "looks like" an internal object and trick the deserializer into giving it meaning.

The patch makes the intent explicit: during serialization, **plain dicts that contain an `lc` key are escaped** by wrapping them, preventing confusion with actual LangChain serialized objects during deserialization.

### The Allowlist: What Can Be Instantiated

LangChain's `load()` / `loads()` functions do not instantiate arbitrary classes -- they check against an allowlist that controls which classes can be deserialized. By default, this allowlist includes classes from `langchain_core`, `langchain_openai`, `langchain_aws`, and other ecosystem packages.

The catch: most classes on the allowlist have harmless constructors. Finding exploitable paths required digging through the ecosystem for classes that do something meaningful on instantiation.

### The Exfiltration Path

LangChain's `loads()` function supports a *secret* type that resolves values from environment variables during deserialization. Before the patch, `secrets_from_env` was enabled by default:

```python
if (
    value.get("lc") == 1
    and value.get("type") == "secret"
    and value.get("id") is not None
):
    [key] = value["id"]
    if key in self.secrets_map:
        return self.secrets_map[key]
    if self.secrets_from_env and key in os.environ and os.environ[key]:
        return os.environ[key]  # <-- Returning env variable
    return None
```

If a deserialized object is returned to an attacker -- for example, message history inside the LLM context -- that could leak environment variables.

The more interesting path is **indirect prompt injection**. Even an attacker who cannot see any LLM responses can exfiltrate secrets by instantiating the right class. `ChatBedrockConverse` from `langchain_aws` is both in the default allowlist of `loads` and makes a GET request on construction. The GET endpoint is attacker-controlled, and a specific HTTP header can be populated with an environment variable via the `secrets_from_env` feature.

### Code Execution via Jinja2 Templates

Among the classes in the default `loads()` allowlist is `PromptTemplate`. This class creates a prompt from a template, and one of the available template formats is Jinja2. When a template is rendered with Jinja2, arbitrary Python code can run.

The researchers did not find a way to trigger this directly from the `loads()` function alone, but if a subsequent call to the deserialized object triggers rendering, code execution follows. There may be paths to direct code execution from `loads()` that have not yet been confirmed.

## Attack Chain Summary

The complete attack chain for the most practical exploit scenario:

1. **Prompt injection** -- attacker crafts input (direct or via poisoned document/tool output) that causes the LLM to produce structured output containing a dict with an `lc` key.
2. **Serialization** -- LangChain's `dumps()` / `dumpd()` serializes this LLM output (e.g., through streaming events, logging, caching, or message history) without escaping the `lc` key.
3. **Deserialization** -- When the serialized data is later loaded (via `load()` / `loads()`), the deserializer treats the injected `lc`-containing dict as a real LangChain object.
4. **Object instantiation** -- An allowlisted class is instantiated with attacker-controlled parameters.
5. **Secret extraction** -- Either (a) `secrets_from_env` resolves environment variables into the instantiated object's fields and those leak back to the attacker, or (b) a class like `ChatBedrockConverse` makes an outbound request to an attacker-controlled endpoint with secrets in HTTP headers.

## Who Is Affected

Applications are potentially exposed if they use vulnerable langchain-core versions. The most common vulnerable patterns (12 flows identified in total):

- `astream_events(version="v1")` -- v1 uses the vulnerable serialization; v2 is not vulnerable
- `Runnable.astream_log()`
- `dumps()` / `dumpd()` on untrusted data, followed by `load()` / `loads()`
- Deserializing untrusted data with `load()` / `loads()`
- Internal serialization flows like `RunnableWithMessageHistory`, `InMemoryVectorStore.load()`, certain caches, pulling manifests from LangChain Hub (`hub.pull`), and other listed components

The most common attack vector is through LLM response fields like `additional_kwargs` or `response_metadata`, which can be controlled via prompt injection and then serialized/deserialized in streaming operations.

## The LangChainJS Parallel (CVE-2025-68665)

A closely related advisory exists in LangChainJS: **GHSA-r399-636x-v7f6 / CVE-2025-68665** with similar mechanics -- `lc` marker confusion during serialization, enabling secret extraction and unsafe instantiation in certain configurations.

The pattern travels across ecosystems: marker-based serialization, untrusted model output, and later deserialization is a recurring risk shape.

## Defensive Guidance

### 1. Patch First

Upgrade langchain-core to a patched version (1.2.5 or 0.3.81+). Validate what version of langchain-core is actually installed in production, including transitive dependencies from langchain, langchain-community, or other ecosystem packages.

### 2. Assume LLM Outputs Can Be Attacker-Shaped

Treat `additional_kwargs`, `response_metadata`, tool outputs, retrieved documents, and message history as untrusted unless proven otherwise. This is especially important if you stream logs/events and later rehydrate them with a loader.

### 3. Review Deserialization Features Like Secret Resolution

Even after upgrading, keep the principle: do not enable secret resolution from environment variables unless you trust the serialized input. The project changed defaults for a reason.

## Broader Implications

This vulnerability is a case study in a bigger pattern affecting agentic AI frameworks:

- An application may deserialize data it believes it produced safely.
- But that serialized output can contain fields influenced by untrusted sources (including LLM outputs shaped by prompt injection).
- A single reserved key used as an internal marker can become a pivot point into secrets and execution-adjacent behaviors.

Serialization formats, orchestration pipelines, tool execution, caches, and tracing are no longer "plumbing" -- they are part of the security boundary. LLM output is an untrusted input. If a framework treats portions of that output as structured objects later, attackers will try to shape it.

## Disclosure Timeline

| Date | Event |
|------|-------|
| December 4, 2025 | Report submitted via Huntr |
| December 5, 2025 | Acknowledged by LangChain maintainers |
| December 24, 2025 | Advisory and CVE published |
| December 25, 2025 | Blog post published by Cyata |

The LangChain project awarded a $4,000 USD bounty -- according to Huntr, the maximum amount ever awarded in the project, with prior bounties up to $125.

## References

- [GitHub Advisory GHSA-c67j-w6g6-q2cm](https://github.com/advisories/GHSA-c67j-w6g6-q2cm)
- [LangChainJS Advisory GHSA-r399-636x-v7f6](https://github.com/advisories/GHSA-r399-636x-v7f6)
- [Cyata "Vault Fault" research](https://cyata.ai/vault-fault/)
