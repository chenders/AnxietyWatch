# Copilot Instructions for AnxietyScope

## Project Overview

AnxietyScope is a personal iOS + watchOS anxiety tracking app with a Python sync server. It combines subjective journaling with objective physiological data from HealthKit, an AirSense 11 CPAP machine, and smart blood pressure monitors.

This is a personal project — single user, never published to the App Store.

## Git Workflow

**Never push directly to `main`.** Always create a feature branch from `main`. Use descriptive branch names like `feat/add-export-csv` or `fix/healthkit-auth-crash`.

## Repository Structure

This is a **multi-language monorepo** with two distinct components:

### iOS App and watchOS Targets (Xcode project)
- **Directories:** iOS app sources live under `AnxietyScope/`. watchOS app and widget targets live in top-level directories `AnxietyScopeWatch Watch App/` and `AnxietyScopeWatchWidgets/`. When adding new files, place iOS code under `AnxietyScope/` and watchOS code under the appropriate watch-specific directory.
- **Language:** Swift 5.9+
- **UI:** SwiftUI (target OS versions must match the Xcode project deployment targets)
- **Persistence:** SwiftData (`@Model` macro, not Core Data)
- **Charts:** Swift Charts framework
- **Health data:** HealthKit framework
- **Barometric data:** Core Motion (`CMAltimeter`)
- **Watch communication:** WatchConnectivity framework
- **No external Swift package dependencies** — prefer Apple frameworks

### Sync Server (`server/`)
- **Language:** Python 3.12
- **Framework:** Flask (no ORM — raw SQL with psycopg2)
- **Database:** PostgreSQL 16
- **Deployment:** Docker Compose, GitHub Actions CI/CD to GHCR

## Swift Coding Conventions

- **SwiftData models:** Use `@Model` macro. One model per file in `Models/`.
- **HealthKit:** ALL HealthKit interaction goes through `HealthKitManager` actor. Never query HealthKit directly from views.
- **Concurrency:** Use async/await and structured concurrency throughout. When system APIs only provide callbacks (e.g., CoreMotion, some HealthKit APIs), wrap them using continuations rather than exposing completion handlers in app code.
- **Error handling:** Use typed errors where practical. Never force-unwrap optionals from external data (HealthKit, CPAP files, network responses).
- **Views:** Keep views small and composable. Extract subviews when a view exceeds ~100 lines. Use `@Observable` view models for complex screens.
- **Naming:** Follow Swift API Design Guidelines. Descriptive names, no abbreviations except well-known ones: HR, HRV, AHI, BP, SpO2.
- **No storyboards or XIBs** — pure SwiftUI.
- **Comments:** Comment the "why", not the "what". HealthKit type identifiers should have inline comments explaining what they measure.

## Python Coding Conventions (server/)

- **Line length:** 120 characters max.
- **SQL:** Always parameterize user-supplied values (`%s` placeholders with psycopg2). Never interpolate user input into SQL strings (no f-strings, `%` formatting, or `.format()` with user data). If you need dynamic table or column names, only interpolate identifiers selected from a strict server-side allowlist, never directly from user input.
- **Auth:** API endpoints use Bearer token auth with SHA-256 hashed keys stored in PostgreSQL. Admin pages use session-based auth with `hmac.compare_digest` for password comparison.
- **Upserts:** All sync operations use `INSERT ... ON CONFLICT ... DO UPDATE` for idempotency.
- **Error responses:** Never leak internal error details (stack traces, DB connection strings) to API clients.

## HealthKit Specifics

When writing HealthKit code, be aware:

- HealthKit does NOT tell you whether the user denied a specific read type. `authorizationStatus` returns `.notDetermined` even if denied (Apple privacy protection). Always handle missing data gracefully.
- Use `HKStatisticsQuery` for aggregations, `HKSampleQuery` for individual samples, `HKStatisticsCollectionQuery` for time-series.
- Sleep stages: `.asleepREM`, `.asleepDeep`, `.asleepCore`, `.awake`, `.inBed`
- Units: HRV in ms, HR in bpm, BP in mmHg, SpO2 in %, temperature in celsius, blood glucose in mg/dL.

## Key Design Principles

1. **HealthKit is the source of truth** for physiological data — the app reads, never writes.
2. **Export-first** — every piece of data should be exportable.
3. **Graceful degradation** — the app works with whatever data is available. Not every user has a CPAP or BP cuff.
4. **Personal baselines over absolute thresholds** — flag deviations from the user's rolling average, not population norms.
5. **The journal is the anchor** — all objective data is contextualized by subjective experience.

## Data Flow: iOS App → Server

The iOS app's `SyncService` POSTs JSON to the server's `/api/sync` endpoint. The JSON schema matches `DataExporter`'s output format — camelCase keys with ISO 8601 dates. The server upserts into PostgreSQL using natural keys (timestamp, date, or name). Both full and incremental syncs use the same upsert path.

## What NOT to Do

- Don't add external Swift package dependencies without strong justification.
- Don't use Core Data — this project uses SwiftData exclusively.
- Don't query HealthKit from views — always go through `HealthKitManager`.
- Don't expose completion handlers in app code — use async/await, wrapping callback-based system APIs with continuations.
- Don't use an ORM in the server — raw SQL with psycopg2 is intentional.
- Don't store secrets in code or commit `.env` files.
