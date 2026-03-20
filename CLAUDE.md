# CLAUDE.md — Project Context for Claude Code

## Git Workflow

**MANDATORY: Never push directly to `main`.** Always create a new feature branch based on `main` unless explicitly instructed otherwise. Use `git checkout -b <branch-name> main` for new work.

## Project Overview

**AnxietyScope** is a personal iOS + watchOS app for anxiety tracking. It combines subjective journaling with objective physiological data from HealthKit, an AirSense 11 CPAP, and smart blood pressure monitors. Single user, never published to App Store.

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
├── AnxietyScope/                    # iOS app target
│   ├── App/
│   │   ├── AnxietyScopeApp.swift    # @main entry point
│   │   └── ContentView.swift        # Tab-based root view
│   ├── Models/                      # SwiftData @Model classes
│   │   ├── AnxietyEntry.swift
│   │   ├── MedicationDose.swift
│   │   ├── MedicationDefinition.swift
│   │   ├── CPAPSession.swift
│   │   ├── BarometricReading.swift
│   │   └── HealthSnapshot.swift
│   ├── Services/
│   │   ├── HealthKitManager.swift   # Actor — all HealthKit reads
│   │   ├── BarometerService.swift   # CMAltimeter wrapper
│   │   ├── CPAPImporter.swift       # SD card data parser
│   │   ├── SnapshotAggregator.swift # Daily HealthKit → HealthSnapshot
│   │   ├── ReportGenerator.swift    # PDF clinical reports
│   │   └── DataExporter.swift       # JSON/CSV export
│   ├── Views/
│   │   ├── Dashboard/
│   │   ├── Journal/
│   │   ├── Medications/
│   │   ├── Trends/
│   │   ├── CPAP/
│   │   ├── Reports/
│   │   └── Settings/
│   └── Utilities/
│       ├── Extensions/
│       └── Constants.swift
├── AnxietyScopeWatch/               # watchOS app target
│   ├── AnxietyScopeWatchApp.swift
│   ├── QuickLogView.swift
│   ├── CurrentStatsView.swift
│   └── ComplicationProvider.swift
├── Shared/                          # Code shared between iOS and watchOS
│   ├── Models/                      # Shared model types
│   └── WatchConnectivityManager.swift
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
Request authorization for ALL needed types at once on first launch. The user will see a single HealthKit permission sheet. Types needed:

**Read types:**
- `HKQuantityTypeIdentifier.heartRateVariabilitySDNN`
- `HKQuantityTypeIdentifier.heartRate`
- `HKQuantityTypeIdentifier.restingHeartRate`
- `HKQuantityTypeIdentifier.respiratoryRate`
- `HKQuantityTypeIdentifier.oxygenSaturation`
- `HKQuantityTypeIdentifier.appleSleepingWristTemperature`
- `HKQuantityTypeIdentifier.stepCount`
- `HKQuantityTypeIdentifier.activeEnergyBurned`
- `HKQuantityTypeIdentifier.appleExerciseTime`
- `HKQuantityTypeIdentifier.environmentalAudioExposure`
- `HKQuantityTypeIdentifier.bloodPressureSystolic`
- `HKQuantityTypeIdentifier.bloodPressureDiastolic`
- `HKQuantityTypeIdentifier.bloodGlucose`
- `HKCategoryTypeIdentifier.sleepAnalysis`

**Important**: HealthKit does NOT tell you whether the user denied a specific type. `authorizationStatus` returns `.notDetermined` OR `.sharingDenied`, but for read permissions it always returns `.notDetermined` even if denied (privacy protection). Design the app to gracefully handle missing data for any metric.

### Querying
- Use `HKStatisticsQuery` for single-value aggregations (daily average HR, total steps)
- Use `HKSampleQuery` for individual samples (sleep analysis stages, individual HRV readings)
- Use `HKStatisticsCollectionQuery` for time-series data (hourly HR averages over a week)
- Use `HKObserverQuery` + background delivery for real-time updates (optional, not needed for V1)

### Sleep Analysis
Sleep stages in watchOS 9+ / iOS 16+:
- `.asleepREM` — REM sleep
- `.asleepDeep` — Deep (slow wave) sleep
- `.asleepCore` — Light (core) sleep
- `.awake` — Awake periods during sleep session
- `.inBed` — Total time in bed

### Units
- HRV: milliseconds (`HKUnit.secondUnit(with: .milli)`)
- Heart rate: bpm (`HKUnit.count().unitDivided(by: .minute())`)
- Blood pressure: mmHg (`HKUnit.millimeterOfMercury()`)
- SpO2: percent (`HKUnit.percent()`)
- Temperature: celsius (`HKUnit.degreeCelsius()`)
- Blood glucose: mg/dL (`HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))`)

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

## Key Design Principles

1. **HealthKit is the source of truth** for physiological data. The app reads from it but never writes to it (except potentially custom types in the future).
2. **Export-first** — every piece of data should be exportable from day one.
3. **Graceful degradation** — the app should work with whatever data is available. Not everyone will have a CPAP or BP cuff on day one.
4. **Personal baselines over absolute thresholds** — flag deviations from the user's own rolling average, not population norms.
5. **The journal is the anchor** — all objective data is contextualized by the user's subjective experience.

## Info.plist Keys Required

```
NSHealthShareUsageDescription — "AnxietyScope reads health data to track anxiety patterns and correlate physiological signals with your journal entries."
NSMotionUsageDescription — "AnxietyScope uses barometric pressure data to correlate atmospheric changes with anxiety patterns."
NSLocationWhenInUseUsageDescription — "AnxietyScope optionally tags journal entries with location to help identify environmental anxiety triggers." (optional, only if location tagging is implemented)
```

## Testing Notes

- HealthKit data can be simulated in the iOS Simulator but is limited. Test on a real device with actual Apple Watch data whenever possible.
- For CPAP data testing, sample OSCAR-compatible data files can be found in the OSCAR project's test fixtures.
- The watchOS simulator cannot generate real HealthKit data. Test Watch complications and quick-log on actual hardware.
