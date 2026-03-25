import pytest
from crypto import encrypt_value, decrypt_value


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
