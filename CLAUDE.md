# CLAUDE.md — Project Context for Claude Code

## Git Workflow

**MANDATORY: Never push directly to `main`.** Always create a new feature branch based on `main` unless explicitly instructed otherwise. Use `git checkout -b <branch-name> main` for new work.

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
**Test target:** `AnxietyWatchTests` (unit tests for date filtering, baselines, model normalization)

## Project Overview

**Anxiety Watch** is a personal iOS + watchOS app for anxiety tracking. It combines subjective journaling with objective physiological data from HealthKit, an AirSense 11 CPAP, and smart blood pressure monitors. Single user, never published to App Store.

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
- **No external Swift package dependencies unless absolutely necessary** — prefer Apple frameworks

## Project Structure

```
AnxietyScope/
├── AnxietyScope/                        # iOS app target
│   ├── App/
│   │   ├── AnxietyScopeApp.swift        # @main entry point
│   │   └── ContentView.swift            # Tab-based root view
│   ├── Models/                          # SwiftData @Model classes
│   ├── Services/
│   │   ├── HealthKitManager.swift       # Actor — all HealthKit reads
│   │   ├── BarometerService.swift       # CMAltimeter wrapper
│   │   ├── CPAPImporter.swift           # SD card data parser
│   │   ├── SnapshotAggregator.swift     # Daily HealthKit → HealthSnapshot
│   │   ├── BaselineCalculator.swift     # Rolling personal baselines
│   │   ├── SyncService.swift            # Talks to sync server
│   │   ├── PhoneConnectivityManager.swift # WatchConnectivity (phone side)
│   │   ├── ReportGenerator.swift        # PDF clinical reports
│   │   └── DataExporter.swift           # JSON/CSV export
│   ├── Views/
│   │   ├── Dashboard/
│   │   ├── Journal/
│   │   ├── Medications/
│   │   ├── Trends/                      # 7 chart views + TrendsView + ChartCard
│   │   ├── CPAP/
│   │   ├── Reports/                     # ExportView
│   │   └── Settings/                    # SettingsView + SyncSettingsView
│   └── Utilities/
│       ├── ShareSheet.swift
│       └── Constants.swift
├── AnxietyScopeWatch Watch App/         # watchOS app target (note space in name)
│   ├── AnxietyScopeWatchApp.swift
│   ├── QuickLogView.swift
│   ├── CurrentStatsView.swift
│   └── WatchConnectivityManager.swift
├── AnxietyWatchWidgets/             # watchOS widget extension
├── server/                          # Python sync server (see Sync Server section)
├── .github/workflows/               # CI/CD (see below)
├── REQUIREMENTS.md
├── CLAUDE.md
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
- **Docker**: `docker compose -f server/docker-compose.yml up` — exposes app on port 8081, Postgres on 127.0.0.1:5439
- **Admin UI**: Blueprint in `server/admin.py`, templates in `server/templates/`
- **Auth**: API requests use Bearer tokens whose SHA-256 hashes are stored in the `api_keys` table; the admin UI uses `ADMIN_PASSWORD` for login and a session cookie with `SameSite=Strict`
- **Required env vars** (set in `.env` or environment): `POSTGRES_PASSWORD`, `ADMIN_PASSWORD` (admin UI login), `SECRET_KEY`
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

## Testing Notes

- HealthKit data can be simulated in the iOS Simulator but is limited. Test on a real device with actual Apple Watch data whenever possible.
- For CPAP data testing, sample OSCAR-compatible data files can be found in the OSCAR project's test fixtures.
- The watchOS simulator cannot generate real HealthKit data. Test Watch complications and quick-log on actual hardware.

## Known Gaps

- **No top-level `.gitignore`** — the repo has no root `.gitignore`. One should be added covering Xcode build artifacts, `.DS_Store`, `server/__pycache__`, `server/.env`, etc. Note that `server/.gitignore` already exists for server-specific files.
