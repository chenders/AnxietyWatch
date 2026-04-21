// AnxietyWatchTests/SensorBaselineTests.swift
import Foundation
import SwiftData
import Testing

@testable import AnxietyWatch

struct SensorBaselineTests {

    private let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 20
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private func makeSnapshot(daysAgo: Int, tremor: Double? = nil, breathing: Double? = nil) -> HealthSnapshot {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: referenceDate)!
        let snapshot = HealthSnapshot(date: date)
        snapshot.tremorBandPowerAvg = tremor
        snapshot.breathingRateAvg = breathing
        return snapshot
    }

    @Test("Tremor baseline requires 14+ data points")
    func tremorBaselineMinimum() {
        let snapshots = (0..<13).map { makeSnapshot(daysAgo: $0, tremor: 0.01) }
        #expect(BaselineCalculator.tremorBaseline(from: snapshots, anchorDate: referenceDate) == nil)
    }

    @Test("Tremor baseline computed with enough data")
    func tremorBaselineComputed() {
        let snapshots = (0..<14).map { makeSnapshot(daysAgo: $0, tremor: 0.01) }
        let result = BaselineCalculator.tremorBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 0.01) < 0.001)
    }

    @Test("Breathing rate baseline requires 14+ data points")
    func breathingBaselineMinimum() {
        let snapshots = (0..<13).map { makeSnapshot(daysAgo: $0, breathing: 16.0) }
        #expect(BaselineCalculator.breathingRateBaseline(from: snapshots, anchorDate: referenceDate) == nil)
    }

    @Test("Breathing rate baseline computed with enough data")
    func breathingBaselineComputed() {
        let snapshots = (0..<14).map { makeSnapshot(daysAgo: $0, breathing: 16.0) }
        let result = BaselineCalculator.breathingRateBaseline(from: snapshots, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 16.0) < 0.01)
    }

    @Test("Tremor baseline excludes snapshots outside window")
    func tremorBaselineWindowFilter() {
        var snapshots = [makeSnapshot(daysAgo: 31, tremor: 1.0)] // outside
        snapshots += (0..<14).map { makeSnapshot(daysAgo: $0, tremor: 0.01) }
        let result = BaselineCalculator.tremorBaseline(from: snapshots, windowDays: 30, anchorDate: referenceDate)
        #expect(result != nil)
        #expect(abs(result!.mean - 0.01) < 0.001)
    }
}
