"""L2 checksum validators — Luhn, IBAN, SSN via python-stdnum."""

from src.gateway.scanner.patterns import ScanMatch


def scan_l2(value: str) -> ScanMatch | None:
    """Scan a string for L2 checksum-validated patterns. Returns first match or None."""
    raise NotImplementedError
