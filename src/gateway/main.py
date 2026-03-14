"""Entry point -- config loading, HTTP server.

Serves the MCP protocol over HTTP. The agent sends JSON-RPC messages
to POST /mcp and receives JSON-RPC responses.
"""

import json
import logging
import os
import sys

from aiohttp import web

from src.gateway.config import load_config
from src.gateway.proxy import MCPProxy
from src.gateway.scanner.engine import ScanEngine

logger = logging.getLogger("tidegate.gateway")


async def handle_mcp(request: web.Request) -> web.Response:
    """Handle MCP JSON-RPC messages."""
    proxy: MCPProxy = request.app["proxy"]

    try:
        body = await request.json()
    except json.JSONDecodeError:
        return web.json_response(
            {"jsonrpc": "2.0", "error": {"code": -32700, "message": "Parse error"}, "id": None},
            status=400,
        )

    method = body.get("method")
    req_id = body.get("id")
    params = body.get("params", {})

    if method == "tools/list":
        result = await proxy.handle_tools_list()
        return web.json_response({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": result,
        })
    elif method == "tools/call":
        result = await proxy.handle_tools_call(params)
        return web.json_response({
            "jsonrpc": "2.0",
            "id": req_id,
            "result": result,
        })
    else:
        return web.json_response({
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        })


async def handle_health(request: web.Request) -> web.Response:
    """Health check endpoint for Docker HEALTHCHECK."""
    return web.json_response({"status": "ok"})


def create_app(config_path: str = "tidegate.yaml") -> web.Application:
    """Create and configure the aiohttp application."""
    config = load_config(config_path)

    scanner = ScanEngine(
        timeout_ms=config.scan_timeout_ms,
        failure_mode=config.scan_failure_mode,
    )
    proxy = MCPProxy(config, scanner)

    app = web.Application()
    app["proxy"] = proxy
    app["config"] = config
    app.router.add_post("/mcp", handle_mcp)
    app.router.add_get("/health", handle_health)

    return app


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    config_path = os.environ.get("TIDEGATE_CONFIG", "tidegate.yaml")
    if len(sys.argv) > 1:
        config_path = sys.argv[1]

    app = create_app(config_path)
    config = app["config"]

    host, port_str = config.listen.rsplit(":", 1)
    port = int(port_str)

    logger.info("Starting tg-gateway on %s:%d", host, port)
    web.run_app(app, host=host, port=port, print=None)


if __name__ == "__main__":
    main()
