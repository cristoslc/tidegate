"""Tests for audit logging — structured JSON entries."""

import json
from datetime import datetime

import pytest

from src.gateway.scanner.patterns import ScanMatch
from src.gateway.scanner.engine import ScanResult
from src.gateway.audit import audit_entry


class TestAuditEntry:
    def test_has_timestamp(self):
        """Every audit entry has a timestamp."""
        entry = audit_entry(
            tool_name="gmail__send_email",
            server="gmail",
            result="allowed",
        )
        assert "timestamp" in entry
        # Should be a valid ISO format timestamp
        datetime.fromisoformat(entry["timestamp"])

    def test_has_tool_name(self):
        entry = audit_entry(
            tool_name="slack__post_message",
            server="slack",
            result="allowed",
        )
        assert entry["tool_name"] == "slack__post_message"

    def test_has_server(self):
        entry = audit_entry(
            tool_name="gmail__send_email",
            server="gmail",
            result="allowed",
        )
        assert entry["server"] == "gmail"

    def test_allowed_result(self):
        entry = audit_entry(
            tool_name="echo__hello",
            server="echo",
            result="allowed",
        )
        assert entry["result"] == "allowed"

    def test_denied_result(self):
        entry = audit_entry(
            tool_name="gmail__send_email",
            server="gmail",
            result="denied",
            scan_result=ScanResult(
                clean=False,
                match=ScanMatch(pattern_name="AWS_ACCESS_KEY", matched_value="AKIAIOSFODNN7EXAMPLE"),
            ),
        )
        assert entry["result"] == "denied"

    def test_sensitive_value_replaced_with_pattern_and_hash(self):
        """Sensitive values replaced with pattern_name + truncated hash."""
        entry = audit_entry(
            tool_name="gmail__send_email",
            server="gmail",
            result="denied",
            scan_result=ScanResult(
                clean=False,
                match=ScanMatch(pattern_name="CREDIT_CARD", matched_value="4111111111111111"),
            ),
        )
        assert "scan_match" in entry
        assert entry["scan_match"]["pattern_name"] == "CREDIT_CARD"
        # Value should be redacted, not the original
        assert "4111111111111111" not in json.dumps(entry)
        # Should contain a hash identifier
        assert "redacted_hash" in entry["scan_match"]

    def test_serializable_as_json(self):
        """Entry can be serialized to JSON (NDJSON compatible)."""
        entry = audit_entry(
            tool_name="gmail__send_email",
            server="gmail",
            result="denied",
            scan_result=ScanResult(
                clean=False,
                match=ScanMatch(pattern_name="SSN", matched_value="078-05-1120"),
            ),
        )
        json_str = json.dumps(entry)
        parsed = json.loads(json_str)
        assert parsed["tool_name"] == "gmail__send_email"
        # Must not contain the actual SSN
        assert "078-05-1120" not in json_str

    def test_allowed_entry_has_no_scan_match(self):
        """Allowed entries have no scan_match field."""
        entry = audit_entry(
            tool_name="echo__hello",
            server="echo",
            result="allowed",
        )
        assert "scan_match" not in entry or entry.get("scan_match") is None
