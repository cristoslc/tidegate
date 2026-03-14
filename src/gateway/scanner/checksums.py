"""L2 checksum validators — Luhn, IBAN, SSN via python-stdnum."""

import re

from stdnum import iban as iban_mod
from stdnum import luhn

from src.gateway.scanner.patterns import ScanMatch


# Extract candidate digit sequences (13-19 digits, with optional separators)
_CC_PATTERN = re.compile(
    r"\b(\d[ \-]?){13,19}\b"
)

# IBAN: 2 uppercase letters + 2 digits + 8-30 alphanumeric, with optional spaces
_IBAN_PATTERN = re.compile(
    r"\b([A-Z]{2}\d{2}[\s]?[A-Z0-9]{4}[\s]?(?:[A-Z0-9]{4}[\s]?){1,7}[A-Z0-9]{1,4})\b"
)

# SSN: NNN-NN-NNNN or NNNNNNNNN (9 digits)
_SSN_PATTERN = re.compile(
    r"\b(\d{3}-\d{2}-\d{4}|\d{9})\b"
)


def _check_credit_card(value: str) -> ScanMatch | None:
    """Extract candidate card numbers and validate with Luhn."""
    for m in _CC_PATTERN.finditer(value):
        candidate = m.group(0).strip()
        digits_only = re.sub(r"[\s\-]", "", candidate)
        if len(digits_only) < 13 or len(digits_only) > 19:
            continue
        if not digits_only.isdigit():
            continue
        try:
            if luhn.validate(digits_only):
                return ScanMatch(pattern_name="CREDIT_CARD", matched_value=candidate)
        except Exception:
            continue
    return None


def _check_iban(value: str) -> ScanMatch | None:
    """Extract candidate IBANs and validate with python-stdnum."""
    for m in _IBAN_PATTERN.finditer(value):
        candidate = m.group(0)
        try:
            iban_mod.validate(candidate)
            return ScanMatch(pattern_name="IBAN", matched_value=candidate)
        except Exception:
            continue
    return None


def _validate_ssn_structure(digits: str) -> bool:
    """Validate SSN structure rules (not just format).

    Rules:
    - Area (first 3): cannot be 000, 666, or 900-999
    - Group (middle 2): cannot be 00
    - Serial (last 4): cannot be 0000
    """
    if len(digits) != 9 or not digits.isdigit():
        return False
    area = int(digits[0:3])
    group = int(digits[3:5])
    serial = int(digits[5:9])

    if area == 0 or area == 666 or area >= 900:
        return False
    if group == 0:
        return False
    if serial == 0:
        return False
    return True


def _check_ssn(value: str) -> ScanMatch | None:
    """Extract candidate SSNs and validate structure."""
    for m in _SSN_PATTERN.finditer(value):
        candidate = m.group(0)
        digits_only = candidate.replace("-", "")
        if _validate_ssn_structure(digits_only):
            return ScanMatch(pattern_name="SSN", matched_value=candidate)
    return None


def scan_l2(value: str) -> ScanMatch | None:
    """Scan a string for L2 checksum-validated patterns. Returns first match or None."""
    # Check credit cards first (most common)
    result = _check_credit_card(value)
    if result:
        return result

    # Check IBAN
    result = _check_iban(value)
    if result:
        return result

    # Check SSN
    result = _check_ssn(value)
    if result:
        return result

    return None
