"""Skeleton integration tests — acceptance criteria for SPEC-007.

These tests define the end-to-end behavior we need. They will fail initially
because the stubs raise NotImplementedError.
"""

import json
import pytest
import asyncio
from aiohttp import web
from aiohttp.test_utils import AioHTTPTestCase, TestServer

from src.gateway.config import GatewayConfig, ServerConfig
from src.gateway.scanner.engine import ScanEngine
from src.gateway.proxy import MCPProxy


def make_config(server_url: str, **overrides) -> GatewayConfig:
    defaults = {
        "listen": "0.0.0.0:4100",
        "scan_timeout_ms": 500,
        "scan_failure_mode": "deny",
        "servers": [ServerConfig(name="echo", transport="http", url=server_url)],
    }
    defaults.update(overrides)
    return GatewayConfig(**defaults)


def make_jsonrpc(method: str, params: dict | None = None, id: int = 1) -> dict:
    msg = {"jsonrpc": "2.0", "method": method, "id": id}
    if params is not None:
        msg["params"] = params
    return msg


class TestIntegrationSkeleton:
    """These tests verify the full gateway flow and MUST fail until implementation is complete."""

    @pytest.mark.asyncio
    async def test_tools_list_aggregates_from_downstream(self):
        """AC1: tools/list aggregates from single downstream server."""
        config = make_config("http://fake:4200/mcp")
        scanner = ScanEngine()
        proxy = MCPProxy(config, scanner)

        # This should fail with NotImplementedError until proxy is implemented
        result = await proxy.handle_tools_list()
        assert "tools" in result

    @pytest.mark.asyncio
    async def test_clean_call_forwarded(self):
        """AC6: Clean arguments -> forwarded, response returned."""
        config = make_config("http://fake:4200/mcp")
        scanner = ScanEngine()
        proxy = MCPProxy(config, scanner)

        request = make_jsonrpc("tools/call", {
            "name": "echo__say_hello",
            "arguments": {"message": "hello world"},
        })
        result = await proxy.handle_tools_call(request["params"])
        assert "content" in result

    @pytest.mark.asyncio
    async def test_aws_key_in_argument_blocked(self):
        """AC3: AWS access key in argument -> blocked with shaped deny."""
        config = make_config("http://fake:4200/mcp")
        scanner = ScanEngine()
        proxy = MCPProxy(config, scanner)

        request = make_jsonrpc("tools/call", {
            "name": "echo__say_hello",
            "arguments": {"message": "my key is AKIAIOSFODNN7EXAMPLE"},
        })
        result = await proxy.handle_tools_call(request["params"])
        assert result.get("isError") is False
        # Shaped deny should not echo the key
        result_text = json.dumps(result)
        assert "AKIAIOSFODNN7EXAMPLE" not in result_text
