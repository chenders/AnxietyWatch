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
