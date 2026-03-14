"""MCP protocol proxy — tools/list aggregation, tools/call routing."""

from src.gateway.config import GatewayConfig
from src.gateway.scanner.engine import ScanEngine


class MCPProxy:
    def __init__(self, config: GatewayConfig, scanner: ScanEngine):
        self.config = config
        self.scanner = scanner

    async def handle_tools_list(self) -> dict:
        """Aggregate tool lists from all downstream servers."""
        raise NotImplementedError

    async def handle_tools_call(self, request: dict) -> dict:
        """Scan args, forward, scan response, return result or deny."""
        raise NotImplementedError
