"""L1 regex patterns for high-confidence credential detection."""

from dataclasses import dataclass


@dataclass
class ScanMatch:
    pattern_name: str
    matched_value: str


def scan_l1(value: str) -> ScanMatch | None:
    """Scan a string for L1 regex patterns. Returns first match or None."""
    raise NotImplementedError
