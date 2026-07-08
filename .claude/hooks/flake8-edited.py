#!/usr/bin/env python3
"""PostToolUse hook: run flake8 on edited Python files under server/.

Mirrors the pattern of swiftlint-edited.py for the server-side Python codebase.
CI (.github/workflows/ci.yml) enforces flake8 on every PR touching server/;
this hook surfaces the same violations in-loop so the model fixes them before
push instead of discovering them in CI minutes later.

Scope: only .py files under server/. Edits to test_*.py outside server/, build
scripts, or other Python in the repo are skipped — flake8 isn't configured for
those paths.

The hook exits 0 silently on every non-applicable case (non-Python file, file
outside server/, flake8 not installed, timeout, malformed JSON). Exit 2 only
when there are real lint findings, so Claude Code surfaces them as a system
message in the same turn.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

LINTABLE_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})

# flake8 on a single file is fast (<1s). 30s is a generous cap.
FLAKE8_TIMEOUT_SECONDS = 30

# Match CI's invocation: server/.github/workflows/ci.yml runs
# `flake8 . --max-line-length=120 --exclude=__pycache__`.
FLAKE8_MAX_LINE_LENGTH = "120"


def file_to_lint(event: dict) -> str | None:
    """Return the file path if this event should trigger flake8, else None.

    Only `.py` files under `server/` are in scope. Files outside server/ may
    be hook scripts, helper utilities, etc. — flake8 isn't configured for them
    and emitting violations there would be noise.
    """
    tool_name = event.get("tool_name")
    if not isinstance(tool_name, str) or tool_name not in LINTABLE_TOOLS:
        return None
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    file_path = tool_input.get("file_path")
    if not isinstance(file_path, str) or not file_path.endswith(".py"):
        return None

    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    server_dir = os.path.join(project_dir, "server") if project_dir else "server"
    # Use os.path.commonpath to test "is file_path under server_dir" robustly
    # against trailing slashes and symlinks the user may have on the path.
    try:
        common = os.path.commonpath([os.path.abspath(file_path), os.path.abspath(server_dir)])
    except ValueError:
        # commonpath raises on mixed drive letters (Windows) or empty inputs.
        # Treat as out-of-scope.
        return None
    if common != os.path.abspath(server_dir):
        return None
    return file_path


def run_flake8(file_path: str) -> tuple[int, str, str]:
    """Run flake8 on a single file. Returns (returncode, stdout, stderr).

    Matches CI invocation flags. Pins cwd to the project root so flake8 finds
    any `setup.cfg`/`.flake8`/`pyproject.toml` config the project has.
    """
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")

    cmd = [
        "flake8",
        f"--max-line-length={FLAKE8_MAX_LINE_LENGTH}",
        "--exclude=__pycache__",
        file_path,
    ]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=FLAKE8_TIMEOUT_SECONDS,
            cwd=project_dir if project_dir else None,
        )
    except (subprocess.TimeoutExpired, OSError):
        return 0, "", ""

    return (
        result.returncode,
        (result.stdout or "").strip(),
        (result.stderr or "").strip(),
    )


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 0
    if not isinstance(event, dict):
        return 0

    file_path = file_to_lint(event)
    if file_path is None:
        return 0

    if not shutil.which("flake8"):
        return 0

    returncode, stdout, stderr = run_flake8(file_path)
    if returncode == 0 and not stdout and not stderr:
        return 0

    # flake8 prints violations to stdout, tool errors to stderr.
    if stdout:
        print(f"flake8 violations in {file_path}:\n{stdout}", file=sys.stderr)
        if stderr:
            print(f"\n[flake8 also wrote to stderr: {stderr}]", file=sys.stderr)
    elif stderr:
        print(f"flake8 error (could not lint {file_path}):\n{stderr}", file=sys.stderr)

    return 2


if __name__ == "__main__":
    sys.exit(main())
