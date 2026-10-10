# Phase 1 Remaining Work — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the remaining Phase 1 items: HealthKit type additions, baseline outlier trimming + dashboard wiring, #Preview blocks, CI hardening, CapRx pipeline completion, and PrescriptionImporter extraction.

**Architecture:** Six independent workstreams. Tasks 1-2 are HealthKit/baseline (Swift, iOS). Task 3 is #Preview blocks (Swift, iOS). Task 4 is CI (YAML). Tasks 5-7 are CapRx pipeline (Python server + Swift iOS). Each workstream can be executed independently.

**Tech Stack:** Swift/SwiftUI/SwiftData, HealthKit, Swift Testing, Python/Flask/PostgreSQL, GitHub Actions

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Modify | `AnxietyWatch/Services/HealthKitManager.swift:17-41` | Add `timeInDaylight`, `physicalEffort` to `allReadTypes` |
| Modify | `AnxietyWatch/Models/HealthSnapshot.swift:63` | Add `timeInDaylightMin`, `physicalEffortAvg` fields |
| Modify | `AnxietyWatch/Services/SnapshotAggregator.swift:177` | Aggregate new HealthKit types |
| Modify | `AnxietyWatchTests/Helpers/ModelFactory.swift:139` | Add new parameters to `healthSnapshot()` |
| Modify | `AnxietyWatch/Services/BaselineCalculator.swift:101-116` | Add outlier trimming to `baseline()` |
| Modify | `AnxietyWatch/Views/Dashboard/DashboardViewModel.swift:16-35` | Add sleep + respiratory baselines |
| Modify | `AnxietyWatch/Views/Dashboard/DashboardView.swift:56-75` | Add sleep + respiratory baseline alerts |
| Modify | `AnxietyWatchTests/BaselineCalculatorTests.swift` | Add outlier trimming tests |
| Modify | `AnxietyWatchTests/Helpers/TestHelpers.swift` | Add `#if DEBUG` guard |
| Modify | `AnxietyWatchTests/Helpers/ModelFactory.swift` | Add `#if DEBUG` guard |
| Modify | `AnxietyWatchTests/Helpers/SampleData.swift` | Add `#if DEBUG` guard |
| Modify | `AnxietyWatch/Views/Dashboard/DashboardView.swift` | Add `#Preview` |
| Modify | `AnxietyWatch/Views/Medications/MedicationsHubView.swift` | Add `#Preview` |
| Modify | `AnxietyWatch/Views/Journal/AddJournalEntryView.swift` | Add `#Preview` |
| Modify | `AnxietyWatch/Views/Trends/TrendsView.swift` | Add `#Preview` |
| Modify | `AnxietyWatch/Views/Prescriptions/PrescriptionDetailView.swift` | Add `#Preview` |
| Modify | `.github/workflows/ios-ci.yml` | Add SwiftLint + watchOS build steps |
| Modify | `server/schema.sql:98-117` | Add `days_supply`, `patient_pay`, `plan_pay`, `dosage_form`, `drug_type` columns |
| Modify | `server/caprx_client.py:299-359` | Log raw claim keys, check for status field |
| Modify | `server/caprx_sync.py:71-129` | Persist new fields in upsert |
| Create | `docs/caprx-api-fields.md` | Document known API response fields |
| Modify | `AnxietyWatch/Models/Prescription.swift` | Add `daysSupply`, `patientPay`, `planPay`, `dosageForm`, `drugType` |
| Modify | `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift:132-142` | Use `daysSupply` as primary run-out input |
| Create | `AnxietyWatch/Services/PrescriptionImporter.swift` | Extract JSON-to-Prescription mapping from SyncService |
| Modify | `AnxietyWatch/Services/SyncService.swift:137-252` | Delegate to PrescriptionImporter |
| Create | `AnxietyWatchTests/PrescriptionImporterTests.swift` | Tests for importer |
| Modify | `server/tests/test_caprx_sync.py` (create) | Tests for new upsert fields |

---

### Task 1: HealthKit Additions (`timeInDaylight`, `physicalEffort`)

**Files:**
- Modify: `AnxietyWatch/Services/HealthKitManager.swift:17-41`
- Modify: `AnxietyWatch/Models/HealthSnapshot.swift:63`
- Modify: `AnxietyWatch/Services/SnapshotAggregator.swift:177`
- Modify: `AnxietyWatchTests/Helpers/ModelFactory.swift:139`

- [ ] **Step 1: Add types to `allReadTypes`**

In `HealthKitManager.swift`, add two entries to the `quantityIdentifiers` array after line 40 (`.walkingAsymmetryPercentage`):

```swift
            .walkingAsymmetryPercentage,      // Left/right asymmetry (0–1)
            // Anxiety-relevant Apple Watch metrics (iOS 17+)
            .timeInDaylight,                  // Outdoor daylight exposure (minutes) — circadian rhythm
            .physicalEffort,                  // Effort level (0–1) — disambiguates exercise vs anxiety HR
        ]
```

- [ ] **Step 2: Add fields to `HealthSnapshot`**

In `HealthSnapshot.swift`, add after line 63 (`var walkingAsymmetryPct: Double?`):

```swift
    // Daylight and effort (iOS 17+ / watchOS 10+)
    var timeInDaylightMin: Int?
    var physicalEffortAvg: Double?
```

- [ ] **Step 3: Add aggregation to `SnapshotAggregator`**

In `SnapshotAggregator.swift`, add after line 177 (the last `walkingAsymmetryPct` assignment), before `try modelContext.save()`:

```swift
        // Time in daylight (cumulative daily total, like steps)
        if let daylight = try await healthKit.cumulativeQuantity(
            .timeInDaylight, unit: .minute(), start: start, end: end
        ) {
            snapshot.timeInDaylightMin = Int(daylight)
        }

        // Physical effort (daily average, unit: kcal/(kg*hr))
        snapshot.physicalEffortAvg = try await healthKit.averageQuantity(
            .physicalEffort,
            unit: .kilocalorie().unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .hour())),
            start: start, end: end
        )
```

- [ ] **Step 4: Add parameters to `ModelFactory.healthSnapshot()`**

In `ModelFactory.swift`, add two parameters to the `healthSnapshot` method signature (after `bpDiastolic`):

```swift
        bpDiastolic: Double? = nil,
        timeInDaylightMin: Int? = nil,
        physicalEffortAvg: Double? = nil
```

And add the assignments in the method body, before `return snapshot`:

```swift
        snapshot.timeInDaylightMin = timeInDaylightMin
        snapshot.physicalEffortAvg = physicalEffortAvg
```

- [ ] **Step 5: Verify it compiles**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | grep -E "error:|BUILD FAILED" | head -5`
Expected: No output (clean build)

- [ ] **Step 6: Run tests**

Run: `make test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add AnxietyWatch/Services/HealthKitManager.swift AnxietyWatch/Models/HealthSnapshot.swift AnxietyWatch/Services/SnapshotAggregator.swift AnxietyWatchTests/Helpers/ModelFactory.swift
git commit -m "feat: add timeInDaylight and physicalEffort to HealthKit pipeline

Apple Watch Series 8 already collects both. timeInDaylight tracks
outdoor daylight exposure (circadian rhythm / anxiety correlation).
physicalEffort disambiguates exercise HR from anxiety HR."
```

---

### Task 2: Baseline Outlier Trimming + Dashboard Wiring

**Files:**
- Modify: `AnxietyWatch/Services/BaselineCalculator.swift:101-116`
- Modify: `AnxietyWatch/Views/Dashboard/DashboardViewModel.swift:16-35`
- Modify: `AnxietyWatch/Views/Dashboard/DashboardView.swift:56-75`
- Modify: `AnxietyWatchTests/BaselineCalculatorTests.swift`

- [ ] **Step 1: Write failing outlier trimming test**

Add to the end of `BaselineCalculatorTests.swift`, before the closing `}`:

```swift
    // MARK: - Outlier trimming

    @Test("Single extreme outlier does not skew baseline mean")
    func outlierDoesNotSkewMean() {
        // 14 values at 50, plus 1 extreme outlier at 200
        var snapshots = (0..<14).map { makeSnapshot(daysAgo: $0, hrvAvg: 50.0) }
        snapshots.append(makeSnapshot(daysAgo: 14, hrvAvg: 200.0))

        let result = BaselineCalculator.hrvBaseline(from: snapshots)
        #expect(result != nil)
        // Mean should be close to 50, not pulled toward 200
        #expect(result!.mean < 55.0)
    }

    @Test("Outlier trimming preserves normal variance")
    func outlierTrimmingPreservesNormalVariance() {
        // 14 values with normal spread (40-60), no outliers
        let snapshots = makeSnapshotsWithHRV(
            (0..<14).map { ($0, 40.0 + Double($0 % 3) * 10.0) }
        )
        let result = BaselineCalculator.hrvBaseline(from: snapshots)
        #expect(result != nil)
        // All values are within normal range — none should be trimmed
        // Mean of [40,50,60,40,50,60,40,50,60,40,50,60,40,50] = 50
        #expect(abs(result!.mean - 50.0) < 0.5)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests/BaselineCalculatorTests/outlierDoesNotSkewMean -quiet 2>&1 | tail -10`
Expected: FAIL — mean is pulled toward 200

- [ ] **Step 3: Add outlier trimming to `baseline()`**

In `BaselineCalculator.swift`, replace the `baseline(from:)` method (lines 101-116):

```swift
    private static func baseline(from values: [Double]) -> BaselineResult? {
        guard values.count >= minimumSampleCount else { return nil }

        // Trim outliers using median absolute deviation (MAD).
        // The median is robust to the outliers we're trying to remove.
        let sorted = values.sorted()
        let median = sorted.count % 2 == 0
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
            : sorted[sorted.count / 2]
        let absoluteDeviations = values.map { abs($0 - median) }.sorted()
        let mad = absoluteDeviations.count % 2 == 0
            ? (absoluteDeviations[absoluteDeviations.count / 2 - 1] + absoluteDeviations[absoluteDeviations.count / 2]) / 2.0
            : absoluteDeviations[absoluteDeviations.count / 2]

        // 2.5 * MAD * 1.4826 (scale factor for normal distribution equivalence)
        let trimThreshold = 2.5 * mad * 1.4826
        let trimmed = trimThreshold > 0
            ? values.filter { abs($0 - median) <= trimThreshold }
            : values
        // Fall back to untrimmed if too many values were removed
        let effective = trimmed.count >= minimumSampleCount ? trimmed : values

        let mean = effective.reduce(0, +) / Double(effective.count)
        // Sample variance (N-1) for correctness with finite samples
        let variance = effective.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(effective.count - 1)
        let stddev = variance.squareRoot()
        let threshold = Constants.deviationThreshold

        return BaselineResult(
            mean: mean,
            standardDeviation: stddev,
            lowerBound: mean - threshold * stddev,
            upperBound: mean + threshold * stddev
        )
    }
```

- [ ] **Step 4: Run outlier tests to verify they pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests/BaselineCalculatorTests -quiet 2>&1 | tail -10`
Expected: All baseline tests pass

- [ ] **Step 5: Add sleep + respiratory baselines to DashboardViewModel**

In `DashboardViewModel.swift`, add after line 17 (`private(set) var rhrBaseline: ...`):

```swift
    private(set) var sleepBaseline: BaselineCalculator.BaselineResult?
    private(set) var respiratoryBaseline: BaselineCalculator.BaselineResult?
```

In `computeBaselines(from:)` (line 32-35), add after the `rhrBaseline` line:

```swift
        sleepBaseline = BaselineCalculator.sleepBaseline(from: snapshots)
        respiratoryBaseline = BaselineCalculator.respiratoryRateBaseline(from: snapshots)
```

- [ ] **Step 6: Add sleep + respiratory baseline alerts to DashboardView**

In `DashboardView.swift`, replace the `baselineAlert` computed property (lines 56-75) with:

```swift
    @ViewBuilder
    private var baselineAlert: some View {
        if let baseline = vm.hrvBaseline,
           let recent = BaselineCalculator.recentAverage(from: recentSnapshots, days: 3, keyPath: \.hrvAvg),
           recent < baseline.lowerBound {
            baselineAlertCard(
                icon: "heart.fill",
                title: "HRV Below Baseline",
                message: "Your 3-day HRV average is below your 30-day baseline",
                color: .orange
            )
        }
        if let baseline = vm.sleepBaseline,
           let lastSleep = recentSnapshots.first?.sleepDurationMin.map(Double.init),
           lastSleep < baseline.lowerBound {
            let pct = Int(((baseline.mean - lastSleep) / baseline.mean) * 100)
            baselineAlertCard(
                icon: "bed.double.fill",
                title: "Sleep Below Baseline",
                message: "Last night's sleep was \(pct)% below your 30-day average",
                color: .indigo
            )
        }
        if let baseline = vm.respiratoryBaseline,
           let lastRR = recentSnapshots.first?.respiratoryRate,
           lastRR > baseline.upperBound {
            let pct = Int(((lastRR - baseline.mean) / baseline.mean) * 100)
            baselineAlertCard(
                icon: "lungs.fill",
                title: "Respiratory Rate Elevated",
                message: "Your respiratory rate is \(pct)% above your 30-day average",
                color: .teal
            )
        }
    }

    private func baselineAlertCard(icon: String, title: String, message: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(color.opacity(0.1), in: .rect(cornerRadius: 12))
    }
```

- [ ] **Step 7: Verify it compiles and tests pass**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | grep -E "error:|BUILD FAILED" | head -5`
Expected: No output

Run: `make test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add AnxietyWatch/Services/BaselineCalculator.swift AnxietyWatch/Views/Dashboard/DashboardViewModel.swift AnxietyWatch/Views/Dashboard/DashboardView.swift AnxietyWatchTests/BaselineCalculatorTests.swift
git commit -m "feat: outlier trimming in baselines + sleep/respiratory alerts on dashboard

BaselineCalculator now trims values beyond 2.5 MAD from the median
before computing mean/stddev. Dashboard shows alert cards when sleep
duration drops or respiratory rate rises above 30-day baseline."
```

---

### Task 3: #Preview Blocks

**Files:**
- Modify: `AnxietyWatchTests/Helpers/TestHelpers.swift`
- Modify: `AnxietyWatchTests/Helpers/ModelFactory.swift`
- Modify: `AnxietyWatchTests/Helpers/SampleData.swift`
- Modify: `AnxietyWatch/Views/Dashboard/DashboardView.swift`
- Modify: `AnxietyWatch/Views/Medications/MedicationsHubView.swift`
- Modify: `AnxietyWatch/Views/Journal/AddJournalEntryView.swift`
- Modify: `AnxietyWatch/Views/Trends/TrendsView.swift`
- Modify: `AnxietyWatch/Views/Prescriptions/PrescriptionDetailView.swift`

The test helpers need `#if DEBUG` guards and to be added to the app target so `#Preview` blocks can use them.

- [ ] **Step 1: Add `#if DEBUG` guards to test helpers**

Wrap the contents of each file:

In `TestHelpers.swift`, wrap the entire file content (after the imports) with:
```swift
import SwiftData
@testable import AnxietyWatch

#if DEBUG
enum TestHelpers {
    // ... existing content ...
}
#endif
```

In `ModelFactory.swift`, wrap the entire file content with:
```swift
import Foundation
@testable import AnxietyWatch

#if DEBUG
enum ModelFactory {
    // ... existing content ...
}
#endif
```

In `SampleData.swift`, wrap the entire file content with:
```swift
import SwiftData
@testable import AnxietyWatch

#if DEBUG
enum SampleData {
    // ... existing content ...
}
#endif
```

- [ ] **Step 2: Add test helper files to the app target**

Run this to find the Xcode project file:
```bash
ls AnxietyWatch.xcodeproj/
```

The files need to be added to the AnxietyWatch app target's "Compile Sources" build phase. Since modifying `project.pbxproj` manually is fragile, the simplest approach is:

Open Xcode and drag `TestHelpers.swift`, `ModelFactory.swift`, and `SampleData.swift` from `AnxietyWatchTests/Helpers/` into the AnxietyWatch target's file list, checking the "AnxietyWatch" target membership box.

Alternatively, use a script to add target membership:
```bash
# Verify the files compile in both targets by building
xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet
```

**Note for agentic workers:** You cannot modify Xcode target membership from the command line. Instead, create new files in the app target directory:

Create `AnxietyWatch/Utilities/PreviewHelpers.swift`:

```swift
#if DEBUG
import SwiftData

/// Preview-friendly container with seeded data. Wraps the test helpers
/// for use in #Preview blocks. Compiled only in DEBUG builds.
enum PreviewHelpers {
    static func makeFullContainer() throws -> ModelContainer {
        let schema = Schema([
            AnxietyEntry.self,
            MedicationDefinition.self,
            MedicationDose.self,
            CPAPSession.self,
            BarometricReading.self,
            HealthSnapshot.self,
            ClinicalLabResult.self,
            Pharmacy.self,
            Prescription.self,
            PharmacyCallLog.self,
            HealthSample.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    static func makeSeededContainer() throws -> ModelContainer {
        let container = try makeFullContainer()
        let context = ModelContext(container)
        seedData(into: context)
        return container
    }

    private static func seedData(into context: ModelContext) {
        let base = Date(timeIntervalSince1970: 1_711_929_600) // 2024-04-01
        let calendar = Calendar.current

        for day in 0..<30 {
            let date = calendar.date(byAdding: .day, value: -day, to: base)!
            let snapshot = HealthSnapshot(date: date)
            snapshot.hrvAvg = 40.0 + Double(day % 7) * 3.0
            snapshot.restingHR = 60.0 + Double(day % 5) * 2.0
            snapshot.sleepDurationMin = 360 + (day % 4) * 30
            snapshot.respiratoryRate = 14.0 + Double(day % 3) * 0.5
            snapshot.steps = 5000 + (day % 6) * 1500
            context.insert(snapshot)
        }

        for i in 0..<15 {
            let entry = AnxietyEntry(
                timestamp: calendar.date(byAdding: .day, value: -(i * 2), to: base)!,
                severity: 3 + (i % 5),
                notes: "",
                tags: i % 3 == 0 ? ["sleep"] : i % 3 == 1 ? ["work"] : []
            )
            context.insert(entry)
        }

        let med = MedicationDefinition(
            name: "Test Medication 50mg",
            defaultDoseMg: 50.0,
            category: "SSRI"
        )
        context.insert(med)

        for i in 0..<10 {
            let dose = MedicationDose(
                timestamp: calendar.date(byAdding: .day, value: -(i * 3), to: base)!,
                medicationName: "Test Medication 50mg",
                doseMg: 50.0,
                isPRN: true,
                medication: med
            )
            context.insert(dose)
        }

        for i in 0..<5 {
            let session = CPAPSession(
                date: calendar.date(byAdding: .day, value: -(i * 6), to: base)!,
                ahi: 1.5 + Double(i) * 0.5,
                totalUsageMinutes: 420,
                leakRate95th: 18.0,
                pressureMin: 6.0,
                pressureMax: 12.0,
                pressureMean: 9.5,
                obstructiveEvents: 3,
                centralEvents: 1,
                hypopneaEvents: 2,
                importSource: "csv"
            )
            context.insert(session)
        }

        let pharmacy = Pharmacy(
            name: "Test Pharmacy #12345",
            address: "100 Example Blvd, Anytown, ST 00000",
            phoneNumber: "555-0100"
        )
        context.insert(pharmacy)

        let rx = Prescription(
            rxNumber: "9999999-00001",
            medicationName: "Test Medication 50mg",
            doseMg: 50.0,
            quantity: 30,
            refillsRemaining: 3,
            dateFilled: base,
            pharmacyName: "Test Pharmacy #12345",
            prescriberName: "Jane Smith MD",
            medication: med,
            pharmacy: pharmacy
        )
        context.insert(rx)

        try? context.save()
    }
}
#endif
```

- [ ] **Step 3: Add `#Preview` to DashboardView**

Add at the bottom of `DashboardView.swift`:

```swift
#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    DashboardView()
        .modelContainer(container)
}
#endif
```

- [ ] **Step 4: Add `#Preview` to MedicationsHubView**

Add at the bottom of `MedicationsHubView.swift`:

```swift
#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    NavigationStack {
        MedicationsHubView()
    }
    .modelContainer(container)
}
#endif
```

- [ ] **Step 5: Add `#Preview` to AddJournalEntryView**

Add at the bottom of `AddJournalEntryView.swift`:

```swift
#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    NavigationStack {
        AddJournalEntryView()
    }
    .modelContainer(container)
}
#endif
```

- [ ] **Step 6: Add `#Preview` to TrendsView**

Add at the bottom of `TrendsView.swift`:

```swift
#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    TrendsView()
        .modelContainer(container)
}
#endif
```

- [ ] **Step 7: Add `#Preview` to PrescriptionDetailView**

Add at the bottom of `PrescriptionDetailView.swift`:

```swift
#if DEBUG
#Preview {
    let container = try! PreviewHelpers.makeSeededContainer()
    let context = ModelContext(container)
    let rx = try! context.fetch(FetchDescriptor<Prescription>()).first!
    NavigationStack {
        PrescriptionDetailView(prescription: rx)
    }
    .modelContainer(container)
}
#endif
```

- [ ] **Step 8: Verify it compiles**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | grep -E "error:|BUILD FAILED" | head -5`
Expected: No output

- [ ] **Step 9: Run tests to verify no regressions**

Run: `make test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 10: Commit**

```bash
git add AnxietyWatch/Utilities/PreviewHelpers.swift AnxietyWatch/Views/Dashboard/DashboardView.swift AnxietyWatch/Views/Medications/MedicationsHubView.swift AnxietyWatch/Views/Journal/AddJournalEntryView.swift AnxietyWatch/Views/Trends/TrendsView.swift AnxietyWatch/Views/Prescriptions/PrescriptionDetailView.swift
git commit -m "dx: add #Preview blocks to 5 most-used views

PreviewHelpers provides a DEBUG-only seeded ModelContainer with 30 days
of realistic data. Previews added to DashboardView, MedicationsHubView,
AddJournalEntryView, TrendsView, and PrescriptionDetailView."
```

---

### Task 4: CI Hardening (SwiftLint + watchOS Build)

**Files:**
- Modify: `.github/workflows/ios-ci.yml`

- [ ] **Step 1: Add SwiftLint step**

In `ios-ci.yml`, add after the "Generate BuildVersion.swift" step (line 36) and before "Run tests with coverage" (line 38):

```yaml
      - name: Run SwiftLint
        continue-on-error: true
        run: |
          brew install swiftlint
          swiftlint lint --reporter github-actions-logging

```

- [ ] **Step 2: Add watchOS build step**

Add after the "Report coverage" step (at the end of the file):

```yaml
      - name: Build watchOS app
        run: |
          xcodebuild build \
            -scheme "AnxietyWatch Watch App" \
            -destination 'generic/platform=watchOS Simulator' \
            -quiet
```

- [ ] **Step 3: Verify YAML is valid**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ios-ci.yml'))" 2>&1 || echo "YAML INVALID"`
Expected: No output (valid YAML)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ios-ci.yml
git commit -m "ci: add SwiftLint step and watchOS build to iOS CI

SwiftLint runs with github-actions-logging for inline PR annotations.
continue-on-error until existing violations are cleaned up. watchOS
build step catches compile errors in the watch target."
```

---

### Task 5: CapRx Pipeline — Server Side

**Files:**
- Modify: `server/schema.sql:98-117`
- Modify: `server/caprx_client.py:299-359`
- Modify: `server/caprx_sync.py:71-129`
- Create: `docs/caprx-api-fields.md`
- Create: `server/tests/test_caprx_sync.py`

- [ ] **Step 1: Add columns to schema**

In `server/schema.sql`, replace the prescriptions table definition (lines 98-117) with:

```sql
CREATE TABLE IF NOT EXISTS prescriptions (
    rx_number               TEXT NOT NULL PRIMARY KEY,
    medication_name         TEXT NOT NULL,
    dose_mg                 DOUBLE PRECISION NOT NULL,
    dose_description        TEXT NOT NULL DEFAULT '',
    quantity                INTEGER NOT NULL,
    refills_remaining       INTEGER NOT NULL DEFAULT 0,
    date_filled             TIMESTAMPTZ NOT NULL,
    estimated_run_out_date  TIMESTAMPTZ,
    pharmacy_name           TEXT NOT NULL DEFAULT '',
    notes                   TEXT NOT NULL DEFAULT '',
    daily_dose_count        DOUBLE PRECISION,
    prescriber_name         TEXT NOT NULL DEFAULT '',
    ndc_code                TEXT NOT NULL DEFAULT '',
    rx_status               TEXT NOT NULL DEFAULT '',
    last_fill_date          TIMESTAMPTZ,
    import_source           TEXT NOT NULL DEFAULT 'manual',
    walgreens_rx_id         TEXT,
    directions              TEXT NOT NULL DEFAULT '',
    days_supply             INTEGER,
    patient_pay             DOUBLE PRECISION,
    plan_pay                DOUBLE PRECISION,
    dosage_form             TEXT NOT NULL DEFAULT '',
    drug_type               TEXT NOT NULL DEFAULT ''
);
```

- [ ] **Step 2: Add migration for existing databases**

In `server/server.py`, find the `init_db()` function and add column migration after the schema creation. Search for where `init_db` is defined and add after the schema execution:

```python
    # Migrate: add CapRx columns if missing
    migrate_cols = [
        ("prescriptions", "days_supply", "INTEGER"),
        ("prescriptions", "patient_pay", "DOUBLE PRECISION"),
        ("prescriptions", "plan_pay", "DOUBLE PRECISION"),
        ("prescriptions", "dosage_form", "TEXT NOT NULL DEFAULT ''"),
        ("prescriptions", "drug_type", "TEXT NOT NULL DEFAULT ''"),
    ]
    for table, col, col_type in migrate_cols:
        cur.execute(
            "SELECT 1 FROM information_schema.columns "
            "WHERE table_name = %s AND column_name = %s",
            (table, col),
        )
        if not cur.fetchone():
            cur.execute(f"ALTER TABLE {table} ADD COLUMN {col} {col_type}")
    conn.commit()
```

- [ ] **Step 3: Log raw claim keys in `normalize_claim`**

In `caprx_client.py`, add key logging at the top of `normalize_claim()` (after line 304, `claim = claim_wrapper.get("claim", {})`):

```python
    # Log available fields on first call for API documentation
    if not hasattr(normalize_claim, "_keys_logged"):
        wrapper_keys = sorted(claim_wrapper.keys())
        claim_keys = sorted(claim.keys())
        logger.info("CapRx claim wrapper keys: %s", wrapper_keys)
        logger.info("CapRx claim keys: %s", claim_keys)
        normalize_claim._keys_logged = True
```

- [ ] **Step 4: Add claim status checking**

In `normalize_claim()`, add after the key logging and before the `drug_name` extraction (before `drug_name = claim.get("drug_name", ...)`):

```python
    # Filter reversed/rejected claims if the API provides status
    claim_status = (
        claim.get("claim_status", "")
        or claim.get("status", "")
        or claim_wrapper.get("status", "")
    )
    if isinstance(claim_status, str) and claim_status.lower() in (
        "reversed", "rejected", "denied", "voided",
    ):
        logger.info("Skipping %s claim (id=%s)", claim_status, claim.get("id"))
        return None
```

- [ ] **Step 5: Pass cost/form fields through and populate rx_status**

The return dict in `normalize_claim()` (lines 345-359) already includes `days_supply`, `patient_pay`, `plan_pay`, `drug_type`, `dosage_form`. Fix the cost fields to parse as numeric:

Replace lines 355-356:
```python
        "patient_pay": claim.get("patient_pay_amount", ""),
        "plan_pay": claim.get("plan_pay_amount", ""),
```

With:
```python
        "patient_pay": _parse_float(claim.get("patient_pay_amount")),
        "plan_pay": _parse_float(claim.get("plan_pay_amount")),
        "rx_status": str(claim_status) if claim_status else "",
```

Add the helper at module level (before `normalize_claim`):

```python
def _parse_float(value) -> float | None:
    """Parse a float from a string or number, returning None on failure."""
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (ValueError, TypeError):
        return None
```

- [ ] **Step 6: Update upsert to persist new fields**

In `caprx_sync.py`, replace the `upsert_prescriptions` function (lines 71-129):

```python
def upsert_prescriptions(conn, prescriptions):
    """Insert or update prescriptions from CapRx claims.

    - Rows with import_source = 'manual' are never overwritten.
    - Rows with import_source = 'caprx' are updated in place.
    - New rx_numbers are inserted with import_source = 'caprx'.

    Returns the number of rows inserted or updated.
    """
    if not prescriptions:
        return 0

    cur = conn.cursor()
    upserted = 0

    for rx in prescriptions:
        rx_number = rx["rx_number"]

        # Compute estimated run-out date from days_supply
        estimated_run_out = None
        ds = rx.get("days_supply") or 0
        if ds > 0:
            estimated_run_out = rx["date_filled"] + timedelta(days=ds)

        cur.execute(
            """INSERT INTO prescriptions
                   (rx_number, medication_name, dose_mg, dose_description,
                    quantity, date_filled, estimated_run_out_date,
                    pharmacy_name, ndc_code, last_fill_date,
                    import_source, days_supply, patient_pay, plan_pay,
                    dosage_form, drug_type, rx_status)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                       'caprx', %s, %s, %s, %s, %s, %s)
               ON CONFLICT (rx_number) DO UPDATE SET
                   medication_name = EXCLUDED.medication_name,
                   dose_mg = EXCLUDED.dose_mg,
                   dose_description = EXCLUDED.dose_description,
                   quantity = EXCLUDED.quantity,
                   date_filled = EXCLUDED.date_filled,
                   estimated_run_out_date = EXCLUDED.estimated_run_out_date,
                   pharmacy_name = EXCLUDED.pharmacy_name,
                   ndc_code = EXCLUDED.ndc_code,
                   last_fill_date = EXCLUDED.last_fill_date,
                   import_source = EXCLUDED.import_source,
                   days_supply = EXCLUDED.days_supply,
                   patient_pay = EXCLUDED.patient_pay,
                   plan_pay = EXCLUDED.plan_pay,
                   dosage_form = EXCLUDED.dosage_form,
                   drug_type = EXCLUDED.drug_type,
                   rx_status = EXCLUDED.rx_status
               WHERE prescriptions.import_source = 'caprx'""",
            (
                rx_number,
                rx["medication_name"],
                rx["dose_mg"],
                rx.get("dose_description", ""),
                rx["quantity"],
                rx["date_filled"],
                estimated_run_out,
                rx.get("pharmacy_name", ""),
                rx.get("ndc_code", ""),
                rx["date_filled"],  # last_fill_date = date_filled
                ds if ds > 0 else None,
                rx.get("patient_pay"),
                rx.get("plan_pay"),
                rx.get("dosage_form", ""),
                rx.get("drug_type", ""),
                rx.get("rx_status", ""),
            ),
        )
        upserted += cur.rowcount

    conn.commit()
    return upserted
```

- [ ] **Step 7: Write server tests for new fields**

Create `server/tests/test_caprx_sync.py`:

```python
"""Tests for CapRx claim normalization and upsert."""

from datetime import datetime, timezone

from caprx_client import normalize_claim


class TestNormalizeClaim:
    """Tests for normalize_claim()."""

    def _make_claim(self, **overrides):
        """Build a minimal valid claim wrapper."""
        claim = {
            "drug_name": "Clonazepam",
            "date_of_service": "2024-03-15T00:00:00Z",
            "id": 12345,
            "quantity_dispensed": 30,
            "days_supply": 30,
            "strength": "1",
            "strength_unit_of_measure": "MG",
            "dosage": "1mg tablet",
            "pharmacy_name": "Test Pharmacy #12345",
            "ndc": "00000-0000-00",
            "patient_pay_amount": "10.00",
            "plan_pay_amount": "45.50",
            "drug_type": "generic",
            "dosage_form": "tablet",
        }
        claim.update(overrides)
        return {"claim": claim}

    def test_basic_normalization(self):
        result = normalize_claim(self._make_claim())
        assert result is not None
        assert result["rx_number"] == "CRX-12345"
        assert result["medication_name"] == "Clonazepam"
        assert result["quantity"] == 30
        assert result["days_supply"] == 30

    def test_cost_fields_parsed(self):
        result = normalize_claim(self._make_claim())
        assert result["patient_pay"] == 10.0
        assert result["plan_pay"] == 45.5

    def test_cost_fields_none_when_empty(self):
        result = normalize_claim(self._make_claim(
            patient_pay_amount="", plan_pay_amount=None
        ))
        assert result["patient_pay"] is None
        assert result["plan_pay"] is None

    def test_dosage_form_and_drug_type(self):
        result = normalize_claim(self._make_claim())
        assert result["dosage_form"] == "tablet"
        assert result["drug_type"] == "generic"

    def test_missing_drug_name_returns_none(self):
        result = normalize_claim(self._make_claim(drug_name=""))
        assert result is None

    def test_missing_claim_id_returns_none(self):
        result = normalize_claim(self._make_claim(id=""))
        assert result is None

    def test_mcg_converted_to_mg(self):
        result = normalize_claim(self._make_claim(
            strength="500", strength_unit_of_measure="MCG"
        ))
        assert result["dose_mg"] == 0.5

    def test_reversed_claim_filtered(self):
        wrapper = self._make_claim()
        wrapper["claim"]["claim_status"] = "reversed"
        result = normalize_claim(wrapper)
        assert result is None

    def test_rejected_claim_filtered(self):
        wrapper = self._make_claim()
        wrapper["claim"]["status"] = "rejected"
        result = normalize_claim(wrapper)
        assert result is None

    def test_active_claim_not_filtered(self):
        wrapper = self._make_claim()
        wrapper["claim"]["claim_status"] = "paid"
        result = normalize_claim(wrapper)
        assert result is not None
```

- [ ] **Step 8: Run server tests**

Run: `cd server && python -m pytest tests/test_caprx_sync.py -v`
Expected: All tests pass

- [ ] **Step 9: Lint server code**

Run: `cd server && flake8 . --max-line-length=120 --exclude=__pycache__`
Expected: No errors

- [ ] **Step 10: Create API fields documentation**

Create `docs/caprx-api-fields.md`:

```markdown
# CapRx API Response Fields

**Last updated:** 2026-03-30
**Source:** `server/caprx_client.py` — `normalize_claim()` function

## How to discover new fields

The `normalize_claim()` function logs all available keys at INFO level
on the first claim processed each sync. Check server logs after a sync:

```
CapRx claim wrapper keys: ['claim', ...]
CapRx claim keys: ['date_of_service', 'dosage', 'drug_name', ...]
```

## Known Fields

### Claim wrapper (`claim_wrapper`)

| Key | Description |
|-----|-------------|
| `claim` | Nested dict containing all claim data fields |

### Claim data (`claim_wrapper["claim"]`)

| Key | Type | Used? | Description |
|-----|------|-------|-------------|
| `id` | int | Yes | Unique claim ID (used to build `rx_number` as `CRX-{id}`) |
| `drug_name` | str | Yes | Generic drug name (PBM adjudication name) |
| `date_of_service` | str | Yes | Fill date (ISO-8601 with Z) |
| `quantity_dispensed` | int | Yes | Number of units dispensed |
| `days_supply` | int | Yes | Days of medication supply |
| `strength` | str | Yes | Numeric strength value |
| `strength_unit_of_measure` | str | Yes | Unit: MG, MCG, etc. |
| `dosage` | str | Yes | Human-readable dosage string |
| `pharmacy_name` | str | Yes | Pharmacy name |
| `ndc` | str | Yes | National Drug Code |
| `patient_pay_amount` | str | Yes | Patient copay (as string, parsed to float) |
| `plan_pay_amount` | str | Yes | Insurance payment (as string, parsed to float) |
| `drug_type` | str | Yes | brand / generic / specialty |
| `dosage_form` | str | Yes | tablet / capsule / solution / etc. |
| `claim_status` / `status` | str | Yes | Claim status — "reversed"/"rejected" claims are filtered out |

### Fields not yet observed

These fields likely exist in the API response but have not been confirmed:

- `prescriber_npi` — Prescriber NPI number
- `pharmacy_npi` / `pharmacy_ncpdp` — Pharmacy identifiers
- `daw_code` — Dispense As Written code
- `therapeutic_class` — Drug classification code

Run a sync with `--verbose` and check logged keys to discover additional fields.
```

- [ ] **Step 11: Commit**

```bash
git add server/schema.sql server/caprx_client.py server/caprx_sync.py server/tests/test_caprx_sync.py docs/caprx-api-fields.md
git commit -m "feat: persist CapRx cost/supply fields + claim status filtering

Add days_supply, patient_pay, plan_pay, dosage_form, drug_type columns
to prescriptions table. Filter reversed/rejected claims. Log raw API
response keys for documentation. Document known API fields."
```

---

### Task 6: iOS Prescription Model + Supply Calculator Update

**Files:**
- Modify: `AnxietyWatch/Models/Prescription.swift`
- Modify: `AnxietyWatch/Services/PrescriptionSupplyCalculator.swift:132-142`
- Modify: `AnxietyWatchTests/Helpers/ModelFactory.swift`

- [ ] **Step 1: Add fields to Prescription model**

In `Prescription.swift`, add after line 37 (`var directions: String = ""`):

```swift
    /// Days of medication supply from PBM (more authoritative than quantity-based estimate)
    var daysSupply: Int?
    /// Patient copay amount from PBM claims
    var patientPay: Double?
    /// Insurance payment amount from PBM claims
    var planPay: Double?
    /// Dosage form: tablet, capsule, solution, etc.
    var dosageForm: String = ""
    /// Drug type: brand, generic, specialty
    var drugType: String = ""
```

Add matching init parameters after `directions: String = ""` in the init signature:

```swift
        directions: String = "",
        daysSupply: Int? = nil,
        patientPay: Double? = nil,
        planPay: Double? = nil,
        dosageForm: String = "",
        drugType: String = "",
```

Add assignments in the init body after `self.directions = directions`:

```swift
        self.daysSupply = daysSupply
        self.patientPay = patientPay
        self.planPay = planPay
        self.dosageForm = dosageForm
        self.drugType = drugType
```

- [ ] **Step 2: Update `effectiveRunOutDate` to use `daysSupply`**

In `PrescriptionSupplyCalculator.swift`, replace `effectiveRunOutDate` (lines 132-142):

```swift
    private static func effectiveRunOutDate(for prescription: Prescription) -> Date? {
        if let stored = prescription.estimatedRunOutDate {
            return stored
        }
        // Prefer daysSupply from PBM (most authoritative) over quantity-based calculation
        if let daysSupply = prescription.daysSupply, daysSupply > 0 {
            return Calendar.current.date(
                byAdding: .day,
                value: daysSupply,
                to: prescription.dateFilled
            )
        }
        guard let daily = prescription.dailyDoseCount else { return nil }
        return estimateRunOutDate(
            dateFilled: prescription.dateFilled,
            quantity: prescription.quantity,
            dailyDoseCount: daily
        )
    }
```

- [ ] **Step 3: Update `alertStalenessLimitDays` to use `daysSupply`**

In `PrescriptionSupplyCalculator.swift`, replace the `alertStalenessLimitDays` method (lines 12-18):

```swift
    static func alertStalenessLimitDays(for prescription: Prescription) -> Int {
        // Prefer daysSupply from PBM over quantity-based calculation
        if let daysSupply = prescription.daysSupply, daysSupply > 0 {
            return max(daysSupply * 2, defaultStalenessLimitDays)
        }
        if let daily = prescription.dailyDoseCount, daily > 0 {
            let supplyDays = Int(ceil(Double(prescription.quantity) / daily))
            return max(supplyDays * 2, defaultStalenessLimitDays)
        }
        return defaultStalenessLimitDays
    }
```

- [ ] **Step 4: Update ModelFactory.prescription()**

In `ModelFactory.swift`, add parameters to the `prescription()` method after `pharmacy: Pharmacy? = nil`:

```swift
        pharmacy: Pharmacy? = nil,
        daysSupply: Int? = nil,
        patientPay: Double? = nil,
        planPay: Double? = nil,
        dosageForm: String = "",
        drugType: String = ""
```

Pass them through to the `Prescription` init:

```swift
            medication: medication,
            pharmacy: pharmacy,
            daysSupply: daysSupply,
            patientPay: patientPay,
            planPay: planPay,
            dosageForm: dosageForm,
            drugType: drugType
```

- [ ] **Step 5: Verify it compiles and tests pass**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | grep -E "error:|BUILD FAILED" | head -5`
Expected: No output

Run: `make test 2>&1 | tail -5`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add AnxietyWatch/Models/Prescription.swift AnxietyWatch/Services/PrescriptionSupplyCalculator.swift AnxietyWatchTests/Helpers/ModelFactory.swift
git commit -m "feat: add daysSupply and cost fields to Prescription model

daysSupply from PBM is used as primary input for run-out date and
staleness calculations, falling back to quantity-based heuristic.
patientPay, planPay, dosageForm, drugType stored for future display."
```

---

### Task 7: PrescriptionImporter Extraction

**Files:**
- Create: `AnxietyWatch/Services/PrescriptionImporter.swift`
- Modify: `AnxietyWatch/Services/SyncService.swift:137-252`
- Create: `AnxietyWatchTests/PrescriptionImporterTests.swift`

- [ ] **Step 1: Write failing test**

Create `AnxietyWatchTests/PrescriptionImporterTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct PrescriptionImporterTests {

    @Test("Complete CapRx record maps all fields")
    func completeCapRxRecord() throws {
        let record: [String: Any] = [
            "rx_number": "CRX-12345",
            "medication_name": "Clonazepam 1mg",
            "dose_mg": 1.0 as Double,
            "dose_description": "1mg tablet",
            "quantity": 30 as Int,
            "refills_remaining": 0 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
            "pharmacy_name": "Test Pharmacy #12345",
            "ndc_code": "00000-0000-00",
            "rx_status": "paid",
            "import_source": "caprx",
            "days_supply": 30 as Int,
            "patient_pay": 10.0 as Double,
            "plan_pay": 45.5 as Double,
            "dosage_form": "tablet",
            "drug_type": "generic",
            "directions": "Take 1 tablet by mouth daily",
        ]

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rx = try PrescriptionImporter.importRecord(record, into: context)

        #expect(rx.rxNumber == "CRX-12345")
        #expect(rx.medicationName == "Clonazepam 1mg")
        #expect(rx.daysSupply == 30)
        #expect(rx.patientPay == 10.0)
        #expect(rx.planPay == 45.5)
        #expect(rx.dosageForm == "tablet")
        #expect(rx.drugType == "generic")
        #expect(rx.directions == "Take 1 tablet by mouth daily")
    }

    @Test("Missing optional fields use defaults")
    func missingOptionalFields() throws {
        let record: [String: Any] = [
            "rx_number": "CRX-99999",
            "medication_name": "Test Med 50mg",
            "dose_mg": 50.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
            "import_source": "caprx",
        ]

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rx = try PrescriptionImporter.importRecord(record, into: context)

        #expect(rx.daysSupply == nil)
        #expect(rx.patientPay == nil)
        #expect(rx.planPay == nil)
        #expect(rx.dosageForm == "")
        #expect(rx.drugType == "")
        #expect(rx.directions == "")
    }

    @Test("daysSupply used for run-out date when present")
    func daysSupplyUsedForRunOut() throws {
        let record: [String: Any] = [
            "rx_number": "CRX-77777",
            "medication_name": "Test Med 50mg",
            "dose_mg": 50.0 as Double,
            "quantity": 90 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
            "days_supply": 30 as Int,
            "import_source": "caprx",
        ]

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let rx = try PrescriptionImporter.importRecord(record, into: context)

        // Run-out should be based on daysSupply (30 days), not quantity (90)
        let expectedRunOut = Calendar.current.date(byAdding: .day, value: 30, to: rx.dateFilled)!
        #expect(rx.estimatedRunOutDate != nil)
        let diff = abs(rx.estimatedRunOutDate!.timeIntervalSince(expectedRunOut))
        #expect(diff < 86400) // within 1 day
    }

    @Test("Existing prescription is updated, not duplicated")
    func existingPrescriptionUpdated() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        // Insert first
        let record1: [String: Any] = [
            "rx_number": "CRX-55555",
            "medication_name": "Test Med 50mg",
            "dose_mg": 50.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
            "import_source": "caprx",
        ]
        _ = try PrescriptionImporter.importRecord(record1, into: context)
        try context.save()

        // Update with new directions
        let record2: [String: Any] = [
            "rx_number": "CRX-55555",
            "medication_name": "Test Med 50mg",
            "dose_mg": 50.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
            "directions": "Take 1 tablet by mouth daily",
            "import_source": "caprx",
        ]
        _ = try PrescriptionImporter.importRecord(record2, into: context)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Prescription>())
        #expect(all.count == 1)
        #expect(all.first?.directions == "Take 1 tablet by mouth daily")
    }

    @Test("Record missing rx_number throws")
    func missingRxNumberThrows() throws {
        let record: [String: Any] = [
            "medication_name": "Test Med",
            "dose_mg": 50.0 as Double,
            "quantity": 30 as Int,
            "date_filled": "2024-04-01T00:00:00.000Z",
        ]

        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)

        #expect(throws: PrescriptionImporter.ImportError.self) {
            try PrescriptionImporter.importRecord(record, into: context)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests/PrescriptionImporterTests -quiet 2>&1 | tail -10`
Expected: FAIL — `PrescriptionImporter` does not exist

- [ ] **Step 3: Create PrescriptionImporter**

Create `AnxietyWatch/Services/PrescriptionImporter.swift`:

```swift
import Foundation
import SwiftData

/// Extracts prescription records from server JSON into SwiftData models.
/// Pure mapping logic — no network, no auth.
enum PrescriptionImporter {

    enum ImportError: Error {
        case missingRxNumber
        case invalidDateFormat(String)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Import a single prescription record from a server JSON dict.
    /// Upserts: updates existing if rx_number matches, otherwise inserts.
    /// Returns the imported or updated Prescription.
    @discardableResult
    static func importRecord(
        _ record: [String: Any],
        into context: ModelContext
    ) throws -> Prescription {
        guard let rxNumber = record["rx_number"] as? String, !rxNumber.isEmpty else {
            throw ImportError.missingRxNumber
        }

        let dateFilled = parseDate(record["date_filled"]) ?? .now
        let lastFillDate = parseDate(record["last_fill_date"])
        let estimatedRunOut = parseDate(record["estimated_run_out_date"])

        let quantity = record["quantity"] as? Int ?? 0
        let dailyDose = record["daily_dose_count"] as? Double ?? 1.0
        let daysSupply = record["days_supply"] as? Int
        let directions = record["directions"] as? String ?? ""
        let refills = record["refills_remaining"] as? Int ?? 0

        // Compute run-out: prefer server value, then daysSupply, then quantity-based
        let computedRunOut = estimatedRunOut
            ?? daysSupplyRunOut(dateFilled: dateFilled, daysSupply: daysSupply)
            ?? PrescriptionSupplyCalculator.estimateRunOutDate(
                dateFilled: dateFilled,
                quantity: quantity,
                dailyDoseCount: dailyDose
            )

        // Check for existing prescription to update
        let existing = try context.fetch(FetchDescriptor<Prescription>())
        if let rx = existing.first(where: { $0.rxNumber == rxNumber }) {
            return update(rx, from: record, directions: directions, refills: refills, context: context)
        }

        // Insert new
        let rx = Prescription(
            rxNumber: rxNumber,
            medicationName: record["medication_name"] as? String ?? "",
            doseMg: record["dose_mg"] as? Double ?? 0,
            doseDescription: record["dose_description"] as? String ?? "",
            quantity: quantity,
            refillsRemaining: refills,
            dateFilled: dateFilled,
            estimatedRunOutDate: computedRunOut,
            pharmacyName: record["pharmacy_name"] as? String ?? "",
            notes: record["notes"] as? String ?? "",
            dailyDoseCount: dailyDose,
            prescriberName: record["prescriber_name"] as? String ?? "",
            ndcCode: record["ndc_code"] as? String ?? "",
            rxStatus: record["rx_status"] as? String ?? "",
            lastFillDate: lastFillDate,
            importSource: record["import_source"] as? String ?? "caprx",
            walgreensRxId: record["walgreens_rx_id"] as? String,
            directions: directions,
            daysSupply: daysSupply,
            patientPay: record["patient_pay"] as? Double,
            planPay: record["plan_pay"] as? Double,
            dosageForm: record["dosage_form"] as? String ?? "",
            drugType: record["drug_type"] as? String ?? ""
        )
        context.insert(rx)

        rx.medication = try findOrCreateMedication(
            name: rx.medicationName, doseMg: rx.doseMg, in: context
        )

        return rx
    }

    /// Import multiple records. Returns the count of added + updated.
    static func importRecords(
        _ records: [[String: Any]],
        into context: ModelContext
    ) throws -> Int {
        var count = 0
        for record in records {
            guard let _ = record["rx_number"] as? String else { continue }
            try importRecord(record, into: context)
            count += 1
        }
        return count
    }

    // MARK: - Private

    private static func update(
        _ rx: Prescription,
        from record: [String: Any],
        directions: String,
        refills: Int,
        context: ModelContext
    ) -> Prescription {
        if !directions.isEmpty && rx.directions.isEmpty {
            rx.directions = directions
        }
        if refills > 0 && rx.refillsRemaining == 0 {
            rx.refillsRemaining = refills
        }
        if rx.prescriberName.isEmpty {
            rx.prescriberName = record["prescriber_name"] as? String ?? ""
        }
        if rx.ndcCode.isEmpty {
            rx.ndcCode = record["ndc_code"] as? String ?? ""
        }
        if rx.rxStatus.isEmpty {
            rx.rxStatus = record["rx_status"] as? String ?? ""
        }
        // Always update cost/supply fields from newer data
        if let ds = record["days_supply"] as? Int {
            rx.daysSupply = ds
        }
        if let pp = record["patient_pay"] as? Double {
            rx.patientPay = pp
        }
        if let plp = record["plan_pay"] as? Double {
            rx.planPay = plp
        }
        let form = record["dosage_form"] as? String ?? ""
        if !form.isEmpty { rx.dosageForm = form }
        let dtype = record["drug_type"] as? String ?? ""
        if !dtype.isEmpty { rx.drugType = dtype }

        if rx.medication == nil || rx.medication?.isActive == false {
            rx.medication = try? findOrCreateMedication(
                name: rx.medicationName, doseMg: rx.doseMg, in: context
            )
        }
        return rx
    }

    private static func daysSupplyRunOut(dateFilled: Date, daysSupply: Int?) -> Date? {
        guard let ds = daysSupply, ds > 0 else { return nil }
        return Calendar.current.date(byAdding: .day, value: ds, to: dateFilled)
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let str = value as? String, !str.isEmpty else { return nil }
        return isoFormatter.date(from: str)
    }

    private static func findOrCreateMedication(
        name: String,
        doseMg: Double,
        in context: ModelContext
    ) throws -> MedicationDefinition? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let allMeds = try context.fetch(FetchDescriptor<MedicationDefinition>())
        let lowered = trimmed.lowercased()

        if let existing = allMeds.first(where: { $0.name.lowercased() == lowered }) {
            if !existing.isActive { existing.isActive = true }
            return existing
        }

        let newMed = MedicationDefinition(name: trimmed, defaultDoseMg: doseMg)
        context.insert(newMed)
        return newMed
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -only-testing:AnxietyWatchTests/PrescriptionImporterTests -quiet 2>&1 | tail -10`
Expected: All 5 tests pass

- [ ] **Step 5: Update SyncService to delegate to PrescriptionImporter**

In `SyncService.swift`, replace the body of `fetchPrescriptions(modelContext:)` (lines 137-252). Keep the HTTP request logic, replace the mapping/upsert logic:

```swift
    @discardableResult
    func fetchPrescriptions(modelContext: ModelContext) async throws -> Int {
        guard isConfigured else { throw SyncError.notConfigured }

        guard var urlComponents = URLComponents(string: serverURL) else {
            throw SyncError.invalidURL
        }
        urlComponents.path = "/api/data/prescriptions"
        guard let url = urlComponents.url else {
            throw SyncError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncError.noConnection
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw SyncError.serverError(httpResponse.statusCode, body)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let records = json?["prescriptions"] as? [[String: Any]] else {
            return 0
        }

        return try PrescriptionImporter.importRecords(records, into: modelContext)
    }
```

Also remove the `findOrCreateMedication` method from `SyncService` (lines 258-279) since it's now in `PrescriptionImporter`. But first check if it's used elsewhere:

Run: `grep -rn 'SyncService.findOrCreateMedication\|SyncService\.findOrCreate' AnxietyWatch/ --include='*.swift'`

If it's only used in `fetchPrescriptions`, remove it. If used elsewhere, keep it as a pass-through:

```swift
    @discardableResult
    static func findOrCreateMedication(
        name: String, doseMg: Double, in modelContext: ModelContext
    ) throws -> MedicationDefinition? {
        // Delegate to PrescriptionImporter — kept for backward compatibility
        try PrescriptionImporter.findOrCreateMedication(name: name, doseMg: doseMg, in: modelContext)
    }
```

Note: This requires making `PrescriptionImporter.findOrCreateMedication` internal instead of private. Change `private static func findOrCreateMedication` to `static func findOrCreateMedication` in `PrescriptionImporter.swift`.

- [ ] **Step 6: Run full test suite**

Run: `make test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Step 7: Commit**

```bash
git add AnxietyWatch/Services/PrescriptionImporter.swift AnxietyWatch/Services/SyncService.swift AnxietyWatchTests/PrescriptionImporterTests.swift
git commit -m "refactor: extract PrescriptionImporter from SyncService

Pure mapping logic (JSON → Prescription model) now lives in
PrescriptionImporter with full test coverage. SyncService handles
only HTTP transport. Supports all new CapRx fields (daysSupply,
cost, dosageForm, drugType)."
```

---

## Verification

After all tasks are complete:

- [ ] **Full iOS build**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator' -quiet 2>&1 | grep -E "error:|BUILD FAILED"`
Expected: No output

- [ ] **Full test suite**

Run: `make test 2>&1 | tail -10`
Expected: All tests pass

- [ ] **Server tests**

Run: `cd server && python -m pytest tests/ -v`
Expected: All tests pass

- [ ] **Server lint**

Run: `cd server && flake8 . --max-line-length=120 --exclude=__pycache__`
Expected: No errors

- [ ] **Verify new HealthKit types**

Run: `grep -n 'timeInDaylight\|physicalEffort' AnxietyWatch/Services/HealthKitManager.swift`
Expected: Both present in allReadTypes

- [ ] **Verify no remaining `try?` in SyncService fetch**

Run: `grep -n 'try?' AnxietyWatch/Services/SyncService.swift`
Expected: No results in fetchPrescriptions (other methods may still have them)

- [ ] **Verify baseline alerts wired**

Run: `grep -n 'sleepBaseline\|respiratoryBaseline' AnxietyWatch/Views/Dashboard/DashboardViewModel.swift`
Expected: Both present
