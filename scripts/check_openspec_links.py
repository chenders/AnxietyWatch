#!/usr/bin/env python3
"""Fail when OpenSpec Markdown has missing local targets or malformed headings."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from urllib.parse import unquote


FENCED_CODE = re.compile(r"^[ \t]*(`{3,}|~{3,}).*?^[ \t]*\1[ \t]*$", re.DOTALL | re.MULTILINE)
INLINE_CODE = re.compile(r"(`+).*?\1", re.DOTALL)
MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
EXTERNAL_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
MALFORMED_HEADING = re.compile(r"^(### Requirement|#### Scenario)\b(?!:)")


def without_code(markdown: str) -> str:
    return INLINE_CODE.sub("", FENCED_CODE.sub("", markdown))


def link_target(raw_target: str) -> str | None:
    raw_target = raw_target.strip()
    if not raw_target:
        return None
    if raw_target.startswith("<"):
        closing = raw_target.find(">")
        target = raw_target[1:closing] if closing >= 0 else raw_target[1:]
    else:
        target = raw_target.split(maxsplit=1)[0]
    if not target or target.startswith(("#", "//")) or EXTERNAL_SCHEME.match(target):
        return None
    return unquote(target.split("#", 1)[0].split("?", 1)[0])


def document_errors(root: Path) -> tuple[list[Path], list[tuple[Path, str]], list[tuple[Path, int, str]]]:
    markdown_files = sorted(root.rglob("*.md"))
    missing: list[tuple[Path, str]] = []
    malformed: list[tuple[Path, int, str]] = []
    for source in markdown_files:
        markdown = without_code(source.read_text(encoding="utf-8"))
        relative_source = source.relative_to(root)
        for line_number, line in enumerate(markdown.splitlines(), start=1):
            if MALFORMED_HEADING.match(line.strip()):
                malformed.append((relative_source, line_number, line.strip()))
        for raw_target in MARKDOWN_LINK.findall(markdown):
            target = link_target(raw_target)
            if target is None:
                continue
            destination = root / target.lstrip("/") if target.startswith("/") else source.parent / target
            if not destination.resolve().exists():
                missing.append((relative_source, target))
    return markdown_files, missing, malformed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="OpenSpec directory to scan")
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.is_dir():
        parser.error(f"not a directory: {root}")

    markdown_files, missing, malformed = document_errors(root)
    if missing:
        print("Missing local OpenSpec Markdown targets:", file=sys.stderr)
        for source, target in missing:
            print(f"  {source}: {target}", file=sys.stderr)
    if malformed:
        print("Malformed OpenSpec headings (expected a colon):", file=sys.stderr)
        for source, line_number, heading in malformed:
            print(f"  {source}:{line_number}: {heading}", file=sys.stderr)
    if missing or malformed:
        return 1

    print(f"OpenSpec document checks passed for {len(markdown_files)} Markdown files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
