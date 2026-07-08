import Foundation
import Testing
@testable import AnxietyWatch

struct SleepEfficiencyCalculatorTests {

    private let ref = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 0))!

    private func event(_ stage: String, startMin: Int, endMin: Int) -> SleepStageEvent {
        SleepStageEvent(
            startTime: ref.addingTimeInterval(Double(startMin) * 60),
            endTime: ref.addingTimeInterval(Double(endMin) * 60),
            stage: stage,
            sourceBundleID: "test",
            sourceName: "test"
        )
    }

    @Test("Clean 8-hour night: efficiency 96.875%, WASO 0")
    func cleanNight() {
        let events = [
            event("inBed", startMin: 0, endMin: 480),
            event("asleepCore", startMin: 5, endMin: 470)
        ]
        let r = SleepEfficiencyCalculator.compute(from: events)
        #expect(r.inBedMinutes == 480)
        #expect(r.asleepMinutes == 465)
        #expect(r.wasoMinutes == 0)
        #expect(abs(r.efficiencyPct - 96.875) < 0.01)
        #expect(r.isBedTimeEstimated == false)
    }

    @Test("Mid-night wake: WASO captures the awake gap between asleep events")
    func midNightWake() {
        let events = [
            event("inBed", startMin: 0, endMin: 480),
            event("asleepCore", startMin: 10, endMin: 200),
            event("awake", startMin: 200, endMin: 230),
            event("asleepCore", startMin: 230, endMin: 470)
        ]
        let r = SleepEfficiencyCalculator.compute(from: events)
        #expect(r.asleepMinutes == 430)
        #expect(r.wasoMinutes == 30)
        #expect(r.isBedTimeEstimated == false)
    }

    @Test("No data returns zeros")
    func empty() {
        let r = SleepEfficiencyCalculator.compute(from: [])
        #expect(r.inBedMinutes == 0)
        #expect(r.asleepMinutes == 0)
        #expect(r.wasoMinutes == 0)
        #expect(r.efficiencyPct == 0)
        #expect(r.isBedTimeEstimated == false)
    }

    @Test("Asleep-only stream (no inBed event): efficiency uses asleep span as denominator")
    func asleepOnly() {
        let events = [event("asleepCore", startMin: 0, endMin: 420)]
        let r = SleepEfficiencyCalculator.compute(from: events)
        #expect(r.asleepMinutes == 420)
        #expect(r.inBedMinutes == 420)
        #expect(abs(r.efficiencyPct - 100.0) < 0.01)
        #expect(r.isBedTimeEstimated == true)
    }

    @Test("Partial inBed coverage smaller than asleep span: denominator floors at asleep span, efficiency pins at 100%")
    func partialInBedCoverage() {
        // inBed covers only 100 min but asleep spans 420 min. The naive
        // denominator (100) would yield 420% efficiency.
        let events = [
            event("inBed", startMin: 0, endMin: 100),
            event("asleepCore", startMin: 5, endMin: 425)
        ]
        let r = SleepEfficiencyCalculator.compute(from: events)
        #expect(r.asleepMinutes == 420)
        #expect(r.inBedMinutes == 420)
        #expect(abs(r.efficiencyPct - 100.0) < 0.01)
        #expect(r.isBedTimeEstimated == true)
    }

    @Test("Awake events before first asleep do not count as WASO")
    func awakeBeforeOnsetIgnored() {
        let events = [
            event("inBed", startMin: 0, endMin: 480),
            event("awake", startMin: 0, endMin: 20),
            event("asleepCore", startMin: 20, endMin: 470)
        ]
        let r = SleepEfficiencyCalculator.compute(from: events)
        #expect(r.wasoMinutes == 0)
        #expect(r.isBedTimeEstimated == false)
    }

    @Test("Overlapping asleep intervals deduplicate (not summed)")
    func overlappingAsleepIntervals() {
        let events = [
            event("asleepCore", startMin: 10, endMin: 200),
            event("asleepCore", startMin: 150, endMin: 470)  // overlaps previous
        ]
        let r = SleepEfficiencyCalculator.compute(from: events)
        // Merged span: 10..470 = 460 minutes (NOT 190 + 320 = 510)
        #expect(r.asleepMinutes == 460)
    }

    @Test("Awake events after final sleep offset do not count as WASO")
    func awakeAfterOffsetIgnored() {
        let events = [
            event("inBed", startMin: 0, endMin: 480),
            event("asleepCore", startMin: 20, endMin: 460),
            event("awake", startMin: 460, endMin: 480)  // post-sleep awake
        ]
        let r = SleepEfficiencyCalculator.compute(from: events)
        #expect(r.wasoMinutes == 0)
    }
}
