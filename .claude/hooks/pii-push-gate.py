#!/usr/bin/env python3
"""PreToolUse hook: BLOCK `git push` when unpushed commits contain PII.

Last line of defense before content leaves the machine. When Claude is
about to run a `git push`, this scans the diff of every unpushed commit on
the current branch against two layers:

1. The gitignored personal denylist (`.claude/pii-denylist.local.txt`) —
   the owner's real strings that must never appear anywhere in the repo.
   Matches are reported masked so this hook's own output never echoes them.
2. Generic patterns: browser/network-capture artifact paths
   (`.playwright-mcp/`), and personalized device-name possessives.

Unlike `pre-pr-reviewer-reminder.py` (advisory), this hook EXITS 2 on a
hit and blocks the push. Remove the offending content (amend/rewrite the
unpushed commits), then retry.

Scope note: this guards pushes made through Claude Code's Bash tool. For
terminal pushes outside Claude, the same check can be installed as a git
pre-push hook — see the "Pre-push PII gate" section in CLAUDE.md.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

DENYLIST_RELPATH = os.path.join(".claude", "pii-denylist.local.txt")

CAPTURE_PATH = re.compile(r"\.playwright-mcp/")
DEVICE_POSSESSIVE = re.compile(r"\b([A-Z][a-z]+)['’]s\s+(?:iPhone|iPad|Apple\s+Watch|MacBook)")
# Fictional owners used in docs/fixtures per CLAUDE.md examples.
FICTIONAL_OWNERS = frozenset({"test", "fake", "mock", "sample", "sam", "jane", "john"})


def repo_root() -> str | None:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10, check=True,
        )
        return out.stdout.strip() or None
    except (subprocess.SubprocessError, OSError):
        return None


def load_denylist(root: str) -> list[str]:
    try:
        with open(os.path.join(root, DENYLIST_RELPATH), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    return [t.strip() for t in lines if t.strip() and not t.strip().startswith("#")]


def unpushed_diff(root: str) -> str:
    """Concatenated added-line diff of commits that would be pushed.

    Uses @{push} when an upstream is configured; falls back to origin/main
    as the base for a brand-new branch. Only ADDED lines are scanned —
    removals of PII are the fix, not the problem."""
    for base in ("@{push}", "origin/main"):
        try:
            out = subprocess.run(
                ["git", "-C", root, "diff", f"{base}...HEAD", "--unified=0"],
                capture_output=True, text=True, timeout=30,
            )
            if out.returncode == 0:
                return "\n".join(
                    line[1:] for line in out.stdout.splitlines()
                    if line.startswith("+") and not line.startswith("+++")
                )
        except (subprocess.SubprocessError, OSError):
            continue
    return ""


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if payload.get("tool_name") != "Bash":
        return 0
    command = (payload.get("tool_input") or {}).get("command") or ""
    if "git push" not in command or "git push-" in command:
        return 0

    root = os.environ.get("CLAUDE_PROJECT_DIR") or repo_root()
    if not root:
        return 0
    added = unpushed_diff(root)
    if not added:
        return 0

    findings: list[str] = []
    lowered = added.lower()
    for term in load_denylist(root):
        if term.lower() in lowered:
            findings.append(
                f"denylisted personal term '{term[0]}…({len(term)} chars)' "
                f"from {DENYLIST_RELPATH}"
            )
    if CAPTURE_PATH.search(added):
        findings.append("browser/network capture artifact path (.playwright-mcp/)")
    for m in DEVICE_POSSESSIVE.finditer(added):
        if m.group(1).lower() not in FICTIONAL_OWNERS:
            findings.append(
                f"personalized device-name possessive ('{m.group(1)}'s …) — use 'Test iPhone' style"
            )
            break

    if not findings:
        return 0

    print(
        "[pii-push-gate] BLOCKED: unpushed commits add content that looks like "
        "PII. This is a public repository — fix the commits before pushing:",
        file=sys.stderr,
    )
    for f in findings:
        print(f"  - {f}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
