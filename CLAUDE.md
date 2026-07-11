# CLAUDE.md — Project Context for Claude Code

## Git Workflow

**MANDATORY: Never commit or push directly to `main`.** Always create a new feature branch based on `main` before making any changes. Use `git checkout -b <branch-name> main` for new work. This applies to all changes including documentation, specs, and plans — not just code.

**Prefer safe git operations.** Use `git pull --rebase` instead of `git pull`. Avoid `git reset --hard`, `git checkout -B`, and `git switch -C` — these discard local commits and uncommitted changes. To sync with remote, ensure a clean working tree (`git stash` first if needed), then use `git pull --rebase`. Avoid `git add -A` or `git add .` — always stage specific files by name to prevent committing tool artifacts or sensitive files.

## Public Repository — Sensitive Data Rules

**This is an open-source repository. Every file, commit message, and PR description is publicly visible.** Never introduce personal, medical, or identifying information. The rules below are based on real incidents that required history rewrites to fix.

### Test data must be obviously fictional
- **Rx numbers:** Use `9999999-00001`, `7654321`, etc. Never use a number that could be a real prescription.
- **Doctor/provider names:** Use `Jane Smith MD`, `Dr. Test Provider`. Never use real names.
- **Addresses:** Use `100 Example Blvd, Anytown, ST 00000`. Never use real addresses.
- **Phone numbers:** Use `555-0100` through `555-0199` (reserved fictional range).
- **Device names:** Use `Test iPhone`, `Test Apple Watch`. Never a real personalized name (`Sam's iPhone`-style) or device nickname.
- **Pharmacy store numbers:** Use `#12345`. Never a real store identifier.
- **Insurance/claim data:** Use `TESTPLAN`, `0000000000`. Never real claim numbers.
- **Medication names in test data are OK** (e.g., "Clonazepam 1mg") — these are public drug names, not personal info.

### Never log credentials or PII
- Never log passwords, API keys, tokens, security answers, usernames, or emails — not even at DEBUG level.
- Log only non-identifying metadata about credentials (e.g., auth step success/failure, field presence/length) — never decrypted values or identifiers.
- When debugging auth flows, log presence/length (`password_present=True, password_len=12`) for credential fields, not their actual values, and do not log usernames or email addresses.

### No personal info in code or comments
- Do not add "Created by [real name]" headers to new Swift files. Xcode adds these by default — remove them.
- Do not reference real people, real devices, real locations, or real medical providers in code comments, commit messages, or PR descriptions.
- Do not commit screenshots that contain personal information (Xcode team names, device names, real health data).

### Images and binary files
- Do not commit screenshots, images, or PDFs without reviewing them for personal data.
- App screenshots for the README/docs must be captured from a simulator running obviously fictional demo data — never from a device or store containing real health data.
- Add any scratch images to `.gitignore` before they can be accidentally staged.
- CI (`pii-scan.yml`) fails PRs that add images/PDFs outside `docs/screenshots/` or `Assets.xcassets/`.

### Never commit tool/session artifacts
- Browser automation and network captures (`.playwright-mcp/`, `*-network.txt`, HAR files) can contain live authenticated-session data for real accounts. They are gitignored, blocked by the `pii-push-gate` hook, and failed by CI — if one ever lands in a commit, treat it as an incident: stop and rewrite the unpushed history, don't just delete the file in a follow-up commit (the blob survives in history).

### The old project name
- The project was renamed from **AnxietyScope** to **AnxietyWatch**. If you encounter any remaining `AnxietyScope` references, fix them.

## Keeping Instruction Files Updated

**MANDATORY:** When making changes that affect project structure, conventions, commands, workflows, coding standards, or rules, you MUST update all relevant instruction files in the same commit. These files must stay in sync:
- **`CLAUDE.md`** — Project context for Claude Code (this file)
- **`AGENTS.md`** — Multi-agent tooling instructions
- **`.github/copilot-instructions.md`** — GitHub Copilot review instructions (cross-cutting; applies to every review)
- **`.github/instructions/swift.instructions.md`** — Swift/iOS-specific Copilot review rules (`applyTo: "**/*.swift"`)
- **`.github/instructions/python.instructions.md`** — Python/server-specific Copilot review rules (`applyTo: "server/**/*.py"`)
- **`REQUIREMENTS.md`** — Full specification and data model

**When editing any instruction file, check the others for the same topic and update them too.** `CLAUDE.md` and the Copilot instruction files cover overlapping ground (coding conventions, testing rules, sensitive data rules, design principles). If you change a rule in one, apply the equivalent change to the other. A rule that exists in `CLAUDE.md` but not the relevant Copilot file (or vice versa) is a bug. Language-specific rules belong in the path-scoped `.github/instructions/*.instructions.md` files so they only activate for matching diffs; cross-cutting rules stay in `.github/copilot-instructions.md`.

## Keeping Phase Plan Docs Updated

**MANDATORY:** When shipping work that has a corresponding plan doc in `docs/plans/`, update the doc with shipped/pending status markers, PR links, and any scope-deltas (decisions made during execution, splits, additions, deferrals) in the same commit as the merge — or as an immediate follow-up PR. The original plan stays preserved verbatim as a historical record; new notes go under an `## Implementation notes (post-merge)` section at the end of the doc. A plan doc that doesn't reflect what actually shipped is a defect: the next contributor (or the next-you) can't pick up where the work left off without re-doing the archaeology.

## Commands

**For Claude Code / agentic workers:** Prefer the XcodeBuildMCP tools (`build_sim`, `test_sim`, `build_run_sim`, `clean`, `screenshot`, `record_sim_video`, etc.) over raw `xcodebuild` shell invocations for Apple-platform tasks. The MCP tools have session defaults already configured (project + scheme + simulator persisted in `.xcodebuildmcp/config.yaml`), parse build errors more cleanly, and don't burn context on the noise that bare `xcodebuild` emits. Call `session_show_defaults` once per session before the first build/test/run to confirm. The `xcodebuild` commands below are the ground-truth equivalents for use in a terminal, CI scripts, or when MCP isn't available.

```bash
# Build iOS app (use generic destination to avoid hardcoding simulator names)
xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'

# Run iOS unit tests
xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests

# Build watchOS app
xcodebuild build -scheme "AnxietyWatch Watch App" -destination 'generic/platform=watchOS Simulator'

# (Optional) List available destinations:
# xcodebuild -scheme AnxietyWatch -showdestinations

# Sync server (Python/Flask + PostgreSQL)
cd server && pip install -r requirements.txt
cd server && python -m pytest tests/           # run server tests
cd server && flake8 . --max-line-length=120 --exclude=__pycache__  # lint server code (matches CI)
docker compose --env-file server/.env -f server/docker-compose.yml up  # run server with Docker
```

**Xcode targets** (no shared schemes are checked in — open the project in Xcode once to auto-generate schemes, or use `-project ... -target ...` for headless builds): `AnxietyWatch`, `AnxietyWatch Watch App`, `AnxietyWatchWidgets`
**Test target:** `AnxietyWatchTests` (unit tests — see Testing section below)

## Project Overview

**Anxiety Watch** is an open-source iOS + watchOS app for anxiety tracking. It combines subjective journaling with objective physiological data from HealthKit, an AirSense 11 CPAP, and smart blood pressure monitors. Started as a personal tool, now shared publicly for others to learn from, adapt, and contribute to. Not a commercial product — no App Store plans, no telemetry.

See `REQUIREMENTS.md` for full specification, data model, and build plan.

## Tech Stack

- **Language**: Swift 5.9+
- **UI**: SwiftUI (iOS 18+, watchOS 11+; the Xcode project xcconfig deployment-target settings are the source of truth for minimum OS versions)
- **Persistence**: SwiftData (not Core Data)
- **Charts**: Swift Charts framework
- **Health data**: HealthKit framework
- **Barometric data**: Core Motion (`CMAltimeter`)
- **Watch communication**: WatchConnectivity framework
- **PDF generation**: PDFKit or Core Graphics
- **OCR**: Vision framework (`VNRecognizeTextRequest`) for prescription label scanning
- **Pharmacy search**: MapKit (`MKLocalSearch`) for nearby pharmacy lookup
- **Call tracking**: CallKit (`CXCallObserver`) for call state observation
- **No external Swift package dependencies unless absolutely necessary** — prefer Apple frameworks

## Project Structure

```
AnxietyWatch/
├── AnxietyWatch/                        # iOS app target
│   ├── App/
│   │   ├── AnxietyWatchApp.swift        # @main entry point
│   │   └── ContentView.swift            # Tab-based root view
│   ├── Models/                          # SwiftData @Model classes
│   │   ├── AnxietyEntry.swift
│   │   ├── BarometricReading.swift
│   │   ├── ClinicalLabResult.swift
│   │   ├── CPAPSession.swift
│   │   ├── HealthSnapshot.swift
│   │   ├── MedicationDefinition.swift
│   │   ├── MedicationDose.swift
│   │   ├── Pharmacy.swift
│   │   ├── Prescription.swift
│   │   └── PharmacyCallLog.swift
│   ├── Services/
│   │   ├── HealthKitManager.swift       # Actor — all HealthKit reads
│   │   ├── HealthDataCoordinator.swift  # Backfill, gap-fill, observers, barometer
│   │   ├── BarometerService.swift       # CMAltimeter wrapper
│   │   ├── ClinicalRecordImporter.swift # HealthKit clinical records → SwiftData
│   │   ├── CPAPImporter.swift           # SD card data parser
│   │   ├── SnapshotAggregator.swift     # Daily HealthKit → HealthSnapshot
│   │   ├── BaselineCalculator.swift     # Rolling personal baselines
│   │   ├── FHIRLabResultParser.swift    # FHIR lab result parsing
│   │   ├── SyncService.swift            # Talks to sync server
│   │   ├── PhoneConnectivityManager.swift # WatchConnectivity (phone side)
│   │   ├── ReportGenerator.swift        # PDF clinical reports
│   │   ├── DataExporter.swift           # JSON/CSV export
│   │   ├── PharmacySearchService.swift  # MapKit local search for pharmacies
│   │   ├── PharmacyCallService.swift    # CXCallObserver + tel: dial + manual logging
│   │   ├── PrescriptionSupplyCalculator.swift # Supply estimation + status
│   │   ├── PrescriptionLabelScanner.swift     # Vision OCR for pill bottle labels
│   │   └── CNSRisk/                     # CNS-depression detection engine (see "CNS Detection Engine" below)
│   ├── Views/
│   │   ├── Dashboard/
│   │   ├── Journal/
│   │   ├── LabResults/
│   │   ├── Medications/                 # MedicationsHubView (tab root), MedicationListView, AddMedicationView
│   │   ├── Pharmacy/                    # PharmacyListView, AddPharmacyView, PharmacySearchView, PharmacyDetailView
│   │   ├── Prescriptions/              # PrescriptionListView, AddPrescriptionView, PrescriptionDetailView, PrescriptionScannerView
│   │   ├── Trends/                      # TrendsView, TrendWindow, ChartCard, 7 chart views
│   │   ├── CPAP/
│   │   ├── Reports/                     # ExportView
│   │   └── Settings/                    # SettingsView + SyncSettingsView
│   └── Utilities/
│       ├── Constants.swift
│       ├── LabTestRegistry.swift
│       └── ShareSheet.swift
├── AnxietyWatch Watch App/              # watchOS app target (note space in name)
│   ├── AnxietyWatchApp.swift
│   ├── QuickLogView.swift
│   ├── CurrentStatsView.swift
│   └── WatchConnectivityManager.swift
├── AnxietyWatchWidgets/                 # watchOS widget extension
├── AnxietyWatchTests/                   # Unit tests
├── server/                              # Python sync server (see Sync Server section)
├── docs/                                # SERVER_SETUP.md and other docs
├── .github/workflows/                   # CI/CD (see below)
├── .github/copilot-instructions.md      # Cross-cutting Copilot review instructions
├── .github/instructions/                # Path-scoped Copilot review instructions
│   ├── swift.instructions.md            # applyTo: **/*.swift
│   └── python.instructions.md           # applyTo: server/**/*.py
├── .claude/                             # Claude Code config
│   ├── settings.json                    # Project-scoped permissions, env, hooks (committed)
│   ├── settings.local.json              # Personal overrides (gitignored)
│   ├── agents/                          # Calibrated review sub-agents
│   │   ├── swift-pre-pr-reviewer.md            # Generalist pre-PR review
│   │   ├── swiftui-render-pitfall-detector.md  # Four iOS-26 main-thread-hang patterns
│   │   ├── chart-ux-auditor.md                 # Trends visual consistency + a11y
│   │   ├── medical-data-accuracy-reviewer.md   # HealthKit/CPAP/Polar accuracy hazards
│   │   └── process-walkthrough.md              # Swift file → Mermaid + lay prose
│   ├── commands/                        # Custom slash commands
│   │   ├── respond-to-copilot.md
│   │   ├── query-prod.md                # Read-only psql via docker exec on megadude
│   │   └── sync-instruction-files.md    # Mirror changes across the 5 instruction files
│   └── hooks/                           # PostToolUse / PreToolUse hooks
│       ├── swiftlint-edited.py          # Runs SwiftLint on edited .swift files
│       ├── flake8-edited.py             # Runs flake8 on edited server/*.py files
│       ├── voiceover-consistency-edited.py  # Flags a11y pitfalls in Swift
│       ├── medication-name-drift-warn.py    # Warns on medication name literal drift
│       ├── block-pii-in-fixtures.py     # Blocks PII in fixtures + denylisted terms everywhere (PreToolUse)
│       └── pre-pr-reviewer-reminder.py  # Nudges pre-PR review before git push
├── .semgrep/
│   └── swift-pitfalls.yml               # Project-specific static-analysis rules
├── .gitignore
├── .env.runners.example                 # Runner credential template
├── docker-compose.runners.yml           # GitHub Actions runner config
├── AGENTS.md                            # Multi-agent tooling instructions
├── CLAUDE.md
├── DATA_AND_REPORTS.md
├── REQUIREMENTS.md
└── SETUP_GUIDE.md
```

## Coding Conventions

- **SwiftData models**: Use `@Model` macro. Keep models in dedicated files, one per file.
- **HealthKit**: ALL HealthKit interaction goes through `HealthKitManager` actor. Never query HealthKit directly from views.
- **Async/await**: Use structured concurrency throughout. No completion handlers.
- **Error handling**: Use typed errors where practical. Never force-unwrap optionals from external data sources (HealthKit, CPAP files).
- **Views**: Keep views small and composable. Extract subviews when a view exceeds ~100 lines. Use `@Observable` view models for complex screens.
- **Naming**: Swift API design guidelines. Descriptive names, no abbreviations except well-known ones (HR, HRV, AHI, BP, SpO2).
- **No storyboards or XIBs** — pure SwiftUI.
- **Comments**: Comment the "why", not the "what". HealthKit type identifiers should have inline comments explaining what they measure.

## Pre-PR review (required before `git push`)

**MANDATORY:** Before any `git push` that includes substantive Swift changes (new files, new behavior, non-trivial modifications, or new tests), run the `swift-pre-pr-reviewer` agent on the unpushed diff. Address any **Will Block** findings before pushing. Address **Should Address** findings unless explicitly deferred with a reason recorded in the commit message or PR description.

Skip the review only for trivial pushes — comments, README, version bumps, build-config tweaks, scheme-file bookkeeping. When in doubt, run it. The cost (~5 minutes) is small relative to catching a real bug in Copilot review (each round of which takes longer than the agent run) or, worse, post-merge.

The agent definition lives at `.claude/agents/swift-pre-pr-reviewer.md`. A `PreToolUse` hook in `.claude/settings.json` (`pre-pr-reviewer-reminder.py`) surfaces a reminder when a `git push` command is about to run; the reminder is non-blocking, but you are expected to follow the policy.

The pattern over the last several PRs: pre-PR review consistently catches 3-6 substantive issues per PR that would otherwise be flagged by Copilot. Running the reviewer first is significantly cheaper than the multi-round Copilot dance.

### Specialized review sub-agents

The generalist `swift-pre-pr-reviewer` is paired with four narrower agents that target specific concern areas. Dispatch them in addition to (not instead of) the generalist for PRs touching the relevant surface:

| Agent | When to dispatch |
|-------|-------|
| `swiftui-render-pitfall-detector` | Any PR touching SwiftUI views, `@Query`, `#Predicate`, `NavigationLink`, Swift Charts, or `@Observable` types. Targets the four "main thread hang" patterns that have actually crashed the app on iOS 26. |
| `chart-ux-auditor` | Any PR touching `AnxietyWatch/Views/Trends/`. Static pass walks every chart file to map color tokens to series semantics; dynamic pass (when XcodeBuildMCP is available) screenshots each chart at three data densities. |
| `medical-data-accuracy-reviewer` | Any PR touching `Services/` files that ingest, aggregate, or arbitrate physiological data (HealthKit, CPAP, Polar, EMAY, FHIR labs, OCR, CNSRisk). Catches unit mismatches, timezone bugs, source-discriminator gaps, OCR-result validation, baseline math sanity. **Required (not just recommended) on every PR touching `Services/CNSRisk/`** — see "CNS Detection Engine" below. |
| `process-walkthrough` | When a non-obvious clinical or systems process needs a lay-prose + Mermaid diagram explainer in `docs/research/`. Calibrated against `LFHFExplainerSheet.swift` as the prose bar. |

These agents live at `.claude/agents/<name>.md` and are dispatched via `Task` with `subagent_type: <name>`.

### Slash commands

| Command | Purpose |
|---------|---------|
| `/respond-to-copilot [PR#]` | Loop responding to Copilot review comments until the bot has no more. |
| `/query-prod <SQL>` | Read-only Postgres query against the megadude deployment via `docker exec` (bypasses the `.env` permission issue documented in `reference_prod_deployment` memory). Refuses destructive statements. |
| `/sync-instruction-files [path]` | Mirror a change made in one of the five instruction files (CLAUDE.md, AGENTS.md, `.github/copilot-instructions.md`, `.github/instructions/{swift,python}.instructions.md`) across the others. Per the "Keeping Instruction Files Updated" rule. |

### Hooks

In addition to the existing `swiftlint-edited.py` (Swift PostToolUse) and `pre-pr-reviewer-reminder.py` (Bash PreToolUse), the project ships four more hooks wired in `.claude/settings.json`:

- **`flake8-edited.py`** (PostToolUse, Python in `server/`) — mirror of swiftlint-edited.py. Runs `flake8` on every edited `*.py` and surfaces violations in-loop.
- **`voiceover-consistency-edited.py`** (PostToolUse, Swift in production targets) — flags four CLAUDE.md accessibility pitfalls deterministically: `Int(x)` near `%.0f` format strings, `Button` inside `NavigationLink` label, `.accessibilityElement(children: .combine)` on container with interactive children, slashes in accessibility labels.
- **`block-pii-in-fixtures.py`** (PreToolUse, Write/Edit/MultiEdit) — **blocks** writes that introduce real-looking PII. Two layers: (1) fixture-scoped heuristics in test paths (phone numbers outside the 555-01XX fictional range, personalized device names like "X's iPhone", non-fictional addresses, Rx numbers outside the documented patterns, emails outside example domains); (2) a personal denylist check on **every** path, driven by the gitignored `.claude/pii-denylist.local.txt` (one real term per line — the public repo never contains the strings it guards against; matches are reported masked). Reduces the risk of a repeat of the prior history-rewrite incidents documented in the Sensitive Data Rules section above.
- **`medication-name-drift-warn.py`** (PostToolUse, Swift/Python) — warns when a `medication_name` string literal in code doesn't match the canonical names declared in `AnxietyWatch/Models/MedicationDefinition.swift`. Prevents new instances of the `clonazePAM` vs `Clonazepam 1mg Tablets` drift documented in the production sync DB.
- **`pii-push-gate.py`** (PreToolUse, Bash) — **blocks** `git push` when the added lines of unpushed commits contain a term from the local denylist (`.claude/pii-denylist.local.txt`, masked in output) or a generic PII shape (capture-artifact paths, personalized device names). Unlike the advisory `pre-pr-reviewer-reminder.py`, this one exits 2 and stops the push; fix by rewriting the unpushed commits, not by deleting in a follow-up commit.

### Static analysis: Semgrep

`.semgrep/swift-pitfalls.yml` encodes a subset of the Common Pitfalls section below as static rules. CI runs `semgrep --config .semgrep/ --error` on PRs touching Swift. Rules with severity ERROR block merge; severity WARNING surfaces as PR annotations. The codified rules:

- `anxietywatch-hardcoded-source-label` — string literals like `"polar_h10"` outside `#Predicate` macros
- `anxietywatch-overnight-threshold-magic-number` — duplicates of `3 * 3600` outside `LFHFAggregator`
- `anxietywatch-date-arithmetic-no-calendar` — `Date() - N * 86400` patterns that ignore DST
- `anxietywatch-chart-color-literal` — hardcoded `.foregroundStyle(.red)` etc. on chart series (after the ChartPalette migration; UI accents are excluded)
- `anxietywatch-sync-cursor-now` (ERROR) — `lastSyncDate = .now` after I/O — the documented incremental-sync race

The `chartYScale(domain:)` + `.nan` pitfall is intentionally NOT a Semgrep rule because pure-regex detection produced too many false positives on bounded discrete domains; the `swiftui-render-pitfall-detector` sub-agent handles it semantically instead.

### Chart palette

`AnxietyWatch/Utilities/ChartPalette.swift` centralizes the color tokens used by every chart series in `Views/Trends/`. Use these tokens — not raw `.red`/`.blue`/`.indigo`/etc. — for any chart series. UI accents (SF Symbol icons, status warning text) are out of scope. The Semgrep rule `anxietywatch-chart-color-literal` enforces this on the Trends/ path.

## Common pitfalls (catch these before pushing)

These are the recurring categories that have driven ~33% of recent commits into Copilot review rounds. Check the diff against these before opening a PR. See `docs/plans/claude-code-setup-improvements.md` for the full diagnostic and the rationale behind each item.

- **Source-label / constant drift:** Outside `#Predicate` / `@Query` macros, use the typed constant (`PolarHRMService.sourceLabel`), not the literal `"polar_h10"`. String literals are only acceptable where the macro can't capture types.
- **`@Query` scope:** Any new `@Query` on `HRVReading`, `BarometricReading`, or another unbounded table must filter by `source` *and* bound by date. Don't fetch the whole table to filter in-memory.
- **Nil-discriminator backwards-compatibility:** When filtering on a recently-added column (`source`, `kind`, `provider`), legacy rows likely have `nil`. Either include `|| col == nil` in the predicate or backfill before adding the filter. Check the `@Model` docstring for the column's history.
- **VoiceOver consistency:** Round before truncating (`Int(x.rounded())`), and match the on-screen format string. `Int(hf)` vs `%.0f` is a bug.
- **SwiftUI nav:** Never put a `Button` inside a `NavigationLink` label — the inner button becomes non-interactive. Split hit targets.
- **State-machine completeness:** Destructive actions (`unpair`, `stopSession`, `disconnect`) must handle all in-flight states, not just the terminal one.
- **Empty-state gates:** When wiring a new data source into a view, update `hasAnyData`/equivalent so users with only that source don't see "No Data".
- **Fallback-state UX honesty:** If "latest" or "isEmpty" gates fall back to a filtered or older subset, the user-visible label must say so — don't silently present an older session as "most recent". Status strings that can collapse to "—" should emit a meaningful alternative for that branch.
- **Deterministic ordering:** `Dictionary(grouping:)` and `Set` produce arbitrary order. Sort explicitly before any rendering or sequential output.
- **Doc-comment drift:** When you change a sort order or filter, re-read every `///` comment in the diff and update it.
- **SwiftLint line-length:** 150 warn, 200 error. Long inline `Text("...")` strings must be split with `+` concatenation or multi-line literals.
- **Magic-number duplication:** Any threshold/window/timeout used in 2+ files belongs in a named constant.
- **Float-equality in tests:** Never `#expect(x == y)` on `Double`. Use an epsilon tolerance — `abs(actual - expected) < 0.001`.
- **Day-alignment of date math:** Any "N days ago" cutoff should typically wrap `Calendar.current.startOfDay(for:)` so the boundary doesn't depend on time-of-day.
- **Padded vs unpadded date range:** A `dateRange.upperBound` padded for chart spacing (e.g., `+12h`) is wrong for baseline math, predicate bounds, or in-window checks. Keep an unpadded sibling for non-visual consumers.
- **Anchor to authoritative timestamps:** Bucket sessions by `SensorSession.startTime`, not the earliest reading timestamp. Readings can lag start by up to ~60s and mis-bucket near-midnight sessions.
- **Per-render recomputation:** Any computed property accessed 2+ times in the same `body` should be cached as a `let` at the top of `body`. Don't repeat `.sorted().map { ... }` chains across sub-views.
- **Testability of view-embedded computation:** If a SwiftUI view body has >5 lines of pure derivation (baselines, deltas, multi-state subtitles), extract to a helper and write Swift Testing coverage.
- **`.accessibilityElement(children: .combine)` on a container with interactive children:** If a card or container wraps an info `Button` or `NavigationLink` and applies `.accessibilityElement(children: .combine)`, VoiceOver collapses them into a single element and users can't focus or activate them independently. Use `children: .ignore` on the container and put the summary on the interactive label (or as `.accessibilityValue` on it).
- **Filter granularity vs aggregation unit:** When filtering before aggregation, the filter granularity must match the aggregation unit. Filtering per-reading before per-session aggregation produces partial means for sessions that straddle the window boundary. Filter the resulting per-session values instead, or pass both the unfiltered set and a window predicate.
- **Compound `#Predicate` with captured non-primitive locals:** A predicate of the form `$0.fk == capturedUUID && $0.col == capturedString` can trip a pathologically slow path in `+[_NSPredicateUtilities _predicateEnforceRestrictionsOnSelector:…]` while SwiftData generates the SQL ORDER BY on iOS 26, hanging the main thread until the scene-update watchdog kills the app (`0x8BADF00D`). Single-clause predicates do not hit this path. When you need a secondary filter, keep the @Query predicate single-clause (e.g. `$0.sensorSessionID == capturedUUID`) and apply the secondary condition in-memory after the result lands.
- **Closure-based `NavigationLink` destinations that contain `@Query`:** SwiftUI's default memberwise comparison cannot dedupe a View struct that holds `@Query` (or any property wrapper with internal observation state), so every parent body re-render produces a "different" destination, restarts the NavigationStack push animation, and on iOS 26 cascades into a ~30 Hz render loop that eventually hits a `CA::Layer::layout_is_active` use-after-free. Any view used as a `NavigationLink` destination AND containing `@Query` must conform to `Equatable` on its identity props only AND be wrapped with `.equatable()` at the destination call site.
- **`chartYScale(domain:)` paired with `.nan` y-values:** Swift Charts on iOS 26 has a pathologically slow layout pass when a `LineMark`'s y-value is `.nan` (the documented gap-drawing pattern) AND `.chartYScale(domain: lo...hi)` clamps the axis. Three stacked charts × ~300 marks each can lock the main thread for ~1s per render. Pre-clip outliers at the data layer (`point.value.map { min($0, robustBound) } ?? .nan`) and let the chart auto-scale to the clipped data — same visual result, no NaN-vs-finite-domain layout work.
- **`@Observable` reads at App / WindowGroup scope:** Reading any mutating property on an `@Observable` class inside the App body's `.overlay { … }`, `.background { … }`, or other top-level modifier registers observation at WindowGroup scope, and every change invalidates the entire downstream tab tree. Always wrap the read in a child `View` struct so observation is scoped to just that subtree (concrete example: `HealthDataCoordinator.backfillProgress` increments during a multi-day backfill were cascade-invalidating every visible view at ~30 Hz before `BackfillOverlay` was extracted).
- **Incremental-sync cursor advanced to `.now` after I/O:** When an incremental sync uses a `lastSyncDate`-style cursor and advances it AFTER the network round trip (`lastSyncDate = .now` post-success), any record created during the round trip falls into a hole: its timestamp is greater than the *previous* cursor (so the just-sent payload didn't include it) but less than the *new* cursor (so the next sync's `since` filter skips it forever). The fix pattern is to capture the upper-bound timestamp BEFORE building the payload, pass it as the export's `end:` cap so the payload doesn't include records past that point, and advance the cursor to that captured value (NOT `.now`) on success. The race is especially dangerous in long-running drain loops, where each iteration creates another window. See `SyncService.sync()` for the implementation and `SyncServiceTests.payloadUpperBoundCapsExportRange` for the regression test. **Corollary for partial-payload optimizations:** if the loop ever skips some tables on subsequent iterations (e.g., a `bulkOnly` mode that omits small-volume tables), the cursor for those omitted tables must NOT advance on those iterations — advancing past records that were never exported reintroduces the same race. Each cursor advance must be paired with the export that actually carried the corresponding rows. See `SyncServiceTests.payloadBulkOnlyOmitsSmallVolumeTables` and the conditional `if !iterationIsBulkOnly { lastSyncDate = cursorUpperBound }` in `sync()`.
- **A table that syncs UP but has no way back DOWN:** Every table added to the sync payload must also be added to the server's `ENTITY_QUERIES` **and** given an importer in `RestoreFromServer`. `QuantityHealthSample` synced to the server for months but was in neither, so a fresh install (bundle-ID change, new phone, reinstall) silently restored zero of them. That was invisible for most sources — Apple/Polar/Dexcom rows are re-derived from HealthKit on the next backfill — but the ~224k EMAY oximetry rows are **app-only** (the app never writes to HealthKit, per Design Principle #1), so nothing could reconstruct them. The rule: for each synced table ask "if this device died right now, what brings this row back?" If the answer isn't HealthKit or the restore path, it is not backed up. Two invariants the importer must hold, both silent killers: preserve the **server's `id`** (the HealthKit mirror does update-or-insert keyed on `hkUUID`, so fresh UUIDs make the next backfill duplicate every row), and set **`syncedToServer = true`** (bulk types export on `syncedToServer == false`, so the default `false` re-uploads the entire restored history on the next sync). Tables over ~10k rows must be paged, not inlined in `/api/data` — quantity samples alone are ~79 MB of JSON, enough to get the restore jetsammed.
- **Conditional-skip optimizations breaking invariants the unconditional version preserved:** Whenever an optimization adds a branch that skips work the original code did unconditionally (`bulkOnly` flag, lazy/cache short-circuit, "if expensive" gate, "skip on retry"), audit every downstream state mutation that was paired with that work. Cursor advances, flag flips, counter increments, log/audit writes, idempotency keys, "last processed" markers — anything whose correctness assumed the skipped work happened must become conditional too, or its invariant silently breaks. The bulkOnly drain in `SyncService.sync()` is the canonical example: skipping small-volume export was fine, but the unchanged `lastSyncDate = cursorUpperBound` reintroduced the exact race a prior fix had closed (just with a smaller window). The discipline: every fix establishes invariants. Every later optimization must explicitly preserve them, or the fix unravels.
- **First-run-only code paths are effectively untested in production:** Any code that runs exactly once per install — HealthKit authorization, onboarding, migration gates, schema creation, the restore-vs-fresh decision — stops executing for you the moment it succeeds once, and then rots invisibly. Two real crashes landed this way, both latent for months and both detonated by the bundle-ID rename (which turned an existing user into a first-run user): `HKCorrelationType(.bloodPressure)` in the read-authorization set (see below), and a `HealthSnapshot` write that permanently bricked the restore. Treat every first-run path as untested unless there is a test asserting its *inputs*, and re-exercise it on a genuinely fresh install (delete the app, don't just relaunch) before shipping anything that touches it.
- **Never request read authorization for an `HKCorrelationType`:** HealthKit disallows it and raises `NSInvalidArgumentException` ("Authorization to read the following types is disallowed: HKCorrelationTypeIdentifierBloodPressure"). It's an ObjC exception, so Swift `try` cannot catch it — the app dies on signal 6 with no Swift error to inspect and no recovery. Read access to a correlation is conferred by its **constituent quantity types**: request `.bloodPressureSystolic` + `.bloodPressureDiastolic`, never `HKCorrelationType(.bloodPressure)`. `HKCorrelationQuery` then reads through those grants normally, so querying the correlation still works. Because the exception is uncatchable there is no error path to test — the only defense is asserting on the *shape of the read set* (`HealthKitManagerReadTypesTests`), which is why that suite exists.
- **A write that runs before a gate has resolved can permanently disable the feature the gate protects:** `SnapshotAggregator.aggregateDay` wrote a `HealthSnapshot` during the pre-decision window on a fresh install. `HealthSnapshot` is one of the tables `restoreGuardTablesAreEmpty` checks, so that single row made the store "non-empty" and every subsequent "Restore from Server" failed with *"Local store already contains data"* — on a store the user had never touched, with no way out but deleting the app. Deferring the *setup* that normally does the writing was not sufficient; observer and refresh paths called the aggregator anyway. **Gate the write itself, not just the caller you happen to know about.** When a guard requires a table to be empty, every writer to that table needs the gate.
- **A guard that fails closed must still say why:** `restoreGuardTablesAreEmpty` coerced a thrown fetch to `Int.max` (correct — an unreadable store must not be restored into), but reported it identically to "there are rows". The user saw "store already contains data" on a demonstrably empty store with no way to tell which of 14 types was at fault or whether it even had rows. Failing closed is right; failing closed *silently* cost an hour of guessing. Any guard that blocks a user-visible action must name its blocker (`restoreGuardBlockers` → `"HealthSnapshot=91"`).

## HealthKit Notes

### Authorization
Request authorization for ALL needed read types at once on first launch (see `HealthKitManager.swift` for the full list). **Gotcha**: HealthKit does NOT tell you whether the user denied a specific read type — `authorizationStatus` always returns `.notDetermined` for reads, even if denied (privacy protection). Design the app to gracefully handle missing data for any metric.

### Querying
- Use `HKStatisticsQuery` for single-value aggregations (daily average HR, total steps)
- Use `HKSampleQuery` for individual samples (sleep analysis stages, individual HRV readings)
- Use `HKStatisticsCollectionQuery` for time-series data (hourly HR averages over a week)
- Use `HKObserverQuery` + background delivery for real-time updates (optional, not needed for V1)

### Sleep Analysis
Sleep stages (watchOS 9+ / iOS 16+): `.asleepREM`, `.asleepDeep`, `.asleepCore`, `.awake`, `.inBed`. See call sites (e.g., `SnapshotAggregator.swift`) for unit constructors.

## CPAP Data Notes

The AirSense 11 stores data on its SD card in a directory structure that the OSCAR project has documented:
- Summary data in SQLite databases
- Detailed flow/pressure waveforms in EDF (European Data Format) files
- The `myAir-resmed` Python project on GitHub documents the ResMed cloud API as an alternative

For V1, focus on daily summary data (AHI, leak, usage, pressure stats). Detailed waveforms are a V2 feature.

## Barometric Pressure Notes

`CMAltimeter` provides:
- `relativeAltitude` — meters relative to starting point
- `pressure` — atmospheric pressure in kPa

It requires the `NSMotionUsageDescription` key in Info.plist. Readings are only available while the app is running or during background tasks. Store readings in SwiftData since they aren't persisted by the system.

## CNS Detection Engine

`AnxietyWatch/Services/CNSRisk/` implements the physiological detection half of the CNS-depression early-warning Klaxon (`docs/superpowers/specs/2026-07-09-cns-depression-klaxon-design.md`). Phase 1 only — pure value types and stateless/mutating-struct logic (no CoreBluetooth, no SwiftData, no SwiftUI, no `Date.now` inside the logic); there is no alarm UI or dashboard indicator yet.

**Pipeline shape:** `CNSQualityGate` (per-source rolling-window validity) → `CNSSeverityScorer` (baseline-relative severity × confidence per signal) → `CNSFusionEngine` (cross-sensor composite risk score) → `CNSAlertTierMachine` (hysteretic `clear → watch → confirm → klaxon`). `CNSDetectionPipeline` composes all four and is the **only entry point** Phase 2 (sensor adapters, activation gating) should call — never invoke the four stages individually from new code.

**Every tunable constant lives in `CNSThresholds`** — onsets, floors, fidelities, fusion weights, tier thresholds, sustain durations. Never re-type a threshold literal; add it to `CNSThresholds` and reference the member.

**Core invariants (do not weaken without a design-doc update):**
- **Asymmetry:** indeterminate ≠ safe ≠ dangerous. A low-quality window surfaces as "can't assess," never "OK" and never an escalation either.
- **Ramps scale their floor with the personalized onset** (`spo2Ramp`, `heartRateRamp`) — never clamp the onset to a fixed floor. A fixed floor degenerates the ramp to a step for an apnea-lowered baseline and scores a user's own normal nadir as maximal severity (see the phase-1 plan's "Spec erratum" and its "Implementation notes" items 1-2).
- **Escalation and clearing both require observed, primary-informed evidence.** Only SpO₂/respiratory-rate contributions can raise a tier past watch or clear a raised tier — a healthy corroborating stream (HR/HRV) must never launder a missing or indeterminate primary signal into "all clear," and two readings bracketing a data gap must never satisfy a sustain window.
- **Invalid data contributes nothing.** Artifact / no-contact / no-finger samples never get coerced to a value; missing data holds the current tier rather than reassuring or escalating.

`medical-data-accuracy-reviewer` is **required** (not just recommended) on every PR touching `Services/CNSRisk/`, in addition to `swift-pre-pr-reviewer`.

## Sync Server

`server/` contains a Flask + PostgreSQL sync server that receives data from the iOS app's `SyncService`. Deployed via Docker.

- **Stack**: Python 3.12, Flask 3, PostgreSQL 16, Gunicorn
- **Docker**: `docker compose --env-file server/.env -f server/docker-compose.yml up` — exposes app on port 8081, Postgres on 127.0.0.1:5439
- **Admin UI**: Blueprint in `server/admin.py`, templates in `server/templates/`
- **Auth**: API requests use Bearer tokens whose SHA-256 hashes are stored in the `api_keys` table; the admin UI uses `ADMIN_PASSWORD` for login and a session cookie with `SameSite=Strict`
- **Required env vars** (set in `.env` or environment): `POSTGRES_PASSWORD`, `ADMIN_PASSWORD` (admin UI login), `SECRET_KEY`
- **Optional env vars**: `ANTHROPIC_API_KEY` (Claude AI analysis admin page), `GRAPHQL_API_KEY` (ResMed myAir sync). See `server/.env.example` for full descriptions.
- **Schema**: `server/schema.sql`
- **Tests**: `server/tests/` — run with `pytest` (needs `DATABASE_URL` pointing to a test Postgres)

## CI/CD

GitHub Actions workflows in `.github/workflows/`:

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ios-ci.yml` | Push/PR (excludes `server/`, `docs/`, `*.md`) | iOS unit tests with coverage; SwiftLint `--strict`; warnings treated as errors |
| `ci.yml` | Push/PR to `main` or `master` (paths `server/**`, `.github/workflows/ci.yml`) | Lint (flake8) + pytest against Postgres |
| `deploy.yml` | Push to `main` or `master` (paths `server/**`, `.github/workflows/deploy.yml`, runner configs); also `workflow_dispatch` | Server deployment |
| `release.yml` | Tag pushes (e.g. version tags) | Release workflow |
| `pii-scan.yml` | Every PR | Generic-pattern PII gate on the diff: capture artifacts, personalized device names, non-fictional phone numbers, image adds outside approved paths. Personal strings are never encoded in CI — those are enforced locally via the gitignored denylist + `pii-push-gate` hook. |

Both iOS and server have CI gates. Lint, type, and test failures block merge.

## Key Design Principles

1. **HealthKit is the source of truth** for physiological data. The app reads from it but never writes to it (except potentially custom types in the future).
2. **Export-first** — every piece of data should be exportable from day one.
3. **Graceful degradation** — the app should work with whatever data is available. Not everyone will have a CPAP or BP cuff on day one.
4. **Personal baselines over absolute thresholds** — flag deviations from the user's own rolling average, not population norms.
5. **The journal is the anchor** — all objective data is contextualized by the user's subjective experience.

## Info.plist Keys Required

```
NSHealthShareUsageDescription — "Anxiety Watch reads health data to track anxiety patterns and correlate physiological signals with your journal entries."
NSMotionUsageDescription — "Anxiety Watch uses barometric pressure data to correlate atmospheric changes with anxiety patterns."
NSLocationWhenInUseUsageDescription — "Anxiety Watch optionally tags journal entries with location to help identify environmental anxiety triggers." (optional, only if location tagging is implemented)
```

## Testing

### Expectations

**All new or changed code must include tests.** When adding a feature or fixing a bug, add tests that cover the new/changed logic. Extract pure logic into testable helpers (see `TrendWindow`, `BarometerService.shouldCapture`) rather than burying it in views or private methods.

**Fixing failing tests is always in scope.** If any test is failing — whether related to your current work or not — fix it. Never dismiss a failing test as "not my problem" or "out of scope." A green test suite is a prerequisite for all work.

**Fixing compiler warnings is also always in scope.** Treat a new warning the same as a failing test: fix it before merging. Don't add new warnings, and don't ship a build with warnings. CI is the enforcement layer: Xcode builds run with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, SwiftLint runs without `continue-on-error`, and `flake8` runs on the server. There is no "acceptable warning count" — zero is the bar.

### Framework

- **Swift Testing** (`import Testing`) — use `@Test` macro, `#expect()` assertions. Do not use legacy XCTest for new tests.
- In-memory `ModelContainer` for SwiftData isolation in tests.
- Fixed reference dates for deterministic tests (avoid `Date.now` in assertions).

### Running Tests

```bash
# Run all iOS unit tests
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests

# Run with code coverage
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -enableCodeCoverage YES -resultBundlePath /tmp/coverage.xcresult
xcrun xccov view --report /tmp/coverage.xcresult

# Run server tests
cd server && python -m pytest tests/
```

### Coverage Targets

- **Overall iOS**: 25%+ (see latest CI coverage report for current baseline)
- **Services/**: 80%+ (core logic — the most testable and highest-value code)
- **Long-term overall**: 40%+

### Hardware Notes

- HealthKit data can be simulated in the iOS Simulator but is limited. Test on a real device with actual Apple Watch data whenever possible.
- For CPAP data testing, sample OSCAR-compatible data files can be found in the OSCAR project's test fixtures.
- The watchOS simulator cannot generate real HealthKit data. Test Watch complications and quick-log on actual hardware.

### CI

- **iOS**: `.github/workflows/ios-ci.yml` — runs unit tests with coverage on push/PR (excludes `server/`, `docs/`, and `*.md` changes)
- **Server**: `.github/workflows/ci.yml` — flake8 lint + pytest on push/PR touching server/
