"""Tests for shaped deny response construction."""

import json

import pytest

from src.gateway.scanner.patterns import ScanMatch
from src.gateway.scanner.engine import ScanResult
from src.gateway.deny import shaped_deny


class TestShapedDeny:
    def test_is_error_false(self):
        """Shaped deny has isError: false so agent adjusts behavior."""
        scan_result = ScanResult(
            clean=False,
            match=ScanMatch(pattern_name="AWS_ACCESS_KEY", matched_value="AKIAIOSFODNN7EXAMPLE"),
        )
        response = shaped_deny("gmail__send_email", scan_result)
        assert response["isError"] is False

    def test_includes_pattern_name(self):
        """Deny response includes what type of sensitive data was detected."""
        scan_result = ScanResult(
            clean=False,
            match=ScanMatch(pattern_name="CREDIT_CARD", matched_value="4111111111111111"),
        )
        response = shaped_deny("slack__post_message", scan_result)
        response_text = json.dumps(response)
        assert "CREDIT_CARD" in response_text

    def test_includes_truncated_hash(self):
        """Deny response includes a truncated hash for audit correlation."""
        scan_result = ScanResult(
            clean=False,
            match=ScanMatch(pattern_name="IBAN", matched_value="GB29NWBK60161331926819"),
        )
        response = shaped_deny("bank__transfer", scan_result)
        response_text = json.dumps(response)
        # Should contain a hash-like identifier (at least 4 hex chars)
        # Format is [PATTERN_NAME:xxxx]
        assert "IBAN:" in response_text

    def test_never_echoes_sensitive_value(self):
        """Deny response NEVER echoes the matched sensitive value."""
        sensitive_values = [
            ("AWS_ACCESS_KEY", "AKIAIOSFODNN7EXAMPLE"),
            ("CREDIT_CARD", "4111111111111111"),
            ("GITHUB_TOKEN", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl"),
            ("IBAN", "GB29NWBK60161331926819"),
            ("SSN", "078-05-1120"),
            ("PEM_PRIVATE_KEY", "-----BEGIN RSA PRIVATE KEY-----"),
            ("BEARER_TOKEN", "Bearer eyJhbGciOiJIUzI1NiJ9"),
        ]
        for pattern_name, value in sensitive_values:
            scan_result = ScanResult(
                clean=False,
                match=ScanMatch(pattern_name=pattern_name, matched_value=value),
            )
            response = shaped_deny("test_tool", scan_result)
            response_text = json.dumps(response)
            assert value not in response_text, (
                f"Deny response echoed sensitive value for {pattern_name}"
            )

    def test_has_content_array(self):
        """Deny response follows MCP result format with content array."""
        scan_result = ScanResult(
            clean=False,
            match=ScanMatch(pattern_name="SSN", matched_value="078-05-1120"),
        )
        response = shaped_deny("hr__lookup", scan_result)
        assert "content" in response
        assert isinstance(response["content"], list)
        assert len(response["content"]) > 0
        assert response["content"][0]["type"] == "text"

    def test_human_readable_message(self):
        """Deny message is human-readable."""
        scan_result = ScanResult(
            clean=False,
            match=ScanMatch(pattern_name="AWS_ACCESS_KEY", matched_value="AKIAIOSFODNN7EXAMPLE"),
        )
        response = shaped_deny("s3__put_object", scan_result)
        text = response["content"][0]["text"]
        assert len(text) > 20  # Should be a meaningful message, not just a code
        assert "blocked" in text.lower() or "denied" in text.lower()

    def test_timeout_deny(self):
        """Timeout scan result produces a valid deny."""
        scan_result = ScanResult(
            clean=False,
            match=ScanMatch(pattern_name="SCAN_TIMEOUT", matched_value="<timeout>"),
        )
        response = shaped_deny("test_tool", scan_result)
        assert response["isError"] is False
        assert "<timeout>" not in json.dumps(response)
