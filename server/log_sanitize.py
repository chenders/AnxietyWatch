"""Helpers for scrubbing exception text before it reaches logs, settings, or the admin UI.

Network-layer exception messages (urllib3's MaxRetryError in particular) embed the
full request URL — including the query string. Several integrations put one-time
credentials in query params (Okta sessionToken, Musixmatch apikey), so raw
exception text must never be logged or persisted verbatim. This module
redacts query strings from URL-looking tokens and bounds the overall length.
"""

import re

# Bounded length for sanitized exception text — long enough to keep the useful
# part of a urllib3/requests message, short enough that a pathological payload
# can't flood a log line or a settings value.
MAX_SANITIZED_LENGTH = 500

# Matches an absolute URL (http/https) or a path-like token (starts with '/',
# the shape urllib3 uses in "Max retries exceeded with url: /path?query")
# followed by a '?' query string. The query part stops at whitespace, quotes,
# or parens so surrounding prose like "(Caused by ...)" survives redaction.
_URL_WITH_QUERY_RE = re.compile(
    r"((?:https?://|/)[^\s?'\"()<>]*)\?[^\s'\"()<>]*"
)


def sanitize_exception_text(text, max_length=MAX_SANITIZED_LENGTH):
    """Redact URL query strings from *text* and truncate to *max_length*.

    Every URL-looking token keeps its scheme/host/path but has everything
    after '?' replaced with '<redacted>', so one-time tokens riding as query
    params (sessionToken, resolve_id, apikey, ...) never survive into logs.
    Accepts any object; non-strings are coerced via ``str()``.
    """
    sanitized = _URL_WITH_QUERY_RE.sub(r"\1?<redacted>", str(text))
    if len(sanitized) > max_length:
        sanitized = sanitized[:max_length] + "…[truncated]"
    return sanitized
