# Tidegate — Unknowns

Open questions for implementation. Mark items resolved when implementation answers them; add new items at the bottom.

## ~~1. MCP SDK Dual-Role and Transport~~ — RESOLVED

**Resolved**: `McpServer` and `McpClient` are separate objects — one listens on a port, one connects to remote ports. They coexist in a single Node.js process the same way Express coexists with `fetch()`. No spike needed.

**Design decisions made during resolution**:
- SSE streaming: buffer full tool call response before scanning and relaying to agent. Adds latency but is the only way to scan response content.
- Multiplexing: `router.ts` resolves tool→server from YAML mapping, calls `servers.forward(serverName, request)`.
- Connection lifecycle: `servers.ts` maintains persistent MCP client connections to downstream servers, reconnects on failure.
- stdio fallback: `servers.ts` manages both Streamable HTTP and stdio transports — same module, pluggable backend.

## ~~2. Credential Injection in Container Model~~ — RESOLVED

**Resolved**: `op run` wraps `docker compose up` on the host — not inside containers. This is 1Password's documented pattern and works cleanly with the container model.

**How it works**:
- `.env` template contains `op://` secret references (e.g., `SLACK_BOT_TOKEN="op://Vault/slack/token"`)
- `op run --env-file .env -- docker compose up` resolves references on the host, passes real values to containers via Compose `environment:` directives
- SA token (`OP_SERVICE_ACCOUNT_TOKEN`) lives in the operator's shell or CI environment, never in any container or compose file
- One SA token can access multiple vaults (permissions set at token creation, immutable afterward)

**Sub-question resolutions**:
1. **Token distribution**: One SA token, multi-vault access. No per-container tokens needed.
2. **Docker Compose integration**: `op run` wraps compose on the host. No file mounts, no `op run` inside containers. Compose `environment:` passes resolved values.
3. **Secret rotation**: Requires container restart (`docker compose restart <service>`). `op run` resolves at startup; running processes keep old values. Acceptable tradeoff.
4. **Failure modes**: If `op run` can't reach 1Password, compose never starts. Fail-fast. No partial state.
5. **Non-1Password fallback**: Plain `.env` file (gitignored) with real values for dev. Same compose file works either way — `op run` just isn't in the chain.

**Design decisions made during resolution**:
- MCP servers universally accept credentials via environment variables (`SLACK_BOT_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`, etc.). No adapter needed.
- Container boundaries provide secrets isolation by default — each Compose service sees only its own `environment:` vars. Tidegate container has no credential env vars.
- stdio fallback (legacy MCP servers as child processes inside Tidegate) breaks credential isolation — those servers share Tidegate's env namespace. Mitigation: only use stdio for credential-free servers (e.g., filesystem), or accept weaker isolation for legacy servers.
- No need for 1Password Connect server, Docker secrets driver, or file-mounted tokens. The simple `op run` wrapper is sufficient.

## ~~3. Network Topology Enforcement~~ — RESOLVED

**Resolved**: Three-network topology with egress proxy. `internal: true` blocks all internet access, a dedicated proxy container allowlists only LLM API domains. Docker's own AI Sandboxes feature uses the same architecture, validating the approach.

**Three networks (was two)**:
- **agent-net** (`internal: true`, `enable_ipv6: false`): agent + tidegate + egress-proxy. No internet access.
- **proxy-net** (`enable_ipv6: false`): egress-proxy only. Internet access for LLM API calls.
- **mcp-net** (`internal: true`, `enable_ipv6: false`): tidegate + MCP server containers. No internet access.

**How egress control works**:
- `agent-net` is `internal: true` — Docker sets no default route and adds iptables DROP rules. Agent cannot reach the internet directly.
- The agent sets `HTTPS_PROXY=http://egress-proxy:3128` to reach LLM APIs.
- The egress-proxy container sits on both `agent-net` (to receive proxy requests) and `proxy-net` (to reach the internet).
- The proxy allowlists LLM API domains only. All other egress is denied.

**How HTTPS allowlisting works (no MITM)**:
1. Agent sends `CONNECT api.anthropic.com:443` to the proxy.
2. Proxy sees the target domain in plaintext in the CONNECT request.
3. Proxy checks its allowlist — allow or deny.
4. If allowed, proxy creates a TCP tunnel. TLS handshake is end-to-end between agent and LLM API.
5. No certificate injection, no MITM, no CA trust needed.

**Sub-question resolutions**:
1. **Internet egress blocking**: `internal: true` on `agent-net`. No iptables inside containers, no `CAP_NET_ADMIN` needed.
2. **LLM API allowlisting**: Proxy sidecar on `agent-net` + `proxy-net`. Domain-based via HTTPS CONNECT inspection.
3. **DNS exfiltration**: CVE-2024-29018 (CVSS 5.9) — Docker's embedded DNS on `internal: true` networks forwarded external lookups through the host namespace. Fixed in Docker >= 25.0.5. Require this version as minimum.
4. **IPv6**: `enable_ipv6: false` on all networks. Docker's IPv6 firewall parity has been historically unreliable (missing ip6tables chains in older versions, ignored `enable_ipv6: false` in 25.0.0–25.0.2). Disabling eliminates the entire risk class.
5. **Verification**: Test container on `agent-net` that attempts `curl evil.com` (must fail), `curl api.anthropic.com` via proxy (must succeed).

**Design decisions made during resolution**:
- Three networks, not two — the proxy network is the minimum viable addition to make "topology is the security model" actually true.
- Docker >= 25.0.5 is a hard requirement (DNS exfiltration fix).
- Agent framework must respect `HTTPS_PROXY` env var (most HTTP clients do by default).
- Proxy allowlist must be hot-updatable without restarting the proxy (e.g., adding a new LLM provider). See Unknown #4.
- Proxy software selection is a separate decision — see Unknown #4.

## ~~4. Egress Proxy Selection~~ — RESOLVED

**Resolved**: Squid 6.12 (Alpine 3.21 package) with hardened CONNECT-only config. Allowlist in standalone file, hot-reloadable via `squid -k reconfigure`. Existing tunnels survive reload.

**Decision**: Squid for MVP. The CVE concern is neutralized — of the 55 Rogers audit vulns, only ~12 HTTP parsing vulns apply to CONNECT-only mode, and ALL are fixed in Squid 6.12+. The remaining 15 unfixed vulns are in ESI (10), pipeline prefetch (4), and auth (1) — features we don't use and disable in config. tinyproxy eliminated (can't separate HTTP/CONNECT, reload bugs). Custom proxy deferred to v2 evaluation.

**Sub-question resolutions**:
1. **Hot-reload**: `squid -k reconfigure` (or `docker kill --signal HUP <container>`). Source code confirms `serverConnectionsClose()` closes listening sockets only — established CONNECT tunnels survive. Brief sub-second window where new connections may be rejected. In-flight LLM API calls are safe.
2. **CONNECT vs SNI**: CONNECT-based filtering via `dstdomain` ACL is sufficient. No SSL bumping or SNI inspection needed. The proxy sees the domain in the plaintext CONNECT request line.
3. **Logging**: Custom JSON `logformat` for allowed/denied CONNECT requests. Log to stdout (`access_log stdio:/dev/stdout`).
4. **Failure mode**: Fail-closed. Docker `restart: unless-stopped`.
5. **Allowlist source of truth**: Standalone file (`/etc/squid/allowlist.txt`), one domain per line. Tidegate or the operator writes this file; proxy reads it on reconfigure. Simpler than Tidegate generating Squid config syntax. File is volume-mounted from the host.
6. **Squid hardening**: Config disables caching (`cache deny all`), ICP/HTCP/SNMP (ports set to 0), cache manager, FTP (no matching URLs from CONNECT), pipeline prefetch, version disclosure, forwarding headers. Blocks all non-CONNECT methods via ACL (`http_access deny !CONNECT`). Alpine package with config-level hardening is sufficient — compile from source only if audit requires it.
7. **Docker image**: Alpine 3.21 + `apk add squid` (Squid 6.12). ~15–20MB. Non-root user `squid` (UID 3128). Entrypoint: `squid -NYC -f /etc/squid/squid.conf`.

**Hardened squid.conf** (reference — will be adapted during implementation):
```
# CONNECT-only forward proxy — all non-tunnel features disabled
http_port 3128
cache deny all
cache_mem 0 MB
icp_port 0
htcp_port 0
snmp_port 0
http_access deny manager
httpd_suppress_version_string on
via off
forwarded_for delete
pipeline_prefetch 0

acl CONNECT method CONNECT
acl SSL_Ports port 443
acl allowed_domains dstdomain "/etc/squid/allowlist.txt"

http_access deny !CONNECT
http_access deny CONNECT !SSL_Ports
http_access allow CONNECT allowed_domains SSL_Ports
http_access deny all

access_log stdio:/dev/stdout
cache_log stdio:/dev/stderr
cache_store_log none
```

**Design decisions made during resolution**:
- Squid is a dependency, not custom code — the proxy is off-the-shelf with a hardened config.
- Allowlist file is the interface between Tidegate/operator and the proxy. Volume-mounted, editable, reload via signal.
- Custom CONNECT proxy (~50–100 LOC) is a viable v2 replacement once we understand real-world edge cases from operating Squid. The file-based allowlist interface stays the same.
- The egress-proxy container is a Tidegate component, not a user-supplied piece. It ships with the compose templates.

## 5. Schema Mapping Generation Workflow


**Question**: How do we efficiently generate schema mappings for new MCP servers?

**What we know**:
- Each MCP server needs a YAML mapping file classifying every tool parameter
- The gateway queries `tools/list` to discover a server's tools and parameters
- An LLM (outside agent context) generates draft field classifications
- A human reviews and approves before the mapping goes live
- Mappings are YAML files, PR-reviewable, community-shareable

**Sub-questions**:
1. **LLM classification prompt**: What prompt reliably classifies parameters as `system_param`, `user_content`, `opaque_credential`, or `structured_data`? What context does the LLM need?
2. **Validation rule generation**: For `system_param` fields, can the LLM suggest appropriate regex/enum constraints? Or must these be human-authored?
3. **Drift detection**: When an MCP server updates and adds new parameters, how does the gateway detect this? Compare `tools/list` output against stored mappings on startup?
4. **Mapping format evolution**: The current YAML format is a sketch. What fields are missing? Versioning? Required vs optional parameters?
5. **Community library**: How should mappings be published and consumed?

**Impact**: The mapping workflow is the gateway's operational burden. If generating and maintaining mappings is painful, adoption dies. Deferred to v3 — hand-authored mappings are fine for MVP and v1.

## 6. Leak Detection in MCP Context

**Question**: How does the 3-layer leak detection architecture adapt to structured MCP tool call parameters?

**What we know**:
- 3-layer architecture: JSON key-name heuristics, checksum-validated patterns (Luhn, mod-97), format+context patterns (SSN)
- Applied to `user_content` fields only — field classification eliminates false positives on `system_param` values
- Scanner is a stateless Python subprocess receiving `{field, value, class}`
- Dependency: `python-stdnum` (~1MB)
- FP rates estimated from documentation analysis, not empirical testing

**Sub-questions**:
1. **L1 relevance**: The JSON key-name heuristic layer scans for keys like `"ssn"` in structured data. Since we already know the field name from schema mappings, is L1 still needed? Or does it add value when scanning nested JSON within a `user_content` field?
2. **Scanner protocol**: What's the exact wire format between TypeScript gateway and Python subprocess? JSON over stdin/stdout? One request per line?
3. **Process pool**: How many Python scanner processes? Fixed pool or dynamic? What's the warm-up cost?
4. **Empirical FP testing**: Still needed — test against real captured agent tool call transcripts.

**Impact**: The scanner interface design determines how cleanly the Python subprocess integrates with the TypeScript gateway.

## 7. MCP Protocol Abuse Resistance

**Question**: How should the gateway handle malformed, oversized, or adversarial MCP messages?

**What we know**:
- The gateway parses every MCP message — it's an attack surface
- A compromised agent could send malformed JSON-RPC to crash or bypass the gateway
- Oversized payloads could cause memory exhaustion

**Sub-questions**:
1. **Message size limits**: What's a reasonable maximum message size for Streamable HTTP requests?
2. **JSON parsing safety**: TypeScript's `JSON.parse` handles most edge cases. Any concerns with deeply nested objects, duplicate keys?
3. **Rate limiting**: Should the gateway rate-limit tool calls from the agent?
4. **Malformed message handling**: Return JSON-RPC error? Log and drop?

**Impact**: The gateway is the security boundary. If it can be crashed or confused by adversarial input, the entire model fails.
