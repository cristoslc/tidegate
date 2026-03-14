# MCP Scanning Gateway Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan.

**Goal:** Implement tg-gateway as a Python MCP protocol proxy that aggregates tools from downstream servers, scans all string values for sensitive data via a two-tier pipeline (regex + checksum), and returns shaped denies on policy violations.

**Architecture:** The gateway is an HTTP server that proxies MCP protocol messages. On `tools/list`, it aggregates tool definitions from all configured downstream servers (prefixing names to avoid collision). On `tools/call`, it scans arguments via L1 regex patterns and L2 checksum validators, forwards clean calls to the appropriate downstream server, scans the response, and returns either the result or a shaped deny. Every call produces a structured audit log entry.

**Tech Stack:** Python 3.12, pytest, aiohttp (HTTP server + client), python-stdnum (checksum validation), PyYAML (config), uv (package management)

---

### Task 1: Project scaffolding and skeleton integration test

**Files:**
- Create: `pyproject.toml`
- Create: `src/gateway/__init__.py`
- Create: `src/gateway/main.py`
- Create: `src/gateway/config.py`
- Create: `src/gateway/proxy.py`
- Create: `src/gateway/scanner/__init__.py`
- Create: `src/gateway/scanner/engine.py`
- Create: `src/gateway/scanner/patterns.py`
- Create: `src/gateway/scanner/checksums.py`
- Create: `src/gateway/deny.py`
- Create: `src/gateway/audit.py`
- Create: `tests/conftest.py`
- Create: `tests/test_integration.py`

- [ ] **Step 1: Initialize Python project with uv**

```sh
cd /path/to/worktree
uv init --name tidegate-gateway --python 3.12
uv add aiohttp pyyaml python-stdnum
uv add --dev pytest pytest-asyncio pytest-timeout aiohttp
```

- [ ] **Step 2: Create package structure**

Create all `__init__.py` files and stub modules with minimal content (empty classes/functions that raise `NotImplementedError`).

- [ ] **Step 3: Write skeleton integration test (RED)**

`tests/test_integration.py` — Tests acceptance criteria 1, 3, 6 at a high level:
- Start gateway with a mock downstream server
- `tools/list` returns aggregated tools
- Clean `tools/call` forwards and returns result
- AWS key in argument returns shaped deny

This test MUST fail initially (skeleton stubs raise NotImplementedError).

- [ ] **Step 4: Commit**

```sh
git add pyproject.toml uv.lock src/gateway/ tests/
git commit -m "feat: scaffold gateway project with failing integration test

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Configuration parsing

**Files:**
- Modify: `src/gateway/config.py`
- Create: `tests/test_config.py`

- [ ] **Step 1: Write config tests (RED)**

`tests/test_config.py`:
- Parse valid YAML with gateway section and servers
- Default values for scan_timeout_ms (500) and scan_failure_mode (deny)
- Multiple servers parsed correctly
- Missing gateway section uses defaults

- [ ] **Step 2: Implement config.py (GREEN)**

Parse `tidegate.yaml` into dataclasses:
```python
@dataclass
class ServerConfig:
    name: str
    transport: str
    url: str

@dataclass
class GatewayConfig:
    listen: str
    scan_timeout_ms: int
    scan_failure_mode: str  # "deny" | "allow"
    servers: list[ServerConfig]
```

- [ ] **Step 3: Commit**

```sh
git add src/gateway/config.py tests/test_config.py
git commit -m "feat: implement config parsing for tidegate.yaml

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: L1 scanner — regex patterns

**Files:**
- Modify: `src/gateway/scanner/patterns.py`
- Create: `tests/test_scanner_patterns.py`

- [ ] **Step 1: Write pattern tests (RED)**

`tests/test_scanner_patterns.py` — One test per pattern type:
- AWS access key (AKIA + 16 alphanum) -> detected
- GitHub token (ghp_ + 36 alphanum) -> detected
- Slack bot token (xoxb-...) -> detected
- PEM private key block -> detected
- Bearer token -> detected
- Clean strings -> not detected
- Each match returns pattern name (e.g., "AWS_ACCESS_KEY")

- [ ] **Step 2: Implement patterns.py (GREEN)**

```python
PATTERNS: list[tuple[str, re.Pattern]] = [
    ("AWS_ACCESS_KEY", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("GITHUB_TOKEN", re.compile(r"gh[ps]_[A-Za-z0-9_]{36,}")),
    ("SLACK_TOKEN", re.compile(r"xox[bporas]-[0-9A-Za-z\-]+")),
    ("PEM_PRIVATE_KEY", re.compile(r"-----BEGIN (?:RSA |EC |DSA )?PRIVATE KEY-----")),
    ("BEARER_TOKEN", re.compile(r"Bearer\s+[A-Za-z0-9\-._~+/]+=*")),
]

def scan_l1(value: str) -> ScanResult | None:
    """Returns first match or None if clean."""
```

- [ ] **Step 3: Commit**

```sh
git add src/gateway/scanner/patterns.py tests/test_scanner_patterns.py
git commit -m "feat: implement L1 regex scanner patterns

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: L2 scanner — checksum validators

**Files:**
- Modify: `src/gateway/scanner/checksums.py`
- Create: `tests/test_scanner_checksums.py`

- [ ] **Step 1: Write checksum tests (RED)**

`tests/test_scanner_checksums.py`:
- Luhn-valid credit card number (4111111111111111) -> detected
- Luhn-invalid number -> not detected
- Valid IBAN (GB29 NWBK 6016 1331 9268 19) -> detected
- Invalid IBAN -> not detected
- Valid SSN format (078-05-1120) -> detected
- Random digits -> not detected

- [ ] **Step 2: Implement checksums.py (GREEN)**

Use `python-stdnum` for IBAN and credit card validation. Implement SSN structure validation. Extract candidate numbers from strings via regex, then validate with checksums.

```python
def scan_l2(value: str) -> ScanResult | None:
    """Returns first checksum-validated match or None if clean."""
```

- [ ] **Step 3: Commit**

```sh
git add src/gateway/scanner/checksums.py tests/test_scanner_checksums.py
git commit -m "feat: implement L2 checksum validators (Luhn, IBAN, SSN)

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 5: Scanner engine (orchestrator)

**Files:**
- Modify: `src/gateway/scanner/engine.py`
- Create: `tests/test_scanner_engine.py`

- [ ] **Step 1: Write engine tests (RED)**

`tests/test_scanner_engine.py`:
- Scans all string values recursively from dict
- Scans nested JSON strings (one level decode)
- L1 match blocks immediately (no L2 needed)
- L2 match blocks after L1 passes
- Clean value passes both tiers
- Timeout handling: scan exceeding timeout returns deny (in deny mode)
- Timeout handling: scan exceeding timeout returns allow (in allow mode)
- Single match in deep nesting blocks entire call

- [ ] **Step 2: Implement engine.py (GREEN)**

```python
class ScanEngine:
    def __init__(self, timeout_ms: int = 500, failure_mode: str = "deny"):
        ...

    async def scan(self, data: Any) -> ScanResult:
        """Recursively scan all string values. Returns first match or clean."""

    def _extract_strings(self, data: Any) -> list[str]:
        """Recursively extract all string values, decode nested JSON."""
```

- [ ] **Step 3: Commit**

```sh
git add src/gateway/scanner/engine.py tests/test_scanner_engine.py
git commit -m "feat: implement scanner engine with timeout and recursive extraction

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Shaped deny responses

**Files:**
- Modify: `src/gateway/deny.py`
- Create: `tests/test_deny.py`

- [ ] **Step 1: Write deny tests (RED)**

`tests/test_deny.py`:
- Shaped deny has isError: false
- Deny includes pattern name
- Deny includes truncated hash of matched value
- Deny NEVER echoes the matched sensitive value
- Deny message is human-readable

- [ ] **Step 2: Implement deny.py (GREEN)**

```python
def shaped_deny(tool_name: str, scan_result: ScanResult) -> dict:
    """Build MCP-compliant deny response that doesn't echo sensitive value."""
    return {
        "content": [{"type": "text", "text": f"..."}],
        "isError": False,
    }
```

- [ ] **Step 3: Commit**

```sh
git add src/gateway/deny.py tests/test_deny.py
git commit -m "feat: implement shaped deny responses

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 7: Audit logging

**Files:**
- Modify: `src/gateway/audit.py`
- Create: `tests/test_audit.py`

- [ ] **Step 1: Write audit tests (RED)**

`tests/test_audit.py`:
- Every call produces a log entry
- Log entry has: timestamp, tool_name, server, result (allowed/denied)
- Sensitive values replaced with pattern_name + truncated hash
- Log entries are structured JSON (NDJSON)

- [ ] **Step 2: Implement audit.py (GREEN)**

```python
def audit_log(tool_name: str, server: str, result: str,
              scan_result: ScanResult | None = None) -> dict:
    """Produce structured audit log entry."""
```

- [ ] **Step 3: Commit**

```sh
git add src/gateway/audit.py tests/test_audit.py
git commit -m "feat: implement structured audit logging

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 8: MCP proxy — tools/list aggregation and tools/call routing

**Files:**
- Modify: `src/gateway/proxy.py`
- Create: `tests/test_proxy.py`

- [ ] **Step 1: Write proxy tests (RED)**

`tests/test_proxy.py`:
- AC1: tools/list aggregates from single downstream server
- AC2: tools/list aggregates from multiple downstream servers (prefixed names)
- AC3: AWS access key in argument -> blocked with shaped deny
- AC4: Credit card (Luhn-valid) in argument -> blocked
- AC5: IBAN in argument -> blocked
- AC6: Clean arguments -> forwarded, response returned
- AC7: GitHub token in response -> blocked
- AC9: Shaped deny doesn't echo matched value
- AC10: Every call produces audit log entry

Use mock downstream servers (aiohttp test server or similar).

- [ ] **Step 2: Implement proxy.py (GREEN)**

```python
class MCPProxy:
    def __init__(self, config: GatewayConfig, scanner: ScanEngine, audit: AuditLogger):
        ...

    async def handle_tools_list(self) -> dict:
        """Aggregate tool lists from all downstream servers."""

    async def handle_tools_call(self, request: dict) -> dict:
        """Scan args, forward, scan response, return result or deny."""

    async def _forward_to_server(self, server: str, request: dict) -> dict:
        """Forward tool call to downstream MCP server."""
```

- [ ] **Step 3: Commit**

```sh
git add src/gateway/proxy.py tests/test_proxy.py
git commit -m "feat: implement MCP proxy with tool aggregation and scanning

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 9: HTTP server entry point

**Files:**
- Modify: `src/gateway/main.py`

- [ ] **Step 1: Implement main.py**

Wire together config, proxy, scanner, and audit into an aiohttp server:
- POST /mcp handles JSON-RPC messages (tools/list, tools/call)
- Loads config from tidegate.yaml (path configurable via env var)
- Binds to configured listen address

- [ ] **Step 2: Commit**

```sh
git add src/gateway/main.py
git commit -m "feat: implement HTTP server entry point

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 10: Integration test (GREEN) and final acceptance

**Files:**
- Modify: `tests/test_integration.py`

- [ ] **Step 1: Update integration test to pass**

With all components implemented, the skeleton integration test from Task 1 should now pass. Add remaining acceptance criteria tests:
- AC8: Scan timeout with deny mode -> blocked
- End-to-end flow with real HTTP

- [ ] **Step 2: Run full test suite**

```sh
uv run pytest tests/ -v
```

All tests must pass.

- [ ] **Step 3: Commit**

```sh
git add tests/
git commit -m "test: all acceptance criteria passing in integration tests

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 11: Dockerfile

**Files:**
- Create: `src/gateway/Dockerfile`
- Create: `src/gateway/tidegate.yaml` (example config)

- [ ] **Step 1: Write Dockerfile**

Following project Docker conventions:
- Pinned base image (python:3.12-alpine with exact digest or tag)
- read_only compatible
- cap_drop: [ALL] compatible
- no-new-privileges compatible
- Non-root user
- HEALTHCHECK instruction

- [ ] **Step 2: Write example tidegate.yaml**

- [ ] **Step 3: Commit**

```sh
git add src/gateway/Dockerfile src/gateway/tidegate.yaml
git commit -m "feat: add Dockerfile and example config

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```
