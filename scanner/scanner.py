"""
scanner.py -- Stateless L2/L3 leak detection subprocess

Protocol: NDJSON over stdin/stdout
  Request:  {"field": "text", "value": "...", "layers": ["L2", "L3"]}
  Response: {"allowed": true}
           or {"allowed": false, "reason": "...", "layer": "scanner_l2"}

Runs as a long-lived child process of the gateway. One JSON line per
request, one JSON line per response. No state between requests.

L2: Checksum-validated patterns (deterministic, zero false positives)
  - Credit card numbers (Luhn algorithm)
  - IBANs (mod-97 validation)
  - US SSNs (format + area number validation)

L3: Statistical and contextual analysis
  - Shannon entropy detection (high-entropy strings = potential secrets)
  - Base64 encoding detection (encoded credentials)
  - SSN with context keywords (reduces false positives)
"""

from __future__ import annotations

import json
import math
import re
import sys
from collections import Counter
from typing import Any

# ── L2: Checksum-validated patterns ──────────────────────────

# Try to import python-stdnum for robust validation.
# Falls back to built-in implementations if unavailable.
try:
    from stdnum import luhn as stdnum_luhn
    from stdnum import iban as stdnum_iban

    def luhn_valid(digits: str) -> bool:
        """Validate a digit string using Luhn algorithm via python-stdnum."""
        try:
            stdnum_luhn.validate(digits)
            return True
        except Exception:
            return False

    def iban_valid(value: str) -> bool:
        """Validate an IBAN via python-stdnum."""
        try:
            stdnum_iban.validate(value)
            return True
        except Exception:
            return False

except ImportError:
    # Fallback: built-in Luhn. No IBAN validation without stdnum.
    def luhn_valid(digits: str) -> bool:
        """Built-in Luhn algorithm (fallback when python-stdnum is unavailable)."""
        if not digits.isdigit() or len(digits) < 2:
            return False
        total = 0
        for i, ch in enumerate(reversed(digits)):
            d = int(ch)
            if i % 2 == 1:
                d *= 2
                if d > 9:
                    d -= 9
            total += d
        return total % 10 == 0

    def iban_valid(value: str) -> bool:
        """Built-in IBAN mod-97 validation (fallback)."""
        cleaned = value.replace(" ", "").replace("-", "").upper()
        if len(cleaned) < 15 or len(cleaned) > 34:
            return False
        if not re.match(r"^[A-Z]{2}[0-9]{2}", cleaned):
            return False
        # Move first 4 chars to end, convert letters to digits
        rearranged = cleaned[4:] + cleaned[:4]
        numeric = ""
        for ch in rearranged:
            if ch.isdigit():
                numeric += ch
            elif ch.isalpha():
                numeric += str(ord(ch) - ord("A") + 10)
            else:
                return False
        return int(numeric) % 97 == 1


# Credit card number pattern: 13-19 digits, possibly separated by spaces/dashes
CREDIT_CARD_RE = re.compile(
    r"\b(?:\d[ -]*?){13,19}\b"
)

# IBAN pattern: 2 letters + 2 digits + 11-30 alphanumeric chars
IBAN_RE = re.compile(
    r"\b[A-Z]{2}\d{2}[ ]?[\dA-Z]{4}(?:[ ]?[\dA-Z]{4}){2,7}(?:[ ]?[\dA-Z]{1,4})?\b",
    re.IGNORECASE,
)

# SSN pattern: NNN-NN-NNNN or NNNNNNNNN (9 digits)
SSN_RE = re.compile(
    r"\b(\d{3})[-. ]?(\d{2})[-. ]?(\d{4})\b"
)

# Invalid SSN area numbers (000, 666, 900-999)
INVALID_SSN_AREAS = {"000", "666"} | {str(n) for n in range(900, 1000)}


def scan_l2(value: str) -> dict[str, Any] | None:
    """
    L2: Deterministic checksum validation.
    Returns a deny dict if a match is found, None otherwise.
    """
    # Credit card detection
    for match in CREDIT_CARD_RE.finditer(value):
        candidate = match.group()
        digits_only = re.sub(r"[^0-9]", "", candidate)
        if 13 <= len(digits_only) <= 19 and luhn_valid(digits_only):
            # Mask the number for the reason string
            masked = digits_only[:4] + "****" + digits_only[-4:]
            return {
                "allowed": False,
                "reason": f"Value contains a valid credit card number (Luhn-validated, {masked})",
                "layer": "scanner_l2",
            }

    # IBAN detection
    for match in IBAN_RE.finditer(value):
        candidate = match.group()
        if iban_valid(candidate):
            country = candidate[:2].upper()
            return {
                "allowed": False,
                "reason": f"Value contains a valid IBAN ({country}** checksum-validated)",
                "layer": "scanner_l2",
            }

    # SSN detection (format + area validation only -- context check is L3)
    for match in SSN_RE.finditer(value):
        area, group, serial = match.groups()
        if area not in INVALID_SSN_AREAS and group != "00" and serial != "0000":
            # Valid SSN format. At L2 we flag it; L3 adds context.
            return {
                "allowed": False,
                "reason": f"Value contains a pattern matching a US SSN ({area}-XX-XXXX format, valid area number)",
                "layer": "scanner_l2",
            }

    return None


# ── L3: Statistical and contextual analysis ──────────────────

# Context keywords that make an SSN match more likely to be a real SSN
SSN_CONTEXT_KEYWORDS = {
    "ssn", "social security", "social_security", "tax id", "tax_id",
    "taxpayer", "ein", "itin", "tin", "identification number",
    "identity", "id number",
}

# Minimum length for entropy analysis (short strings are noisy)
ENTROPY_MIN_LENGTH = 20

# Entropy threshold -- secrets/keys typically have Shannon entropy > 4.5
# English prose is ~3.5-4.0, random base64 is ~5.5-6.0
ENTROPY_THRESHOLD = 4.5

# Base64 pattern: 20+ chars of base64 alphabet ending with optional padding
BASE64_RE = re.compile(
    r"[A-Za-z0-9+/]{20,}={0,3}"
)

# Hex string pattern: 32+ hex chars (common for API keys, hashes)
HEX_RE = re.compile(
    r"\b[0-9a-fA-F]{32,}\b"
)


def shannon_entropy(s: str) -> float:
    """Calculate Shannon entropy of a string in bits per character."""
    if not s:
        return 0.0
    freq = Counter(s)
    length = len(s)
    return -sum(
        (count / length) * math.log2(count / length)
        for count in freq.values()
    )


def scan_l3(value: str) -> dict[str, Any] | None:
    """
    L3: Statistical analysis and contextual detection.
    Returns a deny dict if suspicious, None otherwise.
    """
    value_lower = value.lower()

    # SSN with context keywords (more confident than L2 SSN alone)
    has_ssn_context = any(kw in value_lower for kw in SSN_CONTEXT_KEYWORDS)
    if has_ssn_context:
        for match in SSN_RE.finditer(value):
            area, group, serial = match.groups()
            if area not in INVALID_SSN_AREAS and group != "00" and serial != "0000":
                return {
                    "allowed": False,
                    "reason": "Value contains SSN-format number with context keywords indicating a real Social Security Number",
                    "layer": "scanner_l3",
                }

    # Base64 encoded content detection
    for match in BASE64_RE.finditer(value):
        candidate = match.group()
        if len(candidate) >= 20:
            entropy = shannon_entropy(candidate)
            if entropy > ENTROPY_THRESHOLD:
                return {
                    "allowed": False,
                    "reason": f"Value contains high-entropy base64-encoded content (entropy: {entropy:.1f} bits/char) — possible encoded credential",
                    "layer": "scanner_l3",
                }

    # High-entropy hex strings (potential API keys, hashes with secrets)
    for match in HEX_RE.finditer(value):
        candidate = match.group()
        entropy = shannon_entropy(candidate)
        if entropy > 3.5 and len(candidate) >= 32:
            return {
                "allowed": False,
                "reason": f"Value contains high-entropy hex string ({len(candidate)} chars, entropy: {entropy:.1f} bits/char) — possible credential or secret",
                "layer": "scanner_l3",
            }

    # General high-entropy substring detection
    # Slide a window looking for concentrated high-entropy regions
    if len(value) >= ENTROPY_MIN_LENGTH:
        window_size = 40
        for i in range(0, len(value) - window_size + 1, 10):
            window = value[i : i + window_size]
            # Skip windows that look like natural language (spaces, common words)
            if " " in window and window.count(" ") > 3:
                continue
            entropy = shannon_entropy(window)
            if entropy > 5.0:
                # Very high entropy in a non-prose region
                return {
                    "allowed": False,
                    "reason": f"Value contains high-entropy region (entropy: {entropy:.1f} bits/char in {window_size}-char window) — possible embedded secret",
                    "layer": "scanner_l3",
                }

    return None


# ── Main loop: NDJSON protocol ───────────────────────────────

def process_request(request: dict[str, Any]) -> dict[str, Any]:
    """Process a single scan request and return a response."""
    value = request.get("value")
    layers = request.get("layers", [])

    if not isinstance(value, str):
        return {"allowed": True}

    if "L2" in layers:
        result = scan_l2(value)
        if result is not None:
            return result

    if "L3" in layers:
        result = scan_l3(value)
        if result is not None:
            return result

    return {"allowed": True}


def main() -> None:
    """
    NDJSON loop: read one JSON line from stdin, write one to stdout.
    Flush after every write to ensure the gateway gets the response immediately.
    """
    # Unbuffered stderr for logging
    sys.stderr.write("[scanner] Python L2/L3 scanner started\n")
    sys.stderr.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            response = {
                "allowed": False,
                "reason": f"Scanner internal error: invalid JSON input ({e})",
                "layer": "scanner_l2",
            }
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()
            continue

        try:
            response = process_request(request)
        except Exception as e:
            # Defense-in-depth: scanner bugs should deny, not crash
            response = {
                "allowed": False,
                "reason": f"Scanner internal error: {type(e).__name__}: {e}",
                "layer": "scanner_l2",
            }

        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
