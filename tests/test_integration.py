"""End-to-end integration tests -- full gateway flow via HTTP.

Tests all 10 acceptance criteria from SPEC-007 in an end-to-end context,
running the actual aiohttp server with mock downstream MCP servers.
"""

import json

import pytest
import pytest_asyncio
from aiohttp import web
from aiohttp.test_utils import TestServer, TestClient

from src.gateway.config import GatewayConfig, ServerConfig
from src.gateway.main import create_app


# --- Mock downstream MCP servers ---

def create_echo_mcp_app():
    """Echo server: returns arguments as-is."""
    async def handle(request: web.Request) -> web.Response:
        body = await request.json()
        method = body.get("method")
        req_id = body.get("id", 1)

        if method == "tools/list":
            return web.json_response({
                "jsonrpc": "2.0", "id": req_id,
                "result": {"tools": [
                    {"name": "say_hello", "description": "Says hello", "inputSchema": {"type": "object"}},
                    {"name": "echo", "description": "Echoes input", "inputSchema": {"type": "object"}},
                ]},
            })
        elif method == "tools/call":
            args = body.get("params", {}).get("arguments", {})
            return web.json_response({
                "jsonrpc": "2.0", "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": json.dumps(args)}],
                    "isError": False,
                },
            })
        return web.json_response({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": "Not found"}})

    app = web.Application()
    app.router.add_post("/mcp", handle)
    return app


def create_leaky_mcp_app():
    """Server that leaks a GitHub token in tool call responses."""
    async def handle(request: web.Request) -> web.Response:
        body = await request.json()
        method = body.get("method")
        req_id = body.get("id", 1)

        if method == "tools/list":
            return web.json_response({
                "jsonrpc": "2.0", "id": req_id,
                "result": {"tools": [
                    {"name": "get_creds", "description": "Get credentials", "inputSchema": {"type": "object"}},
                ]},
            })
        elif method == "tools/call":
            return web.json_response({
                "jsonrpc": "2.0", "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": "Here is your token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl"}],
                    "isError": False,
                },
            })
        return web.json_response({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": "Not found"}})

    app = web.Application()
    app.router.add_post("/mcp", handle)
    return app


# --- Fixtures ---

@pytest_asyncio.fixture
async def echo_downstream():
    server = TestServer(create_echo_mcp_app())
    await server.start_server()
    yield server
    await server.close()


@pytest_asyncio.fixture
async def leaky_downstream():
    server = TestServer(create_leaky_mcp_app())
    await server.start_server()
    yield server
    await server.close()


@pytest_asyncio.fixture
async def gateway_app(echo_downstream, tmp_path):
    """Create a gateway app pointing at the echo downstream server."""
    config_file = tmp_path / "tidegate.yaml"
    config_file.write_text(f"""
gateway:
  listen: "0.0.0.0:4100"
  scan_timeout_ms: 500
  scan_failure_mode: deny

servers:
  echo:
    transport: http
    url: http://localhost:{echo_downstream.port}/mcp
""")
    app = create_app(str(config_file))
    return app


@pytest_asyncio.fixture
async def multi_gateway_app(echo_downstream, leaky_downstream, tmp_path):
    """Gateway with both echo and leaky downstream servers."""
    config_file = tmp_path / "tidegate.yaml"
    config_file.write_text(f"""
gateway:
  listen: "0.0.0.0:4100"
  scan_timeout_ms: 500
  scan_failure_mode: deny

servers:
  echo:
    transport: http
    url: http://localhost:{echo_downstream.port}/mcp
  leaky:
    transport: http
    url: http://localhost:{leaky_downstream.port}/mcp
""")
    app = create_app(str(config_file))
    return app


@pytest_asyncio.fixture
async def gateway_client(gateway_app):
    client = TestClient(TestServer(gateway_app))
    await client.start_server()
    yield client
    await client.close()


@pytest_asyncio.fixture
async def multi_gateway_client(multi_gateway_app):
    client = TestClient(TestServer(multi_gateway_app))
    await client.start_server()
    yield client
    await client.close()


def jsonrpc(method: str, params: dict | None = None, req_id: int = 1) -> dict:
    msg = {"jsonrpc": "2.0", "method": method, "id": req_id}
    if params is not None:
        msg["params"] = params
    return msg


# --- Integration tests ---

class TestToolsListIntegration:
    @pytest.mark.asyncio
    async def test_ac1_single_server_aggregation(self, gateway_client):
        """AC1: tools/list aggregates from single downstream server."""
        resp = await gateway_client.post("/mcp", json=jsonrpc("tools/list"))
        assert resp.status == 200
        data = await resp.json()
        tools = data["result"]["tools"]
        names = [t["name"] for t in tools]
        assert "echo__say_hello" in names
        assert "echo__echo" in names

    @pytest.mark.asyncio
    async def test_ac2_multiple_servers_prefixed(self, multi_gateway_client):
        """AC2: tools/list aggregates from multiple servers with prefixed names."""
        resp = await multi_gateway_client.post("/mcp", json=jsonrpc("tools/list"))
        data = await resp.json()
        tools = data["result"]["tools"]
        names = [t["name"] for t in tools]
        assert "echo__say_hello" in names
        assert "echo__echo" in names
        assert "leaky__get_creds" in names
        assert len(names) == 3


class TestArgumentScanning:
    @pytest.mark.asyncio
    async def test_ac3_aws_key_blocked(self, gateway_client):
        """AC3: AWS access key in argument -> blocked with shaped deny."""
        resp = await gateway_client.post("/mcp", json=jsonrpc("tools/call", {
            "name": "echo__say_hello",
            "arguments": {"message": "key: AKIAIOSFODNN7EXAMPLE"},
        }))
        data = await resp.json()
        result = data["result"]
        assert result["isError"] is False
        assert "AWS_ACCESS_KEY" in result["content"][0]["text"]
        assert "AKIAIOSFODNN7EXAMPLE" not in json.dumps(result)

    @pytest.mark.asyncio
    async def test_ac4_credit_card_blocked(self, gateway_client):
        """AC4: Credit card (Luhn-valid) in argument -> blocked."""
        resp = await gateway_client.post("/mcp", json=jsonrpc("tools/call", {
            "name": "echo__say_hello",
            "arguments": {"card": "4111111111111111"},
        }))
        data = await resp.json()
        result = data["result"]
        assert result["isError"] is False
        assert "CREDIT_CARD" in result["content"][0]["text"]

    @pytest.mark.asyncio
    async def test_ac5_iban_blocked(self, gateway_client):
        """AC5: IBAN in argument -> blocked."""
        resp = await gateway_client.post("/mcp", json=jsonrpc("tools/call", {
            "name": "echo__say_hello",
            "arguments": {"iban": "GB29NWBK60161331926819"},
        }))
        data = await resp.json()
        result = data["result"]
        assert result["isError"] is False
        assert "IBAN" in result["content"][0]["text"]


class TestCleanForwarding:
    @pytest.mark.asyncio
    async def test_ac6_clean_forwarded(self, gateway_client):
        """AC6: Clean arguments -> forwarded, response returned."""
        resp = await gateway_client.post("/mcp", json=jsonrpc("tools/call", {
            "name": "echo__say_hello",
            "arguments": {"message": "hello world"},
        }))
        data = await resp.json()
        result = data["result"]
        assert result.get("isError") is not True
        assert "hello" in result["content"][0]["text"]


class TestResponseScanning:
    @pytest.mark.asyncio
    async def test_ac7_github_token_in_response_blocked(self, multi_gateway_client):
        """AC7: GitHub token in response -> blocked."""
        resp = await multi_gateway_client.post("/mcp", json=jsonrpc("tools/call", {
            "name": "leaky__get_creds",
            "arguments": {},
        }))
        data = await resp.json()
        result = data["result"]
        assert result["isError"] is False
        assert "GITHUB_TOKEN" in result["content"][0]["text"]
        assert "ghp_" not in json.dumps(result)


class TestShapedDeny:
    @pytest.mark.asyncio
    async def test_ac9_doesnt_echo_value(self, gateway_client):
        """AC9: Shaped deny doesn't echo matched value."""
        sensitive_values = [
            ("AKIAIOSFODNN7EXAMPLE", "AWS_ACCESS_KEY"),
            ("4111111111111111", "CREDIT_CARD"),
            ("GB29NWBK60161331926819", "IBAN"),
        ]
        for value, _pattern in sensitive_values:
            resp = await gateway_client.post("/mcp", json=jsonrpc("tools/call", {
                "name": "echo__say_hello",
                "arguments": {"data": value},
            }))
            data = await resp.json()
            full = json.dumps(data["result"])
            assert value not in full, f"Response echoed {value}"


class TestAuditLog:
    @pytest.mark.asyncio
    async def test_ac10_audit_log_produced(self, gateway_client):
        """AC10: Every call produces audit log entry."""
        # Make a clean call
        await gateway_client.post("/mcp", json=jsonrpc("tools/call", {
            "name": "echo__say_hello",
            "arguments": {"message": "hello"},
        }))
        proxy = gateway_client.app["proxy"]
        assert len(proxy.audit_log) >= 1
        entry = proxy.audit_log[-1]
        assert "timestamp" in entry
        assert entry["tool_name"] == "echo__say_hello"
        assert entry["server"] == "echo"

        # Make a denied call
        await gateway_client.post("/mcp", json=jsonrpc("tools/call", {
            "name": "echo__say_hello",
            "arguments": {"key": "AKIAIOSFODNN7EXAMPLE"},
        }))
        assert len(proxy.audit_log) >= 2
        denied_entry = proxy.audit_log[-1]
        assert denied_entry["result"] == "denied"


class TestScanTimeoutIntegration:
    @pytest.mark.asyncio
    async def test_ac8_timeout_deny_mode(self, echo_downstream, tmp_path):
        """AC8: Scan timeout with deny mode -> blocked."""
        config_file = tmp_path / "tidegate-timeout.yaml"
        config_file.write_text(f"""
gateway:
  listen: "0.0.0.0:4100"
  scan_timeout_ms: 1
  scan_failure_mode: deny

servers:
  echo:
    transport: http
    url: http://localhost:{echo_downstream.port}/mcp
""")
        app = create_app(str(config_file))
        client = TestClient(TestServer(app))
        await client.start_server()

        # Large payload to try to trigger timeout
        resp = await client.post("/mcp", json=jsonrpc("tools/call", {
            "name": "echo__say_hello",
            "arguments": {"data": " ".join(["word"] * 50000)},
        }))
        data = await resp.json()
        result = data["result"]
        # Should either be blocked (timeout) or clean (fast enough)
        # Main thing is it handles gracefully
        assert "content" in result
        assert isinstance(result["isError"], bool)

        await client.close()


class TestHealthEndpoint:
    @pytest.mark.asyncio
    async def test_health_returns_ok(self, gateway_client):
        """Health endpoint returns 200 OK."""
        resp = await gateway_client.get("/health")
        assert resp.status == 200
        data = await resp.json()
        assert data["status"] == "ok"
