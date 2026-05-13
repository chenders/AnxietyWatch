# AGENTS.md

## XcodeBuildMCP

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.

## Git Workflow

- **Never commit or push directly to `main`.** Always create a feature branch from `main` (`git checkout -b <branch-name> main`).
- **Stage specific files by name.** Never use `git add -A` or `git add .` — this prevents committing tool artifacts or sensitive files.
- Use `git pull --rebase` instead of `git pull`. Avoid `git reset --hard` and other destructive operations.

## Pre-PR review (required before `git push`)

**Mandatory:** Before any `git push` that includes substantive Swift changes (new files, new behavior, non-trivial modifications, or new tests), run the `swift-pre-pr-reviewer` agent on the unpushed diff. Address any **Will Block** findings before pushing. Address **Should Address** findings unless explicitly deferred with a reason recorded in the commit message or PR description.

Skip the review only for trivial pushes (comments, README, version bumps, build-config tweaks, scheme-file bookkeeping). When in doubt, run it.

The agent definition lives at `.claude/agents/swift-pre-pr-reviewer.md` and is calibrated against the recurring Copilot-review categories observed in this repo. A `PreToolUse` hook (`.claude/hooks/pre-pr-reviewer-reminder.py`, wired in `.claude/settings.json`) surfaces a non-blocking reminder at push time; the policy is enforced by convention, not by the hook.

## Keeping Phase Plan Docs Updated

**Mandatory:** When shipping work that has a corresponding plan doc in `docs/plans/`, update the doc with shipped/pending status markers, PR links, and any scope-deltas (decisions made during execution, splits, additions, deferrals) in the same commit as the merge — or as an immediate follow-up PR. The original plan stays preserved verbatim as a historical record; new notes go under an `## Implementation notes (post-merge)` section at the end of the doc. A plan doc that doesn't reflect what actually shipped is a defect: the next contributor can't pick up where the work left off without re-doing the archaeology.

## Testing

- After writing or modifying code, run the relevant tests to verify your changes:
  - iOS: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests`
  - Server: `cd server && python -m pytest tests/`
  - Server lint: `cd server && flake8 . --max-line-length=120 --exclude=__pycache__`
- All new or changed code must include tests. Use Swift Testing (`@Test`, `#expect()`) for iOS tests.
- Fixing failing tests is always in scope — never dismiss a red test as "not my problem."
- Fixing compiler warnings is always in scope — treat a new warning the same as a failing test. Don't add new warnings; don't ship a build with warnings. CI enforces zero: Xcode builds use `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, SwiftLint runs without `continue-on-error`, and `flake8` runs on the server. No "acceptable count" — zero is the bar.

## Public Repository — Sensitive Data Rules

**This is a public repository.** Every file, commit message, and PR description is visible to the world.

- **Test data must be obviously fictional:** Use `9999999-00001` for Rx numbers, `Jane Smith MD` for doctors, `555-0100` for phone numbers, `Test iPhone` for devices. Never use real names, addresses, or identifiers.
- **Never log credentials or PII:** No passwords, API keys, tokens, usernames, or emails in logs — not even at DEBUG level. Log only non-identifying metadata (e.g., `password_present=True`, `field_len=12`).
- **No personal info in code or comments:** Remove Xcode "Created by [real name]" headers. Do not reference real people, real devices, or real locations.
- **No unreviewed images/screenshots:** Do not commit screenshots, images, or PDFs without reviewing for personal data.
- The project was renamed from **AnxietyScope** to **AnxietyWatch** — fix any remaining old references.

## Python Server Conventions (server/)

- **Line length:** 120 characters max (matches flake8 CI config).
- **SQL:** Always parameterize user-supplied values (`%s` with psycopg2). Never interpolate user input into SQL strings.
- **Auth:** Bearer token auth with SHA-256 hashed keys. Admin pages use session-based auth with `hmac.compare_digest`.
- **No ORM** — raw SQL with psycopg2 is intentional.
- **Error responses:** Never leak internal error details (stack traces, DB connection strings) to API clients.

## Key Design Principles

1. **HealthKit is the source of truth** for physiological data — the app reads, never writes.
2. **Export-first** — every piece of data should be exportable.
3. **Graceful degradation** — the app works with whatever data is available.
4. **Personal baselines over absolute thresholds** — flag deviations from the user's rolling average, not population norms.
5. **The journal is the anchor** — all objective data is contextualized by subjective experience.
