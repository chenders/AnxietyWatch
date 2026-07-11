import Foundation
import HealthKit
import SwiftData
import Testing

@testable import AnxietyWatch

struct SnapshotAggregatorMockTests {

    private let referenceDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
    }()

    private func makeAggregator(mock: MockHealthKitDataSource, context: ModelContext) -> SnapshotAggregator {
        SnapshotAggregator(healthKit: mock, modelContext: context, defaults: TestHelpers.gateResolvedDefaults())
    }

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
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.sleepDurationMin == nil)
        #expect(s.sleepDeepMin == nil)
    }

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
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.bpSystolic == nil)
        #expect(s.bpDiastolic == nil)
    }

    @Test("VO2Max outside day range is not set")
    func vo2MaxOutsideDayRange() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
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
        await mock.setMostRecent(.vo2Max, date: referenceDate, value: 42.0)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.vo2Max == 42.0)
    }

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

    @Test("Barometric readings stitched into snapshot")
    func barometricStitched() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let r1 = ModelFactory.barometricReading(timestamp: referenceDate.addingTimeInterval(3600), pressureKPa: 101.0)
        let r2 = ModelFactory.barometricReading(timestamp: referenceDate.addingTimeInterval(7200), pressureKPa: 103.0)
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

    @Test("SpO2 is scaled from 0-1 to percentage (0-100)")
    func spo2Scaled() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        // HealthKit returns 0.96 for 96% SpO2
        await mock.setAverage(.oxygenSaturation, value: 0.96)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.spo2Avg != nil)
        #expect(abs(s.spo2Avg! - 96.0) < 0.01)
    }

    @Test("SpO2 nil stays nil")
    func spo2NilStaysNil() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.spo2Avg == nil)
        #expect(s.spo2NadirOvernight == nil)
        #expect(s.spo2TimeBelow90Min == nil)
        #expect(s.spo2DesatsCount == nil)
    }

    @Test("SpO2 overnight nadir is scaled to percentage")
    func spo2NadirScaled() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setMinimum(.oxygenSaturation, value: 0.85)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.spo2NadirOvernight != nil)
        #expect(abs(s.spo2NadirOvernight! - 85.0) < 0.01)
    }

    @Test("SpO2 T90 aggregates from overnight samples")
    func spo2T90Aggregated() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let base = referenceDate
        // 60 contiguous 5-second samples (= 5 minutes total). First 24 samples
        // (= 120s = 2 min) below 0.90, rest above. Total >= the aggregator's
        // 30-sample minimum so T90 is computed.
        let belowCount = 24
        let totalCount = 60
        let samples = (0..<totalCount).map { i in
            QuantitySample(
                start: base.addingTimeInterval(Double(i) * 5),
                end: base.addingTimeInterval(Double(i + 1) * 5),
                value: i < belowCount ? 0.85 : 0.95
            )
        }
        await mock.setQuantitySamples(.oxygenSaturation, samples)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.spo2TimeBelow90Min == 2)
    }

    @Test("SpO2 desat count aggregates two events from overnight samples")
    func spo2DesatsAggregated() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let base = referenceDate
        // 5 baseline readings, drop, recover, drop, recover, then padded to
        // 60 baseline 0.97s — total 60 samples × 5s = 300s span, clearing
        // both the 30-sample minimum and the 5-min duration minimum.
        let values: [Double] = Array(repeating: 0.97, count: 5)
            + [0.92, 0.93, 0.96, 0.97]
            + [0.91, 0.93, 0.97]
            + Array(repeating: 0.97, count: 48)
        let samples = values.enumerated().map { i, v in
            QuantitySample(
                start: base.addingTimeInterval(Double(i) * 5),
                end: base.addingTimeInterval(Double(i + 1) * 5),
                value: v
            )
        }
        await mock.setQuantitySamples(.oxygenSaturation, samples)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.spo2DesatsCount == 2)
    }

    @Test("SpO2 T90 / desats are nil when samples cover too little time")
    func spo2OvernightStatsNilForBriefBurst() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let base = referenceDate
        // 60 contiguous 1-second samples — clears the 30-sample count
        // threshold but only spans 60s, well below the 5-min duration
        // threshold. Represents a brief monitor burst, not overnight coverage.
        let samples = (0..<60).map { i in
            QuantitySample(
                start: base.addingTimeInterval(Double(i)),
                end: base.addingTimeInterval(Double(i + 1)),
                value: 0.85
            )
        }
        await mock.setQuantitySamples(.oxygenSaturation, samples)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.spo2TimeBelow90Min == nil)
        #expect(s.spo2DesatsCount == nil)
    }

    @Test("SpO2 stats nil when overlapping samples sum to insufficient unique coverage")
    func spo2OvernightStatsNilForDoubleCountedOverlap() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let base = referenceDate
        // Two SpO₂ sources both recording the same 175-second interval (35
        // contiguous 5-second samples, ×2 sources = 70 raw samples). Naive
        // sum would give 350s of "monitoring" (passes 5-min gate); the
        // collapseOverlaps-aware aggregator correctly counts 175s of unique
        // coverage and emits nil.
        var samples: [QuantitySample] = []
        for i in 0..<35 {
            let start = base.addingTimeInterval(Double(i) * 5)
            let end = base.addingTimeInterval(Double(i + 1) * 5)
            samples.append(QuantitySample(start: start, end: end, value: 0.85))
            samples.append(QuantitySample(start: start, end: end, value: 0.86))
        }
        await mock.setQuantitySamples(.oxygenSaturation, samples)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.spo2TimeBelow90Min == nil)
        #expect(s.spo2DesatsCount == nil)
    }

    @Test("SpO2 stats nil when one-second readings are scattered across a wider span")
    func spo2OvernightStatsNilForScatteredOneSecondReadings() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let base = referenceDate
        // 30 one-second samples spaced 1 minute apart — span 29 minutes,
        // but only 30 seconds of actual monitoring. A span-based gate would
        // pass them; the total-monitored-duration gate correctly excludes.
        let samples = (0..<30).map { i in
            QuantitySample(
                start: base.addingTimeInterval(Double(i) * 60),
                end: base.addingTimeInterval(Double(i) * 60 + 1),
                value: 0.85
            )
        }
        await mock.setQuantitySamples(.oxygenSaturation, samples)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.spo2TimeBelow90Min == nil)
        #expect(s.spo2DesatsCount == nil)
    }

    @Test("Glucose SD/CV are nil when readings are clustered in a short window")
    func glucoseVariabilityNilForClusteredReadings() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let base = referenceDate
        // 5 readings within a 30-minute window (e.g., a meal-time CGM cluster)
        // — clears the 4-sample count threshold but fails the 1-hour duration
        // threshold so SD/CV stay nil. Min/max are still emitted.
        let values: [Double] = [110, 130, 145, 160, 150]
        let samples = values.enumerated().map { i, v in
            QuantitySample(
                start: base.addingTimeInterval(Double(i) * 300),  // 5-min spacing
                end: base.addingTimeInterval(Double(i) * 300 + 60),
                value: v
            )
        }
        await mock.setQuantitySamples(.bloodGlucose, samples)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.glucoseMin == 110)
        #expect(s.glucoseMax == 160)
        #expect(s.glucoseStdDev == nil)
        #expect(s.glucoseCV == nil)
    }

    @Test("SpO2 T90 / desats are nil when sample count is below continuous-monitoring threshold")
    func spo2OvernightStatsNilForSparseSamples() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let base = referenceDate
        // 3 spot readings (typical Apple Watch output for a night) — well
        // below the aggregator's 30-sample minimum so the stats should not
        // be computed. Otherwise the day would export a misleading 0-min
        // T90 / 0-desats "good night".
        let samples = [
            QuantitySample(start: base, end: base.addingTimeInterval(60), value: 0.85),
            QuantitySample(start: base.addingTimeInterval(60), end: base.addingTimeInterval(120), value: 0.95),
            QuantitySample(start: base.addingTimeInterval(120), end: base.addingTimeInterval(180), value: 0.88),
        ]
        await mock.setQuantitySamples(.oxygenSaturation, samples)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.spo2TimeBelow90Min == nil)
        #expect(s.spo2DesatsCount == nil)
    }

    @Test("Skin temp wrist stores raw absolute temperature")
    func skinTempWristRaw() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.appleSleepingWristTemperature, value: 35.5)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.skinTempWrist == 35.5)
    }

    @Test("Skin temp deviation is nil without enough baseline data")
    func skinTempDeviationNilWithoutBaseline() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        await mock.setAverage(.appleSleepingWristTemperature, value: 35.5)
        let aggregator = makeAggregator(mock: mock, context: context)
        // Only one day — not enough for a 14-day baseline
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.skinTempDeviation == nil)
    }

    @Test("Skin temp deviation computed from rolling baseline")
    func skinTempDeviationFromBaseline() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()

        // Pre-populate 14 days of historical snapshots with known wrist temps
        let cal = Calendar.current
        for dayOffset in (-14)...(-1) {
            let date = cal.date(byAdding: .day, value: dayOffset, to: referenceDate)!
            let snapshot = HealthSnapshot(date: date)
            snapshot.skinTempWrist = 35.0  // baseline will be 35.0
            context.insert(snapshot)
        }
        try context.save()

        // Today's wrist temp is 35.8 — deviation should be +0.8
        await mock.setAverage(.appleSleepingWristTemperature, value: 35.8)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)

        let all = try context.fetch(FetchDescriptor<HealthSnapshot>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))
        let today = all.first { cal.isDate($0.date, inSameDayAs: referenceDate) }!
        #expect(today.skinTempWrist == 35.8)
        #expect(today.skinTempDeviation != nil)
        #expect(abs(today.skinTempDeviation! - 0.8) < 0.01)
    }

    @Test("Glucose variability stats aggregate from samples")
    func glucoseVariability() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let base = referenceDate
        // [80, 100, 120, 140, 160] — mean=120, SD≈28.28, CV≈23.57%.
        // 5 samples spaced 1 hour apart so the span (4h+) clears the 1-hour
        // minimum-coverage threshold.
        let values: [Double] = [80, 100, 120, 140, 160]
        let samples = values.enumerated().map { i, v in
            QuantitySample(
                start: base.addingTimeInterval(Double(i) * 3600),
                end: base.addingTimeInterval(Double(i) * 3600 + 60),
                value: v
            )
        }
        await mock.setQuantitySamples(.bloodGlucose, samples)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.glucoseMin == 80)
        #expect(s.glucoseMax == 160)
        #expect(abs(s.glucoseStdDev! - 28.28) < 0.1)
        #expect(abs(s.glucoseCV! - 23.57) < 0.1)
    }

    @Test("Glucose variability nil when no samples")
    func glucoseVariabilityEmpty() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.glucoseMin == nil)
        #expect(s.glucoseMax == nil)
        #expect(s.glucoseStdDev == nil)
        #expect(s.glucoseCV == nil)
    }

    @Test("Glucose SD/CV are nil for sparse sampling but min/max remain")
    func glucoseVariabilityNilWithSparseSampling() async throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let mock = MockHealthKitDataSource()
        let base = referenceDate
        // 2 finger-stick readings (below the 4-sample minimum for variability
        // stats). Min/max are still emitted because a single reading is a
        // meaningful extreme; CV/SD would be misleading on this little data.
        let samples = [
            QuantitySample(start: base, end: base.addingTimeInterval(60), value: 95),
            QuantitySample(start: base.addingTimeInterval(3600), end: base.addingTimeInterval(3660), value: 140),
        ]
        await mock.setQuantitySamples(.bloodGlucose, samples)
        let aggregator = makeAggregator(mock: mock, context: context)
        try await aggregator.aggregateDay(referenceDate)
        let s = try context.fetch(FetchDescriptor<HealthSnapshot>())[0]
        #expect(s.glucoseMin == 95)
        #expect(s.glucoseMax == 140)
        #expect(s.glucoseStdDev == nil)
        #expect(s.glucoseCV == nil)
    }

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
