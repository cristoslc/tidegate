"""Configuration parsing for tidegate.yaml."""

from dataclasses import dataclass

import yaml


_DEFAULTS = {
    "listen": "0.0.0.0:4100",
    "scan_timeout_ms": 500,
    "scan_failure_mode": "deny",
}


@dataclass
class ServerConfig:
    name: str
    transport: str
    url: str


@dataclass
class GatewayConfig:
    listen: str
    scan_timeout_ms: int
    scan_failure_mode: str
    servers: list[ServerConfig]


def load_config(path: str) -> GatewayConfig:
    """Load and parse a tidegate.yaml configuration file.

    Raises:
        FileNotFoundError: if the config file does not exist.
        ValueError: if no servers are configured.
    """
    with open(path) as f:
        raw = yaml.safe_load(f)

    if raw is None:
        raw = {}

    gateway_raw = raw.get("gateway", {}) or {}
    servers_raw = raw.get("servers")

    if not servers_raw:
        raise ValueError("Configuration must include a 'servers' section with at least one server")

    listen = gateway_raw.get("listen", _DEFAULTS["listen"])
    scan_timeout_ms = gateway_raw.get("scan_timeout_ms", _DEFAULTS["scan_timeout_ms"])
    scan_failure_mode = gateway_raw.get("scan_failure_mode", _DEFAULTS["scan_failure_mode"])

    servers = []
    for name, server_data in servers_raw.items():
        servers.append(ServerConfig(
            name=name,
            transport=server_data["transport"],
            url=server_data["url"],
        ))

    return GatewayConfig(
        listen=listen,
        scan_timeout_ms=scan_timeout_ms,
        scan_failure_mode=scan_failure_mode,
        servers=servers,
    )
