#!/usr/bin/env python3
"""PostToolUse hook: flag VoiceOver/accessibility pitfalls in edited Swift files.

Catches four recurring accessibility defects documented in CLAUDE.md "Common
pitfalls" that are deterministically detectable with text patterns:

1. Int(x) where the on-screen format uses %.0f — VoiceOver speaks a truncated
   number, the user sees a rounded one. Use Int(x.rounded()) to match.
2. Button inside NavigationLink label — inner Button becomes non-interactive.
3. .accessibilityElement(children: .combine) on a container that also has
   interactive children (Button, NavigationLink) — collapses them into one
   VoiceOver element so the user can't focus them independently.
4. accessibilityLabel("…/…") that suggests VoiceOver mis-pronunciation
   patterns (slashes read as "slash", "vs" read as "vee ess").

Static text patterns can't catch all cases (some are AST-level), but they
catch the common shapes that hit production. The hook exits 0 silently when
no findings exist; exit 2 with the findings in stderr otherwise.

Scope: only files under AnxietyWatch/ or AnxietyWatch Watch App/ — production
Swift, not test fixtures.
"""
from __future__ import annotations

import json
import os
import re
import sys

LINTABLE_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})

# Source directories where accessibility pitfalls are user-facing. Test files
# and build scripts are out of scope.
PRODUCTION_DIRS = ("AnxietyWatch/", "AnxietyWatch Watch App/", "AnxietyWatchWidgets/")


def is_in_scope(file_path: str) -> bool:
    if not file_path.endswith(".swift"):
        return False
    # Match anywhere in the absolute path to handle both repo-relative and
    # absolute paths Claude Code may pass through.
    return any(prod in file_path for prod in PRODUCTION_DIRS)


def find_int_truncation_with_percent_f(content: str) -> list[tuple[int, str]]:
    """Look for Int(x) and %.0f in close proximity.

    Heuristic: scan for any line with Int(<expr>) where <expr> isn't already
    .rounded()-suffixed, then scan a 5-line window for %.0f or %+.0f. A real
    finding is one where both appear in the same view body.
    """
    findings: list[tuple[int, str]] = []
    lines = content.splitlines()
    # Pattern: Int(<expr>) where <expr> does not contain .rounded()
    int_pattern = re.compile(r"\bInt\(\s*([^)]*?)\s*\)")
    fmt_pattern = re.compile(r"%[+\-]?\.?\d*f")

    int_hits: list[tuple[int, str]] = []
    for i, line in enumerate(lines):
        for m in int_pattern.finditer(line):
            inner = m.group(1)
            if ".rounded()" not in inner and "." not in inner:
                # Bare Int(x) — likely truncation
                int_hits.append((i, line.strip()))
                continue
            if ".rounded()" not in inner and (
                ".doubleValue" in inner or ".quantity" in inner
            ):
                # Int on a float-typed expression without .rounded() — same risk
                int_hits.append((i, line.strip()))

    for line_no, snippet in int_hits:
        window_start = max(0, line_no - 3)
        window_end = min(len(lines), line_no + 4)
        window_text = "\n".join(lines[window_start:window_end])
        if fmt_pattern.search(window_text):
            findings.append(
                (
                    line_no + 1,
                    f"Int(...) near %.0f format string — VoiceOver may speak a truncated "
                    f"value while the screen shows a rounded one. Use Int(x.rounded()).\n"
                    f"  {snippet}"
                )
            )
    return findings


def find_button_inside_navigation_link(content: str) -> list[tuple[int, str]]:
    """Detect NavigationLink { … Button(…) … } shapes.

    Single-pass scan tracking NavigationLink open-brace nesting depth and
    looking for `Button(` inside that block. A Button inside the destination
    closure (the {…} before `label:`) is fine; we want to flag Buttons inside
    the *label* closure or in a single-trailing-closure shape that's used as
    the link's content.

    Heuristic: flag any `Button(` appearing within 30 lines after a
    `NavigationLink {` AND before the closing brace of that block, conservative
    enough to be useful without an AST.
    """
    findings: list[tuple[int, str]] = []
    lines = content.splitlines()
    nav_link_starts = [
        i for i, line in enumerate(lines) if re.search(r"\bNavigationLink\b", line)
    ]
    for start in nav_link_starts:
        # Find the matching closing brace by simple counting
        depth = 0
        seen_open = False
        for j in range(start, min(start + 30, len(lines))):
            for ch in lines[j]:
                if ch == "{":
                    depth += 1
                    seen_open = True
                elif ch == "}":
                    depth -= 1
            if seen_open and depth <= 0:
                end = j
                break
        else:
            end = min(start + 30, len(lines))
        block = "\n".join(lines[start:end + 1])
        if re.search(r"\bButton\s*\(", block):
            findings.append(
                (
                    start + 1,
                    "Button(...) inside a NavigationLink block — the inner Button may "
                    "be non-interactive (taps trigger navigation instead of the Button's "
                    "action). Split hit targets.\n  "
                    + lines[start].strip()
                )
            )
    return findings


def find_combine_with_interactive_children(content: str) -> list[tuple[int, str]]:
    """Detect .accessibilityElement(children: .combine) on a container that
    also wraps a Button or NavigationLink.

    Heuristic: for each `.accessibilityElement(children: .combine)`, scan
    backwards up to 40 lines for `Button(` or `NavigationLink`. If found
    within a sibling depth (indented one level less than the modifier), flag.
    """
    findings: list[tuple[int, str]] = []
    lines = content.splitlines()
    pattern = re.compile(r"\.accessibilityElement\(children:\s*\.combine\)")
    for i, line in enumerate(lines):
        if not pattern.search(line):
            continue
        window_start = max(0, i - 40)
        window = "\n".join(lines[window_start:i])
        if re.search(r"\bButton\s*\(|\bNavigationLink\b", window):
            findings.append(
                (
                    i + 1,
                    ".accessibilityElement(children: .combine) on a container that wraps "
                    "an interactive child (Button or NavigationLink) — VoiceOver collapses "
                    "them into one element, so the user can't focus or activate the inner "
                    "control. Use children: .ignore on the container and put the summary on "
                    "the interactive label.\n  " + line.strip()
                )
            )
    return findings


def find_slash_in_accessibility_label(content: str) -> list[tuple[int, str]]:
    """Flag accessibilityLabel/Value strings containing '/' — VoiceOver reads
    '/' as 'slash'. For shorthand like 'LF/HF' that's the intended pronunciation
    so we only flag if the on-screen Text doesn't also use the slash form."""
    findings: list[tuple[int, str]] = []
    lines = content.splitlines()
    pattern = re.compile(r'\.accessibility(?:Label|Value)\(\s*"([^"]*/[^"]*)"\s*\)')
    for i, line in enumerate(lines):
        m = pattern.search(line)
        if not m:
            continue
        label = m.group(1)
        # If the same file also has a Text("...X/Y...") that matches, this is
        # likely intentional shorthand. Skip in that case.
        if re.search(re.escape(label) + r"|" + re.escape(label.replace("/", " over ")), content):
            # Heuristic: only flag if no obvious matching Text usage
            text_pattern = re.compile(r'Text\(\s*"[^"]*/' + re.escape(label.split("/", 1)[1].split(" ")[0]) + r'[^"]*"')
            if text_pattern.search(content):
                continue
        findings.append(
            (
                i + 1,
                f"accessibilityLabel contains '/' which VoiceOver reads as 'slash'. "
                f"Verify pronunciation matches the on-screen wording, or rewrite "
                f"(e.g., 'LF/HF' stays as-is; 'AM/PM' should usually expand).\n  "
                + line.strip()
            )
        )
    return findings


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if not isinstance(event, dict):
        return 0

    tool_name = event.get("tool_name")
    if not isinstance(tool_name, str) or tool_name not in LINTABLE_TOOLS:
        return 0
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0
    file_path = tool_input.get("file_path")
    if not isinstance(file_path, str) or not is_in_scope(file_path):
        return 0

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()
    except (FileNotFoundError, PermissionError, OSError):
        return 0

    findings: list[tuple[int, str]] = []
    findings.extend(find_int_truncation_with_percent_f(content))
    findings.extend(find_button_inside_navigation_link(content))
    findings.extend(find_combine_with_interactive_children(content))
    findings.extend(find_slash_in_accessibility_label(content))

    if not findings:
        return 0

    findings.sort(key=lambda f: f[0])
    rel_path = file_path
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if project_dir and file_path.startswith(project_dir):
        rel_path = file_path[len(project_dir):].lstrip("/")

    print(f"VoiceOver / accessibility findings in {rel_path}:", file=sys.stderr)
    for line_no, msg in findings:
        print(f"  L{line_no}: {msg}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
