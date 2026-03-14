"""Shared test fixtures."""

import pytest


@pytest.fixture
def sample_config_yaml(tmp_path):
    """Create a sample tidegate.yaml for testing."""
    config = tmp_path / "tidegate.yaml"
    config.write_text("""
gateway:
  listen: "0.0.0.0:4100"
  scan_timeout_ms: 500
  scan_failure_mode: deny

servers:
  echo:
    transport: http
    url: http://localhost:4200/mcp
""")
    return str(config)


@pytest.fixture
def multi_server_config_yaml(tmp_path):
    """Config with multiple downstream servers."""
    config = tmp_path / "tidegate.yaml"
    config.write_text("""
gateway:
  listen: "0.0.0.0:4100"
  scan_timeout_ms: 500
  scan_failure_mode: deny

servers:
  gmail:
    transport: http
    url: http://gmail-mcp:3000/mcp
  slack:
    transport: http
    url: http://slack-mcp:3000/mcp
""")
    return str(config)
