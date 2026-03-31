import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import AnxietyWatch

@MainActor
struct DashboardViewModelTests {

    private let calendar = Calendar.current

    // MARK: - baselineColor

    @Test("Color is green when value is within baseline (higher is better)")
    func baselineColorGreenHigherBetter() {
        let vm = DashboardViewModel()
        let baseline = BaselineCalculator.BaselineResult(
            mean: 50, standardDeviation: 5, lowerBound: 40, upperBound: 60
        )
        let color = vm.baselineColor(value: 45, baseline: baseline, higherIsBetter: true)
        #expect(color == .green)
    }

    @Test("Color is yellow when slightly below lower bound (higher is better)")
    func baselineColorYellowHigherBetter() {
        let vm = DashboardViewModel()
        let baseline = BaselineCalculator.BaselineResult(
            mean: 50, standardDeviation: 5, lowerBound: 40, upperBound: 60
        )
        // value between lowerBound - stddev (35) and lowerBound (40)
        let color = vm.baselineColor(value: 37, baseline: baseline, higherIsBetter: true)
        #expect(color == .yellow)
    }

    @Test("Color is red when far below baseline (higher is better)")
    func baselineColorRedHigherBetter() {
        let vm = DashboardViewModel()
        let baseline = BaselineCalculator.BaselineResult(
            mean: 50, standardDeviation: 5, lowerBound: 40, upperBound: 60
        )
        let color = vm.baselineColor(value: 30, baseline: baseline, higherIsBetter: true)
        #expect(color == .red)
    }

    @Test("Color is green when value is within baseline (lower is better)")
    func baselineColorGreenLowerBetter() {
        let vm = DashboardViewModel()
        let baseline = BaselineCalculator.BaselineResult(
            mean: 65, standardDeviation: 5, lowerBound: 55, upperBound: 75
        )
        let color = vm.baselineColor(value: 70, baseline: baseline, higherIsBetter: false)
        #expect(color == .green)
    }

    @Test("Color is red when far above upper bound (lower is better)")
    func baselineColorRedLowerBetter() {
        let vm = DashboardViewModel()
        let baseline = BaselineCalculator.BaselineResult(
            mean: 65, standardDeviation: 5, lowerBound: 55, upperBound: 75
        )
        let color = vm.baselineColor(value: 85, baseline: baseline, higherIsBetter: false)
        #expect(color == .red)
    }

    @Test("Color is primary when no baseline available")
    func baselineColorNilBaseline() {
        let vm = DashboardViewModel()
        let color = vm.baselineColor(value: 50, baseline: nil, higherIsBetter: true)
        #expect(color == .primary)
    }

    // MARK: - sleepColor

    @Test("Sleep color green for 7+ hours")
    func sleepColorGreen() {
        #expect(DashboardViewModel().sleepColor(minutes: 420) == .green)
        #expect(DashboardViewModel().sleepColor(minutes: 480) == .green)
    }

    @Test("Sleep color yellow for 6-7 hours")
    func sleepColorYellow() {
        #expect(DashboardViewModel().sleepColor(minutes: 360) == .yellow)
        #expect(DashboardViewModel().sleepColor(minutes: 419) == .yellow)
    }

    @Test("Sleep color red for <6 hours")
    func sleepColorRed() {
        #expect(DashboardViewModel().sleepColor(minutes: 359) == .red)
        #expect(DashboardViewModel().sleepColor(minutes: 0) == .red)
    }

    // MARK: - stepsColor

    @Test("Steps color green for 8000+")
    func stepsColorGreen() {
        #expect(DashboardViewModel().stepsColor(8000) == .green)
        #expect(DashboardViewModel().stepsColor(12000) == .green)
    }

    @Test("Steps color yellow for 5000-7999")
    func stepsColorYellow() {
        #expect(DashboardViewModel().stepsColor(5000) == .yellow)
        #expect(DashboardViewModel().stepsColor(7999) == .yellow)
    }

    @Test("Steps color red for <5000")
    func stepsColorRed() {
        #expect(DashboardViewModel().stepsColor(4999) == .red)
        #expect(DashboardViewModel().stepsColor(0) == .red)
    }

    // MARK: - latestSample / recentValues

    @Test("latestSample returns first sample for type")
    func latestSampleReturnsFirst() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        let s1 = HealthSample(type: "hr", value: 80, timestamp: Date.now)
        let s2 = HealthSample(type: "hr", value: 70, timestamp: Date.now.addingTimeInterval(-60))
        context.insert(s1)
        context.insert(s2)
        try context.save()

        let vm = DashboardViewModel()
        vm.loadSamples(from: context)
        #expect(vm.latestSample(for: "hr")?.value == 80)
    }

    @Test("latestSample returns nil for missing type")
    func latestSampleNilForMissing() {
        let vm = DashboardViewModel()
        #expect(vm.latestSample(for: "hr") == nil)
    }

    @Test("recentValues returns last N values in chronological order")
    func recentValuesOrder() throws {
        let container = try TestHelpers.makeFullContainer()
        let context = ModelContext(container)
        for i in 0..<5 {
            let sample = HealthSample(type: "hr", value: Double(100 - i * 10),
                                      timestamp: Date.now.addingTimeInterval(-Double(i) * 60))
            context.insert(sample)
        }
        try context.save()

        let vm = DashboardViewModel()
        vm.loadSamples(from: context)
        let values = vm.recentValues(for: "hr", count: 3)
        // Samples sorted desc by timestamp: [100, 90, 80], take 3, reverse → [80, 90, 100]
        #expect(values == [80, 90, 100])
    }

    // MARK: - todaySnapshot / lastSnapshotWith

    @Test("todaySnapshot returns snapshot matching start of today")
    func todaySnapshotFound() {
        let vm = DashboardViewModel()
        let today = calendar.startOfDay(for: .now)
        let snapshot = HealthSnapshot(date: today)
        snapshot.hrvAvg = 45
        #expect(vm.todaySnapshot(from: [snapshot])?.hrvAvg == 45)
    }

    @Test("todaySnapshot returns nil when no today snapshot")
    func todaySnapshotNil() {
        let vm = DashboardViewModel()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now))!
        let snapshot = HealthSnapshot(date: yesterday)
        #expect(vm.todaySnapshot(from: [snapshot]) == nil)
    }

    @Test("lastSnapshotWith finds first snapshot with non-nil value")
    func lastSnapshotWithFindsNonNil() {
        let vm = DashboardViewModel()
        let today = calendar.startOfDay(for: .now)
        let s1 = HealthSnapshot(date: today)
        s1.hrvAvg = nil
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let s2 = HealthSnapshot(date: yesterday)
        s2.hrvAvg = 42
        let result = vm.lastSnapshotWith(\.hrvAvg, from: [s1, s2])
        #expect(result != nil)
        #expect(result?.0.hrvAvg == 42)
        #expect(result?.1 == false) // not today
    }

    @Test("lastSnapshotWith returns isToday true for today's snapshot")
    func lastSnapshotWithIsToday() {
        let vm = DashboardViewModel()
        let today = calendar.startOfDay(for: .now)
        let s = HealthSnapshot(date: today)
        s.hrvAvg = 50
        let result = vm.lastSnapshotWith(\.hrvAvg, from: [s])
        #expect(result?.1 == true)
    }

    // MARK: - latestLabResultPerTest

    @Test("Returns up to 4 unique tracked results from last 7 days")
    func latestLabResultPerTestBasic() {
        let vm = DashboardViewModel()
        let now = Date.now
        let results = [
            ClinicalLabResult(loincCode: "3016-3", testName: "TSH", value: 2.5, unit: "mIU/L",
                              effectiveDate: now, healthKitSampleUUID: "uuid-1"),
            ClinicalLabResult(loincCode: "3024-7", testName: "Free T4", value: 1.2, unit: "ng/dL",
                              effectiveDate: now.addingTimeInterval(-3600), healthKitSampleUUID: "uuid-2"),
            // Duplicate TSH — should be skipped
            ClinicalLabResult(loincCode: "3016-3", testName: "TSH", value: 2.0, unit: "mIU/L",
                              effectiveDate: now.addingTimeInterval(-7200), healthKitSampleUUID: "uuid-3"),
        ]
        let filtered = vm.latestLabResultPerTest(from: results)
        #expect(filtered.count == 2)
        #expect(filtered[0].loincCode == "3016-3")
        #expect(filtered[1].loincCode == "3024-7")
    }

    @Test("Excludes results older than 7 days")
    func latestLabResultPerTestExcludesOld() {
        let vm = DashboardViewModel()
        let oldDate = calendar.date(byAdding: .day, value: -10, to: .now)!
        let results = [
            ClinicalLabResult(loincCode: "3016-3", testName: "TSH", value: 2.5, unit: "mIU/L",
                              effectiveDate: oldDate, healthKitSampleUUID: "uuid-old"),
        ]
        #expect(vm.latestLabResultPerTest(from: results).isEmpty)
    }

    @Test("Excludes untracked LOINC codes")
    func latestLabResultPerTestExcludesUntracked() {
        let vm = DashboardViewModel()
        let results = [
            ClinicalLabResult(loincCode: "99999-9", testName: "Unknown", value: 1.0, unit: "x",
                              effectiveDate: .now, healthKitSampleUUID: "uuid-untracked"),
        ]
        #expect(vm.latestLabResultPerTest(from: results).isEmpty)
    }

    @Test("Caps at 4 results")
    func latestLabResultPerTestMaxFour() {
        let vm = DashboardViewModel()
        let now = Date.now
        // Use 5 distinct tracked LOINC codes from LabTestRegistry
        let codes = ["3016-3", "3024-7", "5765-2", "2143-6", "14979-9"]
        let results = codes.enumerated().map { i, code in
            ClinicalLabResult(loincCode: code, testName: "Test \(i)", value: 1.0, unit: "x",
                              effectiveDate: now.addingTimeInterval(-Double(i) * 60),
                              healthKitSampleUUID: "uuid-\(i)")
        }
        #expect(vm.latestLabResultPerTest(from: results).count == 4)
    }

    // MARK: - freshnessLabel

    @Test("Freshness label says 'last night' for yesterday evening sample")
    func freshnessLabelLastNight() {
        let vm = DashboardViewModel()
        let midnight = calendar.startOfDay(for: .now)
        // Yesterday at 9pm
        var comps = calendar.dateComponents([.year, .month, .day], from: midnight)
        comps.day! -= 1
        comps.hour = 21
        let lastNight = calendar.date(from: comps)!
        #expect(vm.freshnessLabel(lastNight) == "last night")
    }

    @Test("Freshness label uses relative format for today's sample")
    func freshnessLabelToday() {
        let vm = DashboardViewModel()
        // A sample from 1 minute ago should produce a relative string, not "last night"
        let recent = Date.now.addingTimeInterval(-60)
        let label = vm.freshnessLabel(recent)
        #expect(label != "last night")
    }
}
