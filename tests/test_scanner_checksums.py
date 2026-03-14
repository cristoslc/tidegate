"""Tests for L2 checksum validators (Luhn, IBAN, SSN)."""

import pytest
from src.gateway.scanner.checksums import scan_l2


class TestCreditCard:
    def test_luhn_valid_visa(self):
        """4111111111111111 is a well-known Luhn-valid test card number."""
        result = scan_l2("my card is 4111111111111111")
        assert result is not None
        assert result.pattern_name == "CREDIT_CARD"

    def test_luhn_valid_with_spaces(self):
        """Card numbers with spaces should still be detected."""
        result = scan_l2("card: 4111 1111 1111 1111")
        assert result is not None
        assert result.pattern_name == "CREDIT_CARD"

    def test_luhn_valid_with_dashes(self):
        """Card numbers with dashes should still be detected."""
        result = scan_l2("card: 4111-1111-1111-1111")
        assert result is not None
        assert result.pattern_name == "CREDIT_CARD"

    def test_luhn_invalid_number(self):
        """A number that fails Luhn check should not be detected."""
        result = scan_l2("number: 4111111111111112")
        assert result is None

    def test_luhn_valid_amex(self):
        """378282246310005 is a Luhn-valid Amex test number."""
        result = scan_l2("amex: 378282246310005")
        assert result is not None
        assert result.pattern_name == "CREDIT_CARD"

    def test_short_number_not_detected(self):
        """Numbers shorter than 13 digits are not card numbers."""
        result = scan_l2("pin: 1234567890")
        assert result is None


class TestIBAN:
    def test_valid_gb_iban(self):
        result = scan_l2("account: GB29NWBK60161331926819")
        assert result is not None
        assert result.pattern_name == "IBAN"

    def test_valid_de_iban(self):
        result = scan_l2("account: DE89370400440532013000")
        assert result is not None
        assert result.pattern_name == "IBAN"

    def test_valid_iban_with_spaces(self):
        result = scan_l2("account: GB29 NWBK 6016 1331 9268 19")
        assert result is not None
        assert result.pattern_name == "IBAN"

    def test_invalid_iban(self):
        """Invalid check digits should not be detected."""
        result = scan_l2("account: GB00NWBK60161331926819")
        assert result is None

    def test_too_short_for_iban(self):
        result = scan_l2("code: GB29NW")
        assert result is None


class TestSSN:
    def test_valid_ssn_format(self):
        """078-05-1120 is a known valid SSN structure."""
        result = scan_l2("ssn: 078-05-1120")
        assert result is not None
        assert result.pattern_name == "SSN"

    def test_valid_ssn_no_dashes(self):
        result = scan_l2("ssn: 078051120")
        assert result is not None
        assert result.pattern_name == "SSN"

    def test_invalid_ssn_area_zero(self):
        """SSN cannot start with 000."""
        result = scan_l2("ssn: 000-12-1234")
        assert result is None

    def test_invalid_ssn_area_666(self):
        """SSN cannot start with 666."""
        result = scan_l2("ssn: 666-12-1234")
        assert result is None

    def test_invalid_ssn_area_900(self):
        """SSN area 900-999 is invalid."""
        result = scan_l2("ssn: 900-12-1234")
        assert result is None

    def test_invalid_ssn_group_zero(self):
        """SSN group 00 is invalid."""
        result = scan_l2("ssn: 123-00-1234")
        assert result is None

    def test_invalid_ssn_serial_zero(self):
        """SSN serial 0000 is invalid."""
        result = scan_l2("ssn: 123-45-0000")
        assert result is None


class TestCleanStrings:
    def test_normal_text(self):
        assert scan_l2("Hello, world!") is None

    def test_phone_number(self):
        """Phone numbers should not be detected as credit cards."""
        assert scan_l2("call me at 555-123-4567") is None

    def test_random_digits(self):
        """Random digit strings that fail Luhn should not match."""
        assert scan_l2("order 9876543210980") is None

    def test_empty_string(self):
        assert scan_l2("") is None
