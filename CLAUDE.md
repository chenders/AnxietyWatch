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
- **Device names:** Use `Test iPhone`, `Test Apple Watch`. Never `Chris's iPhone` or any personalized name.
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
- Add any scratch images to `.gitignore` before they can be accidentally staged.

### The old project name
- The project was renamed from **AnxietyScope** to **AnxietyWatch**. If you encounter any remaining `AnxietyScope` references, fix them.

## Keeping Instruction Files Updated

**MANDATORY:** When making changes that affect project structure, conventions, commands, workflows, coding standards, or rules, you MUST update all relevant instruction files in the same commit. These files must stay in sync:
- **`CLAUDE.md`** — Project context for Claude Code (this file)
- **`AGENTS.md`** — Multi-agent tooling instructions
- **`.github/copilot-instructions.md`** — GitHub Copilot review instructions
- **`REQUIREMENTS.md`** — Full specification and data model

**When editing any instruction file, check the others for the same topic and update them too.** `CLAUDE.md` and `.github/copilot-instructions.md` cover overlapping ground (coding conventions, testing rules, sensitive data rules, design principles). If you change a rule in one, apply the equivalent change to the other. A rule that exists in `CLAUDE.md` but not `copilot-instructions.md` (or vice versa) is a bug.

## Commands

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
- **UI**: SwiftUI (iOS 17+, watchOS 10+)
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
│   │   └── PrescriptionLabelScanner.swift     # Vision OCR for pill bottle labels
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
├── .github/copilot-instructions.md      # Copilot review instructions
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

Three GitHub Actions workflows in `.github/workflows/`:

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | Push/PR to main touching `server/**` | Lint (flake8) + pytest against Postgres |
| `deploy.yml` | Push to `main`/`master` touching `server/**` | Server deployment |
| `release.yml` | Tag pushes (e.g. version tags) | Release workflow |

CI only covers the Python sync server. There is no automated iOS build/test pipeline yet.

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
