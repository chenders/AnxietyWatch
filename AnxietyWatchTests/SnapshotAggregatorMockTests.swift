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
        SnapshotAggregator(healthKit: mock, modelContext: context)
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
