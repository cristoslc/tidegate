"""Configuration parsing for tidegate.yaml."""

from dataclasses import dataclass


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
    raise NotImplementedError
