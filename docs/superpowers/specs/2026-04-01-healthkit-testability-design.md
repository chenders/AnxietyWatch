# HealthKit Testability & On-Device Integration Testing

**Date:** 2026-04-01
**Status:** Approved

## Problem

HealthKitManager is a concrete actor singleton. Every consumer references `HealthKitManager.shared` directly, making it impossible to substitute fake data in unit tests or verify the full HealthKit pipeline on a real device in a structured way.

Current coverage gaps caused by this coupling:
- SnapshotAggregator: 89% — but HealthKit query → snapshot field mapping is untested
- ClinicalRecordImporter: 7% — deduplication logic buried behind real HealthKit calls
- HealthDataCoordinator: 40% — backfill, buffering, throttling logic untestable
- HealthKitManager: 59% — only exercised indirectly through app usage

## Approach

Protocol-based dependency injection. Extract a `HealthKitDataSource` protocol from HealthKitManager's public API. Consumers accept `any HealthKitDataSource` instead of the concrete type. Unit tests inject a mock; integration tests on a physical device inject the real HealthKitManager.

## Protocol: HealthKitDataSource

```swift
protocol HealthKitDataSource: Sendable {
    // Statistics queries
    func averageQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double?
    func minimumQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double?
    func cumulativeQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                            start: Date, end: Date) async throws -> Double?
    func mostRecentQuantity(_ id: HKQuantityTypeIdentifier,
                            unit: HKUnit) async throws -> (date: Date, value: Double)?

    // Composite queries
    func averageBloodPressure(start: Date, end: Date) async throws -> (systolic: Double, diastolic: Double)?
    func querySleepAnalysis(start: Date, end: Date) async throws -> SleepData
    func queryClinicalLabResults(since startDate: Date?) async throws -> [HKClinicalRecord]
    func oldestSampleDate() async throws -> Date?

    // Observer setup (HealthDataCoordinator only)
    func startObserving(onUpdate: @Sendable @escaping () -> Void) async
    func startAnchoredQueries(
        onNewSamples: @Sendable @escaping ([(type: String, value: Double, timestamp: Date, source: String?)]) -> Void
    ) async
}
```

`SleepData` moves from `HealthKitManager.SleepData` to a top-level struct so the protocol doesn't reference the concrete type.

`HealthKitManager` conforms to `HealthKitDataSource` — all methods already exist with matching signatures.

## Consumer Changes

### SnapshotAggregator
```swift
// Before
let healthKit: HealthKitManager

// After
let healthKit: any HealthKitDataSource
```
No other changes. Already accepts healthKit via init.

### ClinicalRecordImporter
```swift
// Before
let healthKit: HealthKitManager

// After
let healthKit: any HealthKitDataSource
```
No other changes. Already accepts healthKit via init.

### HealthDataCoordinator
```swift
// Before
private let modelContainer: ModelContainer
// Uses HealthKitManager.shared directly in methods

// After
private let modelContainer: ModelContainer
private let healthKit: any HealthKitDataSource

init(modelContainer: ModelContainer, healthKit: any HealthKitDataSource = HealthKitManager.shared) {
    self.modelContainer = modelContainer
    self.healthKit = healthKit
}
```
All internal references to `HealthKitManager.shared` change to `self.healthKit`. Passes `self.healthKit` when constructing SnapshotAggregator and ClinicalRecordImporter.

### Views (no changes)
DashboardViewModel, TrendsView, SettingsView, CPAPListView continue to pass `HealthKitManager.shared` when constructing SnapshotAggregator/ClinicalRecordImporter inline. Views always use the real implementation.

## Test Architecture

### MockHealthKitDataSource (in AnxietyWatchTests/)

A configurable mock that returns preset values:

```swift
actor MockHealthKitDataSource: HealthKitDataSource {
    // Configurable return values per identifier
    var averageResults: [HKQuantityTypeIdentifier: Double] = [:]
    var minimumResults: [HKQuantityTypeIdentifier: Double] = [:]
    var cumulativeResults: [HKQuantityTypeIdentifier: Double] = [:]
    var mostRecentResults: [HKQuantityTypeIdentifier: (date: Date, value: Double)] = [:]
    var bloodPressureResult: (systolic: Double, diastolic: Double)?
    var sleepResult: SleepData = SleepData()
    var clinicalRecords: [HKClinicalRecord] = []
    var oldestDate: Date?

    // Track which methods were called (for verification)
    var queriedIdentifiers: [HKQuantityTypeIdentifier] = []

    func averageQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double? {
        queriedIdentifiers.append(id)
        return averageResults[id]
    }
    // ... etc for each protocol method
}
```

### Unit Tests (AnxietyWatchTests — simulator + CI)

**SnapshotAggregatorTests:**
- Given mock returns HRV 45ms → snapshot.hrvAvg is 45.0
- Given mock returns sleep (deep: 60, REM: 90, core: 270) → snapshot fields match
- Given mock returns nil for BP → snapshot.bpSystolic is nil
- Given mock returns BP (120/80) → snapshot fields match
- Given zero sleep minutes → snapshot.sleepDurationMin is nil (not 0)
- Given mostRecentQuantity date outside the day range → vo2Max/steadiness/afib are not set
- CPAP stitching: given CPAPSession in SwiftData for the same day → snapshot.cpapAHI populated
- Barometric stitching: given BarometricReadings in SwiftData → snapshot.barometricPressureAvgKPa computed

**HealthDataCoordinatorTests:**
- Backfill: given mock with oldestSampleDate 5 days ago → aggregateDay called 5+ times
- Backfill: respects cancellation (Task.isCancelled)
- Clinical import throttling: second call within 3600s is skipped
- Sample buffering: bufferSamples with < maxBufferSize defers flush
- Sample buffering: bufferSamples with >= maxBufferSize flushes immediately
- pruneOldSamples: deletes samples older than 7 days

**ClinicalRecordImporterTests:**
- Deduplication: existing UUID is skipped
- New UUID is inserted
- importedCount matches number of new records
- Zero new records → importedCount returns 0

### Integration Tests (new AnxietyWatchIntegrationTests target — a physical device only)

A separate Xcode test target that:
- Links against HealthKit and the app's model layer
- Uses real `HealthKitManager.shared`
- Only runs when destination is a physical device
- Tagged with `in a dedicated `AnxietyWatchIntegrationTests` target` for filtering

**SnapshotAggregatorIntegrationTests:**
- Aggregate yesterday's data → snapshot has non-nil HRV (device has an Apple Watch paired)
- Aggregate yesterday's data → sleep duration is reasonable (> 0 min, < 1440 min)
- Aggregate yesterday's data → restingHR is in physiological range (30-120 bpm)

**SnapshotAggregatorIntegrationTests (continued):**
- Aggregate 7 days → verify HRV values present
- Aggregate same day twice → verify no duplicate snapshots

**HealthKitManagerIntegrationTests:**
- querySleepAnalysis for last 7 days → returns non-empty SleepData
- averageQuantity for HRV over last 7 days → returns non-nil
- oldestSampleDate → returns a date in the past

## Xcode Target Setup

New target: `AnxietyWatchIntegrationTests`
- Type: Unit Testing Bundle
- Host application: AnxietyWatch
- Destination: physical device only (no simulator)
- Not included in CI (ios-ci.yml only runs AnxietyWatchTests)
- Shares access to app's SwiftData models via @testable import

## Files Created/Modified

### New files
- `AnxietyWatch/Services/HealthKitDataSource.swift` — protocol + SleepData struct
- `AnxietyWatchTests/Helpers/MockHealthKitDataSource.swift` — configurable mock
- `AnxietyWatchTests/SnapshotAggregatorMockTests.swift` — unit tests with mock
- `AnxietyWatchTests/ClinicalRecordImporterMockTests.swift` — unit tests with mock
- `AnxietyWatchIntegrationTests/` — new target directory
- `AnxietyWatchIntegrationTests/SnapshotAggregatorIntegrationTests.swift`
- `AnxietyWatchIntegrationTests/HealthKitManagerIntegrationTests.swift`

### Modified files
- `AnxietyWatch/Services/HealthKitManager.swift` — conform to protocol, move SleepData out
- `AnxietyWatch/Services/SnapshotAggregator.swift` — change type to `any HealthKitDataSource`
- `AnxietyWatch/Services/ClinicalRecordImporter.swift` — change type to `any HealthKitDataSource`
- `AnxietyWatch/Services/HealthDataCoordinator.swift` — accept healthKit via init, use throughout
- `AnxietyWatch.xcodeproj/project.pbxproj` — add integration test target

## Out of Scope

- Mocking BarometerService or PharmacyCallService (different effort, lower value)
- Protocol extraction for WatchConnectivity
- Automated on-device testing in CI (requires self-hosted runner with a tethered device)
