#!/usr/bin/env python3
"""PostToolUse hook: warn when a new medication_name string literal diverges
from the canonical names declared in code.

The trigger case: the production sync database has two entries that refer to
the same drug — 'Clonazepam 1mg Tablets' and 'clonazePAM'. Because the server
table's primary key includes medication_name, a rename has subtle sync
implications and the working pattern has been to use ILIKE in queries rather
than rename. This hook prevents a NEW drift from being introduced — when code
adds a `medication_name = "..."` literal or an enum case that doesn't match an
existing canonical name, warn so the maintainer notices in-loop.

The hook is advisory (exit 2 surfaces a system message but does not block —
the maintainer chooses whether to harmonize or proceed with the drift
deliberately).

Scope: Write/Edit/MultiEdit on Swift files. Python files referencing
medication_name (sync code, admin UI) are also in scope.
"""
from __future__ import annotations

import json
import os
import re
import sys

LINTABLE_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})

# Known canonical names. The maintainer should add to this list when a
# new medication is introduced. The hook reads
# AnxietyWatch/Models/MedicationDefinition.swift at runtime to extract any
# additional canonical names declared there.
SEED_CANONICAL_NAMES = frozenset({
    "Allopurinol",
    "Amphetamine-Dextroamphet ER",
    "Clonazepam 1mg Tablets",
    "D-Amphetamine ER 30mg Salt Combo CP",
    "D-Amphetamine Salt Combo 30mg Tabs",
    "Escitalopram 10mg Tablets",
    "Escitalopram 20mg Tablets",
    "Escitalopram Oxalate",
    "Gabapentin",
    "Mirtazapine 15mg Tablets",
    "Quetiapine 25mg Tablets",
    "Zolpidem Tartrate",
    # 'clonazePAM' is INTENTIONALLY not in this list — it's a legacy drift
    # row, not a new canonical name we want to perpetuate.
})


def discover_canonical_names() -> set[str]:
    """Return the union of seed names and any names declared in
    AnxietyWatch/Models/MedicationDefinition.swift."""
    names = set(SEED_CANONICAL_NAMES)
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if not project_dir:
        return names
    medication_def_path = os.path.join(
        project_dir, "AnxietyWatch", "Models", "MedicationDefinition.swift"
    )
    try:
        with open(medication_def_path, "r", encoding="utf-8") as f:
            content = f.read()
    except (FileNotFoundError, PermissionError, OSError):
        return names
    # Pull any `name: "..."` or `static let foo = "..."` strings near the top
    # of the file — broad heuristic.
    for m in re.finditer(r'"([A-Z][A-Za-z0-9 \-]+)"', content):
        candidate = m.group(1)
        if len(candidate) >= 4 and any(c.isalpha() for c in candidate):
            names.add(candidate)
    return names


def is_in_scope(file_path: str) -> bool:
    if not file_path.endswith((".swift", ".py")):
        return False
    # Skip the seed file itself — declarations there ARE the canonical source.
    if file_path.endswith("MedicationDefinition.swift"):
        return False
    # Skip hook authoring and tests — these files quote medication names as
    # docstring examples or fixtures and we don't want to warn on their own
    # source.
    skip_segments = ("/.claude/", "/docs/", "/server/tests/", "/AnxietyWatchTests/")
    if any(seg in file_path for seg in skip_segments):
        return False
    return True


def extract_medication_strings(content: str) -> list[tuple[int, str]]:
    """Find string literals that appear in a medication-name context."""
    findings: list[tuple[int, str]] = []
    lines = content.splitlines()
    # Patterns:
    #   medication_name = "..."  / medicationName: "..."
    #   "..." as the right-hand side of a comparison with a known column
    #   Predicate { $0.medication_name == "..." }
    # Patterns match common ways medication names get assigned in this codebase:
    #   medication_name = "..."           Python / SQL-flavored
    #   medicationName = "..."            Swift property assignment
    #   medicationName: String = "..."    Swift `let` with type annotation
    #   medicationName: "..."             dict-literal / TOML / YAML-ish
    #   .medicationName == "..."          predicate comparison
    name_patterns = [
        # Bare assignment / comparison forms
        re.compile(r'medication_?[Nn]ame\s*[:=]+\s*"([^"]+)"'),
        # Swift `let` with type annotation: `name: Type = "..."`
        re.compile(r'medication_?[Nn]ame\s*:\s*\w+\??\s*=\s*"([^"]+)"'),
        # Dotted access with equality / assignment
        re.compile(r'\.medicationName\s*={1,2}\s*"([^"]+)"'),
    ]
    for i, line in enumerate(lines):
        for pat in name_patterns:
            for m in pat.finditer(line):
                findings.append((i + 1, m.group(1)))
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

    canonical = discover_canonical_names()
    strings = extract_medication_strings(content)
    if not strings:
        return 0

    drifted: list[tuple[int, str]] = []
    for line_no, value in strings:
        if value in canonical:
            continue
        # Soft match: ignore-case equivalence is still drift (clonazePAM vs
        # Clonazepam 1mg Tablets has different casing AND different content,
        # but a single-case-flip variant should still be flagged).
        soft_matches = [c for c in canonical if c.lower() == value.lower()]
        if soft_matches:
            drifted.append((
                line_no,
                f"'{value}' — differs by case only from canonical '{soft_matches[0]}'.",
            ))
            continue
        drifted.append((line_no, f"'{value}' — not in canonical list."))

    if not drifted:
        return 0

    rel_path = file_path
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if project_dir and file_path.startswith(project_dir):
        rel_path = file_path[len(project_dir):].lstrip("/")

    print(
        f"Medication name drift warning in {rel_path}: literal(s) do not match "
        f"canonical names declared in AnxietyWatch/Models/MedicationDefinition.swift "
        f"or the seed allowlist.",
        file=sys.stderr,
    )
    for line_no, msg in drifted:
        print(f"  L{line_no}: {msg}", file=sys.stderr)
    print(
        "\nIf this is a new medication, add it to MedicationDefinition.swift first. "
        "If it's a deliberate variant (e.g., dose strength), confirm both the iOS "
        "definition and the production sync DB agree on the spelling.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
