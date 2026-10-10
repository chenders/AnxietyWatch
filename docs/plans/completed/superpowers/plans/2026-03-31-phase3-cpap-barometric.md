# Phase 3: CPAP & Barometric Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire CPAP and barometric data into the HealthSnapshot daily pipeline so they participate in baselines, deviation alerts, and cross-metric correlation. Add duplicate-safe imports, a CPAP detail view, and enhanced dashboard/trend integration.

**Architecture:** Snapshot-first — 4 new optional fields on `HealthSnapshot`. `SnapshotAggregator` stitches `CPAPSession` and `BarometricReading` data into each day's snapshot after HealthKit queries. `CPAPImporter` gains upsert-by-date logic and returns a date range for backfill. `BaselineCalculator` gets AHI and barometric baselines using the same MAD-trimmed rolling window pattern.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, Swift Charts, Swift Testing

**Spec:** `docs/superpowers/specs/2026-03-31-phase3-cpap-barometric-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `AnxietyWatch/Models/HealthSnapshot.swift` | Modify | Add 4 CPAP/barometric fields |
| `AnxietyWatch/Services/CPAPImporter.swift` | Modify | `ImportResult` struct, upsert logic, date range |
| `AnxietyWatch/Services/SnapshotAggregator.swift` | Modify | CPAP + barometric stitching |
| `AnxietyWatch/Services/BaselineCalculator.swift` | Modify | AHI + barometric baselines |
| `AnxietyWatch/Views/Dashboard/DashboardViewModel.swift` | Modify | New baseline state, compute calls |
| `AnxietyWatch/Views/Dashboard/DashboardView.swift` | Modify | CPAP/barometric alerts, tappable cards |
| `AnxietyWatch/Views/Trends/CPAPTrendChart.swift` | Modify | Baseline RuleMark, anxiety overlays |
| `AnxietyWatch/Views/Trends/BarometricTrendChart.swift` | Modify | Baseline RuleMark |
| `AnxietyWatch/Views/Trends/TrendsView.swift` | Modify | Pass `allSnapshots` to CPAP chart |
| `AnxietyWatch/Views/CPAP/CPAPListView.swift` | Modify | NavigationLink rows, summary header, backfill |
| `AnxietyWatch/Views/CPAP/CPAPDetailView.swift` | Create | Session detail + correlation context |
| `AnxietyWatchTests/Helpers/ModelFactory.swift` | Modify | Add CPAP/barometric fields to `healthSnapshot()` |
| `AnxietyWatchTests/CPAPImporterTests.swift` | Modify | Add upsert + dateRange tests |
| `AnxietyWatchTests/BaselineCalculatorCPAPTests.swift` | Create | AHI + barometric baseline tests |

---

### Task 1: Add CPAP/barometric fields to HealthSnapshot

**Files:**
- Modify: `AnxietyWatch/Models/HealthSnapshot.swift`
- Modify: `AnxietyWatchTests/Helpers/ModelFactory.swift`

- [ ] **Step 1: Add 4 new optional properties to HealthSnapshot**

In `AnxietyWatch/Models/HealthSnapshot.swift`, add after the `physicalEffortAvg` property (line 67):

```swift
// CPAP (matched from CPAPSession by date)
var cpapAHI: Double?
var cpapUsageMinutes: Int?

// Barometric (aggregated from BarometricReading by date)
var barometricPressureAvgKPa: Double?
var barometricPressureChangeKPa: Double?
```

- [ ] **Step 2: Update ModelFactory.healthSnapshot to include new fields**

In `AnxietyWatchTests/Helpers/ModelFactory.swift`, add parameters to the `healthSnapshot()` factory method:

```swift
static func healthSnapshot(
    date: Date = referenceDate,
    hrvAvg: Double? = 42.0,
    hrvMin: Double? = nil,
    restingHR: Double? = 62.0,
    sleepDurationMin: Int? = 420,
    sleepDeepMin: Int? = 60,
    sleepREMMin: Int? = 90,
    sleepCoreMin: Int? = 270,
    sleepAwakeMin: Int? = 20,
    steps: Int? = 8500,
    activeCalories: Double? = 350.0,
    exerciseMinutes: Int? = 30,
    spo2Avg: Double? = 97.0,
    respiratoryRate: Double? = 14.0,
    bpSystolic: Double? = nil,
    bpDiastolic: Double? = nil,
    timeInDaylightMin: Int? = nil,
    physicalEffortAvg: Double? = nil,
    cpapAHI: Double? = nil,
    cpapUsageMinutes: Int? = nil,
    barometricPressureAvgKPa: Double? = nil,
    barometricPressureChangeKPa: Double? = nil
) -> HealthSnapshot {
    let snapshot = HealthSnapshot(date: date)
    snapshot.hrvAvg = hrvAvg
    snapshot.hrvMin = hrvMin
    snapshot.restingHR = restingHR
    snapshot.sleepDurationMin = sleepDurationMin
    snapshot.sleepDeepMin = sleepDeepMin
    snapshot.sleepREMMin = sleepREMMin
    snapshot.sleepCoreMin = sleepCoreMin
    snapshot.sleepAwakeMin = sleepAwakeMin
    snapshot.steps = steps
    snapshot.activeCalories = activeCalories
    snapshot.exerciseMinutes = exerciseMinutes
    snapshot.spo2Avg = spo2Avg
    snapshot.respiratoryRate = respiratoryRate
    snapshot.bpSystolic = bpSystolic
    snapshot.bpDiastolic = bpDiastolic
    snapshot.timeInDaylightMin = timeInDaylightMin
    snapshot.physicalEffortAvg = physicalEffortAvg
    snapshot.cpapAHI = cpapAHI
    snapshot.cpapUsageMinutes = cpapUsageMinutes
    snapshot.barometricPressureAvgKPa = barometricPressureAvgKPa
    snapshot.barometricPressureChangeKPa = barometricPressureChangeKPa
    return snapshot
}
```

- [ ] **Step 3: Build to verify model compiles**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Models/HealthSnapshot.swift AnxietyWatchTests/Helpers/ModelFactory.swift
git commit -m "feat: add CPAP and barometric fields to HealthSnapshot"
```

---

### Task 2: CPAPImporter — duplicate detection and ImportResult

**Files:**
- Modify: `AnxietyWatch/Services/CPAPImporter.swift`
- Modify: `AnxietyWatchTests/CPAPImporterTests.swift`

- [ ] **Step 1: Write failing tests for upsert and ImportResult**

Add to `AnxietyWatchTests/CPAPImporterTests.swift`:

```swift
@Test("Re-importing same CSV updates existing sessions instead of duplicating")
func upsertOnDuplicate() throws {
    let csv = """
    date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
    2026-03-20,2.5,420,18.3,6.0,12.0,9.5,3,1,2
    """
    let url = try writeTempCSV(csv)
    defer { try? FileManager.default.removeItem(at: url) }

    let container = try TestHelpers.makeFullContainer()
    let context = ModelContext(container)

    // First import
    let result1 = try CPAPImporter.importCSV(from: url, into: context)
    #expect(result1.inserted == 1)
    #expect(result1.updated == 0)

    // Second import with updated AHI
    let csv2 = """
    date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
    2026-03-20,3.0,420,18.3,6.0,12.0,9.5,3,1,2
    """
    let url2 = try writeTempCSV(csv2)
    defer { try? FileManager.default.removeItem(at: url2) }

    let result2 = try CPAPImporter.importCSV(from: url2, into: context)
    #expect(result2.inserted == 0)
    #expect(result2.updated == 1)

    // Only one session should exist
    let sessions = try context.fetch(FetchDescriptor<CPAPSession>())
    #expect(sessions.count == 1)
    #expect(sessions[0].ahi == 3.0)
}

@Test("ImportResult.dateRange covers all imported dates")
func dateRangeCorrect() throws {
    let csv = """
    date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
    2026-03-18,2.0,400,16.0,6.0,12.0,9.0,2,1,1
    2026-03-20,2.5,420,18.3,6.0,12.0,9.5,3,1,2
    2026-03-22,1.5,450,14.0,6.0,11.0,9.0,1,0,1
    """
    let url = try writeTempCSV(csv)
    defer { try? FileManager.default.removeItem(at: url) }

    let container = try TestHelpers.makeFullContainer()
    let context = ModelContext(container)

    let result = try CPAPImporter.importCSV(from: url, into: context)
    #expect(result.dateRange != nil)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let expectedStart = Calendar.current.startOfDay(for: formatter.date(from: "2026-03-18")!)
    let expectedEnd = Calendar.current.startOfDay(for: formatter.date(from: "2026-03-22")!)
    #expect(result.dateRange!.lowerBound == expectedStart)
    #expect(result.dateRange!.upperBound == expectedEnd)
}

@Test("Mixed insert and update in single import")
func mixedInsertAndUpdate() throws {
    let container = try TestHelpers.makeFullContainer()
    let context = ModelContext(container)

    // Pre-insert one session
    let existing = CPAPSession(
        date: DateFormatter.cpapDate("2026-03-20")!,
        ahi: 2.0, totalUsageMinutes: 400, leakRate95th: 16.0,
        pressureMin: 6.0, pressureMax: 12.0, pressureMean: 9.0,
        obstructiveEvents: 2, centralEvents: 1, hypopneaEvents: 1,
        importSource: "csv"
    )
    context.insert(existing)
    try context.save()

    // Import CSV with existing date + new date
    let csv = """
    date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
    2026-03-20,3.0,420,18.3,6.0,12.0,9.5,3,1,2
    2026-03-21,1.8,390,15.1,6.0,11.5,9.2,2,0,1
    """
    let url = try writeTempCSV(csv)
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try CPAPImporter.importCSV(from: url, into: context)
    #expect(result.inserted == 1)
    #expect(result.updated == 1)

    let sessions = try context.fetch(FetchDescriptor<CPAPSession>(sortBy: [SortDescriptor(\.date)]))
    #expect(sessions.count == 2)
}
```

Note: The `DateFormatter.cpapDate` helper and the change to `ImportResult` return type will cause compile errors. That's expected — the tests should fail.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests/CPAPImporterTests 2>&1 | tail -10`
Expected: Compilation errors (ImportResult doesn't exist yet, importCSV returns Int not ImportResult)

- [ ] **Step 3: Implement ImportResult and upsert logic in CPAPImporter**

Replace the contents of `AnxietyWatch/Services/CPAPImporter.swift` with:

```swift
import Foundation
import SwiftData

/// Parses CPAP session data from CSV files.
/// Auto-detects two formats:
/// - Simple: date,ahi,usage_minutes,leak_95th,p_min,p_max,p_mean,obstructive,central,hypopnea
/// - OSCAR Summary: 42-column export from OSCAR (Open Source CPAP Analysis Reporter)
enum CPAPImporter {

    struct ImportResult {
        let inserted: Int
        let updated: Int
        /// Date range of all processed sessions (for snapshot backfill).
        let dateRange: ClosedRange<Date>?

        var total: Int { inserted + updated }
    }

    enum ImportError: Error, LocalizedError {
        case invalidFormat
        case noData
        case fileAccessDenied

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Unrecognized CSV format. Expected a simple CPAP CSV or an OSCAR Summary export."
            case .noData: return "No valid sessions found in file"
            case .fileAccessDenied: return "Could not access the selected file"
            }
        }
    }

    /// Import CPAP sessions from a CSV file. Upserts by date — existing sessions are updated.
    static func importCSV(from url: URL, into context: ModelContext) throws -> ImportResult {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer { if isSecurityScoped { url.stopAccessingSecurityScopedResource() } }

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count > 1 else { throw ImportError.noData }

        let header = lines[0]
        let dataLines = Array(lines.dropFirst())

        if isOSCARFormat(header) {
            return try importOSCAR(dataLines, into: context)
        } else if isSimpleFormat(header) {
            return try importSimple(dataLines, into: context)
        } else {
            throw ImportError.invalidFormat
        }
    }

    // MARK: - Format Detection

    /// Normalize header for resilient format detection: strip BOM, whitespace, lowercase.
    private static func normalizedHeader(_ header: String) -> String {
        var result = header
        if result.hasPrefix("\u{feff}") { result.removeFirst() }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isOSCARFormat(_ header: String) -> Bool {
        normalizedHeader(header).hasPrefix("date,session count,start,end,total time,ahi")
    }

    private static func isSimpleFormat(_ header: String) -> Bool {
        normalizedHeader(header).hasPrefix("date,ahi,usage_minutes")
    }

    // MARK: - Upsert Helper

    /// Find existing session for the given date, or nil.
    private static func existingSession(for date: Date, in context: ModelContext) -> CPAPSession? {
        let normalized = Calendar.current.startOfDay(for: date)
        let descriptor = FetchDescriptor<CPAPSession>(
            predicate: #Predicate { $0.date == normalized }
        )
        return try? context.fetch(descriptor).first
    }

    /// Update an existing session's fields from parsed data.
    private static func updateSession(
        _ session: CPAPSession,
        ahi: Double, totalUsageMinutes: Int, leakRate95th: Double?,
        pressureMin: Double, pressureMax: Double, pressureMean: Double,
        obstructiveEvents: Int, centralEvents: Int, hypopneaEvents: Int,
        importSource: String
    ) {
        session.ahi = ahi
        session.totalUsageMinutes = totalUsageMinutes
        session.leakRate95th = leakRate95th
        session.pressureMin = pressureMin
        session.pressureMax = pressureMax
        session.pressureMean = pressureMean
        session.obstructiveEvents = obstructiveEvents
        session.centralEvents = centralEvents
        session.hypopneaEvents = hypopneaEvents
        session.importSource = importSource
    }

    // MARK: - Simple Format Parser

    private static func importSimple(_ lines: [String], into context: ModelContext) throws -> ImportResult {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var inserted = 0
        var updated = 0
        var minDate: Date?
        var maxDate: Date?

        for line in lines {
            let fields = line.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 10 else { continue }

            guard let date = dateFormatter.date(from: fields[0]),
                  let ahi = Double(fields[1]),
                  let usage = Int(fields[2]),
                  let leak = Double(fields[3]),
                  let pMin = Double(fields[4]),
                  let pMax = Double(fields[5]),
                  let pMean = Double(fields[6]),
                  let obstructive = Int(fields[7]),
                  let central = Int(fields[8]),
                  let hypopnea = Int(fields[9])
            else { continue }

            let normalized = Calendar.current.startOfDay(for: date)
            if let existing = existingSession(for: normalized, in: context) {
                updateSession(existing, ahi: ahi, totalUsageMinutes: usage, leakRate95th: leak,
                              pressureMin: pMin, pressureMax: pMax, pressureMean: pMean,
                              obstructiveEvents: obstructive, centralEvents: central,
                              hypopneaEvents: hypopnea, importSource: "csv")
                updated += 1
            } else {
                let session = CPAPSession(
                    date: date, ahi: ahi, totalUsageMinutes: usage, leakRate95th: leak,
                    pressureMin: pMin, pressureMax: pMax, pressureMean: pMean,
                    obstructiveEvents: obstructive, centralEvents: central,
                    hypopneaEvents: hypopnea, importSource: "csv"
                )
                context.insert(session)
                inserted += 1
            }

            minDate = minDate.map { min($0, normalized) } ?? normalized
            maxDate = maxDate.map { max($0, normalized) } ?? normalized
        }

        guard inserted + updated > 0 else { throw ImportError.noData }
        try context.save()
        let dateRange = (minDate != nil && maxDate != nil) ? minDate!...maxDate! : nil
        return ImportResult(inserted: inserted, updated: updated, dateRange: dateRange)
    }

    // MARK: - OSCAR Summary Format Parser

    /// OSCAR Summary CSV column indices:
    /// 0: Date, 4: Total Time (HH:MM:SS), 5: AHI
    /// 6: CA Count, 8: OA Count, 9: H Count
    /// 22: Median Pressure, 36: 99.5% Pressure
    private static func importOSCAR(_ lines: [String], into context: ModelContext) throws -> ImportResult {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var inserted = 0
        var updated = 0
        var minDate: Date?
        var maxDate: Date?

        for line in lines {
            let fields = line.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 37 else { continue }

            guard let date = dateFormatter.date(from: fields[0]),
                  let ahi = Double(fields[5]),
                  let centralEvents = Int(fields[6]),
                  let obstructiveEvents = Int(fields[8]),
                  let hypopneaEvents = Int(fields[9]),
                  let medianPressure = Double(fields[22]),
                  let pressure995 = Double(fields[36])
            else { continue }

            let usageMinutes = parseHHMMSS(fields[4])
            guard usageMinutes > 0 else { continue }

            let normalized = Calendar.current.startOfDay(for: date)
            if let existing = existingSession(for: normalized, in: context) {
                updateSession(existing, ahi: ahi, totalUsageMinutes: usageMinutes, leakRate95th: nil,
                              pressureMin: medianPressure, pressureMax: pressure995, pressureMean: medianPressure,
                              obstructiveEvents: obstructiveEvents, centralEvents: centralEvents,
                              hypopneaEvents: hypopneaEvents, importSource: "oscar")
                updated += 1
            } else {
                let session = CPAPSession(
                    date: date, ahi: ahi, totalUsageMinutes: usageMinutes, leakRate95th: nil,
                    pressureMin: medianPressure, pressureMax: pressure995, pressureMean: medianPressure,
                    obstructiveEvents: obstructiveEvents, centralEvents: centralEvents,
                    hypopneaEvents: hypopneaEvents, importSource: "oscar"
                )
                context.insert(session)
                inserted += 1
            }

            minDate = minDate.map { min($0, normalized) } ?? normalized
            maxDate = maxDate.map { max($0, normalized) } ?? normalized
        }

        guard inserted + updated > 0 else { throw ImportError.noData }
        try context.save()
        let dateRange = (minDate != nil && maxDate != nil) ? minDate!...maxDate! : nil
        return ImportResult(inserted: inserted, updated: updated, dateRange: dateRange)
    }

    /// Parse "HH:MM:SS" to total minutes (truncating seconds).
    private static func parseHHMMSS(_ str: String) -> Int {
        let parts = str.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 60 + parts[1]
    }
}
```

- [ ] **Step 4: Fix existing tests that use the old Int return type**

The existing tests call `let count = try CPAPImporter.importCSV(...)` expecting an `Int`. Update them to use `ImportResult`:

In `CPAPImporterTests.swift`, change all instances of:
```swift
let count = try CPAPImporter.importCSV(from: url, into: context)
#expect(count == N)
```
to:
```swift
let result = try CPAPImporter.importCSV(from: url, into: context)
#expect(result.inserted == N)
```

Also update `CPAPListView.swift` line 64 — change:
```swift
let count = try CPAPImporter.importCSV(from: url, into: modelContext)
alertMessage = "Imported \(count) session\(count == 1 ? "" : "s")."
```
to:
```swift
let result = try CPAPImporter.importCSV(from: url, into: modelContext)
if result.updated > 0 {
    alertMessage = "Imported \(result.total) session\(result.total == 1 ? "" : "s") (\(result.updated) updated)."
} else {
    alertMessage = "Imported \(result.inserted) session\(result.inserted == 1 ? "" : "s")."
}
```

Also add the `DateFormatter.cpapDate` helper used in the new test. Add it as a private extension at the bottom of `CPAPImporterTests.swift`:
```swift
private extension DateFormatter {
    static func cpapDate(_ string: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: string)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests/CPAPImporterTests 2>&1 | grep -E '(Test Case|passed|failed|error:)'`
Expected: All tests pass including the 3 new upsert/dateRange tests.

- [ ] **Step 6: Commit**

```bash
git add AnxietyWatch/Services/CPAPImporter.swift AnxietyWatchTests/CPAPImporterTests.swift AnxietyWatch/Views/CPAP/CPAPListView.swift
git commit -m "feat: add duplicate detection and ImportResult to CPAPImporter"
```

---

### Task 3: SnapshotAggregator — CPAP and barometric stitching

**Files:**
- Modify: `AnxietyWatch/Services/SnapshotAggregator.swift`

- [ ] **Step 1: Add CPAP stitching after HealthKit queries**

At the end of `SnapshotAggregator.aggregateDay(_:)`, after `snapshot.physicalEffortAvg = ...` and before `try modelContext.save()`, add:

```swift
// Stitch CPAP data from CPAPSession (matched by date)
let cpapDescriptor = FetchDescriptor<CPAPSession>(
    predicate: #Predicate { $0.date == start }
)
if let cpapSession = try modelContext.fetch(cpapDescriptor).first {
    snapshot.cpapAHI = cpapSession.ahi
    snapshot.cpapUsageMinutes = cpapSession.totalUsageMinutes
} else {
    snapshot.cpapAHI = nil
    snapshot.cpapUsageMinutes = nil
}

// Stitch barometric data (average and change for the day)
let barometricDescriptor = FetchDescriptor<BarometricReading>(
    predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end }
)
let barometricReadings = try modelContext.fetch(barometricDescriptor)
if !barometricReadings.isEmpty {
    let pressures = barometricReadings.map(\.pressureKPa)
    snapshot.barometricPressureAvgKPa = pressures.reduce(0, +) / Double(pressures.count)
    if let minP = pressures.min(), let maxP = pressures.max() {
        snapshot.barometricPressureChangeKPa = maxP - minP
    }
} else {
    snapshot.barometricPressureAvgKPa = nil
    snapshot.barometricPressureChangeKPa = nil
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Services/SnapshotAggregator.swift
git commit -m "feat: stitch CPAP and barometric data into daily HealthSnapshot"
```

---

### Task 4: BaselineCalculator — AHI and barometric baselines

**Files:**
- Modify: `AnxietyWatch/Services/BaselineCalculator.swift`
- Create: `AnxietyWatchTests/BaselineCalculatorCPAPTests.swift`

- [ ] **Step 1: Write failing tests for new baselines**

Create `AnxietyWatchTests/BaselineCalculatorCPAPTests.swift`:

```swift
import Foundation
import Testing

@testable import AnxietyWatch

struct BaselineCalculatorCPAPTests {

    private let referenceDate = Date.now

    private func makeSnapshotWithAHI(daysAgo: Int, ahi: Double?) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: referenceDate)!
        let snapshot = HealthSnapshot(date: date)
        snapshot.cpapAHI = ahi
        return snapshot
    }

    private func makeSnapshotWithPressure(daysAgo: Int, pressure: Double?) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: referenceDate)!
        let snapshot = HealthSnapshot(date: date)
        snapshot.barometricPressureAvgKPa = pressure
        return snapshot
    }

    // MARK: - AHI Baseline

    @Test("AHI baseline requires 14+ data points")
    func ahiBaselineRequiresMinimum() {
        let snapshots = (0..<13).map { makeSnapshotWithAHI(daysAgo: $0, ahi: 2.5) }
        #expect(BaselineCalculator.cpapAHIBaseline(from: snapshots) == nil)
    }

    @Test("AHI baseline computed with enough data")
    func ahiBaselineComputed() {
        let snapshots = (0..<14).map { makeSnapshotWithAHI(daysAgo: $0, ahi: 2.5) }
        let result = BaselineCalculator.cpapAHIBaseline(from: snapshots)
        #expect(result != nil)
        #expect(abs(result!.mean - 2.5) < 0.01)
    }

    @Test("AHI baseline excludes snapshots outside window")
    func ahiBaselineWindowFilter() {
        var snapshots = [makeSnapshotWithAHI(daysAgo: 31, ahi: 20.0)] // outside
        snapshots += (0..<14).map { makeSnapshotWithAHI(daysAgo: $0, ahi: 3.0) }
        let result = BaselineCalculator.cpapAHIBaseline(from: snapshots, windowDays: 30)
        #expect(result != nil)
        #expect(abs(result!.mean - 3.0) < 0.01)
    }

    @Test("AHI baseline ignores nil cpapAHI snapshots")
    func ahiBaselineIgnoresNil() {
        var snapshots = (0..<14).map { makeSnapshotWithAHI(daysAgo: $0, ahi: 2.5) }
        snapshots.append(makeSnapshotWithAHI(daysAgo: 14, ahi: nil))
        let result = BaselineCalculator.cpapAHIBaseline(from: snapshots)
        #expect(result != nil)
        #expect(abs(result!.mean - 2.5) < 0.01)
    }

    @Test("AHI outlier trimming handles mask-off night")
    func ahiOutlierTrimming() {
        // 14 normal nights at AHI 2.5, plus one mask-off night at AHI 40
        var snapshots = (0..<14).map { makeSnapshotWithAHI(daysAgo: $0, ahi: 2.5) }
        snapshots.append(makeSnapshotWithAHI(daysAgo: 14, ahi: 40.0))
        let result = BaselineCalculator.cpapAHIBaseline(from: snapshots)
        #expect(result != nil)
        // Mean should be close to 2.5, not pulled toward 40
        #expect(result!.mean < 5.0)
    }

    // MARK: - Barometric Pressure Baseline

    @Test("Barometric baseline requires 14+ data points")
    func barometricBaselineRequiresMinimum() {
        let snapshots = (0..<13).map { makeSnapshotWithPressure(daysAgo: $0, pressure: 101.3) }
        #expect(BaselineCalculator.barometricPressureBaseline(from: snapshots) == nil)
    }

    @Test("Barometric baseline computed with enough data")
    func barometricBaselineComputed() {
        let snapshots = (0..<14).map { makeSnapshotWithPressure(daysAgo: $0, pressure: 101.3) }
        let result = BaselineCalculator.barometricPressureBaseline(from: snapshots)
        #expect(result != nil)
        #expect(abs(result!.mean - 101.3) < 0.01)
    }

    @Test("Barometric baseline excludes snapshots outside window")
    func barometricBaselineWindowFilter() {
        var snapshots = [makeSnapshotWithPressure(daysAgo: 31, pressure: 95.0)] // outside
        snapshots += (0..<14).map { makeSnapshotWithPressure(daysAgo: $0, pressure: 101.3) }
        let result = BaselineCalculator.barometricPressureBaseline(from: snapshots, windowDays: 30)
        #expect(result != nil)
        #expect(abs(result!.mean - 101.3) < 0.01)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests/BaselineCalculatorCPAPTests 2>&1 | tail -10`
Expected: Compilation errors (methods don't exist yet)

- [ ] **Step 3: Implement the two new baseline methods**

Add to `AnxietyWatch/Services/BaselineCalculator.swift`, after `respiratoryRateBaseline`:

```swift
/// Compute CPAP AHI baseline.
static func cpapAHIBaseline(
    from snapshots: [HealthSnapshot],
    windowDays: Int = Constants.baselineWindowDays
) -> BaselineResult? {
    let daysAgo = Calendar.current.date(byAdding: .day, value: -windowDays, to: .now)!
    let cutoff = Calendar.current.startOfDay(for: daysAgo)
    let values = snapshots
        .filter { $0.date >= cutoff }
        .compactMap(\.cpapAHI)

    return baseline(from: values)
}

/// Compute barometric pressure baseline.
static func barometricPressureBaseline(
    from snapshots: [HealthSnapshot],
    windowDays: Int = Constants.baselineWindowDays
) -> BaselineResult? {
    let daysAgo = Calendar.current.date(byAdding: .day, value: -windowDays, to: .now)!
    let cutoff = Calendar.current.startOfDay(for: daysAgo)
    let values = snapshots
        .filter { $0.date >= cutoff }
        .compactMap(\.barometricPressureAvgKPa)

    return baseline(from: values)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests/BaselineCalculatorCPAPTests 2>&1 | grep -E '(Test Case|passed|failed)'`
Expected: All 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/BaselineCalculator.swift AnxietyWatchTests/BaselineCalculatorCPAPTests.swift
git commit -m "feat: add CPAP AHI and barometric pressure baselines"
```

---

### Task 5: Dashboard — baseline alerts for CPAP and barometric

**Files:**
- Modify: `AnxietyWatch/Views/Dashboard/DashboardViewModel.swift`
- Modify: `AnxietyWatch/Views/Dashboard/DashboardView.swift`

- [ ] **Step 1: Add baseline state to DashboardViewModel**

In `DashboardViewModel.swift`, add two new properties after `respiratoryBaseline` (line 19):

```swift
private(set) var cpapAHIBaseline: BaselineCalculator.BaselineResult?
private(set) var barometricBaseline: BaselineCalculator.BaselineResult?
```

In `computeBaselines(from:)`, add after the `respiratoryBaseline` line:

```swift
cpapAHIBaseline = BaselineCalculator.cpapAHIBaseline(from: snapshots)
barometricBaseline = BaselineCalculator.barometricPressureBaseline(from: snapshots)
```

- [ ] **Step 2: Add CPAP and barometric alerts to DashboardView**

In `DashboardView.swift`, in the `baselineAlert` computed property, add after the respiratory rate alert block (before the closing brace):

```swift
if let baseline = vm.cpapAHIBaseline,
   let recentAHI = BaselineCalculator.recentAverage(from: recentSnapshots, days: 3, keyPath: \.cpapAHI),
   recentAHI > baseline.upperBound, baseline.mean > 0 {
    let pct = Int(((recentAHI - baseline.mean) / baseline.mean) * 100)
    baselineAlertCard(
        icon: "lungs.fill",
        title: "CPAP AHI Elevated",
        message: "Your 3-night AHI average is \(pct)% above your 30-day baseline",
        color: .purple
    )
}
if let baseline = vm.barometricBaseline,
   let todayPressure = recentSnapshots.first?.barometricPressureAvgKPa,
   todayPressure < baseline.lowerBound {
    baselineAlertCard(
        icon: "barometer",
        title: "Low Barometric Pressure",
        message: "Pressure is significantly below your 30-day average",
        color: .gray
    )
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Views/Dashboard/DashboardViewModel.swift AnxietyWatch/Views/Dashboard/DashboardView.swift
git commit -m "feat: add CPAP AHI and barometric baseline alerts to dashboard"
```

---

### Task 6: Enhanced CPAP dashboard card + barometric card

**Files:**
- Modify: `AnxietyWatch/Views/Dashboard/DashboardView.swift`

- [ ] **Step 1: Enhance the CPAP dashboard card with baseline deviation**

Replace the `cpapSection` computed property in `DashboardView.swift`:

```swift
@ViewBuilder
private var cpapSection: some View {
    if let lastSession = recentCPAP.first {
        let deviationText: String? = {
            guard let baseline = vm.cpapAHIBaseline else { return nil }
            let diff = lastSession.ahi - baseline.mean
            let direction = diff >= 0 ? "above" : "below"
            return String(format: "%.1f %@ average", abs(diff), direction)
        }()

        NavigationLink(value: lastSession.id) {
            MetricCard(
                title: "Last CPAP",
                value: String(format: "AHI %.1f", lastSession.ahi),
                subtitle: [
                    String(format: "%dh %dm — %@",
                        lastSession.totalUsageMinutes / 60,
                        lastSession.totalUsageMinutes % 60,
                        lastSession.date.formatted(.dateTime.month().day())),
                    deviationText
                ].compactMap { $0 }.joined(separator: " · "),
                color: lastSession.ahi < 5 ? .green : lastSession.ahi < 15 ? .yellow : .orange
            )
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Enhance the barometric dashboard card with daily change**

Replace the `barometricSection` computed property:

```swift
@ViewBuilder
private var barometricSection: some View {
    if let pressure = barometer.currentPressureKPa {
        let changeText: String? = {
            guard let todaySnapshot = vm.todaySnapshot(from: recentSnapshots),
                  let change = todaySnapshot.barometricPressureChangeKPa,
                  change > 0.01 else { return nil }
            return String(format: "%.1f kPa range today", change)
        }()

        MetricCard(
            title: "Barometric Pressure",
            value: String(format: "%.1f kPa", pressure),
            subtitle: changeText ?? "Current",
            color: .gray
        )
    }
}
```

- [ ] **Step 3: Add NavigationDestination for CPAP detail**

In the `NavigationStack` body of `DashboardView`, add a `.navigationDestination` modifier. Find the `.navigationTitle("Dashboard")` line and add before it:

```swift
.navigationDestination(for: UUID.self) { sessionID in
    if let session = recentCPAP.first(where: { $0.id == sessionID }) {
        CPAPDetailView(session: session, snapshots: recentSnapshots, entries: recentEntries)
    }
}
```

This will show a compiler error until Task 7 creates `CPAPDetailView`. That's fine — we'll build after Task 7.

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Views/Dashboard/DashboardView.swift
git commit -m "feat: enhance CPAP and barometric dashboard cards"
```

---

### Task 7: CPAPDetailView

**Files:**
- Create: `AnxietyWatch/Views/CPAP/CPAPDetailView.swift`

- [ ] **Step 1: Create CPAPDetailView**

Create `AnxietyWatch/Views/CPAP/CPAPDetailView.swift`:

```swift
import SwiftUI

struct CPAPDetailView: View {
    let session: CPAPSession
    let snapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]

    private var daySnapshot: HealthSnapshot? {
        let sessionDate = Calendar.current.startOfDay(for: session.date)
        return snapshots.first { $0.date == sessionDate }
    }

    private var dayEntries: [AnxietyEntry] {
        let start = Calendar.current.startOfDay(for: session.date)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        return entries.filter { $0.timestamp >= start && $0.timestamp < end }
    }

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Date", value: session.date.formatted(.dateTime.weekday(.wide).month().day().year()))
                LabeledContent("Source", value: session.importSource)
            }

            Section("Key Metrics") {
                HStack {
                    Text("AHI")
                    Spacer()
                    Text(String(format: "%.1f events/hr", session.ahi))
                        .foregroundStyle(ahiColor)
                        .fontWeight(.semibold)
                }
                LabeledContent("Usage", value: usageString)
                if let leak = session.leakRate95th {
                    LabeledContent("Leak (95th %ile)", value: String(format: "%.1f L/min", leak))
                }
            }

            Section("Events") {
                LabeledContent("Obstructive", value: "\(session.obstructiveEvents)")
                LabeledContent("Central", value: "\(session.centralEvents)")
                LabeledContent("Hypopnea", value: "\(session.hypopneaEvents)")
            }

            Section("Pressure (cmH\u{2082}O)") {
                LabeledContent("Min", value: String(format: "%.1f", session.pressureMin))
                LabeledContent("Mean", value: String(format: "%.1f", session.pressureMean))
                LabeledContent("Max", value: String(format: "%.1f", session.pressureMax))
            }

            if daySnapshot != nil || !dayEntries.isEmpty {
                Section("That Day's Context") {
                    if let snap = daySnapshot {
                        if let hrv = snap.hrvAvg {
                            LabeledContent("HRV", value: String(format: "%.0f ms", hrv))
                        }
                        if let rhr = snap.restingHR {
                            LabeledContent("Resting HR", value: String(format: "%.0f bpm", rhr))
                        }
                        if let sleep = snap.sleepDurationMin {
                            LabeledContent("Sleep", value: "\(sleep / 60)h \(sleep % 60)m")
                        }
                    }
                    ForEach(dayEntries) { entry in
                        LabeledContent(
                            "Anxiety @ \(entry.timestamp.formatted(.dateTime.hour().minute()))",
                            value: "\(entry.severity)/10"
                        )
                    }
                }
            }
        }
        .navigationTitle("CPAP Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var usageString: String {
        let h = session.totalUsageMinutes / 60
        let m = session.totalUsageMinutes % 60
        return "\(h)h \(m)m"
    }

    private var ahiColor: Color {
        switch session.ahi {
        case ..<5: return .green
        case 5..<15: return .yellow
        case 15..<30: return .orange
        default: return .red
        }
    }
}
```

- [ ] **Step 2: Build to verify everything compiles (including Task 6 navigation)**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Views/CPAP/CPAPDetailView.swift
git commit -m "feat: add CPAPDetailView with cross-metric context panel"
```

---

### Task 8: CPAPListView — NavigationLink rows, summary header, backfill

**Files:**
- Modify: `AnxietyWatch/Views/CPAP/CPAPListView.swift`

- [ ] **Step 1: Update CPAPListView with NavigationLink rows, summary, and backfill**

Replace the contents of `AnxietyWatch/Views/CPAP/CPAPListView.swift`:

```swift
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct CPAPListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CPAPSession.date, order: .reverse) private var sessions: [CPAPSession]
    @Query(sort: \HealthSnapshot.date, order: .reverse) private var snapshots: [HealthSnapshot]
    @Query(sort: \AnxietyEntry.timestamp, order: .reverse) private var entries: [AnxietyEntry]
    @State private var showingAddSession = false
    @State private var showingImporter = false
    @State private var alertMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    showingAddSession = true
                } label: {
                    Label("Add Manual Entry", systemImage: "plus.circle")
                }
                Button {
                    showingImporter = true
                } label: {
                    Label("Import CSV File", systemImage: "doc.badge.plus")
                }
            }

            if sessions.isEmpty {
                Section {
                    Text("No CPAP sessions recorded yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                summarySection

                Section("Sessions (\(sessions.count))") {
                    ForEach(sessions) { session in
                        NavigationLink {
                            CPAPDetailView(session: session, snapshots: snapshots, entries: entries)
                        } label: {
                            CPAPSessionRow(session: session)
                        }
                    }
                    .onDelete(perform: deleteSessions)
                }
            }
        }
        .navigationTitle("CPAP Data")
        .sheet(isPresented: $showingAddSession) {
            AddCPAPSessionView()
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Import", isPresented: .constant(alertMessage != nil)) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        let last7 = sessions.prefix(while: {
            $0.date >= Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        })
        let last30 = sessions.prefix(while: {
            $0.date >= Calendar.current.date(byAdding: .day, value: -30, to: .now)!
        })

        Section("Summary") {
            if !last7.isEmpty {
                let avg7 = last7.map(\.ahi).reduce(0, +) / Double(last7.count)
                LabeledContent("7-day avg AHI", value: String(format: "%.1f", avg7))
            }
            if !last30.isEmpty {
                let avg30 = last30.map(\.ahi).reduce(0, +) / Double(last30.count)
                LabeledContent("30-day avg AHI", value: String(format: "%.1f", avg30))
            }
            LabeledContent("Total sessions", value: "\(sessions.count)")
        }
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let result = try CPAPImporter.importCSV(from: url, into: modelContext)
                if result.updated > 0 {
                    alertMessage = "Imported \(result.total) session\(result.total == 1 ? "" : "s") (\(result.updated) updated)."
                } else {
                    alertMessage = "Imported \(result.inserted) session\(result.inserted == 1 ? "" : "s")."
                }
                // Backfill snapshots for imported date range
                if let dateRange = result.dateRange {
                    Task {
                        await backfillSnapshots(dateRange: dateRange)
                    }
                }
            } catch {
                alertMessage = error.localizedDescription
            }
        case .failure(let error):
            alertMessage = error.localizedDescription
        }
    }

    private func backfillSnapshots(dateRange: ClosedRange<Date>) async {
        let aggregator = SnapshotAggregator(
            healthKit: HealthKitManager.shared,
            modelContext: modelContext
        )
        var date = dateRange.lowerBound
        while date <= dateRange.upperBound {
            try? await aggregator.aggregateDay(date)
            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? dateRange.upperBound.addingTimeInterval(1)
        }
    }

    private func deleteSessions(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
    }
}

// MARK: - Row

struct CPAPSessionRow: View {
    let session: CPAPSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.date, format: .dateTime.month().day().year())
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "AHI %.1f", session.ahi))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(ahiColor)
            }
            HStack(spacing: 12) {
                Label(usageString, systemImage: "clock")
                if let leak = session.leakRate95th {
                    Label(String(format: "%.1f L/min leak", leak), systemImage: "wind")
                }
                Label(session.importSource, systemImage: "arrow.down.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var usageString: String {
        let h = session.totalUsageMinutes / 60
        let m = session.totalUsageMinutes % 60
        return "\(h)h \(m)m"
    }

    /// AHI clinical severity: <5 normal, 5-15 mild, 15-30 moderate, >30 severe
    private var ahiColor: Color {
        switch session.ahi {
        case ..<5: return .green
        case 5..<15: return .yellow
        case 15..<30: return .orange
        default: return .red
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Views/CPAP/CPAPListView.swift
git commit -m "feat: add navigation, summary, and backfill to CPAPListView"
```

---

### Task 9: CPAPTrendChart — baseline and anxiety overlays

**Files:**
- Modify: `AnxietyWatch/Views/Trends/CPAPTrendChart.swift`
- Modify: `AnxietyWatch/Views/Trends/TrendsView.swift`

- [ ] **Step 1: Update CPAPTrendChart with baseline RuleMark and anxiety overlays**

Replace `AnxietyWatch/Views/Trends/CPAPTrendChart.swift`:

```swift
import Charts
import SwiftData
import SwiftUI

struct CPAPTrendChart: View {
    let sessions: [CPAPSession]
    /// Full history needed for baseline calculation
    let allSnapshots: [HealthSnapshot]
    let entries: [AnxietyEntry]
    let dateRange: ClosedRange<Date>

    private var baseline: BaselineCalculator.BaselineResult? {
        BaselineCalculator.cpapAHIBaseline(from: allSnapshots)
    }

    var body: some View {
        ChartCard(
            title: "CPAP — AHI & Usage",
            subtitle: baselineSubtitle,
            isEmpty: sessions.isEmpty
        ) {
            Chart {
                ForEach(sessions) { session in
                    BarMark(
                        x: .value("Date", session.date, unit: .day),
                        y: .value("AHI", session.ahi)
                    )
                    .foregroundStyle(ahiColor(session.ahi).gradient)
                }

                if let baseline {
                    RuleMark(y: .value("Baseline", baseline.mean))
                        .foregroundStyle(.green.opacity(0.6))
                        .lineStyle(StrokeStyle(dash: [5, 3]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("avg")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }

                    RuleMark(y: .value("Upper", baseline.upperBound))
                        .foregroundStyle(.red.opacity(0.3))
                        .lineStyle(StrokeStyle(dash: [3, 3]))
                }

                ForEach(entries) { entry in
                    RuleMark(x: .value("Date", entry.timestamp, unit: .day))
                        .foregroundStyle(anxietyColor(entry.severity).opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .annotation(position: .top, spacing: 0) {
                            Text("\(entry.severity)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(anxietyColor(entry.severity))
                        }
                }
            }
            .chartXScale(domain: dateRange)
            .chartYAxisLabel("AHI (events/hr)")
            .frame(height: 180)

            // Usage as a separate small chart
            Chart(sessions) { session in
                let hours = Double(session.totalUsageMinutes) / 60.0
                BarMark(
                    x: .value("Date", session.date, unit: .day),
                    y: .value("Hours", hours)
                )
                .foregroundStyle(.teal.gradient)
            }
            .chartXScale(domain: dateRange)
            .chartYAxisLabel("Usage (hours)")
            .frame(height: 120)
        }
    }

    private var baselineSubtitle: String? {
        guard let baseline else { return nil }
        return String(format: "30-day avg: %.1f events/hr", baseline.mean)
    }

    private func ahiColor(_ ahi: Double) -> Color {
        switch ahi {
        case ..<5: return .green
        case 5..<15: return .yellow
        case 15..<30: return .orange
        default: return .red
        }
    }

    private func anxietyColor(_ severity: Int) -> Color {
        switch severity {
        case 1...3: return .green
        case 4...6: return .yellow
        case 7...8: return .orange
        default: return .red
        }
    }
}
```

- [ ] **Step 2: Update TrendsView to pass allSnapshots and entries to CPAPTrendChart**

In `AnxietyWatch/Views/Trends/TrendsView.swift`, find line 130:

```swift
CPAPTrendChart(sessions: cpapSessions, dateRange: dateRange)
```

Replace with:

```swift
CPAPTrendChart(sessions: cpapSessions, allSnapshots: allSnapshots, entries: entries, dateRange: dateRange)
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Views/Trends/CPAPTrendChart.swift AnxietyWatch/Views/Trends/TrendsView.swift
git commit -m "feat: add baseline and anxiety overlays to CPAP trend chart"
```

---

### Task 10: BarometricTrendChart — baseline RuleMark

**Files:**
- Modify: `AnxietyWatch/Views/Trends/BarometricTrendChart.swift`
- Modify: `AnxietyWatch/Views/Trends/TrendsView.swift`

- [ ] **Step 1: Read the current BarometricTrendChart to understand its structure**

Read `AnxietyWatch/Views/Trends/BarometricTrendChart.swift` to understand the current chart structure before modifying.

- [ ] **Step 2: Add baseline RuleMark to BarometricTrendChart**

Add an `allSnapshots` parameter to `BarometricTrendChart` and a baseline computed property:

```swift
let allSnapshots: [HealthSnapshot]

private var baseline: BaselineCalculator.BaselineResult? {
    BaselineCalculator.barometricPressureBaseline(from: allSnapshots)
}
```

Inside the `Chart` block, after the existing pressure line/point marks and before the anxiety entry RuleMarks, add:

```swift
if let baseline {
    RuleMark(y: .value("Baseline", baseline.mean))
        .foregroundStyle(.green.opacity(0.6))
        .lineStyle(StrokeStyle(dash: [5, 3]))
        .annotation(position: .trailing, alignment: .leading) {
            Text("avg")
                .font(.caption2)
                .foregroundStyle(.green)
        }
}
```

Add a `subtitle` parameter to the `ChartCard`:
```swift
subtitle: baseline.map { String(format: "30-day avg: %.1f kPa", $0.mean) }
```

- [ ] **Step 3: Update TrendsView to pass allSnapshots to BarometricTrendChart**

In `TrendsView.swift`, find the `BarometricTrendChart(...)` call and add `allSnapshots: allSnapshots`:

```swift
BarometricTrendChart(readings: barometricReadings, entries: entries, allSnapshots: allSnapshots, dateRange: dateRange)
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Views/Trends/BarometricTrendChart.swift AnxietyWatch/Views/Trends/TrendsView.swift
git commit -m "feat: add baseline RuleMark to barometric trend chart"
```

---

### Task 11: Run full test suite and fix any issues

**Files:** All modified files

- [ ] **Step 1: Run all tests**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests 2>&1 | grep -E '(Test Suite|passed|failed|error:)'`
Expected: All tests pass.

- [ ] **Step 2: Fix any failures**

If any tests fail, investigate and fix. Common issues:
- Tests that create `CPAPTrendChart` or `BarometricTrendChart` may need updated initializers
- `DataExporterTests` may need updates if it creates HealthSnapshots and checks field counts

- [ ] **Step 3: Build watchOS target to verify no breakage**

Run: `xcodebuild build -scheme "AnxietyWatch Watch App" -destination 'generic/platform=watchOS Simulator' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit any fixes**

```bash
git add -u
git commit -m "fix: resolve test and build issues from Phase 3 integration"
```

(Skip this step if no fixes were needed.)
