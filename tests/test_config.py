"""Tests for configuration parsing."""

import pytest
from src.gateway.config import load_config, GatewayConfig, ServerConfig


class TestConfigParsing:
    def test_parse_valid_yaml(self, tmp_path):
        """Parse a valid tidegate.yaml with all fields."""
        config_file = tmp_path / "tidegate.yaml"
        config_file.write_text("""
gateway:
  listen: "0.0.0.0:4100"
  scan_timeout_ms: 300
  scan_failure_mode: allow

servers:
  gmail:
    transport: http
    url: http://gmail-mcp:3000/mcp
""")
        config = load_config(str(config_file))
        assert isinstance(config, GatewayConfig)
        assert config.listen == "0.0.0.0:4100"
        assert config.scan_timeout_ms == 300
        assert config.scan_failure_mode == "allow"
        assert len(config.servers) == 1
        assert config.servers[0].name == "gmail"
        assert config.servers[0].transport == "http"
        assert config.servers[0].url == "http://gmail-mcp:3000/mcp"

    def test_default_values(self, tmp_path):
        """Missing gateway section uses defaults."""
        config_file = tmp_path / "tidegate.yaml"
        config_file.write_text("""
servers:
  echo:
    transport: http
    url: http://localhost:4200/mcp
""")
        config = load_config(str(config_file))
        assert config.listen == "0.0.0.0:4100"
        assert config.scan_timeout_ms == 500
        assert config.scan_failure_mode == "deny"

    def test_default_gateway_values_partial(self, tmp_path):
        """Partial gateway section fills in defaults."""
        config_file = tmp_path / "tidegate.yaml"
        config_file.write_text("""
gateway:
  listen: "0.0.0.0:5000"

servers:
  echo:
    transport: http
    url: http://localhost:4200/mcp
""")
        config = load_config(str(config_file))
        assert config.listen == "0.0.0.0:5000"
        assert config.scan_timeout_ms == 500
        assert config.scan_failure_mode == "deny"

    def test_multiple_servers(self, tmp_path):
        """Multiple servers parsed correctly."""
        config_file = tmp_path / "tidegate.yaml"
        config_file.write_text("""
gateway:
  listen: "0.0.0.0:4100"

servers:
  gmail:
    transport: http
    url: http://gmail-mcp:3000/mcp
  slack:
    transport: http
    url: http://slack-mcp:3000/mcp
  github:
    transport: http
    url: http://github-mcp:3000/mcp
""")
        config = load_config(str(config_file))
        assert len(config.servers) == 3
        names = [s.name for s in config.servers]
        assert "gmail" in names
        assert "slack" in names
        assert "github" in names

    def test_missing_servers_raises(self, tmp_path):
        """Config with no servers section raises ValueError."""
        config_file = tmp_path / "tidegate.yaml"
        config_file.write_text("""
gateway:
  listen: "0.0.0.0:4100"
""")
        with pytest.raises(ValueError, match="servers"):
            load_config(str(config_file))

    def test_missing_file_raises(self):
        """Non-existent config file raises FileNotFoundError."""
        with pytest.raises(FileNotFoundError):
            load_config("/nonexistent/tidegate.yaml")
