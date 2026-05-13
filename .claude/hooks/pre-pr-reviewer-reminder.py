#!/usr/bin/env python3
"""
PreToolUse hook: reminds about `swift-pre-pr-reviewer` before `git push`.

Non-blocking. When Claude is about to run a `git push`, this surfaces a
reminder of the project policy (CLAUDE.md / AGENTS.md): substantive Swift
changes should be reviewed by the `swift-pre-pr-reviewer` agent before
being pushed.

Skip-criteria (trivial pushes — comments, README, version bumps,
auto-generated metadata) are judgment calls left to the model. The hook
just surfaces the reminder; the model decides whether to interrupt the
push, run the agent, address findings, and retry.

Exits 0 unconditionally — never blocks the push.
"""

import json
import sys


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0

    if payload.get("tool_name") != "Bash":
        return 0

    # `.get("command", "")` only defaults when the key is absent;
    # an explicit JSON `null` would pass through as Python `None`,
    # and `"git push" in None` raises TypeError → exit 1 → blocks
    # the tool call. The `or ""` keeps the contract that this hook
    # exits 0 unconditionally regardless of input shape.
    command = payload.get("tool_input", {}).get("command") or ""
    # Be permissive — match `git push`, `git push -u origin foo`,
    # `git push --force`, etc. Avoid false-positives on `git push-help`
    # or similar (unlikely but defensive).
    if "git push" not in command:
        return 0
    if "git push-" in command:
        return 0

    reminder = (
        "[pre-pr-reviewer-reminder] Project policy: before pushing "
        "substantive Swift changes (new files, non-trivial behavior, new "
        "tests), run the `swift-pre-pr-reviewer` agent on the unpushed "
        "diff and address findings first. Skip only for trivial pushes "
        "(comments, README, version bumps, build-config tweaks). If you "
        "have NOT run the reviewer for the unpushed commits in this "
        "session and the changes are non-trivial, consider cancelling "
        "this push, running the agent, then retrying. See CLAUDE.md / "
        "AGENTS.md."
    )
    # stderr so Claude Code surfaces the message as hook context without
    # blocking the tool call.
    print(reminder, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())