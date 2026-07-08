"""Tests for the exception-text sanitizer shared by the sync integrations."""

from log_sanitize import sanitize_exception_text, MAX_SANITIZED_LENGTH


def test_absolute_url_query_redacted():
    text = (
        "HTTPSConnectionPool(host='example.okta.com', port=443): "
        "Max retries exceeded with url: "
        "https://example.okta.com/oauth2/v1/authorize?client_id=abc&sessionToken=FAKE-TOKEN-123"
    )
    result = sanitize_exception_text(text)
    assert "FAKE-TOKEN-123" not in result
    assert "sessionToken" not in result
    assert "https://example.okta.com/oauth2/v1/authorize?<redacted>" in result


def test_path_only_url_query_redacted():
    # urllib3's MaxRetryError uses a bare path, not an absolute URL.
    text = (
        "Max retries exceeded with url: "
        "/ws/1.1/matcher.lyrics.get?q_track=song&apikey=FAKE-KEY-456 "
        "(Caused by NewConnectionError('...'))"
    )
    result = sanitize_exception_text(text)
    assert "FAKE-KEY-456" not in result
    assert "/ws/1.1/matcher.lyrics.get?<redacted>" in result
    # Surrounding prose survives redaction.
    assert "Caused by NewConnectionError" in result


def test_multiple_urls_all_redacted():
    text = (
        "first /login?resolve_id=FAKE-RESOLVE-1 then "
        "https://sso.example.com/cb?resolve_id=FAKE-RESOLVE-2"
    )
    result = sanitize_exception_text(text)
    assert "FAKE-RESOLVE-1" not in result
    assert "FAKE-RESOLVE-2" not in result
    assert result.count("?<redacted>") == 2


def test_text_without_urls_unchanged():
    text = "Connection refused by peer"
    assert sanitize_exception_text(text) == text


def test_truncated_to_bound():
    text = "x" * (MAX_SANITIZED_LENGTH + 100)
    result = sanitize_exception_text(text)
    assert len(result) <= MAX_SANITIZED_LENGTH + len("…[truncated]")
    assert result.endswith("…[truncated]")


def test_custom_max_length():
    result = sanitize_exception_text("abcdefghij", max_length=5)
    assert result.startswith("abcde")
    assert result.endswith("…[truncated]")


def test_non_string_input_coerced():
    exc = ValueError("boom /auth?token=FAKE-789")
    result = sanitize_exception_text(exc)
    assert "FAKE-789" not in result
    assert "boom /auth?<redacted>" in result
