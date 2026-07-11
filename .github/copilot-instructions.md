# Copilot Instructions for AnxietyWatch

## Project Overview

AnxietyWatch is a personal iOS + watchOS anxiety tracking app with a Python sync server. It combines subjective journaling with objective physiological data from HealthKit, an AirSense 11 CPAP machine, and smart blood pressure monitors.

This is an open-source personal project — not a commercial product, no App Store plans.

## Instruction File Layout

This file holds cross-cutting standards that apply to every review. Language-specific guidance lives in path-scoped files Copilot activates only when matching files are changed:

- `.github/instructions/swift.instructions.md` — applies to `**/*.swift` (iOS app, watchOS app, widgets, Swift tests).
- `.github/instructions/python.instructions.md` — applies to `server/**/*.py`.

When changing conventions, update the file whose path scope covers the rule. Cross-cutting changes go here. Also keep `CLAUDE.md`, `AGENTS.md`, and `REQUIREMENTS.md` in sync — a rule in one but not the others is a bug, flag it.

## Review Priorities

When you have limited comments to spend, spend them in this order:

1. **Correctness bugs** — wrong output, off-by-one, missing state branches, non-deterministic ordering that affects rendering, predicate scope bugs, nil-discriminator backwards-compatibility.
2. **Performance footguns** — unbounded queries that filter in-memory, computed properties called repeatedly in one render, `O(n)` rebuilds in hot paths, DoS-by-payload-size on server endpoints.
3. **Accessibility / a11y consistency** — VoiceOver text not matching on-screen formatting, missing labels, nav/button hit-target conflicts (Swift-side only).
4. **State-machine gaps** — destructive actions that only handle the obvious state, sheets dismissible mid-recording with no Stop affordance, fallback states that misreport.
5. **Source-of-truth drift** — hardcoded constants where a typed reference exists, magic numbers duplicated across files, doc comments contradicting the code below them, schema/migration drift between `schema.sql` and Alembic migrations.
6. **API / public-repo safety** — PII, real-looking test data, leaked secrets.

**Skip or deprioritize:** doc-comment punctuation, naming bikesheds, low-signal style preferences. SwiftLint and flake8 enforce *some* style rules in CI (see `.swiftlint.yml` — `line_length` 200-char hard error is the most notable; several common defaults like `trailing_comma` are explicitly disabled). For *style* rules: don't enumerate by hand if CI catches them; if CI doesn't catch them they're not worth comment budget anyway. **This deprioritization applies only to style.** Substantive issues from priorities 1-4 above (correctness, performance, accessibility, state-machine gaps) must still be flagged whether or not CI catches them — many won't be CI-detectable at all.

## Review philosophy

Only comment when you have HIGH CONFIDENCE (>80%) that an issue exists. Prefer silence over uncertainty. Avoid hedging language like "consider", "maybe", "you might want to" — if a fix is right, state it as a fix; if uncertain, don't comment.

Be concise: one sentence per comment when possible.

**A table that syncs UP must have a way back DOWN.** Any table added to the sync payload must also appear in the server's `ENTITY_QUERIES` *and* get an importer in `RestoreFromServer` — otherwise it backs up to the server but a fresh install (bundle-ID change, new phone, reinstall) restores zero rows of it. `QuantityHealthSample` was in neither for months. It looked harmless because HealthKit-sourced rows (Apple/Polar/Dexcom) get re-derived by the next backfill — but app-only rows (EMAY oximetry: the app never writes to HealthKit) had no other source and were simply lost. When reviewing a diff that adds or extends a synced table, ask: *if this device died right now, what brings this row back?* If the answer is neither HealthKit nor the restore path, flag it. Restore importers must preserve the server's `id` (the HealthKit mirror does update-or-insert on `hkUUID`; fresh UUIDs duplicate every row on the next backfill) and set `syncedToServer = true` (bulk types export on `syncedToServer == false`; the default re-uploads the whole restored history).

**First-run-only code paths are effectively untested — scrutinize them hardest.** Any code that runs exactly once per install (HealthKit authorization, onboarding, migration gates, schema creation, restore-vs-fresh decisions) stops executing for the developer the moment it succeeds once, then rots invisibly. Two real crashes shipped this way, both latent for months and both detonated by a bundle-ID rename that turned an existing user into a first-run user: an `HKCorrelationType` in the HealthKit read set (uncatchable ObjC exception → signal 6 on the very first permission prompt), and a `HealthSnapshot` write during the pre-decision window that permanently bricked "Restore from Server". When a diff touches a once-per-install path, ask: *has anyone actually run this on a fresh install since the last change, or only on an already-initialized one?* Flag it if there's no test asserting the path's **inputs** — for uncatchable failures there is no error path to test, so validating the input shape is the only available defense.

**A guard that fails closed must still name its blocker.** Failing closed is correct (an unreadable or non-empty store must not be restored into). Failing closed *silently* is a defect: `restoreGuardTablesAreEmpty` coerced a thrown fetch to `Int.max` and reported it identically to "there are rows", so the user saw "store already contains data" on a demonstrably empty store with no way to tell which of 14 tables was at fault. If a guard blocks a user-visible action, its error must carry the specific reason.

**Watch for interaction bugs between fixes within a single PR or branch.** When a diff combines a bug fix with an optimization (or two fixes in different rounds of review), check whether the optimization preserves the invariants the fix established. Common pattern: a fix introduces "always do X before Y" as a correctness invariant; a later optimization adds a branch that skips X conditionally but leaves Y unconditional — silently breaking the invariant in a smaller window. This is the kind of bug that's invisible when reviewing each commit independently but obvious when reviewing the combined diff. See the "conditional-skip optimizations" pitfall in `.github/instructions/swift.instructions.md` for the canonical example (sync drain `bulkOnly` flag + cursor advance).

## CI context

This repo runs SwiftLint `--strict`, Semgrep (`.semgrep/swift-pitfalls.yml`), and treats Swift warnings as errors in CI (`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`); the server runs flake8.

- **Don't flag SwiftLint *style* violations** actively enforced by `.swiftlint.yml` *in linted paths* — most notably `line_length` (150 warn, 200 hard error). CI's `swiftlint --strict` blocks these automatically for files under `AnxietyWatch/` and `AnxietyWatchTests/`. **Scope caveat:** `.swiftlint.yml` excludes `AnxietyWatch Watch App/` and `AnxietyWatchWidgets/` — Swift files in those directories are *not* linted in CI, so do flag style issues there manually (or recommend expanding the lint scope if the team wants repo-wide enforcement). Also note that `.swiftlint.yml` disables several common defaults (`trailing_comma`, `force_try`, length limits, etc.) — don't assume an example rule is enforced without checking the config.
- **Don't flag Semgrep findings already enforced by `.semgrep/swift-pitfalls.yml`**: hardcoded `"polar_h10"` / `"healthkit"` source labels outside `#Predicate`, `3 * 3600` magic numbers outside `LFHFAggregator`, `Date() - N * 86400` patterns, hardcoded chart-series colors in `Views/Trends/`, `lastSyncDate = .now` after I/O in `SyncService`. CI will block these before review.
- **Do flag *substantive* warnings whose cause isn't obvious from the diff** — deprecation, force-unwrap risks, unused-but-should-be-used vars, missing-init issues. CI will also fail on these, but your comment explains the *fix* faster than the CI message does. Per Testing Requirements below, fixing new warnings is always in scope for the author.

## CNS Detection Engine (`AnxietyWatch/Services/CNSRisk/`)

Safety-critical path — the physiological detection half of the CNS-depression early-warning Klaxon. Treat any change here as priority-1 correctness review regardless of diff size. Specific rules (full detail in `.github/instructions/swift.instructions.md`):

- Every threshold, onset, floor, fidelity, fusion weight, or sustain duration must be a `CNSThresholds` member — never a re-typed literal.
- Severity ramps must scale their saturation floor down with a personalized onset, never clamp the onset to a fixed floor (a fixed floor degenerates the ramp to a step and can score a user's own normal baseline as maximal severity).
- An indeterminate quality-gate window must never yield a severity/confidence score — indeterminate is not safe and not dangerous.
- Escalation and clearing both require primary-informed (SpO₂/respiratory-rate) evidence — a corroborating-only (HR/HRV) reading must never clear a raised alert tier.
- `medical-data-accuracy-reviewer` is required (not just recommended) on every PR touching this directory, per `CLAUDE.md`/`AGENTS.md`.

## Git Workflow

**Never push directly to `main`.** Always create a feature branch from `main`. Use descriptive branch names like `feat/add-export-csv` or `fix/healthkit-auth-crash`.

**Stage specific files by name.** Never use `git add -A` or `git add .` — this prevents committing tool artifacts or sensitive files.

## Repository Structure

This is a **multi-language monorepo** with two distinct components:

- **iOS app, watchOS app, widgets:** Swift 5.9+, SwiftUI, SwiftData (`@Model`), Swift Charts, HealthKit, Core Motion (`CMAltimeter`), WatchConnectivity. Test framework is Swift Testing (`@Test`). iOS sources live under `AnxietyWatch/`; watchOS sources under `AnxietyWatch Watch App/` and `AnxietyWatchWidgets/`. Swift-specific review rules live in `.github/instructions/swift.instructions.md`.
- **Sync server (`server/`):** Python 3.12, Flask, raw SQL with psycopg2 (no ORM), PostgreSQL 16, Docker Compose, GitHub Actions CI/CD to GHCR. Required env vars: `POSTGRES_PASSWORD`, `ADMIN_PASSWORD`, `SECRET_KEY`. Optional: `ANTHROPIC_API_KEY`, `GRAPHQL_API_KEY`. See `server/.env.example` and `.github/instructions/python.instructions.md` for Python-specific review rules.

## Key Design Principles

1. **HealthKit is the source of truth** for physiological data — the app reads, never writes.
2. **Export-first** — every piece of data should be exportable.
3. **Graceful degradation** — the app works with whatever data is available. Not every user has a CPAP or BP cuff.
4. **Personal baselines over absolute thresholds** — flag deviations from the user's rolling average, not population norms.
5. **The journal is the anchor** — all objective data is contextualized by subjective experience.

## Testing Requirements (cross-cutting)

- **All new or changed code must include tests.** PRs that add features or fix bugs without corresponding tests should be flagged.
- **Fixing failing tests is always in scope.** If a PR touches code near a failing test, or if CI is red, fixing the test is part of the work — never flag it as "out of scope."
- **Fixing compiler warnings is always in scope.** Treat a new warning the same as a failing test. CI enforces zero warnings: Xcode builds use `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, SwiftLint runs without `continue-on-error`, and `flake8` runs on the server. There is no "acceptable warning count" — flag any PR that introduces new warnings, period.

Language-specific testing conventions live in the path-scoped instruction files.

## Public Repository — Sensitive Data Rules

**This is a public repository.** Every file, commit, and PR is visible to the world. Flag any of the following in code review:

### Test data must be obviously fictional
- **Flag** real-looking Rx numbers, doctor names, addresses, phone numbers, device names, insurance claim numbers, or pharmacy store identifiers in test fixtures. Acceptable: `9999999-00001`, `Jane Smith MD`, `100 Example Blvd, Anytown, ST 00000`, `555-0100`, `Test iPhone`, `#12345`, `TESTPLAN`.
- **OK:** Generic medication names like "Clonazepam 1mg" — these are public drug names.

### Never log credentials or PII
- **Flag** any log call that includes a password, API key, token, security answer, username, or email address — even at DEBUG level.
- **OK:** Logging non-identifying metadata like `password_present=True`, `auth_step=success`, or `field_len=12`. Not OK: `username=%r` (usernames/emails are PII).

### No personal info in code
- **Flag** "Created by [real name]" Xcode file headers — these should be removed or generic.
- **Flag** references to real people, real device names, or real locations in code, comments, or PR descriptions.
- **Flag** committed screenshots or images that haven't been reviewed for personal data (Xcode team names, device identifiers, real health data). App screenshots must come from a simulator with fictional demo data.
- **Flag** any committed browser-automation or network-capture artifact (`.playwright-mcp/` paths, `*-network.txt`, HAR files) — these can contain live authenticated-session data. Removing the file in a later commit is NOT a fix; the blob persists in history and the unpushed commits must be rewritten.

### Project name
- The project was renamed from AnxietyScope to AnxietyWatch. **Flag** any remaining `AnxietyScope` references.

## What NOT to Do (cross-cutting)

- Don't add features or fix bugs without adding corresponding tests.
- Don't store secrets in code or commit `.env` files.
- Don't commit screenshots or images without reviewing for personal data.

Language-specific don'ts live in the path-scoped instruction files.
