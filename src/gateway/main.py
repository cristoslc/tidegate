"""Entry point — config loading, HTTP server."""

import asyncio
import sys

from aiohttp import web

from src.gateway.config import load_config
from src.gateway.proxy import MCPProxy
from src.gateway.scanner.engine import ScanEngine


def create_app(config_path: str = "tidegate.yaml") -> web.Application:
    """Create and configure the aiohttp application."""
    raise NotImplementedError


def main() -> None:
    config_path = sys.argv[1] if len(sys.argv) > 1 else "tidegate.yaml"
    app = create_app(config_path)
    web.run_app(app)


if __name__ == "__main__":
    main()
