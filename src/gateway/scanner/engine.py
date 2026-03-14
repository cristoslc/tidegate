"""Scanner orchestrator — runs L1 then L2, handles timeout."""

from dataclasses import dataclass
from typing import Any


@dataclass
class ScanResult:
    clean: bool
    match: Any | None = None  # ScanMatch if not clean


class ScanEngine:
    def __init__(self, timeout_ms: int = 500, failure_mode: str = "deny"):
        self.timeout_ms = timeout_ms
        self.failure_mode = failure_mode

    async def scan(self, data: Any) -> ScanResult:
        """Recursively scan all string values. Returns first match or clean."""
        raise NotImplementedError
