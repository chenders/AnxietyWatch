#!/usr/bin/env python3
"""PreToolUse hook: block real PII patterns in test fixtures and journals.

This repository is open-source — every file, commit, and PR description is
publicly visible. CLAUDE.md documents real prior incidents where personal data
landed in tests and required git history rewrites to scrub. This hook prevents
the next one.

Scope: Write/Edit/MultiEdit on files under
  - AnxietyWatchTests/
  - server/tests/
  - .github/workflows/ (less common but PII has slipped in via test env vars)

What it flags:

- Phone numbers that look real (outside the 555-0100..555-0199 fictional range)
- Addresses not containing 'Example' or 'Anytown' suggesting a real street
- Personalized device names like "Sam's iPhone" / "X's Apple Watch" / "Y's iPad"
- Pharmacy store numbers other than the fixture #12345
- Rx numbers that don't match the documented fictional patterns (9999999-*, 7654321)
- Email addresses outside the allowed example domains (example.com/org/net,
  users.noreply.github.com)
- Real doctor names — heuristic: "Dr. <FirstName> <LastName>" or "<Last>, MD"
  outside an allowlist of explicit fictional names

In addition to the fixture-scoped checks above, a personal denylist check runs on
EVERY Write/Edit regardless of path: `.claude/pii-denylist.local.txt` (gitignored,
one term per line, '#' comments) holds the owner's real PII strings — names,
emails, device nicknames — that must never appear anywhere in the repo. The file
is local-only so the public repo never contains the strings it is guarding
against; matches are reported masked for the same reason.

The hook is opinionated: it BLOCKS the write (returns exit 2 with the finding
listed on stderr). The model then has to revise the fixture to use the
documented fictional values before retrying.
"""
from __future__ import annotations

import json
import os
import re
import sys

WRITE_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})

# Fictional values explicitly OK per CLAUDE.md "Public Repository — Sensitive
# Data Rules".
FICTIONAL_NAMES_ALLOWED = {
    "Jane Smith",
    "John Doe",
    "Jane Doe",
    "Test Provider",
    "Test Doctor",
    "Test Patient",
}
FICTIONAL_PHONE_RANGE = re.compile(r"^555-01\d\d$")
FICTIONAL_RX_PATTERNS = (
    re.compile(r"^9999999-\d{5}$"),
    re.compile(r"^7654321$"),
)
FICTIONAL_STORE = "#12345"

DENYLIST_FILENAME = "pii-denylist.local.txt"

ALLOWED_EMAIL_DOMAINS = (
    "example.com",
    "example.org",
    "example.net",
    "users.noreply.github.com",
)
# Subdomains are fine for the RFC 2606 example domains (e.g. mail.example.org).
SUBDOMAIN_ALLOWED_SUFFIXES = tuple(
    f".{d}" for d in ("example.com", "example.org", "example.net")
)


def denylist_path() -> str:
    """The gitignored local denylist lives next to the hooks dir: .claude/pii-denylist.local.txt."""
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if project_dir:
        return os.path.join(project_dir, ".claude", DENYLIST_FILENAME)
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", DENYLIST_FILENAME)


def load_denylist() -> list[str]:
    try:
        with open(denylist_path(), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    terms: list[str] = []
    for line in lines:
        term = line.strip()
        if term and not term.startswith("#"):
            terms.append(term)
    return terms


def find_denylisted_terms(content: str) -> list[str]:
    """Case-insensitive substring match against the local denylist.

    Matches are reported MASKED (first character + length) so the real string
    never lands in hook output or session transcripts."""
    findings: list[str] = []
    lowered = content.lower()
    for term in load_denylist():
        if term.lower() in lowered:
            masked = f"{term[0]}…({len(term)} chars)"
            findings.append(
                f"Denylisted personal term '{masked}' from .claude/{DENYLIST_FILENAME} — "
                f"this string must never appear in the repo."
            )
    return findings


def find_disallowed_emails(content: str) -> list[str]:
    """Email addresses outside the allowed example domains."""
    findings: list[str] = []
    pattern = re.compile(r"\b[\w.+-]+@([\w-]+(?:\.[\w-]+)+)\b")
    for m in pattern.finditer(content):
        domain = m.group(1).lower()
        if domain in ALLOWED_EMAIL_DOMAINS or domain.endswith(SUBDOMAIN_ALLOWED_SUFFIXES):
            continue
        findings.append(
            f"Email address with domain '{domain}' — use an example.com/org/net "
            f"placeholder (e.g. test@example.com)."
        )
    return findings


def is_in_scope(file_path: str) -> bool:
    """Return True only for test/fixture paths where personal data must not appear."""
    in_scope_dirs = (
        "AnxietyWatchTests/",
        "server/tests/",
        ".github/workflows/",
    )
    return any(d in file_path for d in in_scope_dirs)


def find_real_phone_numbers(content: str) -> list[str]:
    """Phone-shaped strings outside the 555-0100..555-0199 range."""
    findings: list[str] = []
    # Match (XXX) XXX-XXXX, XXX-XXX-XXXX, +1 XXX XXX XXXX, etc.
    pattern = re.compile(
        r"(?:\+?1[-\s.]?)?\(?(\d{3})\)?[-\s.]?(\d{3})[-\s.]?(\d{4})"
    )
    for m in pattern.finditer(content):
        full = m.group(0)
        last_seven = f"{m.group(2)}-{m.group(3)}"
        if FICTIONAL_PHONE_RANGE.match(last_seven):
            continue
        # Skip obvious non-phone hits like timestamps, UUIDs fragments
        context_start = max(0, m.start() - 20)
        context = content[context_start:m.end() + 5]
        if re.search(r"\.\d{3}-\d{3}-\d{4}", context):
            # Looks like a part of a UUID or version string
            continue
        findings.append(f"Phone-shaped string '{full}' — not in fictional 555-01XX range.")
    return findings


def find_real_rx_numbers(content: str) -> list[str]:
    """Rx-like patterns that don't match the documented fictional ones."""
    findings: list[str] = []
    # Rx context: a 6-12 digit number near "rx" / "prescription" / "Rx#"
    pattern = re.compile(
        r"(?:rx|prescription|Rx#?|rxNumber|prescriptionId)\s*[:=]?\s*[\"']?([\w\-]+)[\"']?",
        re.IGNORECASE,
    )
    for m in pattern.finditer(content):
        candidate = m.group(1)
        if not re.match(r"^[\d\-]+$", candidate):
            continue
        if any(p.match(candidate) for p in FICTIONAL_RX_PATTERNS):
            continue
        if candidate.startswith("99999"):
            continue
        findings.append(f"Rx number '{candidate}' — not in fictional pattern (9999999-XXXXX / 7654321).")
    return findings


def find_personalized_device_names(content: str) -> list[str]:
    """Personalized device names like "Sam's iPhone" — never commit a real one."""
    findings: list[str] = []
    pattern = re.compile(r"\b([A-Z][a-z]+)['’]s\s+(iPhone|iPad|Apple\s+Watch|Mac|MacBook)")
    for m in pattern.finditer(content):
        owner = m.group(1)
        # Test prefix is OK
        if owner.lower() in ("test", "fake", "mock", "sample"):
            continue
        device = m.group(2)
        findings.append(f"Personalized device name '{owner}'s {device}' — use 'Test {device}' instead.")
    return findings


def find_non_fictional_addresses(content: str) -> list[str]:
    """Street-address-shaped strings that don't contain Example/Anytown."""
    findings: list[str] = []
    # Heuristic: <number> <Word>[ Word]* (Street|St|Ave|Avenue|Blvd|Boulevard|Drive|Dr|Way|Lane|Rd|Road)
    pattern = re.compile(
        r"\b\d+\s+[A-Z][a-zA-Z]+(?:\s+[A-Z][a-zA-Z]+){0,3}\s+"
        r"(?:St|Street|Ave|Avenue|Blvd|Boulevard|Drive|Dr|Way|Lane|Rd|Road)\b",
        re.IGNORECASE,
    )
    for m in pattern.finditer(content):
        addr = m.group(0)
        if "Example" in addr or "Anytown" in addr or "Test" in addr or "Fake" in addr:
            continue
        findings.append(f"Real-looking address '{addr}' — use '100 Example Blvd, Anytown'.")
    return findings


def find_real_doctor_names(content: str) -> list[str]:
    """Heuristic: 'Dr. FirstName LastName' or 'LastName, MD' not on the allowlist."""
    findings: list[str] = []
    patterns = [
        re.compile(r"\bDr\.?\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\b"),
        re.compile(r"\b([A-Z][a-z]+(?:,\s*)?(?:M\.?D\.?))\b"),
    ]
    for pat in patterns:
        for m in pat.finditer(content):
            name = m.group(1).strip()
            if name in FICTIONAL_NAMES_ALLOWED:
                continue
            # Allow generic medical terms like "MD" appearing in code variable names
            if any(name.startswith(prefix) for prefix in ("Test", "Mock", "Fake", "Sample", "Example")):
                continue
            findings.append(f"Doctor/provider name '{name}' — use 'Jane Smith MD' or 'Test Provider'.")
    return findings


def find_non_fictional_store_numbers(content: str) -> list[str]:
    """Pharmacy store numbers other than #12345."""
    findings: list[str] = []
    pattern = re.compile(r"(?:store|pharmacy|storeNumber)\s*[:=]?\s*[\"']?#?(\d{3,8})[\"']?", re.IGNORECASE)
    for m in pattern.finditer(content):
        num = m.group(1)
        if num == "12345":
            continue
        # Allow round dev numbers
        if num in {"0", "1", "99999"}:
            continue
        findings.append(f"Pharmacy store number '#{num}' — use '#12345'.")
    return findings


def find_findings(content: str) -> list[str]:
    findings: list[str] = []
    findings.extend(find_real_phone_numbers(content))
    findings.extend(find_real_rx_numbers(content))
    findings.extend(find_personalized_device_names(content))
    findings.extend(find_non_fictional_addresses(content))
    findings.extend(find_real_doctor_names(content))
    findings.extend(find_non_fictional_store_numbers(content))
    findings.extend(find_disallowed_emails(content))
    # Deduplicate while preserving order
    seen: set[str] = set()
    deduped: list[str] = []
    for f in findings:
        if f in seen:
            continue
        seen.add(f)
        deduped.append(f)
    return deduped


def extract_content(tool_input: dict, tool_name: str) -> str:
    """Reconstruct the content that would be written. PreToolUse fires BEFORE
    the file is mutated, so we look at the tool_input directly."""
    if tool_name == "Write":
        c = tool_input.get("content")
        return c if isinstance(c, str) else ""
    if tool_name == "Edit":
        return tool_input.get("new_string", "") or ""
    if tool_name == "MultiEdit":
        edits = tool_input.get("edits") or []
        parts: list[str] = []
        for e in edits:
            if isinstance(e, dict):
                ns = e.get("new_string", "")
                if isinstance(ns, str):
                    parts.append(ns)
        return "\n".join(parts)
    return ""


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if not isinstance(event, dict):
        return 0

    tool_name = event.get("tool_name")
    if not isinstance(tool_name, str) or tool_name not in WRITE_TOOLS:
        return 0
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0
    file_path = tool_input.get("file_path")
    if not isinstance(file_path, str):
        return 0
    # Never scan the denylist file itself — writing it would otherwise self-block.
    if os.path.basename(file_path) == DENYLIST_FILENAME:
        return 0

    content = extract_content(tool_input, tool_name)
    if not content:
        return 0

    # Personal denylist applies to EVERY path; fixture heuristics only in scope.
    findings = find_denylisted_terms(content)
    if is_in_scope(file_path):
        findings.extend(find_findings(content))
    if not findings:
        return 0

    rel_path = file_path
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if project_dir and file_path.startswith(project_dir):
        rel_path = file_path[len(project_dir):].lstrip("/")

    print(
        f"Possible PII in {rel_path} — blocking write. This is a public "
        f"repository; per CLAUDE.md 'Public Repository — Sensitive Data Rules', use "
        f"only documented fictional values.",
        file=sys.stderr,
    )
    for finding in findings:
        print(f"  - {finding}", file=sys.stderr)
    print(
        "\nAllowed substitutions:\n"
        "  Phone:    555-0100 through 555-0199\n"
        "  Address:  100 Example Blvd, Anytown, ST 00000\n"
        "  Rx:       9999999-00001 or 7654321\n"
        "  Doctor:   Jane Smith MD / Test Provider\n"
        "  Device:   Test iPhone, Test Apple Watch\n"
        "  Store:    #12345\n",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
