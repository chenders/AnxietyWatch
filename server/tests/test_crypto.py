import pytest
from crypto import encrypt_value, decrypt_value, decrypt_value_with_plaintext_fallback


def test_round_trip():
    secret = "test-secret-key-for-encryption"
    plaintext = "my-resmed-password-123"
    encrypted = encrypt_value(plaintext, secret)
    assert encrypted != plaintext
    assert decrypt_value(encrypted, secret) == plaintext


def test_different_secrets_produce_different_output():
    plaintext = "same-password"
    enc1 = encrypt_value(plaintext, "secret-one")
    enc2 = encrypt_value(plaintext, "secret-two")
    assert enc1 != enc2


def test_wrong_secret_fails():
    encrypted = encrypt_value("password", "correct-secret")
    with pytest.raises(Exception):
        decrypt_value(encrypted, "wrong-secret")


def test_empty_string():
    secret = "test-secret"
    encrypted = encrypt_value("", secret)
    assert decrypt_value(encrypted, secret) == ""


def test_special_characters():
    secret = "test-secret"
    plaintext = "p@$$w0rd!#%^&*()"
    encrypted = encrypt_value(plaintext, secret)
    assert decrypt_value(encrypted, secret) == plaintext


def test_encrypted_output_is_different_each_time():
    """Fernet includes a timestamp, so same input produces different ciphertext."""
    secret = "test-secret"
    enc1 = encrypt_value("password", secret)
    enc2 = encrypt_value("password", secret)
    assert enc1 != enc2  # Fernet adds timestamp nonce


# ---------------------------------------------------------------------------
# decrypt_value_with_plaintext_fallback (F-080)
# ---------------------------------------------------------------------------


def test_fallback_decrypts_encrypted_value():
    secret = "test-secret"
    encrypted = encrypt_value("user@example.com", secret)
    assert decrypt_value_with_plaintext_fallback(encrypted, secret) == "user@example.com"


def test_fallback_returns_legacy_plaintext_as_is():
    """Rows written before F-080 hold plaintext identifiers — the sync read
    path must still return them so cron syncs keep working un-migrated."""
    assert (
        decrypt_value_with_plaintext_fallback("legacy-user@example.com", "test-secret")
        == "legacy-user@example.com"
    )


def test_fallback_none_passthrough():
    assert decrypt_value_with_plaintext_fallback(None, "test-secret") is None


def test_fallback_wrong_key_raises_not_returns_ciphertext():
    """A real Fernet token decrypted with the WRONG key is a config error,
    not legacy plaintext: the token shape is recognized, so the decrypt
    failure must propagate rather than hand the ciphertext back as if it
    were an identifier (which the admin upgrade path would then double-
    encrypt). Copilot review of #162."""
    from cryptography.fernet import InvalidToken
    encrypted = encrypt_value("user@example.com", "the-right-secret")
    with pytest.raises(InvalidToken):
        decrypt_value_with_plaintext_fallback(encrypted, "the-wrong-secret")


def test_looks_like_fernet_token_discriminates():
    from crypto import looks_like_fernet_token
    assert looks_like_fernet_token(encrypt_value("x", "s"))
    assert not looks_like_fernet_token("legacy-user@example.com")
    assert not looks_like_fernet_token("")
    # A non-token url-safe-base64 string that decodes short must not be
    # mistaken for a token.
    assert not looks_like_fernet_token("YWJj")  # "abc"
