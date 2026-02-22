# Tidegate

A schema-aware MCP gateway that enforces field-level security policy on AI agent tool calls. Tidegate is an architecture layer — topology + gateway + scanner + mappings — not a standalone binary. The network topology is the security model.

## The problem

AI agent frameworks give agents broad access to tools — Slack, GitHub, filesystems, databases — through MCP servers. A malicious skill, prompt injection, or hallucination can exfiltrate sensitive data through legitimate tool calls. The agent has authorized access to the tools; the attack uses allowed channels.

Every existing MCP gateway does blob-level PII/secret scanning or tool-level ACL. None classify fields by security role or enforce per-field policy. At 50+ tools, blob scanning produces unacceptable false positive rates — `system_param` values (base64 IDs, hex strings, channel IDs, commit SHAs) routinely trigger scanners.

## The approach

Tidegate sits between the agent and its MCP servers as a transparent MCP proxy. The agent connects to Tidegate over Streamable HTTP as a normal MCP server — it doesn't know it's a gateway. Tidegate validates every tool call with full semantic context (tool names, parameter names, field classifications) before forwarding to the real MCP server.

**Field classification eliminates false positives**: `system_param` fields get regex/enum/type validation. Only `user_content` fields get leak scanning. Blob scanners that fire on a Slack channel ID (`C0ABC1234`) never see it — the field is classified as `system_param` and validated by regex.

**Principles**:
- The agent framework is swappable. Any MCP client connects.
- Credentials never enter the agent or gateway. MCP servers hold secrets.
- Unmapped tools are invisible. Unmapped fields are blocked. New fields invisible until human-reviewed.
- The gateway is advisory without the network topology. The topology is the product.
- Fork nothing you can't maintain.

## Architecture

```
agent-net (internal)              proxy-net (internet)
  │                                  │
  agent ──→ egress-proxy ───────────→ LLM API only
  │           (domain allowlist)
  │
  │ MCP (Streamable HTTP)
  ▼
  tidegate
  │
  │ MCP (Streamable HTTP)
  ▼
  mcp-net (internal)
  │
  ├── slack-mcp    (credentials via op run)
  ├── github-mcp   (credentials via op run)
  └── ...
      │
      ▼
    Internet
```

```
Tidegate container (single Node.js process)
  ├── MCP server (upstream) + MCP client (downstream)
  ├── Policy engine + L1 scanning + audit log
  ├── Shaped denies on validation/scan failure
  ├── Killswitch
  │
  │ JSON over stdio
  ├── Python scanner subprocess (L2/L3, stateless)
  │
  │ stdio (fallback for legacy servers)
  ├── Legacy MCP servers as child processes
```

### Network topology (the security model)

Three Docker networks enforce the trust boundary:

- **agent-net** (`internal: true`): Agent + Tidegate + egress-proxy. No direct internet access.
- **proxy-net**: Egress-proxy only. Internet access for LLM API calls.
- **mcp-net** (`internal: true`): Tidegate + MCP server containers. No internet access.

The agent reaches LLM APIs through the egress-proxy (`HTTPS_PROXY`), which allowlists only LLM API domains via HTTPS CONNECT inspection — no MITM, no certificate injection, end-to-end TLS. Without this topology, a prompt-injected agent bypasses the gateway with a raw HTTP call. The compose templates defining these boundaries are the product as much as the policy engine.

Requires Docker >= 25.0.5 (CVE-2024-29018 DNS exfiltration fix). All networks use `enable_ipv6: false`.

### Two distinct threat surfaces

- **Skills** (agent plugins): untrusted code running inside the agent container. Defended by **denying the agent direct egress** — `agent-net` is `internal: true`, so the agent can only reach Tidegate (MCP tools) and LLM APIs (via egress-proxy allowlist). Everything else is blocked at the network level.
- **MCP servers**: vetted infrastructure you deploy. Defended by the gateway's **field-level policy**. They are the HTTP clients, they hold credentials, they make the API calls.

## Defense hierarchy

```
MOST EFFECTIVE — stops determined adversaries
────────────────────────────────────────────
1. Credential isolation (MCP servers hold secrets, not agent)
   Agent never has the secret. Can't steal what you don't have.

2. Schema enforcement (Tidegate gateway)
   Agent can only invoke mapped tools with mapped fields.
   Unmapped tools invisible. Unknown fields blocked.

3. Network topology (agent-net / mcp-net)
   Agent cannot reach MCP servers directly.
   Agent cannot reach the internet directly.

4. Agent egress lockdown (Tidegate + LLM API only)
   Malicious skills can't phone home.
────────────────────────────────────────────
5. Field-level leak detection (Tidegate gateway)
   3-layer scan on user_content fields only:
   L1: JSON key-name heuristics
   L2: Structural patterns + checksum (Luhn, mod-97, vendor prefix)
   L3: Encoding detection, entropy anomaly, length anomaly
   Catches accidental leaks. Does NOT stop semantic exfiltration.
────────────────────────────────────────────
6. Behavioral anomaly detection (future)
   Audit log infrastructure ready, detection logic deferred.
────────────────────────────────────────────
LEAST EFFECTIVE — catches mistakes, not attackers
```

## Gateway enforcement pipeline

1. **Tool exists in mappings?** → unmapped tools invisible to agent
2. **All fields mapped?** → unknown/new fields blocked until reviewed
3. **No extra fields?** → agent can't invent parameters
4. **system_param validates?** → enum, regex, type check per field
5. **user_content scans clean?** → 3-layer leak detection
6. **Forward to MCP server**
7. **Response fields mapped?** → unmapped response fields stripped
8. **Response content clean?** → sensitive data scanning
9. **Return to agent**

Shaped deny at any step returns a valid MCP tool result explaining what was blocked and why (`isError: false` — the agent reads and adjusts, not retries blindly).

## Tech stack

| Component | Language | Why |
|---|---|---|
| Gateway | TypeScript | MCP SDK is TS-native, type system enforces schema mappings |
| Scanner | Python subprocess | `python-stdnum` for checksums, stateless, replaceable |
| L1 scanning | TypeScript (in-process) | Key-name heuristics, no subprocess round-trip |
| Mappings | YAML | PR-reviewable, community-contributable |
| Compose templates | Docker Compose | Network topology enforcement |

### Gateway modules

| Module | Role |
|---|---|
| `host.ts` | MCP server over Streamable HTTP. Filtered tool list. Shaped denies. |
| `router.ts` | Request lifecycle orchestration. Denial at any step short-circuits. |
| `policy.ts` | YAML loader, field validation, tool filtering, response stripping. Pure functions. |
| `scanner.ts` | L1 in-process. L2/L3 via Python subprocess pool. |
| `servers.ts` | MCP client connections downstream. Streamable HTTP or stdio. Zero security logic. |
| `audit.ts` | NDJSON structured logging. Every allow/deny/error. |

## Schema mapping format

```yaml
# tidegate.yaml
version: "1"
defaults:
  scan_timeout_ms: 500
  scan_failure_mode: deny
  unknown_field_policy: deny

servers:
  slack:
    transport: http
    url: http://slack-mcp:3000
    tools:
      post_message:
        params:
          channel:
            class: system_param
            type: string
            validation: "regex:^C[A-Z0-9]{8,}$"
            required: true
          text:
            class: user_content
            type: string
            scan: [L1, L2, L3]
            required: true
        response:
          ok:
            class: system_param
          ts:
            class: system_param

  some-legacy-server:
    transport: stdio
    command: npx
    args: ["-y", "@some/old-mcp-server"]
    env:
      API_KEY: "op://vault/some-key"
    tools: # ...
```

### Field classes

| Class | What it is | Validation | Leak scan |
|---|---|---|---|
| `system_param` | Constrained values (IDs, enums, paths) | Regex, enum, type check | No |
| `user_content` | Free-form text from agent | None (free text) | Full 3-layer scan |
| `opaque_credential` | Injected by MCP server, never from agent | Must not appear in agent request | N/A |
| `structured_data` | Code, JSON, structured payloads | Format validation | Pattern scanning |

## Credential model

Credentials live in MCP server containers. They are injected at startup via `op run` (1Password Service Accounts), not at runtime.

- `op run --env-file .env` wraps `docker compose up` on the host — resolves `op://` references, passes real values to containers via Compose `environment:`
- 1Password Service Account token (`OP_SERVICE_ACCOUNT_TOKEN`) lives in the operator's shell or CI, never in containers or compose files
- One SA token can access multiple vaults (permissions set at creation, immutable)
- For dev: plain `.env` file (gitignored) with real values, no `op run` in the chain
- The agent and gateway never see API keys, tokens, or passwords

## What this does NOT protect against

- **Semantic exfiltration via user_content fields**: A determined agent can embed proprietary code, conversation excerpts, or sensitive data in legitimate free-text fields. No pattern-based detection can catch this.
- **MCP server supply chain compromise**: If a community MCP server is backdoored, the gateway can't detect it. Mitigated by pinning versions and reviewing server code.
- **Kernel escapes**: Docker shares the host kernel. For stronger isolation, use gVisor or Firecracker.
- **LLM API as exfiltration channel**: The agent's only egress besides Tidegate. Low bandwidth, high complexity, accepted risk.

## Hardening checklist

### Container security
- [ ] All containers run as non-root (`user: "1000:1000"`)
- [ ] Read-only root filesystem (`read_only: true`)
- [ ] No privileged mode
- [ ] Drop all capabilities (`cap_drop: ALL`)
- [ ] `no-new-privileges: true`
- [ ] tmpfs for /tmp in all containers
- [ ] Resource limits (memory, CPU)

### Network topology
- [ ] Three Docker networks: `agent-net` (internal), `proxy-net`, `mcp-net` (internal)
- [ ] All networks: `enable_ipv6: false`
- [ ] Agent container on `agent-net` only, with `HTTPS_PROXY=http://egress-proxy:3128`
- [ ] Tidegate on both `agent-net` and `mcp-net`
- [ ] Egress-proxy on both `agent-net` and `proxy-net`, domain allowlist for LLM APIs
- [ ] MCP server containers on `mcp-net` only
- [ ] Docker >= 25.0.5 (CVE-2024-29018 DNS exfiltration fix)

### Credential security
- [ ] 1Password Service Account token file-mounted
- [ ] `op run` wraps all MCP server startup
- [ ] No plaintext credentials in .env, compose files, or container env vars
- [ ] No credentials in agent or gateway processes

### Gateway security
- [ ] Audit log append-only
- [ ] All tool mappings reviewed before first run
- [ ] Unmapped tools/fields default to invisible/blocked

## Build order

1. **Gateway** — TypeScript MCP proxy + policy engine + audit log
2. **Scanner** — Python subprocess for L2/L3 leak detection
3. **Mappings** — YAML files for initial MCP servers (Slack, GitHub, filesystem)
4. **Compose templates** — Wire agent + gateway + MCP servers with network topology
5. **Test** — Verify unmapped-tool blocking, field validation, leak detection, shaped denies
6. **Expand** — More server mappings, adapter docs, community library

## License

MIT
