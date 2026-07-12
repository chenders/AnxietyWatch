# AGENTS.md

## XcodeBuildMCP

- Prefer XcodeBuildMCP tools (`build_sim`, `test_sim`, `build_run_sim`, `clean`, `screenshot`, `record_sim_video`, `snapshot_ui`, etc.) over raw `xcodebuild` shell commands. Project/scheme/simulator defaults are persisted in `.xcodebuildmcp/config.yaml`, so most calls need no arguments.
- Call `session_show_defaults` once per session before the first build/test/run to confirm defaults are active.
- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.

## Git Workflow

- **Never commit or push directly to `main`.** Always create a feature branch from `main` (`git checkout -b <branch-name> main`).
- **Stage specific files by name.** Never use `git add -A` or `git add .` — this prevents committing tool artifacts or sensitive files.
- Use `git pull --rebase` instead of `git pull`. Avoid `git reset --hard` and other destructive operations.

## Pre-PR review (required before `git push`)

**Mandatory:** Before any `git push` that includes substantive Swift changes (new files, new behavior, non-trivial modifications, or new tests), run the `swift-pre-pr-reviewer` agent on the unpushed diff. Address any **Will Block** findings before pushing. Address **Should Address** findings unless explicitly deferred with a reason recorded in the commit message or PR description.

Skip the review only for trivial pushes (comments, README, version bumps, build-config tweaks, scheme-file bookkeeping). When in doubt, run it.

The agent definition lives at `.claude/agents/swift-pre-pr-reviewer.md` and is calibrated against the recurring Copilot-review categories observed in this repo. A `PreToolUse` hook (`.claude/hooks/pre-pr-reviewer-reminder.py`, wired in `.claude/settings.json`) surfaces a non-blocking reminder at push time; the policy is enforced by convention, not by the hook.

### Specialized review sub-agents

Pair the generalist `swift-pre-pr-reviewer` with these narrower agents on PRs touching the relevant surface (dispatch in parallel via `Task` with `subagent_type:`):

- **`swiftui-render-pitfall-detector`** — SwiftUI / SwiftData / Charts changes. Targets four iOS-26 main-thread-hang patterns (compound `#Predicate`, `NavigationLink` + `@Query`, `chartYScale(domain:)` + `.nan`, `@Observable` at WindowGroup scope).
- **`chart-ux-auditor`** — `AnxietyWatch/Views/Trends/` changes. Maps color tokens to series semantics; optionally screenshots via XcodeBuildMCP.
- **`medical-data-accuracy-reviewer`** — `Services/` changes touching HealthKit, CPAP, Polar, EMAY, FHIR labs, OCR, or CNSRisk. Unit mismatches, timezone, source-discriminator, OCR validation, baseline math. **Required (not just recommended) for `Services/CNSRisk/`.**
- **`process-walkthrough`** — single-file walkthrough generator (Mermaid + lay prose). Use to populate `docs/research/` for opaque processes (sync drain loop, clock-reset detection, baseline calculation).

## CNS Detection Engine

`AnxietyWatch/Services/CNSRisk/` is the physiological detection half of the CNS-depression early-warning Klaxon (Phase 1: detection-only, no alarm UI yet — see `docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md`). Pipeline: `CNSQualityGate` → `CNSSeverityScorer` → `CNSFusionEngine` → `CNSAlertTierMachine`, composed by `CNSDetectionPipeline` (the only entry point later phases should call). Every tunable lives in `CNSThresholds` — never re-type a literal. Invariants: indeterminate ≠ safe ≠ dangerous; severity ramps scale their floor with the personalized onset (never clamp onset to a fixed floor); escalation and clearing both require observed, primary-informed (SpO₂/RR) evidence; invalid data contributes nothing. `medical-data-accuracy-reviewer` is required (not just recommended) on every PR touching this directory.

### Slash commands

- `/query-prod <SQL>` — read-only psql against the megadude deployment via `docker exec` (bypasses `.env` permission issue).
- `/sync-instruction-files [path]` — mirror an instruction-file change across CLAUDE.md / AGENTS.md / `.github/copilot-instructions.md` / `.github/instructions/{swift,python}.instructions.md`.
- `/respond-to-copilot [PR#]` — loop responding to Copilot review comments.

### Static analysis: Semgrep

CI runs `semgrep --config .semgrep/ --error` on PRs touching Swift. Rules at `.semgrep/swift-pitfalls.yml` cover hardcoded source labels, magic-number duplication, raw-second date arithmetic, ChartPalette violations, and the incremental-sync `lastSyncDate = .now` race (severity ERROR — blocks merge).

## Sync/restore round-trip rule

**A table that syncs UP must have a way back DOWN.** Every table added to the sync payload must also appear in the server's `ENTITY_QUERIES` **and** get an importer in `RestoreFromServer` — otherwise it backs up to the server but a fresh install (bundle-ID change, new phone, reinstall) restores zero rows of it. `QuantityHealthSample` was in neither for months; it looked harmless because HealthKit-sourced rows are re-derived by the next backfill, but the ~224k app-only EMAY oximetry rows (the app never writes to HealthKit) had no other source and would simply have been lost.

For every synced table, ask: **"if this device died right now, what brings this row back?"** If the answer is neither HealthKit nor the restore path, it isn't backed up.

## First-run-only paths

**Code that runs once per install is effectively untested.** HealthKit authorization, onboarding, migration gates, schema creation, the restore-vs-fresh decision — each stops executing the moment it succeeds once, then rots invisibly. Two real crashes shipped this way, both latent for months, both detonated by the bundle-ID rename that turned an existing user into a first-run user:

- `HKCorrelationType(.bloodPressure)` in the HealthKit read set — HealthKit disallows authorizing correlation types for read and raises an **uncatchable** ObjC `NSInvalidArgumentException`, so the app aborted on signal 6 the instant the user tapped "Allow". Request the constituent quantity types (`.bloodPressureSystolic` / `.bloodPressureDiastolic`) instead.
- A `HealthSnapshot` write during the pre-decision window — one row made the store "non-empty" and permanently blocked the restore that the migration gate exists to enable.

When touching a once-per-install path: re-exercise it on a **genuinely fresh install** (delete the app; relaunching is not the same thing), and add a test asserting the path's *inputs* — for uncatchable failures there is no error path to assert on, so input-shape validation is the only defense available.

Restore importers must preserve the server's `id` (the HealthKit mirror does update-or-insert on `hkUUID`; fresh UUIDs duplicate every row on the next backfill), set `syncedToServer = true` (bulk types export on `syncedToServer == false`; the default re-uploads the whole restored history), and be added to `restoreGuardTablesAreEmpty`. Tables over ~10k rows must be paged, not inlined in `/api/data`.

## Keeping Phase Plan Docs Updated

**Mandatory:** When shipping work that has a corresponding plan doc in `docs/plans/`, update the doc with shipped/pending status markers, PR links, and any scope-deltas (decisions made during execution, splits, additions, deferrals) in the same commit as the merge — or as an immediate follow-up PR. The original plan stays preserved verbatim as a historical record; new notes go under an `## Implementation notes (post-merge)` section at the end of the doc. A plan doc that doesn't reflect what actually shipped is a defect: the next contributor can't pick up where the work left off without re-doing the archaeology.

## Testing

- After writing or modifying code, run the relevant tests to verify your changes:
  - iOS: use the XcodeBuildMCP `test_sim` tool when available; the shell equivalent is `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests`
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
- **No unreviewed images/screenshots:** Do not commit screenshots, images, or PDFs without reviewing for personal data. App screenshots must be captured from a simulator running fictional demo data.
- **No tool/session artifacts:** Never commit browser-automation or network captures (`.playwright-mcp/`, `*-network.txt`, HAR files) — they can contain live authenticated-session data. If one lands in a commit, rewrite the unpushed history; deleting it in a follow-up commit leaves the blob in history.
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
