#!/usr/bin/env python3
"""Unit tests for steam_totp.py: python3 Scripts/test_steam_totp.py"""
import base64
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import steam_totp  # noqa: E402

RFC_KEY = b"12345678901234567890"  # RFC 6238 appendix B, SHA-1 seed
# (unix time, RFC 6238 8-digit TOTP, Steam code of the same truncated value)
VECTORS = [
    (59, 94287082, "PV9M4"),
    (1111111109, 7081804, "PY4YB"),
    (1111111111, 14050471, "5PP3V"),
    (1234567890, 89005924, "VHHQY"),
    (2000000000, 69279037, "9N776"),
    (20000000000, 65353130, "R5DMB"),
]


class SteamTOTPTests(unittest.TestCase):
    def test_truncation_matches_rfc6238(self):
        for t, rfc, _ in VECTORS:
            self.assertEqual(steam_totp.truncated(RFC_KEY, t // 30) % 10**8, rfc, t)

    def test_steam_codes(self):
        secret = base64.b64encode(RFC_KEY).decode()
        for t, _, steam in VECTORS:
            self.assertEqual(steam_totp.code(secret, t), steam, t)

    def test_encoding_is_base26_least_significant_first(self):
        a = steam_totp.ALPHABET
        self.assertEqual(len(a), 26)
        self.assertEqual(steam_totp.encode(0), "22222")
        self.assertEqual(steam_totp.encode(1), "32222")
        self.assertEqual(steam_totp.encode(26), "23222")
        self.assertEqual(steam_totp.encode(26**5 + 1), "32222")  # only 5 characters are kept
        v = 3 + 5 * 26 + 7 * 26**2 + 11 * 26**3 + 25 * 26**4
        self.assertEqual(steam_totp.encode(v), a[3] + a[5] + a[7] + a[11] + a[25])

    def test_code_is_constant_within_a_period(self):
        secret = base64.b64encode(b"\x01" * 20).decode()
        self.assertEqual(steam_totp.code(secret, 60), steam_totp.code(secret, 89))
        self.assertNotEqual(steam_totp.code(secret, 89), steam_totp.code(secret, 90))
        self.assertEqual(steam_totp.seconds_left(60), 30)
        self.assertEqual(steam_totp.seconds_left(89), 1)

    def test_rejects_bad_secret(self):
        with self.assertRaises(Exception):
            steam_totp.code("not base64!!")

    def test_cli_prints_only_the_code(self):
        env = dict(os.environ, OWE_CI_STEAM_SHARED_SECRET=base64.b64encode(RFC_KEY).decode())
        out = subprocess.run([sys.executable, steam_totp.__file__], env=env, capture_output=True, text=True, check=True)
        self.assertRegex(out.stdout, r"^[23456789BCDFGHJKMNPQRTVWXY]{5}\n$")
        env.pop("OWE_CI_STEAM_SHARED_SECRET")
        out = subprocess.run([sys.executable, steam_totp.__file__], env=env, capture_output=True, text=True)
        self.assertEqual(out.returncode, 2)
        self.assertEqual(out.stdout, "")


if __name__ == "__main__":
    unittest.main()
