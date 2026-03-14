"""Scanner orchestrator — runs L1 then L2, handles timeout."""

import asyncio
import json
from dataclasses import dataclass
from typing import Any

from src.gateway.scanner.patterns import ScanMatch, scan_l1
from src.gateway.scanner.checksums import scan_l2


@dataclass
class ScanResult:
    clean: bool
    match: ScanMatch | None = None


class ScanEngine:
    def __init__(self, timeout_ms: int = 500, failure_mode: str = "deny"):
        self.timeout_ms = timeout_ms
        self.failure_mode = failure_mode

    async def scan(self, data: Any) -> ScanResult:
        """Recursively scan all string values. Returns first match or clean.

        On timeout:
        - failure_mode="deny" -> returns blocked with a timeout match
        - failure_mode="allow" -> returns clean
        """
        try:
            result = await asyncio.wait_for(
                self._do_scan(data),
                timeout=self.timeout_ms / 1000.0,
            )
            return result
        except asyncio.TimeoutError:
            if self.failure_mode == "deny":
                return ScanResult(
                    clean=False,
                    match=ScanMatch(pattern_name="SCAN_TIMEOUT", matched_value="<timeout>"),
                )
            else:
                return ScanResult(clean=True)

    async def _do_scan(self, data: Any) -> ScanResult:
        """Perform the actual scanning."""
        strings = self._extract_strings(data)

        for value in strings:
            # L1: fast regex patterns
            l1_result = scan_l1(value)
            if l1_result:
                return ScanResult(clean=False, match=l1_result)

            # L2: checksum validators
            l2_result = scan_l2(value)
            if l2_result:
                return ScanResult(clean=False, match=l2_result)

            # Yield control to allow timeout to fire on large payloads
            await asyncio.sleep(0)

        return ScanResult(clean=True)

    def _extract_strings(self, data: Any) -> list[str]:
        """Recursively extract all string values, decode nested JSON (one level)."""
        strings: list[str] = []
        self._walk(data, strings, decode_json=True)
        return strings

    def _walk(self, data: Any, strings: list[str], decode_json: bool = True) -> None:
        """Walk a data structure and collect all string values."""
        if isinstance(data, str):
            strings.append(data)
            # Try to decode as JSON (one level only)
            if decode_json:
                try:
                    parsed = json.loads(data)
                    if isinstance(parsed, (dict, list)):
                        self._walk(parsed, strings, decode_json=False)
                except (json.JSONDecodeError, ValueError):
                    pass
        elif isinstance(data, dict):
            for value in data.values():
                self._walk(value, strings, decode_json=decode_json)
        elif isinstance(data, (list, tuple)):
            for item in data:
                self._walk(item, strings, decode_json=decode_json)
        # Ignore non-string, non-container types (int, float, bool, None)
