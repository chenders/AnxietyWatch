"""Tests for json_helpers — shared LLM JSON parsing."""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from json_helpers import parse_llm_json, _extract_json_text  # noqa: E402


def test_parse_clean_json():
    """Clean JSON without fences is parsed directly."""
    result = parse_llm_json('{"key": "value", "num": 42}')
    assert result == {"key": "value", "num": 42}


def test_parse_fenced_json():
    """JSON wrapped in ```json ... ``` is extracted and parsed."""
    text = 'Here are the results:\n\n```json\n{"findings": [{"claim": "test"}]}\n```\n\nDone.'
    result = parse_llm_json(text)
    assert result == {"findings": [{"claim": "test"}]}


def test_parse_fenced_no_language_tag():
    """JSON wrapped in ``` ... ``` (no language tag) is extracted."""
    text = 'Results:\n\n```\n{"key": "value"}\n```'
    result = parse_llm_json(text)
    assert result == {"key": "value"}


def test_parse_unclosed_fence():
    """Truncated response with unclosed fence is handled."""
    text = (
        'Let me compile the results.\n\n```json\n'
        '{"findings": [{"claim": "Tapering guidelines", "confidence": 0.95}]}'
    )
    result = parse_llm_json(text)
    assert result is not None
    assert result["findings"][0]["claim"] == "Tapering guidelines"
    assert result["findings"][0]["confidence"] == 0.95


def test_parse_citation_newlines():
    """Literal newlines from web search citations inside JSON values are cleaned."""
    text = (
        '```json\n'
        '{\n'
        '  "credentials": "\\nMD, Board Certified\\n; \\nlicensed in Oregon\\n",\n'
        '  "nested": [{"title": "\\nSome\\npaper\\n"}]\n'
        '}\n'
        '```'
    )
    result = parse_llm_json(text)
    assert result is not None
    assert "\n" not in result["credentials"]
    assert "MD, Board Certified" in result["credentials"]
    assert result["nested"][0]["title"] == "Some paper"


def test_parse_returns_none_on_garbage():
    """Completely unparseable text returns None."""
    result = parse_llm_json("This is not JSON at all, just plain text.")
    assert result is None


def test_extract_json_text_fenced():
    """_extract_json_text strips fences and language tag."""
    text = '```json\n{"key": "val"}\n```'
    assert _extract_json_text(text) == '{"key": "val"}'


def test_extract_json_text_fenced_uppercase_tag():
    """_extract_json_text handles uppercase language tags."""
    text = '```JSON\n{"key": "val"}\n```'
    assert _extract_json_text(text) == '{"key": "val"}'


def test_extract_json_text_unclosed():
    """_extract_json_text handles unclosed fences."""
    text = '```json\n{"key": "val"}'
    extracted = _extract_json_text(text)
    assert '{"key": "val"}' in extracted


def test_extract_json_text_bare():
    """_extract_json_text returns bare text as-is."""
    text = '{"key": "val"}'
    assert _extract_json_text(text) == '{"key": "val"}'


def test_extract_json_text_multiple_fences():
    """_extract_json_text captures the first fenced block, not trailing content."""
    text = (
        'Preamble\n```json\n{"key": "val"}\n```\n\n'
        '**Note:** This is a caveat with ```example``` code.'
    )
    extracted = _extract_json_text(text)
    assert '{"key": "val"}' == extracted


def test_extract_json_text_space_before_language_tag():
    """_extract_json_text handles a space between ``` and the language tag."""
    text = '``` json\n{"key": "val"}\n```'
    extracted = _extract_json_text(text)
    assert extracted == '{"key": "val"}'


def test_parse_scalar_returns_none():
    """Scalar JSON values (string, number, null) return None — callers expect dict/list."""
    assert parse_llm_json('"just a string"') is None
    assert parse_llm_json('42') is None
    assert parse_llm_json('null') is None
    assert parse_llm_json('true') is None


def test_extract_json_text_skips_empty_inline_fence():
    """_extract_json_text skips empty inline fences and finds the real block."""
    text = 'Use ```json``` format.\n\n```json\n{"key": "val"}\n```'
    extracted = _extract_json_text(text)
    assert extracted == '{"key": "val"}'


def test_parse_literal_newlines_in_values():
    """Actual literal newlines inside JSON strings (invalid JSON) are repaired."""
    # Literal newline chars inside a JSON value — json.loads will reject this,
    # but json_repair should fix it, then _clean_citation_artifacts cleans up.
    text = '{"credentials": "MD,\nBoard Certified;\nlicensed in Oregon"}'
    result = parse_llm_json(text)
    assert result is not None
    assert "MD," in result["credentials"]
    assert "Board Certified" in result["credentials"]
    assert "\n" not in result["credentials"]
