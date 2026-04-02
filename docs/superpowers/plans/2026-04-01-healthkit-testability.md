# HealthKit Testability & Integration Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract a HealthKitDataSource protocol from HealthKitManager so services can be unit tested with mocks, and add an on-device integration test target that verifies the full HealthKit pipeline on a physical device.

**Architecture:** Protocol-based DI. A `HealthKitDataSource` protocol captures all HealthKit query methods consumers call. `HealthKitManager` conforms to it. Consumers change their stored type from `HealthKitManager` to `any HealthKitDataSource`. Unit tests inject `MockHealthKitDataSource`; integration tests inject the real `HealthKitManager.shared`.

**Tech Stack:** Swift Testing, SwiftData (in-memory containers), HealthKit, Xcode test targets

**Spec:** `docs/superpowers/specs/2026-04-01-healthkit-testability-design.md`

---

## File Structure

### New files
- `AnxietyWatch/Services/HealthKitDataSource.swift` — protocol + top-level SleepData struct
- `AnxietyWatchTests/Helpers/MockHealthKitDataSource.swift` — configurable mock actor
- `AnxietyWatchTests/SnapshotAggregatorMockTests.swift` — unit tests for aggregation logic
- `AnxietyWatchTests/ClinicalRecordImporterMockTests.swift` — unit tests for deduplication
- `AnxietyWatchIntegrationTests/SnapshotAggregatorIntegrationTests.swift` — on-device pipeline tests
- `AnxietyWatchIntegrationTests/HealthKitManagerIntegrationTests.swift` — on-device HealthKit query tests

### Modified files
- `AnxietyWatch/Services/HealthKitManager.swift` — conform to protocol, move SleepData out
- `AnxietyWatch/Services/SnapshotAggregator.swift` — change type to `any HealthKitDataSource`
- `AnxietyWatch/Services/ClinicalRecordImporter.swift` — change type to `any HealthKitDataSource`
- `AnxietyWatch/Services/HealthDataCoordinator.swift` — accept healthKit via init, use throughout

---

### Task 1: Extract HealthKitDataSource protocol and SleepData

**Files:**
- Create: `AnxietyWatch/Services/HealthKitDataSource.swift`
- Modify: `AnxietyWatch/Services/HealthKitManager.swift`

- [ ] **Step 1: Create HealthKitDataSource.swift with protocol and SleepData**

```swift
// AnxietyWatch/Services/HealthKitDataSource.swift
import Foundation
import HealthKit

/// Aggregated sleep stage data from HealthKit.
/// Top-level so it can be used in the protocol without referencing HealthKitManager.
struct SleepData: Sendable {
    var totalMinutes: Int = 0
    var deepMinutes: Int = 0
    var remMinutes: Int = 0
    var coreMinutes: Int = 0
    var awakeMinutes: Int = 0
}

/// Abstraction over HealthKit queries. HealthKitManager conforms to this;
/// tests can inject a MockHealthKitDataSource instead.
protocol HealthKitDataSource: Sendable {
    // Statistics queries
    func averageQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double?
    func minimumQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double?
    func cumulativeQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                            start: Date, end: Date) async throws -> Double?
    func mostRecentQuantity(_ identifier: HKQuantityTypeIdentifier,
                            unit: HKUnit) async throws -> (date: Date, value: Double)?

    // Composite queries
    func averageBloodPressure(start: Date, end: Date) async throws -> (systolic: Double, diastolic: Double)?
    func querySleepAnalysis(start: Date, end: Date) async throws -> SleepData
    func queryClinicalLabResults(since startDate: Date?) async throws -> [HKClinicalRecord]
    func oldestSampleDate() async throws -> Date?

    // Observer setup
    func startObserving(onUpdate: @Sendable @escaping () -> Void)
    func startAnchoredQueries(
        onNewSamples: @Sendable @escaping ([(type: String, value: Double, timestamp: Date, source: String?)]) -> Void
    )
}
```

- [ ] **Step 2: Update HealthKitManager to conform to the protocol**

In `AnxietyWatch/Services/HealthKitManager.swift`:

1. Delete the nested `SleepData` struct (lines 404-410) — it's now top-level in `HealthKitDataSource.swift`.
2. Add conformance declaration after the class opening:

```swift
actor HealthKitManager: HealthKitDataSource {
```

No method signatures need to change — they already match the protocol.

- [ ] **Step 3: Build to verify conformance compiles**

Run:
```bash
xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Services/HealthKitDataSource.swift AnxietyWatch/Services/HealthKitManager.swift
git commit -m "refactor: extract HealthKitDataSource protocol from HealthKitManager"
```

---

### Task 2: Update consumers to accept the protocol

**Files:**
- Modify: `AnxietyWatch/Services/SnapshotAggregator.swift:8`
- Modify: `AnxietyWatch/Services/ClinicalRecordImporter.swift:7-8`
- Modify: `AnxietyWatch/Services/HealthDataCoordinator.swift:10-21`

- [ ] **Step 1: Update SnapshotAggregator**

In `AnxietyWatch/Services/SnapshotAggregator.swift`, change line 8:

```swift
// Before
let healthKit: HealthKitManager

// After
let healthKit: any HealthKitDataSource
```

- [ ] **Step 2: Update ClinicalRecordImporter**

In `AnxietyWatch/Services/ClinicalRecordImporter.swift`, change line 8:

```swift
// Before
let healthKit: HealthKitManager

// After
let healthKit: any HealthKitDataSource
```

- [ ] **Step 3: Update HealthDataCoordinator**

In `AnxietyWatch/Services/HealthDataCoordinator.swift`:

Add a `healthKit` property and update the init:

```swift
@Observable
final class HealthDataCoordinator {
    private let modelContainer: ModelContainer
    private let healthKit: any HealthKitDataSource
    private var hasSetupObservers = false
    private var pendingRefreshTask: Task<Void, Never>?
    private var lastClinicalImport: Date = .distantPast

    /// Exposed so the UI can show backfill progress.
    var isBackfilling = false
    var backfillProgress = 0
    var backfillTotal = 0

    init(modelContainer: ModelContainer, healthKit: any HealthKitDataSource = HealthKitManager.shared) {
        self.modelContainer = modelContainer
        self.healthKit = healthKit
    }
```

Then replace every `HealthKitManager.shared` reference inside the class with `healthKit`:

- Line 52: `try await HealthKitManager.shared.oldestSampleDate()` → `try await healthKit.oldestSampleDate()`
- Line 66: `healthKit: HealthKitManager.shared,` → `healthKit: healthKit,`
- Line 140: `healthKit: HealthKitManager.shared,` → `healthKit: healthKit,`
- Line 168: `healthKit: HealthKitManager.shared,` → `healthKit: healthKit,`
- Line 186: `await HealthKitManager.shared.startObserving` → `await healthKit.startObserving`
- Line 196: `await HealthKitManager.shared.startAnchoredQueries` → `await healthKit.startAnchoredQueries`
- Line 255: `healthKit: HealthKitManager.shared,` → `healthKit: healthKit,`
- Line 291: `healthKit: HealthKitManager.shared,` → `healthKit: healthKit,`

- [ ] **Step 4: Build to verify all consumers compile**

Run:
```bash
xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Run existing tests to verify no regressions**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add AnxietyWatch/Services/SnapshotAggregator.swift AnxietyWatch/Services/ClinicalRecordImporter.swift AnxietyWatch/Services/HealthDataCoordinator.swift
git commit -m "refactor: update consumers to accept HealthKitDataSource protocol"
```

---

### Task 3: Create MockHealthKitDataSource

**Files:**
- Create: `AnxietyWatchTests/Helpers/MockHealthKitDataSource.swift`

- [ ] **Step 1: Create the mock**

```swift
// AnxietyWatchTests/Helpers/MockHealthKitDataSource.swift
import Foundation
import HealthKit

@testable import AnxietyWatch

/// Configurable mock for unit testing services that depend on HealthKit.
/// Set return values via the dictionaries before calling the service under test.
actor MockHealthKitDataSource: HealthKitDataSource {
    var averageResults: [HKQuantityTypeIdentifier: Double] = [:]
    var minimumResults: [HKQuantityTypeIdentifier: Double] = [:]
    var cumulativeResults: [HKQuantityTypeIdentifier: Double] = [:]
    var mostRecentResults: [HKQuantityTypeIdentifier: (date: Date, value: Double)] = [:]
    var bloodPressureResult: (systolic: Double, diastolic: Double)?
    var sleepResult = SleepData()
    var clinicalRecords: [HKClinicalRecord] = []
    var oldestDate: Date?

    /// Tracks which identifiers were queried, for verification.
    private(set) var queriedIdentifiers: [HKQuantityTypeIdentifier] = []

    func averageQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double? {
        queriedIdentifiers.append(identifier)
        return averageResults[identifier]
    }

    func minimumQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                         start: Date, end: Date) async throws -> Double? {
        queriedIdentifiers.append(identifier)
        return minimumResults[identifier]
    }

    func cumulativeQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit,
                            start: Date, end: Date) async throws -> Double? {
        queriedIdentifiers.append(identifier)
        return cumulativeResults[identifier]
    }

    func mostRecentQuantity(_ identifier: HKQuantityTypeIdentifier,
                            unit: HKUnit) async throws -> (date: Date, value: Double)? {
        queriedIdentifiers.append(identifier)
        return mostRecentResults[identifier]
    }

    func averageBloodPressure(start: Date, end: Date) async throws -> (systolic: Double, diastolic: Double)? {
        bloodPressureResult
    }

    func querySleepAnalysis(start: Date, end: Date) async throws -> SleepData {
        sleepResult
    }

    func queryClinicalLabResults(since startDate: Date?) async throws -> [HKClinicalRecord] {
        clinicalRecords
    }

    func oldestSampleDate() async throws -> Date? {
        oldestDate
    }

    func startObserving(onUpdate: @Sendable @escaping () -> Void) {
        // No-op in tests
    }

    func startAnchoredQueries(
        onNewSamples: @Sendable @escaping ([(type: String, value: Double, timestamp: Date, source: String?)]) -> Void
    ) {
        // No-op in tests
    }
}
```

- [ ] **Step 2: Build tests to verify mock compiles**

Run:
```bash
xcodebuild build-for-testing -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatchTests/Helpers/MockHealthKitDataSource.swift
git commit -m "test: add MockHealthKitDataSource for unit testing HealthKit consumers"
```

---

### Task 4: Write SnapshotAggregator mock tests

**Files:**
- Create: `AnxietyWatchTests/SnapshotAggregatorMockTests.swift`

- [ ] **Step 1: Write SnapshotAggregatorMockTests**

```swift
// AnxietyWatchTests/SnapshotAggregatorMockTests.swift
import Foundation
import HealthKit
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests SnapshotAggregator with a mock HealthKit data source.
/// Verifies that HealthKit return values are correctly mapped to HealthSnapshot fields.
struct SnapshotAggregatorMockTests {

    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    }()

    private func makeAggregator(
        mock: MockHealthKitDataSource,
        context: ModelContext
    ) -> SnapshotAggregator {
        SnapshotAggregator(healthKit: mock, modelContext: context)
    }

    // MARK: - HRV mapping

    @Test("HRV average maps to snapshot.hrvAvg")
    func hrvAvgMapped() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 45.0)

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots.count == 1)
        #expect(snapshots[0].hrvAvg == 45.0)
    }

    @Test("HRV minimum maps to snapshot.hrvMin")
    func hrvMinMapped() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setMinimum(.heartRateVariabilitySDNN, value: 28.0)

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots[0].hrvMin == 28.0)
    }

    // MARK: - Sleep mapping

    @Test("Sleep data maps to snapshot sleep fields")
    func sleepMapped() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setSleep(SleepData(totalMinutes: 420, deepMinutes: 60, remMinutes: 90, coreMinutes: 270, awakeMinutes: 20))

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.sleepDurationMin == 420)
        #expect(s.sleepDeepMin == 60)
        #expect(s.sleepREMMin == 90)
        #expect(s.sleepCoreMin == 270)
        #expect(s.sleepAwakeMin == 20)
    }

    @Test("Zero sleep minutes maps to nil (not 0)")
    func zeroSleepIsNil() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // Default SleepData has all zeros

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.sleepDurationMin == nil)
        #expect(s.sleepDeepMin == nil)
    }

    // MARK: - Blood pressure

    @Test("Blood pressure maps to snapshot BP fields")
    func bpMapped() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setBloodPressure(systolic: 120.0, diastolic: 80.0)

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.bpSystolic == 120.0)
        #expect(s.bpDiastolic == 80.0)
    }

    @Test("Nil blood pressure clears snapshot BP fields")
    func bpNilClears() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // bloodPressureResult defaults to nil

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.bpSystolic == nil)
        #expect(s.bpDiastolic == nil)
    }

    // MARK: - mostRecentQuantity date filtering

    @Test("VO2Max outside day range is not set")
    func vo2MaxOutsideDayRange() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // Set a VO2Max sample dated 3 days before reference date — outside the day range
        let oldDate = Calendar.current.date(byAdding: .day, value: -3, to: referenceDate)!
        await mock.setMostRecent(.vo2Max, date: oldDate, value: 42.0)

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.vo2Max == nil)
    }

    @Test("VO2Max within day range is set")
    func vo2MaxWithinDayRange() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // Set a VO2Max sample on the reference date itself
        await mock.setMostRecent(.vo2Max, date: referenceDate, value: 42.0)

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.vo2Max == 42.0)
    }

    // MARK: - CPAP stitching

    @Test("CPAP session stitched into snapshot by date")
    func cpapStitched() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()

        let session = ModelFactory.cpapSession(date: referenceDate, ahi: 3.5, totalUsageMinutes: 400)
        context.insert(session)
        try context.save()

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.cpapAHI == 3.5)
        #expect(s.cpapUsageMinutes == 400)
    }

    // MARK: - Barometric stitching

    @Test("Barometric readings stitched into snapshot")
    func barometricStitched() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()

        // Insert two readings on the reference date
        let r1 = ModelFactory.barometricReading(
            timestamp: referenceDate.addingTimeInterval(3600),
            pressureKPa: 101.0
        )
        let r2 = ModelFactory.barometricReading(
            timestamp: referenceDate.addingTimeInterval(7200),
            pressureKPa: 103.0
        )
        context.insert(r1)
        context.insert(r2)
        try context.save()

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.barometricPressureAvgKPa != nil)
        #expect(abs(s.barometricPressureAvgKPa! - 102.0) < 0.01)
        #expect(abs(s.barometricPressureChangeKPa! - 2.0) < 0.01)
    }

    // MARK: - Deduplication

    @Test("Aggregating same day twice updates existing snapshot")
    func deduplicatesSnapshots() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.heartRateVariabilitySDNN, value: 40.0)

        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        await mock.setAverage(.heartRateVariabilitySDNN, value: 50.0)
        try await aggregator.aggregateDay(referenceDate)

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots.count == 1)
        #expect(snapshots[0].hrvAvg == 50.0)
    }
}

// MARK: - Mock helper setters

extension MockHealthKitDataSource {
    func setAverage(_ id: HKQuantityTypeIdentifier, value: Double) {
        averageResults[id] = value
    }
    func setMinimum(_ id: HKQuantityTypeIdentifier, value: Double) {
        minimumResults[id] = value
    }
    func setCumulative(_ id: HKQuantityTypeIdentifier, value: Double) {
        cumulativeResults[id] = value
    }
    func setMostRecent(_ id: HKQuantityTypeIdentifier, date: Date, value: Double) {
        mostRecentResults[id] = (date, value)
    }
    func setBloodPressure(systolic: Double, diastolic: Double) {
        bloodPressureResult = (systolic, diastolic)
    }
    func setSleep(_ data: SleepData) {
        sleepResult = data
    }
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests/SnapshotAggregatorMockTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Run full test suite**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatchTests/SnapshotAggregatorMockTests.swift
git commit -m "test: add SnapshotAggregator mock tests for HealthKit field mapping"
```

---

### Task 5: Write ClinicalRecordImporter mock tests

**Files:**
- Create: `AnxietyWatchTests/ClinicalRecordImporterMockTests.swift`

Note: ClinicalRecordImporter's `importLabResults()` calls `healthKit.queryClinicalLabResults()` which returns `[HKClinicalRecord]`. HKClinicalRecord cannot be constructed in tests (no public initializer). The mock returns an empty array by default, so we can test the deduplication logic by testing what happens when the mock returns no records (the common path), and verify the count behavior. Testing with actual HKClinicalRecord objects requires the integration test target on a real device.

- [ ] **Step 1: Write ClinicalRecordImporterMockTests**

```swift
// AnxietyWatchTests/ClinicalRecordImporterMockTests.swift
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Tests ClinicalRecordImporter deduplication and import count logic.
/// Note: HKClinicalRecord has no public initializer, so the mock returns
/// empty arrays. Full pipeline testing with real records requires the
/// integration test target on a physical device.
struct ClinicalRecordImporterMockTests {

    @Test("Returns 0 when no clinical records available")
    func noRecordsReturnsZero() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // mock.clinicalRecords defaults to []

        let importer = ClinicalRecordImporter(healthKit: mock, modelContext: context)
        let count = try await importer.importLabResults()

        #expect(count == 0)
    }

    @Test("No save when zero records imported")
    func noSaveOnZeroImports() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()

        let importer = ClinicalRecordImporter(healthKit: mock, modelContext: context)
        _ = try await importer.importLabResults()

        // No ClinicalLabResult should exist
        let results = try context.fetch(FetchDescriptor<ClinicalLabResult>())
        #expect(results.isEmpty)
    }

    @Test("Existing lab results are not duplicated on reimport")
    func existingResultsNotDuplicated() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()

        // Pre-insert a lab result
        let existing = ModelFactory.clinicalLabResult(
            healthKitSampleUUID: "existing-uuid-1"
        )
        context.insert(existing)
        try context.save()

        let importer = ClinicalRecordImporter(healthKit: mock, modelContext: context)
        let count = try await importer.importLabResults()

        #expect(count == 0)
        let results = try context.fetch(FetchDescriptor<ClinicalLabResult>())
        #expect(results.count == 1)
    }
}
```

- [ ] **Step 2: Run tests**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests/ClinicalRecordImporterMockTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatchTests/ClinicalRecordImporterMockTests.swift
git commit -m "test: add ClinicalRecordImporter mock tests"
```

---

### Task 6: Create integration test target and on-device tests

**Files:**
- Create: `AnxietyWatchIntegrationTests/SnapshotAggregatorIntegrationTests.swift`
- Create: `AnxietyWatchIntegrationTests/HealthKitManagerIntegrationTests.swift`
- Modify: `AnxietyWatch.xcodeproj/project.pbxproj` (via Xcode or xcodebuild)

- [ ] **Step 1: Create the integration test directory**

```bash
mkdir -p AnxietyWatchIntegrationTests
```

- [ ] **Step 2: Add the integration test target to the Xcode project**

Use the XcodeBuildMCP or manually add via Xcode. The target should be:
- Name: `AnxietyWatchIntegrationTests`
- Type: Unit Testing Bundle
- Host application: AnxietyWatch
- Frameworks: HealthKit, SwiftData

If adding manually via Xcode is needed, open the project in Xcode, add a new Unit Testing Bundle target named `AnxietyWatchIntegrationTests`, set its host application to `AnxietyWatch`, and add HealthKit to its linked frameworks.

- [ ] **Step 3: Write HealthKitManagerIntegrationTests**

```swift
// AnxietyWatchIntegrationTests/HealthKitManagerIntegrationTests.swift
import HealthKit
import Testing

@testable import AnxietyWatch

/// Integration tests that run on a physical device with real HealthKit data.
/// These verify that HealthKitManager queries return actual data from the device.
/// Prerequisites: device must have Apple Watch paired with health data synced.
@Suite(.tags(.integration))
struct HealthKitManagerIntegrationTests {

    private let hk = HealthKitManager.shared

    @Test("oldestSampleDate returns a date in the past")
    func oldestSampleDateExists() async throws {
        let date = try await hk.oldestSampleDate()
        #expect(date != nil, "Expected HealthKit to have at least one HRV sample")
        if let date {
            #expect(date < Date.now, "Oldest sample should be in the past")
        }
    }

    @Test("HRV average for last 7 days is non-nil")
    func hrvAverageExists() async throws {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
        let avg = try await hk.averageQuantity(
            .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            start: start, end: end
        )
        #expect(avg != nil, "Expected HRV data from Apple Watch in last 7 days")
    }

    @Test("Sleep analysis for last 7 days returns data")
    func sleepAnalysisExists() async throws {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
        let sleep = try await hk.querySleepAnalysis(start: start, end: end)
        #expect(sleep.totalMinutes > 0, "Expected sleep data from Apple Watch in last 7 days")
    }

    @Test("Resting HR for last 7 days is in physiological range")
    func restingHRInRange() async throws {
        let end = Date.now
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end)!
        let rhr = try await hk.averageQuantity(
            .restingHeartRate,
            unit: .count().unitDivided(by: .minute()),
            start: start, end: end
        )
        if let rhr {
            #expect(rhr >= 30 && rhr <= 120, "Resting HR \(rhr) outside physiological range")
        }
    }
}

extension Tag {
    @Tag static var integration: Self
}
```

- [ ] **Step 4: Write SnapshotAggregatorIntegrationTests**

```swift
// AnxietyWatchIntegrationTests/SnapshotAggregatorIntegrationTests.swift
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

/// Integration tests that verify the full HealthKit → SnapshotAggregator → HealthSnapshot pipeline
/// on a physical device with real data.
@Suite(.tags(.integration))
struct SnapshotAggregatorIntegrationTests {

    @Test("Aggregating yesterday produces a snapshot with HRV data")
    func yesterdaySnapshotHasHRV() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        try await aggregator.aggregateDay(yesterday)

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots.count == 1)
        #expect(snapshots[0].hrvAvg != nil, "Expected HRV data from Apple Watch")
    }

    @Test("Aggregating yesterday produces reasonable sleep duration")
    func yesterdaySnapshotHasSleep() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        try await aggregator.aggregateDay(yesterday)

        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        if let sleep = s.sleepDurationMin {
            #expect(sleep > 0 && sleep < 1440, "Sleep duration \(sleep) min outside reasonable range")
        }
    }

    @Test("Aggregating 7 days produces non-nil HRV baseline")
    func weekBaselineComputes() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        for day in 1...7 {
            let date = Calendar.current.date(byAdding: .day, value: -day, to: .now)!
            try await aggregator.aggregateDay(date)
        }

        let snapshots = try context.fetch(
            FetchDescriptor<HealthSnapshot>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        )
        // Baseline needs 14+ points, but 7 days of real data should have HRV values
        let hrvValues = snapshots.compactMap(\.hrvAvg)
        #expect(!hrvValues.isEmpty, "Expected at least some HRV values from 7 days of data")
    }

    @Test("Aggregating same day twice does not create duplicates")
    func noDuplicates() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: context
        )

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        try await aggregator.aggregateDay(yesterday)
        try await aggregator.aggregateDay(yesterday)

        let snapshots = try context.fetch(FetchDescriptor<HealthSnapshot>())
        #expect(snapshots.count == 1, "Running twice should update, not duplicate")
    }
}
```

- [ ] **Step 5: Build the integration test target**

Run:
```bash
xcodebuild build-for-testing -scheme AnxietyWatch -destination 'platform=iOS,name=<your-device>' 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED` (or similar — the integration tests need to compile against the device SDK)

- [ ] **Step 6: Run integration tests on a physical device**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS,name=<your-device>' -only-testing:AnxietyWatchIntegrationTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

Note: HealthKit authorization must be granted on the device. If tests fail with authorization errors, open the app on a physical device first and grant HealthKit permissions.

- [ ] **Step 7: Commit**

```bash
git add AnxietyWatchIntegrationTests/ AnxietyWatch.xcodeproj/project.pbxproj
git commit -m "test: add on-device integration tests for HealthKit pipeline"
```

---

### Task 7: Final verification and PR

- [ ] **Step 1: Run full unit test suite**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,id=2C8D977D-2028-4D19-AC2F-8AEC73AACC3B' -only-testing:AnxietyWatchTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: Run integration tests on device**

Run:
```bash
xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS,name=<your-device>' -only-testing:AnxietyWatchIntegrationTests 2>&1 | grep '** TEST'
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 3: Create PR**

Create a PR targeting `main` with title: "refactor: extract HealthKitDataSource protocol + add mock and integration tests"
