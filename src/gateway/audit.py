"""Audit logging — structured JSON."""

from src.gateway.scanner.engine import ScanResult


def audit_entry(tool_name: str, server: str, result: str,
                scan_result: ScanResult | None = None) -> dict:
    """Produce structured audit log entry."""
    raise NotImplementedError
