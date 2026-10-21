#!/usr/bin/env python3
"""Steam Guard mobile authenticator codes (Steam's TOTP variant), standard library only.

Steam's codes are RFC 6238 TOTP with HMAC-SHA1 over the 30-second counter and RFC 4226 dynamic
truncation, but the 31-bit result is written as 5 characters of the alphabet below (least
significant first) instead of decimal digits.

    steam_totp.py            reads the base64 shared_secret from OWE_CI_STEAM_SHARED_SECRET
    steam_totp.py --stdin    reads it from standard input instead

Prints only the code. Never logs the secret.
"""
import base64
import hashlib
import hmac
import os
import struct
import sys
import time

ALPHABET = "23456789BCDFGHJKMNPQRTVWXY"
PERIOD = 30


def truncated(key: bytes, counter: int) -> int:
    """RFC 4226 dynamic truncation of HMAC-SHA1(key, counter): a 31-bit integer."""
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    return struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF


def encode(value: int) -> str:
    chars = []
    for _ in range(5):
        value, index = divmod(value, len(ALPHABET))
        chars.append(ALPHABET[index])
    return "".join(chars)


def code(shared_secret_b64: str, timestamp: float | None = None) -> str:
    key = base64.b64decode(shared_secret_b64.strip(), validate=True)
    now = time.time() if timestamp is None else timestamp
    return encode(truncated(key, int(now) // PERIOD))


def seconds_left(timestamp: float | None = None) -> int:
    now = time.time() if timestamp is None else timestamp
    return PERIOD - int(now) % PERIOD


def main(argv: list[str]) -> int:
    secret = sys.stdin.readline() if "--stdin" in argv else os.environ.get("OWE_CI_STEAM_SHARED_SECRET", "")
    if not secret.strip():
        print("steam_totp: no shared secret", file=sys.stderr)
        return 2
    try:
        print(code(secret))
    except (ValueError, base64.binascii.Error):
        print("steam_totp: the shared secret isn't valid base64", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
