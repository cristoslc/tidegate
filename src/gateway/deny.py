"""Shaped deny response construction.

Deny responses use isError: false so the agent adjusts its behavior
rather than retrying. The sensitive value is NEVER echoed in the response.
"""

import hashlib

from src.gateway.scanner.engine import ScanResult


def _truncated_hash(value: str) -> str:
    """Produce a 4-character hex hash for audit correlation."""
    return hashlib.sha256(value.encode()).hexdigest()[:4]


def shaped_deny(tool_name: str, scan_result: ScanResult) -> dict:
    """Build MCP-compliant deny response that doesn't echo sensitive value.

    Returns a dict with:
    - content: [{type: "text", text: "..."}]
    - isError: False
    """
    match = scan_result.match
    pattern_name = match.pattern_name
    value_hash = _truncated_hash(match.matched_value)

    if pattern_name == "SCAN_TIMEOUT":
        text = (
            f"Blocked: tool call to '{tool_name}' was denied because the "
            f"security scan timed out. The scan could not complete within "
            f"the configured timeout. [{pattern_name}:{value_hash}]"
        )
    else:
        text = (
            f"Blocked: tool call to '{tool_name}' was denied because "
            f"sensitive data of type {pattern_name} was detected in the "
            f"request. The value has been redacted. [{pattern_name}:{value_hash}]"
        )

    return {
        "content": [{"type": "text", "text": text}],
        "isError": False,
    }
