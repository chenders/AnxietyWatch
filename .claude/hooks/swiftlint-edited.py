#!/usr/bin/env python3
"""PostToolUse hook: run SwiftLint on edited Swift files.

Claude Code passes a JSON tool event on stdin. If the event is a
Write/Edit/MultiEdit of a `.swift` file, this hook runs
`swiftlint lint --strict --quiet <file>` and, if SwiftLint
reports any violation, prints the output to stderr and exits with
code 2. Exit code 2 tells Claude Code to feed the stderr back into
the conversation as a system message so the model sees the violation
in the same turn and can fix it before moving on — instead of
discovering it post-push in CI.

The hook is intentionally non-fatal across environment differences:
- non-Swift file, non-edit tool, malformed JSON → exit 0 silently
- SwiftLint not installed → exit 0 silently (the goal is to help
  when SwiftLint is available, not to require it on every machine)
- SwiftLint timeout or OSError → exit 0 silently

Coexists with .claude/hooks/post-tool-call.py (the provenance hook
in the maintainer's local settings.json). Both hooks can be matched
on the same PostToolUse event; Claude Code runs them independently.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

# Tool names this hook reacts to. Matches Claude Code's tool-event
# `tool_name` values for file-mutating tools.
LINTABLE_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})

# Cap the SwiftLint run so a misbehaving config can't hang the hook
# indefinitely. SwiftLint on a single file is fast (<1s typical); 30s
# is a generous upper bound.
SWIFTLINT_TIMEOUT_SECONDS = 30


def file_to_lint(event: dict) -> str | None:
    """Decide whether this tool event triggers a SwiftLint run.

    Returns the file path to lint, or None if the event should be
    skipped (non-edit tool, non-Swift file, unexpected schema).

    Each field is type-checked rather than just defaulted, because
    `dict.get(key, default)` only returns `default` when the key is
    *absent*; if Claude Code ever emits `{"tool_input": null}` or a
    non-dict value, naive chained `.get()` would raise AttributeError
    and make the hook fail noisily. We want unexpected schemas to
    exit 0 silently.
    """
    tool_name = event.get("tool_name")
    if not isinstance(tool_name, str) or tool_name not in LINTABLE_TOOLS:
        return None
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    file_path = tool_input.get("file_path")
    if not isinstance(file_path, str) or not file_path.endswith(".swift"):
        return None
    return file_path


def run_swiftlint(file_path: str) -> tuple[int, str, str]:
    """Run SwiftLint on a single file. Returns (returncode, stdout, stderr).

    Channels are returned separately so the caller can label them
    correctly — SwiftLint prints lint *violations* to stdout (the
    model should fix the code) and *tool/config errors* to stderr
    (a different signal: lint couldn't run, may need maintainer
    attention). Merging the two would mislabel config errors as
    violations.

    Pins SwiftLint's cwd and `--config` to the project root via the
    `CLAUDE_PROJECT_DIR` env var that Claude Code sets on hook
    invocation. Without these pins, SwiftLint's behavior depends on
    the launcher's cwd and on its upward-search heuristic for
    `.swiftlint.yml`, which can silently produce wrong results (e.g.,
    miss our excluded paths or use SwiftLint defaults instead of our
    150/200-char `line_length` thresholds). With the pins, behavior
    is deterministic regardless of where the hook is launched from.
    """
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")

    cmd = ["swiftlint", "lint", "--strict", "--quiet"]
    if project_dir:
        config_path = os.path.join(project_dir, ".swiftlint.yml")
        if os.path.isfile(config_path):
            cmd.extend(["--config", config_path])
    cmd.append(file_path)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=SWIFTLINT_TIMEOUT_SECONDS,
            cwd=project_dir if project_dir else None,
        )
    except (subprocess.TimeoutExpired, OSError):
        # Treat as "couldn't lint, don't break the conversation."
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

    if not shutil.which("swiftlint"):
        return 0

    returncode, stdout, stderr = run_swiftlint(file_path)
    if returncode == 0 and not stdout and not stderr:
        return 0

    # Label by output channel so the model can distinguish "fix the code"
    # (lint violations on stdout) from "couldn't lint" (tool/config error
    # on stderr). Mixing them would let a config error masquerade as a
    # violation the author should fix.
    if stdout:
        print(f"SwiftLint violations in {file_path}:\n{stdout}", file=sys.stderr)
        if stderr:
            print(f"\n[SwiftLint also wrote to stderr: {stderr}]", file=sys.stderr)
    elif stderr:
        print(f"SwiftLint error (could not lint {file_path}):\n{stderr}", file=sys.stderr)

    # Exit 2 so Claude Code surfaces the stderr to the model in the
    # same turn — the violation or tool error comes back as feedback
    # the model can act on immediately.
    return 2


if __name__ == "__main__":
    sys.exit(main())