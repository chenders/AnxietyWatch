# Real-Time Health Data & Intraday Dashboard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add individual health sample caching with HKAnchoredObjectQuery, new HealthKit types for Apple Watch Series 8, and an intraday sparkline dashboard.

**Architecture:** Two-layer data model — `HealthSample` (7-day cache of individual readings) feeds the dashboard's latest-value and sparkline displays, while `HealthSnapshot` (daily aggregates, forever) continues to drive trends, reports, and baselines. `HKAnchoredObjectQuery` replaces `HKObserverQuery` for quantity types.

**Tech Stack:** Swift/SwiftUI, SwiftData, HealthKit, Swift Charts (sparklines)

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `AnxietyWatch/Models/HealthSample.swift` | SwiftData model for individual health readings |
| `AnxietyWatch/Utilities/SampleTypeConfig.swift` | Maps HealthKit type identifiers → canonical units, display names, thresholds |
| `AnxietyWatch/Utilities/TrendCalculator.swift` | Computes trend direction (rising/stable/dropping) from sample arrays |
| `AnxietyWatch/Views/Dashboard/SparklineView.swift` | SwiftUI sparkline chart with gradient fill and gap handling |
| `AnxietyWatch/Views/Dashboard/RecentBarsView.swift` | Last-N-readings bar chart for sparse metrics |
| `AnxietyWatch/Views/Dashboard/ProgressBarView.swift` | Goal progress bar for cumulative metrics |
| `AnxietyWatch/Views/Dashboard/LiveMetricCard.swift` | Side-by-side card: value stack + visualization |
| `AnxietyWatchTests/HealthSampleTests.swift` | HealthSample CRUD, pruning, query tests |
| `AnxietyWatchTests/TrendCalculatorTests.swift` | Trend direction logic tests |
| `AnxietyWatchTests/SparklineDataTests.swift` | Sparkline point conversion and gap detection tests |

### Modified Files

| File | Changes |
|------|---------|
| `AnxietyWatch/Models/HealthSnapshot.swift` | Add 9 new optional fields for new HealthKit types |
| `AnxietyWatch/Services/HealthKitManager.swift` | Add new types to `allReadTypes`, add `startAnchoredQueries()` method, reduce `startObserving()` to sleep only |
| `AnxietyWatch/Services/HealthDataCoordinator.swift` | Wire anchored queries, insert samples, add pruning |
| `AnxietyWatch/Services/SnapshotAggregator.swift` | Aggregate new HealthKit types into daily snapshot |
| `AnxietyWatch/App/AnxietyWatchApp.swift` | Register `HealthSample.self` in ModelContainer schema |
| `AnxietyWatch/Views/Dashboard/DashboardView.swift` | Replace MetricCard usage with LiveMetricCard, add HealthSample queries |

---

### Task 1: HealthSample Model

**Files:**
- Create: `AnxietyWatch/Models/HealthSample.swift`
- Create: `AnxietyWatchTests/HealthSampleTests.swift`

- [ ] **Step 1: Write the HealthSample model**

Create `AnxietyWatch/Models/HealthSample.swift`:

```swift
import Foundation
import SwiftData

/// Individual health reading from HealthKit. Cached for 7 days to power
/// dashboard sparklines and "latest value" displays. Daily HealthSnapshot
/// handles long-term trending.
@Model
final class HealthSample {
    var id: UUID
    var type: String
    var value: Double
    var timestamp: Date
    var source: String?

    init(type: String, value: Double, timestamp: Date, source: String? = nil) {
        self.id = UUID()
        self.type = type
        self.value = value
        self.timestamp = timestamp
        self.source = source
    }
}
```

- [ ] **Step 2: Write tests for HealthSample creation and querying**

Create `AnxietyWatchTests/HealthSampleTests.swift`:

```swift
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct HealthSampleTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([HealthSample.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("HealthSample stores type, value, timestamp, and source")
    func basicCreation() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = HealthSample(type: "HKQuantityTypeIdentifierHeartRate", value: 72.0, timestamp: ts, source: "Apple Watch")
        context.insert(sample)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<HealthSample>())
        #expect(fetched.count == 1)
        #expect(fetched[0].type == "HKQuantityTypeIdentifierHeartRate")
        #expect(fetched[0].value == 72.0)
        #expect(fetched[0].timestamp == ts)
        #expect(fetched[0].source == "Apple Watch")
    }

    @Test("Query samples by type and date range")
    func queryByTypeAndRange() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hrType = "HKQuantityTypeIdentifierHeartRate"
        let hrvType = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"

        // Insert 3 HR samples and 1 HRV sample
        for i in 0..<3 {
            let sample = HealthSample(
                type: hrType,
                value: 70 + Double(i),
                timestamp: now.addingTimeInterval(Double(i) * 600)
            )
            context.insert(sample)
        }
        context.insert(HealthSample(type: hrvType, value: 42, timestamp: now))
        try context.save()

        // Query HR samples only
        let descriptor = FetchDescriptor<HealthSample>(
            predicate: #Predicate<HealthSample> { $0.type == hrType },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let results = try context.fetch(descriptor)
        #expect(results.count == 3)
        #expect(results[0].value == 70)
        #expect(results[2].value == 72)
    }

    @Test("Prune deletes samples older than retention period")
    func pruneOldSamples() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let eightDaysAgo = now.addingTimeInterval(-8 * 86400)
        let sixDaysAgo = now.addingTimeInterval(-6 * 86400)

        context.insert(HealthSample(type: "hr", value: 70, timestamp: eightDaysAgo))
        context.insert(HealthSample(type: "hr", value: 72, timestamp: sixDaysAgo))
        context.insert(HealthSample(type: "hr", value: 75, timestamp: now))
        try context.save()

        // Prune anything older than 7 days from `now`
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let old = try context.fetch(FetchDescriptor<HealthSample>(
            predicate: #Predicate<HealthSample> { $0.timestamp < cutoff }
        ))
        for sample in old { context.delete(sample) }
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<HealthSample>())
        #expect(remaining.count == 2)
    }
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/HealthSampleTests`
Expected: All 3 tests PASS

- [ ] **Step 4: Commit**

```bash
git add AnxietyWatch/Models/HealthSample.swift AnxietyWatchTests/HealthSampleTests.swift
git commit -m "feat: add HealthSample SwiftData model with tests"
```

---

### Task 2: SampleTypeConfig

**Files:**
- Create: `AnxietyWatch/Utilities/SampleTypeConfig.swift`

- [ ] **Step 1: Create the type configuration mapping**

Create `AnxietyWatch/Utilities/SampleTypeConfig.swift`:

```swift
import HealthKit

/// Maps HealthKit quantity type identifiers to their canonical units, display names,
/// and trend thresholds. Used by the anchored query pipeline and dashboard cards.
struct SampleTypeConfig {
    let identifier: HKQuantityTypeIdentifier
    let unit: HKUnit
    let displayName: String
    let unitLabel: String
    /// Absolute change from 1h rolling average that counts as "rising" or "dropping"
    let trendThreshold: Double

    /// All types that get individual sample caching via HKAnchoredObjectQuery.
    static let anchoredTypes: [SampleTypeConfig] = [
        SampleTypeConfig(
            identifier: .heartRate,
            unit: .count().unitDivided(by: .minute()),
            displayName: "Heart Rate",
            unitLabel: "bpm",
            trendThreshold: 3
        ),
        SampleTypeConfig(
            identifier: .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            displayName: "HRV",
            unitLabel: "ms",
            trendThreshold: 5
        ),
        SampleTypeConfig(
            identifier: .oxygenSaturation,
            unit: .percent(),
            displayName: "Blood Oxygen",
            unitLabel: "%",
            trendThreshold: 0.01
        ),
        SampleTypeConfig(
            identifier: .respiratoryRate,
            unit: .count().unitDivided(by: .minute()),
            displayName: "Respiratory Rate",
            unitLabel: "breaths/min",
            trendThreshold: 1
        ),
        SampleTypeConfig(
            identifier: .restingHeartRate,
            unit: .count().unitDivided(by: .minute()),
            displayName: "Resting HR",
            unitLabel: "bpm",
            trendThreshold: 3
        ),
        SampleTypeConfig(
            identifier: .vo2Max,
            unit: HKUnit(from: "mL/kg*min"),
            displayName: "VO₂ Max",
            unitLabel: "mL/kg/min",
            trendThreshold: 1
        ),
        SampleTypeConfig(
            identifier: .walkingHeartRateAverage,
            unit: .count().unitDivided(by: .minute()),
            displayName: "Walking HR",
            unitLabel: "bpm",
            trendThreshold: 3
        ),
        SampleTypeConfig(
            identifier: .appleWalkingSteadiness,
            unit: .percent(),
            displayName: "Walking Steadiness",
            unitLabel: "%",
            trendThreshold: 0.02
        ),
        SampleTypeConfig(
            identifier: .bloodPressureSystolic,
            unit: .millimeterOfMercury(),
            displayName: "BP Systolic",
            unitLabel: "mmHg",
            trendThreshold: 5
        ),
        SampleTypeConfig(
            identifier: .bloodPressureDiastolic,
            unit: .millimeterOfMercury(),
            displayName: "BP Diastolic",
            unitLabel: "mmHg",
            trendThreshold: 3
        ),
        SampleTypeConfig(
            identifier: .bloodGlucose,
            unit: .gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)),
            displayName: "Blood Glucose",
            unitLabel: "mg/dL",
            trendThreshold: 10
        ),
        SampleTypeConfig(
            identifier: .environmentalAudioExposure,
            unit: .decibelAWeightedSoundPressureLevel(),
            displayName: "Env. Sound",
            unitLabel: "dBA",
            trendThreshold: 5
        ),
        SampleTypeConfig(
            identifier: .headphoneAudioExposure,
            unit: .decibelAWeightedSoundPressureLevel(),
            displayName: "Headphone Audio",
            unitLabel: "dBA",
            trendThreshold: 5
        ),
    ]

    /// Look up config by raw identifier string (as stored in HealthSample.type).
    static func config(for rawIdentifier: String) -> SampleTypeConfig? {
        anchoredTypes.first { $0.identifier.rawValue == rawIdentifier }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add AnxietyWatch/Utilities/SampleTypeConfig.swift
git commit -m "feat: add SampleTypeConfig mapping for HealthKit types"
```

---

### Task 3: TrendCalculator + Tests

**Files:**
- Create: `AnxietyWatch/Utilities/TrendCalculator.swift`
- Create: `AnxietyWatchTests/TrendCalculatorTests.swift`

- [ ] **Step 1: Write failing tests for trend direction**

Create `AnxietyWatchTests/TrendCalculatorTests.swift`:

```swift
import Foundation
import Testing

@testable import AnxietyWatch

struct TrendCalculatorTests {

    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSamples(_ values: [(minutesAgo: Int, value: Double)]) -> [HealthSample] {
        values.map { pair in
            HealthSample(
                type: "hr",
                value: pair.value,
                timestamp: baseTime.addingTimeInterval(-Double(pair.minutesAgo) * 60)
            )
        }
    }

    @Test("Returns nil with no samples")
    func noSamples() {
        let result = TrendCalculator.direction(samples: [], threshold: 3, now: baseTime)
        #expect(result == nil)
    }

    @Test("Returns nil with only one sample")
    func singleSample() {
        let samples = makeSamples([(0, 72)])
        let result = TrendCalculator.direction(samples: samples, threshold: 3, now: baseTime)
        #expect(result == nil)
    }

    @Test("Stable when latest is within threshold of 1h average")
    func stableWithinThreshold() {
        // 1h avg is ~71, latest is 72 — within ±3 threshold
        let samples = makeSamples([(0, 72), (10, 71), (20, 70), (40, 72)])
        let result = TrendCalculator.direction(samples: samples, threshold: 3, now: baseTime)
        #expect(result == .stable)
    }

    @Test("Rising when latest exceeds 1h average plus threshold")
    func risingAboveThreshold() {
        // 1h avg of older samples ≈ 70, latest is 80 — well above +3
        let samples = makeSamples([(0, 80), (10, 70), (20, 70), (40, 70)])
        let result = TrendCalculator.direction(samples: samples, threshold: 3, now: baseTime)
        #expect(result == .rising)
    }

    @Test("Dropping when latest is below 1h average minus threshold")
    func droppingBelowThreshold() {
        // 1h avg of older samples ≈ 80, latest is 70 — well below -3
        let samples = makeSamples([(0, 70), (10, 80), (20, 80), (40, 80)])
        let result = TrendCalculator.direction(samples: samples, threshold: 3, now: baseTime)
        #expect(result == .dropping)
    }

    @Test("Only considers samples within the last hour for average")
    func ignoresOlderThanOneHour() {
        // Old samples (>1h) at 90, recent ones at 70, latest at 72 — should be stable vs recent avg
        let samples = makeSamples([(0, 72), (10, 70), (20, 70), (90, 90), (120, 90)])
        let result = TrendCalculator.direction(samples: samples, threshold: 3, now: baseTime)
        #expect(result == .stable)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/TrendCalculatorTests`
Expected: FAIL — `TrendCalculator` does not exist

- [ ] **Step 3: Implement TrendCalculator**

Create `AnxietyWatch/Utilities/TrendCalculator.swift`:

```swift
import Foundation

/// Computes trend direction by comparing the latest reading to the
/// 1-hour rolling average of prior readings.
enum TrendCalculator {

    enum Direction: String {
        case rising
        case stable
        case dropping

        var symbol: String {
            switch self {
            case .rising: "↗"
            case .stable: "→"
            case .dropping: "↘"
            }
        }

        var label: String {
            switch self {
            case .rising: "rising"
            case .stable: "stable"
            case .dropping: "dropping"
            }
        }
    }

    /// Returns the trend direction for a set of samples.
    /// Samples must be sorted by timestamp (any order — we sort internally).
    /// Returns nil if fewer than 2 samples.
    static func direction(
        samples: [HealthSample],
        threshold: Double,
        now: Date = .now
    ) -> Direction? {
        guard samples.count >= 2 else { return nil }

        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let latest = sorted.last!

        // Compute average of samples in the last hour, excluding the latest
        let oneHourAgo = now.addingTimeInterval(-3600)
        let priorInWindow = sorted.dropLast().filter { $0.timestamp >= oneHourAgo }

        guard !priorInWindow.isEmpty else { return nil }

        let avg = priorInWindow.map(\.value).reduce(0, +) / Double(priorInWindow.count)

        if latest.value > avg + threshold {
            return .rising
        } else if latest.value < avg - threshold {
            return .dropping
        } else {
            return .stable
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/TrendCalculatorTests`
Expected: All 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Utilities/TrendCalculator.swift AnxietyWatchTests/TrendCalculatorTests.swift
git commit -m "feat: add TrendCalculator with rising/stable/dropping detection"
```

---

### Task 4: SparklineView + Data Preparation + Tests

**Files:**
- Create: `AnxietyWatch/Views/Dashboard/SparklineView.swift`
- Create: `AnxietyWatchTests/SparklineDataTests.swift`

- [ ] **Step 1: Write failing tests for sparkline data preparation**

Create `AnxietyWatchTests/SparklineDataTests.swift`:

```swift
import Foundation
import Testing

@testable import AnxietyWatch

struct SparklineDataTests {

    private let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

    private func makeSamples(_ minuteValuePairs: [(Int, Double)]) -> [HealthSample] {
        minuteValuePairs.map { (minutesSinceMidnight, value) in
            HealthSample(
                type: "hr",
                value: value,
                timestamp: midnight.addingTimeInterval(Double(minutesSinceMidnight) * 60)
            )
        }
    }

    @Test("Points are normalized to 0-1 on both axes")
    func normalizesPoints() {
        let samples = makeSamples([(0, 60), (720, 80)]) // midnight and noon
        let now = midnight.addingTimeInterval(720 * 60) // noon
        let result = SparklineData.points(from: samples, midnight: midnight, now: now)

        #expect(result.count == 2)
        // First point: x=0 (midnight), y=1 (min value at bottom)
        #expect(abs(result[0].x - 0.0) < 0.01)
        #expect(abs(result[0].y - 1.0) < 0.01) // 60 is min → y=1 (inverted)
        // Last point: x=1 (noon=now), y=0 (max value at top)
        #expect(abs(result[1].x - 1.0) < 0.01)
        #expect(abs(result[1].y - 0.0) < 0.01) // 80 is max → y=0 (inverted)
    }

    @Test("Returns empty for no samples")
    func emptyForNoSamples() {
        let result = SparklineData.points(from: [], midnight: midnight, now: midnight)
        #expect(result.isEmpty)
    }

    @Test("Single sample returns one point")
    func singleSample() {
        let samples = makeSamples([(360, 70)]) // 6 AM
        let now = midnight.addingTimeInterval(720 * 60)
        let result = SparklineData.points(from: samples, midnight: midnight, now: now)
        #expect(result.count == 1)
        #expect(abs(result[0].x - 0.5) < 0.01) // 6 AM is 50% of midnight-to-noon
    }

    @Test("Gap segments split at 2-hour gaps")
    func detectsGaps() {
        // Cluster at 1AM, then gap, then cluster at 6AM
        let samples = makeSamples([(60, 70), (70, 71), (360, 72), (370, 73)])
        let now = midnight.addingTimeInterval(720 * 60)
        let segments = SparklineData.segments(from: samples, midnight: midnight, now: now, gapThresholdMinutes: 120)
        #expect(segments.count == 2)
        #expect(segments[0].count == 2)
        #expect(segments[1].count == 2)
    }

    @Test("No gap when readings are close together")
    func noGapWhenClose() {
        let samples = makeSamples([(60, 70), (90, 71), (120, 72)])
        let now = midnight.addingTimeInterval(720 * 60)
        let segments = SparklineData.segments(from: samples, midnight: midnight, now: now, gapThresholdMinutes: 120)
        #expect(segments.count == 1)
        #expect(segments[0].count == 3)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/SparklineDataTests`
Expected: FAIL — `SparklineData` does not exist

- [ ] **Step 3: Implement SparklineData and SparklineView**

Create `AnxietyWatch/Views/Dashboard/SparklineView.swift`:

```swift
import SwiftUI

/// Normalized point for sparkline rendering. x and y are 0–1.
struct SparklinePoint {
    let x: Double
    let y: Double
}

/// Prepares HealthSample arrays into normalized points for sparkline rendering.
enum SparklineData {

    /// Convert samples into normalized 0–1 points.
    /// X: position between midnight and now. Y: inverted (0=max, 1=min) for
    /// natural chart rendering where higher values appear higher.
    static func points(
        from samples: [HealthSample],
        midnight: Date,
        now: Date
    ) -> [SparklinePoint] {
        guard !samples.isEmpty else { return [] }

        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let totalSeconds = now.timeIntervalSince(midnight)
        guard totalSeconds > 0 else { return [] }

        let values = sorted.map(\.value)
        let minVal = values.min()!
        let maxVal = values.max()!
        let range = maxVal - minVal

        return sorted.map { sample in
            let x = sample.timestamp.timeIntervalSince(midnight) / totalSeconds
            let y = range > 0 ? 1.0 - (sample.value - minVal) / range : 0.5
            return SparklinePoint(x: x.clamped(to: 0...1), y: y)
        }
    }

    /// Split samples into contiguous segments, breaking at gaps > threshold.
    /// Each segment is an array of normalized SparklinePoints.
    static func segments(
        from samples: [HealthSample],
        midnight: Date,
        now: Date,
        gapThresholdMinutes: Int = 120
    ) -> [[SparklinePoint]] {
        guard !samples.isEmpty else { return [] }

        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        let allPoints = points(from: sorted, midnight: midnight, now: now)

        let gapSeconds = Double(gapThresholdMinutes) * 60
        var segments: [[SparklinePoint]] = []
        var current: [SparklinePoint] = []

        for (i, point) in allPoints.enumerated() {
            if i > 0 {
                let timeDelta = sorted[i].timestamp.timeIntervalSince(sorted[i - 1].timestamp)
                if timeDelta > gapSeconds {
                    if !current.isEmpty { segments.append(current) }
                    current = []
                }
            }
            current.append(point)
        }
        if !current.isEmpty { segments.append(current) }

        return segments
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Intraday sparkline with gradient fill, gap handling, and current-value dot.
struct SparklineView: View {
    let segments: [[SparklinePoint]]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Canvas { context, size in
                for segment in segments {
                    guard segment.count >= 2 else {
                        // Single point: draw a dot
                        if let pt = segment.first {
                            let center = CGPoint(x: pt.x * w, y: pt.y * h)
                            let dot = Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4))
                            context.fill(dot, with: .color(color))
                        }
                        continue
                    }

                    // Line path
                    var linePath = Path()
                    linePath.move(to: CGPoint(x: segment[0].x * w, y: segment[0].y * h))
                    for pt in segment.dropFirst() {
                        linePath.addLine(to: CGPoint(x: pt.x * w, y: pt.y * h))
                    }
                    context.stroke(linePath, with: .color(color), lineWidth: 1.5)

                    // Fill path
                    var fillPath = linePath
                    fillPath.addLine(to: CGPoint(x: segment.last!.x * w, y: h))
                    fillPath.addLine(to: CGPoint(x: segment[0].x * w, y: h))
                    fillPath.closeSubpath()
                    context.fill(fillPath, with: .linearGradient(
                        Gradient(colors: [color.opacity(0.25), color.opacity(0)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: h)
                    ))
                }

                // Current value dot on last point of last segment
                if let lastSeg = segments.last, let lastPt = lastSeg.last {
                    let center = CGPoint(x: lastPt.x * w, y: lastPt.y * h)
                    let dot = Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
                    context.fill(dot, with: .color(color))
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests/SparklineDataTests`
Expected: All 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Views/Dashboard/SparklineView.swift AnxietyWatchTests/SparklineDataTests.swift
git commit -m "feat: add SparklineView with data normalization and gap detection"
```

---

### Task 5: ProgressBarView and RecentBarsView

**Files:**
- Create: `AnxietyWatch/Views/Dashboard/ProgressBarView.swift`
- Create: `AnxietyWatch/Views/Dashboard/RecentBarsView.swift`

- [ ] **Step 1: Create ProgressBarView for cumulative metrics**

Create `AnxietyWatch/Views/Dashboard/ProgressBarView.swift`:

```swift
import SwiftUI

/// Progress bar showing current value toward a goal.
/// Used for cumulative metrics like steps, calories, exercise minutes.
struct ProgressBarView: View {
    let current: Double
    let goal: Double
    let color: Color

    private var fraction: Double {
        guard goal > 0 else { return 0 }
        return min(current / goal, 1.0)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.gradient)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)

            HStack {
                Text("\(Int(fraction * 100))% of goal")
                Spacer()
                Text(goal.formatted(.number.precision(.fractionLength(0))))
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }
}
```

- [ ] **Step 2: Create RecentBarsView for sparse metrics**

Create `AnxietyWatch/Views/Dashboard/RecentBarsView.swift`:

```swift
import SwiftUI

/// Last-N-readings bar chart for sparse metrics like VO₂ Max.
/// Each bar represents one reading, opacity fades for older readings.
struct RecentBarsView: View {
    let values: [Double]
    let color: Color
    let maxBars: Int

    init(values: [Double], color: Color, maxBars: Int = 7) {
        self.values = values
        self.color = color
        self.maxBars = maxBars
    }

    var body: some View {
        let displayValues = Array(values.suffix(maxBars))
        let maxVal = displayValues.max() ?? 1
        let minVal = displayValues.min() ?? 0
        let range = max(maxVal - minVal, 1)

        VStack(alignment: .trailing, spacing: 2) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(displayValues.enumerated()), id: \.offset) { index, value in
                    let normalizedHeight = 0.3 + 0.7 * (value - minVal) / range
                    let opacity = 0.4 + 0.6 * Double(index) / Double(max(displayValues.count - 1, 1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(opacity))
                        .frame(width: 8, height: 40 * normalizedHeight)
                }
            }
            .frame(height: 40, alignment: .bottom)

            Text("last \(displayValues.count) readings")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Views/Dashboard/ProgressBarView.swift AnxietyWatch/Views/Dashboard/RecentBarsView.swift
git commit -m "feat: add ProgressBarView and RecentBarsView for dashboard cards"
```

---

### Task 6: LiveMetricCard

**Files:**
- Create: `AnxietyWatch/Views/Dashboard/LiveMetricCard.swift`

- [ ] **Step 1: Create the side-by-side LiveMetricCard**

Create `AnxietyWatch/Views/Dashboard/LiveMetricCard.swift`:

```swift
import SwiftUI

/// Visualization type for the right side of a LiveMetricCard.
enum MetricVisualization {
    case sparkline(segments: [[SparklinePoint]], color: Color)
    case progressBar(current: Double, goal: Double, color: Color)
    case recentBars(values: [Double], color: Color)
    case sleepStages(deep: Int, rem: Int, core: Int, awake: Int)
    case none
}

/// Side-by-side metric card: value stack on the left, visualization on the right.
struct LiveMetricCard: View {
    let title: String
    let value: String
    let unitLabel: String
    let trend: TrendCalculator.Direction?
    let freshness: String
    let color: Color
    let visualization: MetricVisualization

    var body: some View {
        HStack(spacing: 12) {
            // Left: value stack
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.title2.bold())
                        .foregroundStyle(color)
                    Text(unitLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let trend {
                    Text("\(trend.symbol) \(trend.label)")
                        .font(.caption2)
                        .foregroundStyle(trendColor(trend))
                }
                Text(freshness)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            // Right: visualization
            visualizationView
                .frame(maxWidth: .infinity, maxHeight: 50)
        }
        .padding()
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private var visualizationView: some View {
        switch visualization {
        case .sparkline(let segments, let sparkColor):
            VStack(spacing: 2) {
                SparklineView(segments: segments, color: sparkColor)
                HStack {
                    Text("12a")
                    Spacer()
                    Text("6a")
                    Spacer()
                    Text("12p")
                    Spacer()
                    Text("Now")
                }
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
            }
        case .progressBar(let current, let goal, let barColor):
            ProgressBarView(current: current, goal: goal, color: barColor)
        case .recentBars(let values, let barColor):
            RecentBarsView(values: values, color: barColor)
        case .sleepStages(let deep, let rem, let core, let awake):
            SleepStagesView(deep: deep, rem: rem, core: core, awake: awake)
        case .none:
            EmptyView()
        }
    }

    private func trendColor(_ trend: TrendCalculator.Direction) -> Color {
        switch trend {
        case .rising: .orange
        case .stable: .green
        case .dropping: .blue
        }
    }
}

/// Compact sleep stage breakdown bar with legend.
struct SleepStagesView: View {
    let deep: Int
    let rem: Int
    let core: Int
    let awake: Int

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let total = Double(deep + rem + core + awake)
                guard total > 0 else { return }
                HStack(spacing: 0) {
                    stageBar(minutes: deep, total: total, color: .indigo, width: geo.size.width)
                    stageBar(minutes: rem, total: total, color: .purple, width: geo.size.width)
                    stageBar(minutes: core, total: total, color: .cyan, width: geo.size.width)
                    stageBar(minutes: awake, total: total, color: .gray, width: geo.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)

            HStack(spacing: 8) {
                if deep > 0 { stageLabel("Deep", deep, .indigo) }
                if rem > 0 { stageLabel("REM", rem, .purple) }
                if core > 0 { stageLabel("Core", core, .cyan) }
            }
            .font(.system(size: 8))
        }
    }

    private func stageBar(minutes: Int, total: Double, color: Color, width: CGFloat) -> some View {
        color.frame(width: width * Double(minutes) / total)
    }

    private func stageLabel(_ name: String, _ minutes: Int, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(name) \(minutes)m").foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add AnxietyWatch/Views/Dashboard/LiveMetricCard.swift
git commit -m "feat: add LiveMetricCard with sparkline, progress, and bars visualizations"
```

---

### Task 7: HealthSnapshot New Fields

**Files:**
- Modify: `AnxietyWatch/Models/HealthSnapshot.swift`

- [ ] **Step 1: Add new fields to HealthSnapshot**

In `AnxietyWatch/Models/HealthSnapshot.swift`, add after the `bloodGlucoseAvg` field (after line 43):

```swift
    // Cardiorespiratory fitness
    var vo2Max: Double?

    // Walking metrics
    var walkingHeartRateAvg: Double?
    var walkingSteadiness: Double?

    // Atrial fibrillation
    var atrialFibrillationBurden: Double?

    // Audio exposure
    var headphoneAudioExposure: Double?

    // Gait metrics
    var walkingSpeed: Double?
    var walkingStepLength: Double?
    var walkingDoubleSupportPct: Double?
    var walkingAsymmetryPct: Double?
```

- [ ] **Step 2: Commit**

```bash
git add AnxietyWatch/Models/HealthSnapshot.swift
git commit -m "feat: add HealthSnapshot fields for new HealthKit types"
```

---

### Task 8: Expand HealthKitManager Authorization + Anchored Queries

**Files:**
- Modify: `AnxietyWatch/Services/HealthKitManager.swift`

- [ ] **Step 1: Add new types to allReadTypes**

In `HealthKitManager.swift`, replace the `quantityIdentifiers` array in `allReadTypes` (lines 16–30) with:

```swift
        let quantityIdentifiers: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN,       // HRV (SDNN, ms)
            .heartRate,                       // Instantaneous HR (bpm)
            .restingHeartRate,                // Resting HR (bpm)
            .respiratoryRate,                 // Breaths per minute (sleep)
            .oxygenSaturation,                // SpO2 (%)
            .appleSleepingWristTemperature,   // Wrist temp deviation during sleep (°C)
            .stepCount,                       // Daily steps
            .activeEnergyBurned,              // Active calories (kcal)
            .appleExerciseTime,               // Exercise minutes
            .environmentalAudioExposure,      // Ambient noise (dBA)
            .bloodPressureSystolic,           // Systolic BP (mmHg)
            .bloodPressureDiastolic,          // Diastolic BP (mmHg)
            .bloodGlucose,                    // Blood glucose (mg/dL)
            // New: Apple Watch Series 8 types
            .vo2Max,                          // Cardiorespiratory fitness (mL/kg/min)
            .walkingHeartRateAverage,         // Average HR during walking (bpm)
            .headphoneAudioExposure,          // Headphone volume (dBA)
            .appleWalkingSteadiness,          // Balance/fall risk (0–1)
            .atrialFibrillationBurden,        // % time in AFib (0–1)
            .walkingSpeed,                    // Gait pace (m/s)
            .walkingStepLength,               // Stride length (m)
            .walkingDoubleSupportPercentage,  // Both feet on ground (0–1)
            .walkingAsymmetryPercentage,      // Left/right asymmetry (0–1)
        ]
```

- [ ] **Step 2: Reduce observedSampleTypes to sleep only**

Replace the `observedSampleTypes` property (lines 210–219) with:

```swift
    /// Sleep analysis stays on HKObserverQuery since it's a category type.
    /// All quantity types have moved to HKAnchoredObjectQuery.
    private var observedSampleTypes: [HKSampleType] {
        [HKCategoryType(.sleepAnalysis)]
    }
```

- [ ] **Step 3: Add startAnchoredQueries method**

Add the following after the `startObserving` method (after line 247):

```swift
    // MARK: - Anchored Object Queries

    private var activeAnchoredQueries: [HKAnchoredObjectQuery] = []

    /// UserDefaults key prefix for persisting query anchors per type.
    private static let anchorKeyPrefix = "HKAnchor_"

    /// Start anchored object queries for all types in SampleTypeConfig.anchoredTypes.
    /// Calls onNewSamples with an array of (type raw identifier, value, timestamp, source)
    /// for each batch of new samples received.
    func startAnchoredQueries(
        onNewSamples: @Sendable @escaping ([(type: String, value: Double, timestamp: Date, source: String?)]) -> Void
    ) {
        guard isAvailable else { return }

        for query in activeAnchoredQueries {
            healthStore.stop(query)
        }
        activeAnchoredQueries.removeAll()

        for config in SampleTypeConfig.anchoredTypes {
            let sampleType = HKQuantityType(config.identifier)
            let anchor = loadAnchor(for: config.identifier.rawValue)

            let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, (any Error)?) -> Void = {
                [weak self] query, newSamples, _, newAnchor, error in
                guard error == nil, let samples = newSamples as? [HKQuantitySample] else { return }

                if let newAnchor {
                    Task { await self?.saveAnchor(newAnchor, for: config.identifier.rawValue) }
                }

                guard !samples.isEmpty else { return }

                let converted: [(type: String, value: Double, timestamp: Date, source: String?)] = samples.map { sample in
                    let value = sample.quantity.doubleValue(for: config.unit)
                    let source = sample.sourceRevision.source.name
                    return (config.identifier.rawValue, value, sample.endDate, source)
                }
                onNewSamples(converted)
            }

            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit,
                resultsHandler: handler
            )
            query.updateHandler = handler
            healthStore.execute(query)
            activeAnchoredQueries.append(query)

            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { _, _ in }
        }
    }

    private func loadAnchor(for typeKey: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: Self.anchorKeyPrefix + typeKey) else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor, for typeKey: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.anchorKeyPrefix + typeKey)
    }
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/HealthKitManager.swift
git commit -m "feat: expand HealthKit types and add HKAnchoredObjectQuery support"
```

---

### Task 9: SnapshotAggregator New Fields

**Files:**
- Modify: `AnxietyWatch/Services/SnapshotAggregator.swift`

- [ ] **Step 1: Add aggregation for new HealthKit types**

In `SnapshotAggregator.swift`, add after the blood glucose aggregation (after line 119, before `try modelContext.save()`):

```swift
        // VO2 Max — use most recent reading for the day since it's infrequently updated
        if let vo2 = try await healthKit.mostRecentQuantity(.vo2Max, unit: HKUnit(from: "mL/kg*min")) {
            if vo2.date >= start && vo2.date < end {
                snapshot.vo2Max = vo2.value
            }
        }

        // Walking heart rate average
        snapshot.walkingHeartRateAvg = try await healthKit.averageQuantity(
            .walkingHeartRateAverage,
            unit: .count().unitDivided(by: .minute()),
            start: start, end: end
        )

        // Walking steadiness
        if let steadiness = try await healthKit.mostRecentQuantity(.appleWalkingSteadiness, unit: .percent()) {
            if steadiness.date >= start && steadiness.date < end {
                snapshot.walkingSteadiness = steadiness.value
            }
        }

        // Atrial fibrillation burden
        if let afib = try await healthKit.mostRecentQuantity(.atrialFibrillationBurden, unit: .percent()) {
            if afib.date >= start && afib.date < end {
                snapshot.atrialFibrillationBurden = afib.value
            }
        }

        // Headphone audio exposure
        snapshot.headphoneAudioExposure = try await healthKit.averageQuantity(
            .headphoneAudioExposure,
            unit: .decibelAWeightedSoundPressureLevel(),
            start: start, end: end
        )

        // Gait metrics
        snapshot.walkingSpeed = try await healthKit.averageQuantity(
            .walkingSpeed,
            unit: HKUnit.meter().unitDivided(by: .second()),
            start: start, end: end
        )
        snapshot.walkingStepLength = try await healthKit.averageQuantity(
            .walkingStepLength,
            unit: .meter(),
            start: start, end: end
        )
        snapshot.walkingDoubleSupportPct = try await healthKit.averageQuantity(
            .walkingDoubleSupportPercentage,
            unit: .percent(),
            start: start, end: end
        )
        snapshot.walkingAsymmetryPct = try await healthKit.averageQuantity(
            .walkingAsymmetryPercentage,
            unit: .percent(),
            start: start, end: end
        )
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/Services/SnapshotAggregator.swift
git commit -m "feat: aggregate new HealthKit types in SnapshotAggregator"
```

---

### Task 10: HealthDataCoordinator — Wire Anchored Queries + Pruning

**Files:**
- Modify: `AnxietyWatch/Services/HealthDataCoordinator.swift`

- [ ] **Step 1: Add sample insertion and pruning methods**

In `HealthDataCoordinator.swift`, add a new section before the `// MARK: - Barometer Persistence` line:

```swift
    // MARK: - Sample Cache

    /// Insert new HealthKit samples into the HealthSample cache.
    private func insertSamples(_ samples: [(type: String, value: Double, timestamp: Date, source: String?)]) {
        let context = ModelContext(modelContainer)
        for sample in samples {
            context.insert(HealthSample(
                type: sample.type,
                value: sample.value,
                timestamp: sample.timestamp,
                source: sample.source
            ))
        }
        try? context.save()
    }

    /// Delete HealthSample rows older than 7 days.
    func pruneOldSamples() {
        let context = ModelContext(modelContainer)
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        let old = try? context.fetch(FetchDescriptor<HealthSample>(
            predicate: #Predicate<HealthSample> { $0.timestamp < cutoff }
        ))
        for sample in old ?? [] {
            context.delete(sample)
        }
        try? context.save()
    }
```

- [ ] **Step 2: Update startObserving to launch anchored queries**

Replace the `startObserving()` method (lines 144–153) with:

```swift
    private func startObserving() async {
        guard !hasSetupObservers else { return }
        hasSetupObservers = true

        // Sleep analysis stays on observer query (category type)
        await HealthKitManager.shared.startObserving { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }

        // All quantity types use anchored queries for individual sample caching
        await HealthKitManager.shared.startAnchoredQueries { [weak self] newSamples in
            Task { @MainActor in
                self?.insertSamples(newSamples)
                self?.scheduleRefresh()
            }
        }
    }
```

- [ ] **Step 3: Add pruning to setupIfNeeded**

In `setupIfNeeded()` (line 25), add `pruneOldSamples()` as the first call:

```swift
    func setupIfNeeded() async {
        pruneOldSamples()
        startBarometerPersistence()
        await backfillIfNeeded()
        await fillGaps()
        await importClinicalRecordsIfNeeded()
        await startObserving()
    }
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add AnxietyWatch/Services/HealthDataCoordinator.swift
git commit -m "feat: wire anchored queries and sample pruning in HealthDataCoordinator"
```

---

### Task 11: Register HealthSample in ModelContainer

**Files:**
- Modify: `AnxietyWatch/App/AnxietyWatchApp.swift`

- [ ] **Step 1: Add HealthSample to the schema**

In `AnxietyWatchApp.swift`, add `HealthSample.self` to the schema array (line 9):

```swift
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
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AnxietyWatch/App/AnxietyWatchApp.swift
git commit -m "feat: register HealthSample in app ModelContainer"
```

---

### Task 12: Dashboard Integration

**Files:**
- Modify: `AnxietyWatch/Views/Dashboard/DashboardView.swift`

This is the largest task — the dashboard is rewritten to use `LiveMetricCard` with `HealthSample` queries for sparklines and latest readings, while keeping the existing `HealthSnapshot` queries for baselines and daily aggregates.

- [ ] **Step 1: Add HealthSample query and helper methods**

At the top of `DashboardView`, add the HealthSample query alongside the existing queries (after line 16):

```swift
    @Query(sort: \HealthSample.timestamp, order: .reverse)
    private var recentSamples: [HealthSample]
```

Add these helper methods in the `// MARK: - Helpers` section (replacing or adding alongside existing helpers):

```swift
    /// Get today's samples for a given HealthKit type identifier.
    private func todaySamples(for typeRawValue: String) -> [HealthSample] {
        let midnight = Calendar.current.startOfDay(for: .now)
        return recentSamples.filter { $0.type == typeRawValue && $0.timestamp >= midnight }
    }

    /// Get the most recent sample for a given type (any day in the cache).
    private func latestSample(for typeRawValue: String) -> HealthSample? {
        recentSamples.first { $0.type == typeRawValue }
    }

    /// Get the last N values for a given type (for RecentBarsView).
    private func recentValues(for typeRawValue: String, count: Int = 7) -> [Double] {
        let samples = recentSamples
            .filter { $0.type == typeRawValue }
            .prefix(count)
        return samples.reversed().map(\.value)
    }

    /// Build sparkline segments for a given type using today's samples.
    private func sparklineSegments(for typeRawValue: String) -> [[SparklinePoint]] {
        let samples = todaySamples(for: typeRawValue)
        let midnight = Calendar.current.startOfDay(for: .now)
        return SparklineData.segments(from: samples, midnight: midnight, now: .now)
    }

    /// Freshness label for a sample timestamp.
    private func freshnessLabel(_ date: Date) -> String {
        let midnight = Calendar.current.startOfDay(for: .now)
        if date >= midnight {
            return date.formatted(.relative(presentation: .named))
        }
        // Check if it's from last night (sleep metrics)
        let yesterdayMidnight = Calendar.current.date(byAdding: .day, value: -1, to: midnight)!
        if date >= yesterdayMidnight {
            return "last night"
        }
        return date.formatted(.relative(presentation: .named))
    }

    /// Compute trend direction for a given type.
    private func trend(for typeRawValue: String) -> TrendCalculator.Direction? {
        let config = SampleTypeConfig.config(for: typeRawValue)
        let samples = todaySamples(for: typeRawValue)
        return TrendCalculator.direction(
            samples: samples,
            threshold: config?.trendThreshold ?? 3
        )
    }
```

- [ ] **Step 2: Replace the healthSection with LiveMetricCards**

Replace the `healthSection` method (lines 124–191) with:

```swift
    @ViewBuilder
    private func healthSection(
        hrvBaseline: BaselineCalculator.BaselineResult?,
        rhrBaseline: BaselineCalculator.BaselineResult?
    ) -> some View {
        // Heart Rate — sparkline
        let hrType = HKQuantityTypeIdentifier.heartRate.rawValue
        if let latest = latestSample(for: hrType) {
            LiveMetricCard(
                title: "Heart Rate",
                value: String(format: "%.0f", latest.value),
                unitLabel: "bpm",
                trend: trend(for: hrType),
                freshness: freshnessLabel(latest.timestamp),
                color: baselineColor(value: latest.value, baseline: rhrBaseline, higherIsBetter: false),
                visualization: .sparkline(
                    segments: sparklineSegments(for: hrType),
                    color: .red
                )
            )
        }

        // HRV — sparkline
        let hrvType = HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue
        if let latest = latestSample(for: hrvType) {
            LiveMetricCard(
                title: "HRV",
                value: String(format: "%.0f", latest.value),
                unitLabel: "ms",
                trend: trend(for: hrvType),
                freshness: freshnessLabel(latest.timestamp),
                color: baselineColor(value: latest.value, baseline: hrvBaseline, higherIsBetter: true),
                visualization: .sparkline(
                    segments: sparklineSegments(for: hrvType),
                    color: .blue
                )
            )
        }

        // Resting HR — sparkline (usually sparse, 1/day)
        let rhrType = HKQuantityTypeIdentifier.restingHeartRate.rawValue
        if let latest = latestSample(for: rhrType) {
            LiveMetricCard(
                title: "Resting HR",
                value: String(format: "%.0f", latest.value),
                unitLabel: "bpm",
                trend: trend(for: rhrType),
                freshness: freshnessLabel(latest.timestamp),
                color: baselineColor(value: latest.value, baseline: rhrBaseline, higherIsBetter: false),
                visualization: .recentBars(values: recentValues(for: rhrType), color: .red)
            )
        }

        // SpO2 — sparkline (sleep cluster)
        let spo2Type = HKQuantityTypeIdentifier.oxygenSaturation.rawValue
        if let latest = latestSample(for: spo2Type) {
            LiveMetricCard(
                title: "Blood Oxygen",
                value: String(format: "%.0f", latest.value * 100),
                unitLabel: "%",
                trend: trend(for: spo2Type),
                freshness: freshnessLabel(latest.timestamp),
                color: .green,
                visualization: .sparkline(
                    segments: sparklineSegments(for: spo2Type),
                    color: .green
                )
            )
        }

        // VO2 Max — recent bars
        let vo2Type = HKQuantityTypeIdentifier.vo2Max.rawValue
        let vo2Values = recentValues(for: vo2Type)
        if let latest = latestSample(for: vo2Type) {
            LiveMetricCard(
                title: "VO₂ Max",
                value: String(format: "%.1f", latest.value),
                unitLabel: "mL/kg/min",
                trend: trend(for: vo2Type),
                freshness: freshnessLabel(latest.timestamp),
                color: .indigo,
                visualization: .recentBars(values: vo2Values, color: .indigo)
            )
        }

        // Walking HR — recent bars
        let walkHRType = HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue
        let walkHRValues = recentValues(for: walkHRType)
        if let latest = latestSample(for: walkHRType) {
            LiveMetricCard(
                title: "Walking HR",
                value: String(format: "%.0f", latest.value),
                unitLabel: "bpm",
                trend: trend(for: walkHRType),
                freshness: freshnessLabel(latest.timestamp),
                color: .orange,
                visualization: .recentBars(values: walkHRValues, color: .orange)
            )
        }

        // Sleep — stage breakdown (from HealthSnapshot, not sample cache)
        if let (snapshot, isToday) = lastSnapshotWith(\.sleepDurationMin) {
            let sleep = snapshot.sleepDurationMin!
            let hours = sleep / 60
            let mins = sleep % 60
            LiveMetricCard(
                title: "Sleep",
                value: "\(hours)h \(mins)m",
                unitLabel: "",
                trend: nil,
                freshness: isToday ? "last night" : staleLabel(snapshot.date),
                color: isToday ? sleepColor(minutes: sleep) : .secondary,
                visualization: .sleepStages(
                    deep: snapshot.sleepDeepMin ?? 0,
                    rem: snapshot.sleepREMMin ?? 0,
                    core: snapshot.sleepCoreMin ?? 0,
                    awake: snapshot.sleepAwakeMin ?? 0
                )
            )
        }

        // Steps — progress bar (from HealthSnapshot)
        if let (snapshot, isToday) = lastSnapshotWith(\.steps) {
            let steps = snapshot.steps!
            LiveMetricCard(
                title: "Steps",
                value: steps.formatted(),
                unitLabel: "",
                trend: nil,
                freshness: isToday ? "today" : staleLabel(snapshot.date),
                color: isToday ? stepsColor(steps) : .secondary,
                visualization: .progressBar(current: Double(steps), goal: 8000, color: stepsColor(steps))
            )
        }

        // Active Calories — progress bar (from HealthSnapshot)
        if let (snapshot, isToday) = lastSnapshotWith(\.activeCalories) {
            let cals = snapshot.activeCalories!
            LiveMetricCard(
                title: "Active Calories",
                value: String(format: "%.0f", cals),
                unitLabel: "kcal",
                trend: nil,
                freshness: isToday ? "today" : staleLabel(snapshot.date),
                color: isToday ? .orange : .secondary,
                visualization: .progressBar(current: cals, goal: 500, color: .orange)
            )
        }

        // Exercise — progress bar (from HealthSnapshot)
        if let (snapshot, isToday) = lastSnapshotWith(\.exerciseMinutes) {
            let mins = snapshot.exerciseMinutes!
            LiveMetricCard(
                title: "Exercise",
                value: "\(mins)",
                unitLabel: "min",
                trend: nil,
                freshness: isToday ? "today" : staleLabel(snapshot.date),
                color: isToday ? .green : .secondary,
                visualization: .progressBar(current: Double(mins), goal: 30, color: .green)
            )
        }

        // Environmental Sound — sparkline
        let envType = HKQuantityTypeIdentifier.environmentalAudioExposure.rawValue
        if let latest = latestSample(for: envType) {
            LiveMetricCard(
                title: "Env. Sound",
                value: String(format: "%.0f", latest.value),
                unitLabel: "dBA",
                trend: trend(for: envType),
                freshness: freshnessLabel(latest.timestamp),
                color: .gray,
                visualization: .sparkline(
                    segments: sparklineSegments(for: envType),
                    color: .gray
                )
            )
        }

        // Headphone Audio — sparkline
        let headType = HKQuantityTypeIdentifier.headphoneAudioExposure.rawValue
        if let latest = latestSample(for: headType) {
            LiveMetricCard(
                title: "Headphone Audio",
                value: String(format: "%.0f", latest.value),
                unitLabel: "dBA",
                trend: trend(for: headType),
                freshness: freshnessLabel(latest.timestamp),
                color: .teal,
                visualization: .sparkline(
                    segments: sparklineSegments(for: headType),
                    color: .teal
                )
            )
        }

        // Respiratory Rate — sparkline (sleep cluster)
        let rrType = HKQuantityTypeIdentifier.respiratoryRate.rawValue
        if let latest = latestSample(for: rrType) {
            LiveMetricCard(
                title: "Respiratory Rate",
                value: String(format: "%.0f", latest.value),
                unitLabel: "breaths/min",
                trend: trend(for: rrType),
                freshness: freshnessLabel(latest.timestamp),
                color: .mint,
                visualization: .sparkline(
                    segments: sparklineSegments(for: rrType),
                    color: .mint
                )
            )
        }

        // Walking Steadiness — recent bars
        let steadyType = HKQuantityTypeIdentifier.appleWalkingSteadiness.rawValue
        let steadyValues = recentValues(for: steadyType)
        if let latest = latestSample(for: steadyType) {
            LiveMetricCard(
                title: "Walking Steadiness",
                value: String(format: "%.0f", latest.value * 100),
                unitLabel: "%",
                trend: trend(for: steadyType),
                freshness: freshnessLabel(latest.timestamp),
                color: .cyan,
                visualization: .recentBars(values: steadyValues, color: .cyan)
            )
        }

        // AFib Burden — from daily snapshot (single value per day)
        if let (snapshot, isToday) = lastSnapshotWith(\.atrialFibrillationBurden) {
            let burden = snapshot.atrialFibrillationBurden!
            LiveMetricCard(
                title: "AFib Burden",
                value: String(format: "%.1f", burden * 100),
                unitLabel: "%",
                trend: nil,
                freshness: isToday ? "today" : staleLabel(snapshot.date),
                color: burden < 0.01 ? .green : .orange,
                visualization: .none
            )
        }

        // Blood Pressure — latest value only
        let bpSysType = HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue
        let bpDiaType = HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue
        if let sys = latestSample(for: bpSysType),
           let dia = latestSample(for: bpDiaType) {
            LiveMetricCard(
                title: "Blood Pressure",
                value: "\(String(format: "%.0f", sys.value))/\(String(format: "%.0f", dia.value))",
                unitLabel: "mmHg",
                trend: nil,
                freshness: freshnessLabel(sys.timestamp),
                color: .pink,
                visualization: .none
            )
        }

        // Blood Glucose — sparkline if dense, value only if sparse
        let bgType = HKQuantityTypeIdentifier.bloodGlucose.rawValue
        if let latest = latestSample(for: bgType) {
            let todayCount = todaySamples(for: bgType).count
            LiveMetricCard(
                title: "Blood Glucose",
                value: String(format: "%.0f", latest.value),
                unitLabel: "mg/dL",
                trend: trend(for: bgType),
                freshness: freshnessLabel(latest.timestamp),
                color: .purple,
                visualization: todayCount >= 3
                    ? .sparkline(segments: sparklineSegments(for: bgType), color: .purple)
                    : .none
            )
        }
    }
```

- [ ] **Step 3: Add HealthKit import**

At the top of `DashboardView.swift`, add:

```swift
import HealthKit
```

This is needed for `HKQuantityTypeIdentifier` references in the health section.

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run all existing tests to check for regressions**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add AnxietyWatch/Views/Dashboard/DashboardView.swift
git commit -m "feat: integrate LiveMetricCard with sparklines and latest readings on dashboard"
```

---

### Task 13: Final Build Verification + Full Test Suite

- [ ] **Step 1: Run full build**

Run: `xcodebuild build -scheme AnxietyWatch -destination 'generic/platform=iOS Simulator'`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run full test suite**

Run: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests`
Expected: All tests PASS

- [ ] **Step 3: Run watchOS build to verify no breakage**

Run: `xcodebuild build -scheme "AnxietyWatch Watch App" -destination 'generic/platform=watchOS Simulator'`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Verify on device**

Manual testing checklist:
- Open dashboard — verify new metric cards appear with latest readings
- Check freshness timestamps are accurate ("3 min ago", "last night", etc.)
- Verify sparklines render for HR, HRV, SpO2, environmental sound
- Verify progress bars for steps, calories, exercise
- Verify recent bars for VO₂ Max, walking HR
- Verify sleep stage breakdown bar
- Confirm existing trends, reports, and export still work

---

## Follow-Up (Not in This Plan)

- **Barometric pressure sparkline:** The spec calls for an intraday sparkline, but barometric readings come from `BarometricReading` (CMAltimeter, SwiftData), not the HealthKit `HealthSample` pipeline. Adding this requires a separate `@Query` on `BarometricReading` and converting to `SparklinePoint` — a small standalone task.
- **Dashboard card ordering/customization:** Currently all cards are shown in a fixed order. Users may want to reorder or hide metrics.
- **Watch-side HealthKit queries:** The Watch app could query HealthKit directly for truly fresh readings instead of waiting for phone sync.
