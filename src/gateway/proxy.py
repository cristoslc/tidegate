"""MCP protocol proxy -- tools/list aggregation, tools/call routing.

The proxy sits between the agent and downstream MCP servers. It:
1. Aggregates tools from all configured downstream servers (prefixed names)
2. Scans tool call arguments before forwarding
3. Scans responses before returning to the agent
4. Returns shaped denies on policy violations
5. Produces audit log entries for every call
"""

import aiohttp

from src.gateway.config import GatewayConfig, ServerConfig
from src.gateway.scanner.engine import ScanEngine, ScanResult
from src.gateway.deny import shaped_deny
from src.gateway.audit import audit_entry, log_audit


class MCPProxy:
    def __init__(self, config: GatewayConfig, scanner: ScanEngine):
        self.config = config
        self.scanner = scanner
        self.audit_log: list[dict] = []

    def _resolve_server(self, prefixed_name: str) -> tuple[ServerConfig, str] | None:
        """Resolve a prefixed tool name to (server_config, original_tool_name).

        Tool names are prefixed as: servername__toolname
        """
        for server in self.config.servers:
            prefix = server.name + "__"
            if prefixed_name.startswith(prefix):
                original_name = prefixed_name[len(prefix):]
                return server, original_name
        return None

    async def handle_tools_list(self) -> dict:
        """Aggregate tool lists from all downstream servers.

        Each tool name is prefixed with the server name to avoid collisions:
        e.g., gmail__send_email, slack__post_message
        """
        all_tools = []

        async with aiohttp.ClientSession() as session:
            for server in self.config.servers:
                tools = await self._fetch_tools(session, server)
                for tool in tools:
                    prefixed_tool = dict(tool)
                    prefixed_tool["name"] = f"{server.name}__{tool['name']}"
                    all_tools.append(prefixed_tool)

        return {"tools": all_tools}

    async def handle_tools_call(self, request: dict) -> dict:
        """Scan args, forward to downstream, scan response, return result or deny.

        Every call produces an audit log entry regardless of outcome.
        """
        prefixed_name = request.get("name", "")
        arguments = request.get("arguments", {})

        resolved = self._resolve_server(prefixed_name)
        if resolved is None:
            return {
                "content": [{"type": "text", "text": f"Unknown tool: {prefixed_name}"}],
                "isError": True,
            }

        server, original_name = resolved

        # Step 1: Scan arguments
        arg_scan = await self.scanner.scan(arguments)
        if not arg_scan.clean:
            deny = shaped_deny(prefixed_name, arg_scan)
            entry = audit_entry(
                tool_name=prefixed_name,
                server=server.name,
                result="denied",
                scan_result=arg_scan,
            )
            self.audit_log.append(entry)
            log_audit(entry)
            return deny

        # Step 2: Forward to downstream server
        response_result = await self._forward_call(server, original_name, arguments)

        # Step 3: Scan response
        resp_scan = await self.scanner.scan(response_result)
        if not resp_scan.clean:
            deny = shaped_deny(prefixed_name, resp_scan)
            entry = audit_entry(
                tool_name=prefixed_name,
                server=server.name,
                result="denied",
                scan_result=resp_scan,
            )
            self.audit_log.append(entry)
            log_audit(entry)
            return deny

        # Step 4: Return clean response
        entry = audit_entry(
            tool_name=prefixed_name,
            server=server.name,
            result="allowed",
        )
        self.audit_log.append(entry)
        log_audit(entry)
        return response_result

    async def _fetch_tools(self, session: aiohttp.ClientSession,
                           server: ServerConfig) -> list[dict]:
        """Fetch tool list from a downstream MCP server."""
        payload = {
            "jsonrpc": "2.0",
            "method": "tools/list",
            "id": 1,
        }
        async with session.post(server.url, json=payload) as resp:
            data = await resp.json()
            return data.get("result", {}).get("tools", [])

    async def _forward_call(self, server: ServerConfig, tool_name: str,
                            arguments: dict) -> dict:
        """Forward a tool call to a downstream MCP server and return the result."""
        payload = {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "id": 1,
            "params": {
                "name": tool_name,
                "arguments": arguments,
            },
        }
        async with aiohttp.ClientSession() as session:
            async with session.post(server.url, json=payload) as resp:
                data = await resp.json()
                return data.get("result", {})
