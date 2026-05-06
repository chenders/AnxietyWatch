import Foundation
import HealthKit
import SwiftData
import Testing

@testable import AnxietyWatch

@Suite("SnapshotAggregator dataQuality JSON")
struct SnapshotAggregatorReliabilityTests {

    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
    }()

    /// Day-window start that the aggregator will compute (matches its
    /// `Calendar.current.startOfDay(for: referenceDate)` call).
    private var dayStart: Date { Calendar.current.startOfDay(for: referenceDate) }
    /// Overnight window start (noon previous day, in `Calendar.current`).
    private var overnightStart: Date {
        let cal = Calendar.current
        let prevDay = cal.date(byAdding: .day, value: -1, to: dayStart)!
        return cal.date(byAdding: .hour, value: 12, to: cal.startOfDay(for: prevDay))!
    }

    /// Decode `dataQuality` JSON to a Swift dictionary for inspection in tests.
    private func decodeDataQuality(_ snapshot: HealthSnapshot) throws -> [String: [String: Any]] {
        let json = try #require(snapshot.dataQuality)
        let data = try #require(json.data(using: .utf8))
        let any = try JSONSerialization.jsonObject(with: data, options: [])
        let dict = any as? [String: [String: Any]] ?? [:]
        return dict
    }

    /// Insert N glucose samples spanning `coverageHours`, each from the given source.
    @discardableResult
    private func insertGlucoseSamples(
        context: ModelContext,
        count: Int,
        coverageHours: Double,
        sourceBundleID: String,
        sourceName: String,
        anchor: Date
    ) -> [QuantityHealthSample] {
        var inserted: [QuantityHealthSample] = []
        let stepSeconds = count > 1 ? (coverageHours * 3600) / Double(count - 1) : 0
        for i in 0..<count {
            let ts = anchor.addingTimeInterval(Double(i) * stepSeconds)
            let s = QuantityHealthSample(
                timestamp: ts,
                metricType: HKQuantityTypeIdentifier.bloodGlucose.rawValue,
                value: 110,
                unitString: "mg/dL",
                sourceBundleID: sourceBundleID,
                sourceName: sourceName
            )
            context.insert(s)
            inserted.append(s)
        }
        return inserted
    }

    @discardableResult
    private func insertSpO2Samples(
        context: ModelContext,
        count: Int,
        coverageHours: Double,
        sourceBundleID: String,
        sourceName: String,
        anchor: Date
    ) -> [QuantityHealthSample] {
        var inserted: [QuantityHealthSample] = []
        let stepSeconds = count > 1 ? (coverageHours * 3600) / Double(count - 1) : 0
        for i in 0..<count {
            let ts = anchor.addingTimeInterval(Double(i) * stepSeconds)
            let s = QuantityHealthSample(
                timestamp: ts,
                metricType: HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
                value: 0.96,
                unitString: "%",
                sourceBundleID: sourceBundleID,
                sourceName: sourceName
            )
            context.insert(s)
            inserted.append(s)
        }
        return inserted
    }

    // MARK: - Glucose

    @Test("Glucose reliability high: 250 Stelo samples spanning 20h")
    func glucoseHigh() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // Anchor 1h into the day; 20h spread fits cleanly within the 24h window
        // the aggregator computes via `Calendar.current.startOfDay`.
        let anchor = dayStart.addingTimeInterval(3600)
        insertGlucoseSamples(context: context, count: 250, coverageHours: 20,
                             sourceBundleID: "com.dexcom.stelo", sourceName: "Stelo", anchor: anchor)
        try context.save()

        let aggregator = SnapshotAggregator(healthKit: mock, modelContext: context)
        try await aggregator.aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        let dq = try decodeDataQuality(snap)
        #expect(dq["glucose"]?["reliability"] as? String == "high")
        let sources = dq["glucose"]?["sources"] as? [String: Int] ?? [:]
        #expect(sources["com.dexcom.stelo"] == 250)
    }

    @Test("Glucose reliability medium: 50 Stelo samples spanning 14h")
    func glucoseMedium() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let anchor = dayStart.addingTimeInterval(3600)
        insertGlucoseSamples(context: context, count: 50, coverageHours: 14,
                             sourceBundleID: "com.dexcom.stelo", sourceName: "Stelo", anchor: anchor)
        try context.save()

        let aggregator = SnapshotAggregator(healthKit: mock, modelContext: context)
        try await aggregator.aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        let dq = try decodeDataQuality(snap)
        #expect(dq["glucose"]?["reliability"] as? String == "medium")
        let sources = dq["glucose"]?["sources"] as? [String: Int] ?? [:]
        #expect(sources["com.dexcom.stelo"] == 50)
    }

    @Test("Glucose reliability low: 5 manual fingerstick samples")
    func glucoseLow() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let anchor = dayStart.addingTimeInterval(3600)
        insertGlucoseSamples(context: context, count: 5, coverageHours: 6,
                             sourceBundleID: "com.apple.health", sourceName: "Health",
                             anchor: anchor)
        try context.save()

        let aggregator = SnapshotAggregator(healthKit: mock, modelContext: context)
        try await aggregator.aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        let dq = try decodeDataQuality(snap)
        #expect(dq["glucose"]?["reliability"] as? String == "low")
        let sources = dq["glucose"]?["sources"] as? [String: Int] ?? [:]
        #expect(sources["com.apple.health"] == 5)
    }

    // MARK: - SpO2 (overnight window — noon-to-noon)

    @Test("SpO2 reliability high: 480 EMAY samples spanning 7h overnight")
    func spo2High() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // Anchor 11h into overnight window (=11pm of prev calendar day).
        // 7h spread keeps everything inside the 24h noon-to-noon window.
        let anchor = overnightStart.addingTimeInterval(11 * 3600)
        insertSpO2Samples(context: context, count: 480, coverageHours: 7,
                          sourceBundleID: "com.emay.sleepo2", sourceName: "EMAY SleepO2", anchor: anchor)
        try context.save()

        let aggregator = SnapshotAggregator(healthKit: mock, modelContext: context)
        try await aggregator.aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        let dq = try decodeDataQuality(snap)
        #expect(dq["spo2"]?["reliability"] as? String == "high")
        let sources = dq["spo2"]?["sources"] as? [String: Int] ?? [:]
        #expect(sources["com.emay.sleepo2"] == 480)
    }

    @Test("SpO2 reliability medium: 30 EMAY + 5 Apple Watch over 4h overnight")
    func spo2Medium() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let anchor = overnightStart.addingTimeInterval(11 * 3600)
        insertSpO2Samples(context: context, count: 30, coverageHours: 4,
                          sourceBundleID: "com.emay.sleepo2", sourceName: "EMAY SleepO2", anchor: anchor)
        // Add 30 more emay samples to clear the 60-sample mixed-mode threshold;
        // `medium` rule is "dedicated + Apple Watch with ≥60 samples".
        insertSpO2Samples(context: context, count: 30, coverageHours: 4,
                          sourceBundleID: "com.emay.sleepo2", sourceName: "EMAY SleepO2",
                          anchor: anchor.addingTimeInterval(60))
        insertSpO2Samples(context: context, count: 5, coverageHours: 4,
                          sourceBundleID: "com.apple.health", sourceName: "Apple Watch",
                          anchor: anchor.addingTimeInterval(120))
        try context.save()

        let aggregator = SnapshotAggregator(healthKit: mock, modelContext: context)
        try await aggregator.aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        let dq = try decodeDataQuality(snap)
        #expect(dq["spo2"]?["reliability"] as? String == "medium")
        let sources = dq["spo2"]?["sources"] as? [String: Int] ?? [:]
        #expect(sources["com.emay.sleepo2"] == 60)
        #expect(sources["com.apple.health"] == 5)
    }

    @Test("SpO2 reliability low: 10 Apple Watch only")
    func spo2Low() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let anchor = overnightStart.addingTimeInterval(11 * 3600)
        insertSpO2Samples(context: context, count: 10, coverageHours: 6,
                          sourceBundleID: "com.apple.health", sourceName: "Apple Watch", anchor: anchor)
        try context.save()

        let aggregator = SnapshotAggregator(healthKit: mock, modelContext: context)
        try await aggregator.aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        let dq = try decodeDataQuality(snap)
        #expect(dq["spo2"]?["reliability"] as? String == "low")
        let sources = dq["spo2"]?["sources"] as? [String: Int] ?? [:]
        #expect(sources["com.apple.health"] == 10)
    }

    // MARK: - Heart rate

    @Test("HR reliability high: 50 Apple Watch samples")
    func hrHigh() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let anchor = dayStart.addingTimeInterval(3600)
        for i in 0..<50 {
            let s = QuantityHealthSample(
                timestamp: anchor.addingTimeInterval(Double(i) * 60),
                metricType: HKQuantityTypeIdentifier.heartRate.rawValue,
                value: 72,
                unitString: "count/min",
                sourceBundleID: "com.apple.health",
                sourceName: "Apple Watch"
            )
            context.insert(s)
        }
        try context.save()

        let aggregator = SnapshotAggregator(healthKit: mock, modelContext: context)
        try await aggregator.aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        let dq = try decodeDataQuality(snap)
        #expect(dq["hr"]?["reliability"] as? String == "high")
        let sources = dq["hr"]?["sources"] as? [String: Int] ?? [:]
        #expect(sources["com.apple.health"] == 50)
    }

    // MARK: - Empty mirror

    @Test("Empty mirror produces insufficient reliability for all metric families")
    func emptyMirrorInsufficient() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let aggregator = SnapshotAggregator(healthKit: mock, modelContext: context)
        try await aggregator.aggregateDay(referenceDate)

        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        let dq = try decodeDataQuality(snap)
        // Each emitted family should be present and report insufficient + empty sources
        let expectedFamilies = ["glucose", "spo2", "hr", "hrv", "rhr", "rr", "bp",
                                "wristTemp", "bodyTemp", "weight"]
        for family in expectedFamilies {
            #expect(dq[family]?["reliability"] as? String == "insufficient",
                    "expected \(family) reliability=insufficient")
            let sources = dq[family]?["sources"] as? [String: Int] ?? [:]
            #expect(sources.isEmpty, "expected \(family) sources to be empty")
        }
    }

    @Test("dataQuality JSON keys are sorted deterministically")
    func dataQualityKeysSorted() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let aggregator = SnapshotAggregator(healthKit: mock, modelContext: context)
        try await aggregator.aggregateDay(referenceDate)
        let snap = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        let json = try #require(snap.dataQuality)
        // sortedKeys means top-level family keys appear in alphabetical order.
        // First key alphabetically among our families is "bodyTemp".
        let bodyTempIdx = json.range(of: "\"bodyTemp\"")?.lowerBound
        let glucoseIdx = json.range(of: "\"glucose\"")?.lowerBound
        let spo2Idx = json.range(of: "\"spo2\"")?.lowerBound
        let bp = try #require(bodyTempIdx)
        let glu = try #require(glucoseIdx)
        let sp = try #require(spo2Idx)
        #expect(bp < glu)
        #expect(glu < sp)
    }
}
