"""Shaped deny response construction."""

from src.gateway.scanner.engine import ScanResult


def shaped_deny(tool_name: str, scan_result: ScanResult) -> dict:
    """Build MCP-compliant deny response that doesn't echo sensitive value."""
    raise NotImplementedError
