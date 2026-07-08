"""Fernet encryption helpers for settings values (e.g., myAir password)."""

import base64

from cryptography.fernet import Fernet
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives import hashes


def _fernet_key(secret: str) -> bytes:
    """Derive a valid Fernet key from an arbitrary secret string."""
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=b"anxietywatch-settings",
        iterations=100_000,
    )
    return base64.urlsafe_b64encode(kdf.derive(secret.encode()))


def encrypt_value(plaintext: str, secret: str) -> str:
    """Encrypt a string using Fernet with a PBKDF2-derived key."""
    return Fernet(_fernet_key(secret)).encrypt(plaintext.encode()).decode()


def decrypt_value(token: str, secret: str) -> str:
    """Decrypt a Fernet token back to plaintext."""
    return Fernet(_fernet_key(secret)).decrypt(token.encode()).decode()


def looks_like_fernet_token(value: str) -> bool:
    """True if `value` has the structural shape of a Fernet token.

    A Fernet token is url-safe base64 of `0x80 || timestamp(8) || IV(16) ||
    ciphertext || HMAC(32)`, so it decodes to at least 57 bytes whose first
    byte is the 0x80 version marker. This is a *shape* check, not an
    authenticity check: a value that looks like this but fails to decrypt
    means the key is wrong (a real config error), NOT that the value is
    legacy plaintext. Distinguishing the two keeps a misconfigured
    SECRET_KEY from silently handing back ciphertext as if it were an
    identifier — or double-encrypting it on the next save (F-080 hardening,
    Copilot review of #162).
    """
    try:
        raw = base64.urlsafe_b64decode(value.encode())
    except (ValueError, TypeError):
        return False
    return len(raw) >= 57 and raw[0] == 0x80


def decrypt_value_with_plaintext_fallback(value: str | None, secret: str) -> str | None:
    """Decrypt a stored settings value, tolerating legacy plaintext (F-080).

    ResMed email / Walgreens username were historically stored plaintext.
    New admin saves encrypt them, but rows written before that change still
    hold plaintext. Fallback logic:

    - Value doesn't look like a Fernet token → legacy plaintext, return as-is.
    - Value looks like a Fernet token AND decrypts → return the plaintext.
    - Value looks like a Fernet token but FAILS to decrypt → SECRET_KEY is
      wrong; the underlying `InvalidToken` propagates rather than the
      ciphertext being handed back as an identifier (and later
      double-encrypted by the admin upgrade path).

    Only use this for identifiers with a known plaintext history — passwords
    have always been encrypted, so use strict `decrypt_value` there.
    """
    if value is None:
        return None
    if not looks_like_fernet_token(value):
        return value
    return decrypt_value(value, secret)
