"""L1 regex patterns for high-confidence credential detection."""

import re
from dataclasses import dataclass


@dataclass
class ScanMatch:
    pattern_name: str
    matched_value: str


# Each pattern: (name, compiled regex)
# Ordered by likelihood of encounter in typical tool call payloads.
PATTERNS: list[tuple[str, re.Pattern]] = [
    ("AWS_ACCESS_KEY", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("GITHUB_TOKEN", re.compile(r"gh[ps]_[A-Za-z0-9_]{36,}")),
    ("SLACK_TOKEN", re.compile(r"xox[bporas]-[0-9A-Za-z\-]{10,}")),
    ("PEM_PRIVATE_KEY", re.compile(r"-----BEGIN (?:RSA |EC |DSA )?PRIVATE KEY-----")),
    ("BEARER_TOKEN", re.compile(r"Bearer\s+[A-Za-z0-9\-._~+/]{8,}=*")),
]


def scan_l1(value: str) -> ScanMatch | None:
    """Scan a string for L1 regex patterns. Returns first match or None."""
    for name, pattern in PATTERNS:
        m = pattern.search(value)
        if m:
            return ScanMatch(pattern_name=name, matched_value=m.group(0))
    return None
