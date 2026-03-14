"""Audit logging — structured JSON.

Every tool call produces an audit log entry. Sensitive values are
replaced with pattern_name + truncated SHA-256 hash.
"""

import hashlib
import json
import logging
import sys
from datetime import datetime, timezone

from src.gateway.scanner.engine import ScanResult

logger = logging.getLogger("tidegate.audit")


def _truncated_hash(value: str) -> str:
    """Produce a 4-character hex hash for audit correlation."""
    return hashlib.sha256(value.encode()).hexdigest()[:4]


def audit_entry(tool_name: str, server: str, result: str,
                scan_result: ScanResult | None = None) -> dict:
    """Produce structured audit log entry.

    Args:
        tool_name: The MCP tool name (may be prefixed).
        server: The downstream server name.
        result: "allowed" or "denied".
        scan_result: If denied, the scan result with match details.

    Returns:
        A JSON-serializable dict suitable for NDJSON logging.
    """
    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "tool_name": tool_name,
        "server": server,
        "result": result,
    }

    if scan_result and scan_result.match:
        entry["scan_match"] = {
            "pattern_name": scan_result.match.pattern_name,
            "redacted_hash": _truncated_hash(scan_result.match.matched_value),
        }

    return entry


def log_audit(entry: dict) -> None:
    """Write an audit entry to the audit log as NDJSON."""
    logger.info(json.dumps(entry, separators=(",", ":")))
