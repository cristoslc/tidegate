"""Tests for L1 regex scanner patterns."""

import pytest
from src.gateway.scanner.patterns import scan_l1


class TestAWSAccessKey:
    def test_detects_aws_access_key(self):
        result = scan_l1("my key is AKIAIOSFODNN7EXAMPLE")
        assert result is not None
        assert result.pattern_name == "AWS_ACCESS_KEY"

    def test_detects_aws_key_in_json(self):
        result = scan_l1('{"aws_access_key_id": "AKIAI44QH8DHBEXAMPLE"}')
        assert result is not None
        assert result.pattern_name == "AWS_ACCESS_KEY"

    def test_ignores_partial_aws_key(self):
        """AKIA followed by too few characters is not a match."""
        result = scan_l1("AKIA1234")
        assert result is None


class TestGitHubToken:
    def test_detects_ghp_token(self):
        result = scan_l1("token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")
        assert result is not None
        assert result.pattern_name == "GITHUB_TOKEN"

    def test_detects_ghs_token(self):
        result = scan_l1("ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl")
        assert result is not None
        assert result.pattern_name == "GITHUB_TOKEN"

    def test_ignores_short_gh_prefix(self):
        result = scan_l1("ghp_short")
        assert result is None


class TestSlackToken:
    def test_detects_xoxb_token(self):
        result = scan_l1("xoxb-123456789012-1234567890123-AbCdEfGhIjKlMnOpQrStUvWx")
        assert result is not None
        assert result.pattern_name == "SLACK_TOKEN"

    def test_detects_xoxp_token(self):
        result = scan_l1("xoxp-123456789012-1234567890123-AbCdEfGhIjKlMnOp")
        assert result is not None
        assert result.pattern_name == "SLACK_TOKEN"


class TestPEMPrivateKey:
    def test_detects_rsa_private_key(self):
        result = scan_l1("-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA...")
        assert result is not None
        assert result.pattern_name == "PEM_PRIVATE_KEY"

    def test_detects_generic_private_key(self):
        result = scan_l1("-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBg...")
        assert result is not None
        assert result.pattern_name == "PEM_PRIVATE_KEY"

    def test_detects_ec_private_key(self):
        result = scan_l1("-----BEGIN EC PRIVATE KEY-----\nMHQCAQEEI...")
        assert result is not None
        assert result.pattern_name == "PEM_PRIVATE_KEY"


class TestBearerToken:
    def test_detects_bearer_token(self):
        result = scan_l1("Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U")
        assert result is not None
        assert result.pattern_name == "BEARER_TOKEN"

    def test_detects_simple_bearer(self):
        result = scan_l1("Bearer abc123def456")
        assert result is not None
        assert result.pattern_name == "BEARER_TOKEN"


class TestCleanStrings:
    def test_normal_text_passes(self):
        assert scan_l1("Hello, world!") is None

    def test_email_passes(self):
        assert scan_l1("user@example.com") is None

    def test_url_passes(self):
        assert scan_l1("https://example.com/api/v1/resource") is None

    def test_empty_string_passes(self):
        assert scan_l1("") is None

    def test_numbers_pass(self):
        assert scan_l1("The answer is 42") is None
