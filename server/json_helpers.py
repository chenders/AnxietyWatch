"""Shared helpers for parsing JSON from Claude API responses.

Claude's web search tool inserts citation text that introduces literal
newlines inside JSON string values, and responses may be truncated
(unclosed code fences).  These helpers handle both issues.
"""

import json
import logging
import re

logger = logging.getLogger(__name__)


def _clean_citation_artifacts(v):
    """Recursively clean citation-artifact newlines from parsed JSON values."""
    if isinstance(v, str):
        return re.sub(r"\n+", " ", v).strip()
    if isinstance(v, list):
        return [_clean_citation_artifacts(x) for x in v]
    if isinstance(v, dict):
        return {k: _clean_citation_artifacts(val) for k, val in v.items()}
    return v


def _extract_json_text(full_text):
    """Extract JSON text from a Claude response.

    Handles:
      - ```json ... ``` (with or without language tag)
      - ``` ... ```
      - Unclosed fences (truncated responses that hit max_tokens)
      - Bare JSON (no fences)
    """
    # Fenced block: ```json ... ``` or ``` ... ```
    # Use a regex that strips any language tag after the opening fence
    fence_match = re.search(
        r"```\s*(?:\w+)?\s*([\s\S]*?)```", full_text
    )
    if fence_match:
        return fence_match.group(1).strip()

    # Unclosed fence (truncated response) — take everything after the opening
    unclosed_match = re.search(r"```\s*(?:\w+)?\s*([\s\S]*)", full_text)
    if unclosed_match:
        return unclosed_match.group(1).strip()

    return full_text.strip()


def parse_llm_json(full_text):
    """Parse JSON from an LLM response, handling fences and citation artifacts.

    Tries standard json.loads first, then falls back to json_repair for
    responses with citation-artifact newlines in string values.

    Returns the parsed dict/list on success, or None on failure.
    """
    json_text = _extract_json_text(full_text)

    # Fast path: try standard parsing
    try:
        result = json.loads(json_text)
        if not isinstance(result, (dict, list)):
            return None
        return _clean_citation_artifacts(result)
    except (json.JSONDecodeError, ValueError):
        pass

    # Slow path: use json_repair for malformed JSON
    try:
        from json_repair import repair_json
        repaired = repair_json(json_text)
        result = json.loads(repaired)
        if not isinstance(result, (dict, list)):
            return None
        return _clean_citation_artifacts(result)
    except Exception:
        logger.exception("JSON repair failed for LLM response")
        return None
