import Foundation
import Testing

@testable import AnxietyWatch

struct LFHFAggregatorCoalesceTests {

    // Fixed 2 AM reference; avoids Date.now in any assertion.
    private let ref: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 5, day: 13, hour: 2))!
    }()

    // MARK: - Helpers

    /// Build a SensorSession whose start/end are offset from `ref` by the
    /// given minute counts. Uses the minimal public init and assigns `source`
    /// and `endTime` afterwards so callers don't depend on a non-existent
    /// convenience init.
    private func session(
        _ startOffsetMin: Int,
        _ durationMin: Int,
        id: UUID = UUID()
    ) -> SensorSession {
        let start = ref.addingTimeInterval(Double(startOffsetMin) * 60)
        let end   = start.addingTimeInterval(Double(durationMin) * 60)
        let s = SensorSession(startTime: start, batteryAtStart: 80)
        s.id = id
        s.endTime = end
        s.source = PolarHRMService.sourceLabel
        return s
    }

    // MARK: - coalesce basics

    @Test("Empty input returns empty")
    func empty() {
        #expect(LFHFAggregator.coalesce(sessions: []).isEmpty)
    }

    @Test("Single session becomes one night with wear time == duration")
    func singleSession() {
        let s = session(0, 300) // 5 h
        let nights = LFHFAggregator.coalesce(sessions: [s])
        #expect(nights.count == 1)
        #expect(nights[0].id == s.id)
        #expect(nights[0].wearTimeSeconds == 300 * 60)
        #expect(nights[0].memberSessionIDs == [s.id])
    }

    @Test("Sessions with nil endTime are excluded")
    func nilEndTimeExcluded() {
        // SensorSession's default init leaves endTime nil.
        let s = SensorSession(startTime: ref, batteryAtStart: 80)
        s.source = PolarHRMService.sourceLabel
        #expect(LFHFAggregator.coalesce(sessions: [s]).isEmpty)
    }

    @Test("Adjacent sessions within 45 min gap coalesce; total = sum of wear time only")
    func coalesceAdjacent() {
        let a = session(0, 60)   // 0..60
        let b = session(75, 60)  // 75..135  (15 min gap from a)
        let nights = LFHFAggregator.coalesce(sessions: [a, b])
        #expect(nights.count == 1)
        #expect(nights[0].id == a.id)                    // first member's ID
        #expect(nights[0].wearTimeSeconds == 120 * 60)   // 60 + 60, NOT 135 min
        #expect(nights[0].memberSessionIDs == [a.id, b.id])
    }

    @Test("Sessions separated by more than 45 min do NOT coalesce")
    func gapTooLarge() {
        let a = session(0, 60)
        let b = session(120, 60)  // 60 min gap > 45 min default
        let nights = LFHFAggregator.coalesce(sessions: [a, b])
        #expect(nights.count == 2)
    }

    @Test("Fragmented May-13 case (6 sessions, 201 min total wear) is one night")
    func may13Fragmentation() {
        // Six sessions ending with a 175-min stretch; max gap 31 min,
        // all within the 45-min default.
        let s1 = session(0, 6)     // ends  6
        let s2 = session(15, 2)    // 9 min gap from s1 end (6)
        let s3 = session(18, 1)    // 1 min gap
        let s4 = session(21, 2)    // 2 min gap
        let s5 = session(24, 15)   // 1 min gap; ends 39
        let s6 = session(70, 175)  // 31 min gap from s5 end (39)
        let nights = LFHFAggregator.coalesce(sessions: [s1, s2, s3, s4, s5, s6])
        #expect(nights.count == 1)
        #expect(nights[0].wearTimeSeconds == 201 * 60)
        #expect(nights[0].wearTimeSeconds >= LFHFAggregator.overnightThresholdSeconds)
    }

    @Test("Unsorted input is sorted by startTime before sweeping")
    func unsortedInput() {
        let a = session(0, 60)
        let b = session(80, 60)
        let nights = LFHFAggregator.coalesce(sessions: [b, a])  // deliberately reversed
        #expect(nights.count == 1)
        #expect(nights[0].memberSessionIDs == [a.id, b.id])
    }

    @Test("Custom gapTolerance lets caller widen/tighten the merge window")
    func customGapTolerance() {
        let a = session(0, 60)
        let b = session(120, 60)  // 60 min gap
        let nightsDefault = LFHFAggregator.coalesce(sessions: [a, b])
        #expect(nightsDefault.count == 2)  // 60 min > 45 min default
        let nightsWide = LFHFAggregator.coalesce(sessions: [a, b], gapTolerance: 60 * 60 + 1)
        #expect(nightsWide.count == 1)
    }

    // MARK: - nightlyAggregates(from:coalescedNights:)

    @Test("nightlyAggregates groups readings across coalesced member sessions")
    func aggregatesAcrossMembers() {
        let s1 = session(0, 60)
        let s2 = session(75, 60)

        let r1 = HRVReading(
            timestamp: ref.addingTimeInterval(30 * 60),
            rmssd: 25, sdnn: 30, pnn50: 10,
            lfPower: 0, hfPower: 0, lfHfRatio: 0,
            sensorSessionID: s1.id, source: PolarHRMService.sourceLabel
        )
        let r2 = HRVReading(
            timestamp: ref.addingTimeInterval(100 * 60),
            rmssd: 35, sdnn: 40, pnn50: 10,
            lfPower: 0, hfPower: 0, lfHfRatio: 0,
            sensorSessionID: s2.id, source: PolarHRMService.sourceLabel
        )

        let nights = LFHFAggregator.coalesce(sessions: [s1, s2])
        let out = LFHFAggregator.nightlyAggregates(from: [r1, r2], coalescedNights: nights)

        // Both readings have non-zero SDNN, so one coalesced night should appear.
        #expect(out.sdnn.count == 1)
        // Trimmed mean of [30, 40] == 35
        #expect(out.sdnn[0].value != nil)
        #expect(abs((out.sdnn[0].value ?? 0) - 35) < 0.5)
        // Night is anchored to first member's startTime.
        #expect(out.sdnn[0].id == s1.id)
        #expect(out.sdnn[0].night == s1.startTime)
    }

    @Test("nightlyAggregates returns empty output when coalescedNights is empty")
    func aggregatesEmptyNights() {
        let r = HRVReading(
            timestamp: ref, rmssd: 40, sdnn: 50, pnn50: 10,
            lfPower: 1, hfPower: 2, lfHfRatio: 0.5,
            sensorSessionID: UUID(), source: PolarHRMService.sourceLabel
        )
        let out = LFHFAggregator.nightlyAggregates(from: [r], coalescedNights: [])
        #expect(out.means.isEmpty)
        #expect(out.sdnn.isEmpty)
        #expect(out.rmssd.isEmpty)
    }

    // MARK: - nightlyHRFromSummaries(from:coalescedNights:)

    @Test("nightlyHRFromSummaries weights member hrMean by duration")
    func weightedHR() {
        // s1: 60 min, hrMean 80. s2: 120 min, hrMean 60.
        // Weighted mean: (60*80 + 120*60) / 180 = 66.667
        let s1Start = ref
        let s1End   = s1Start.addingTimeInterval(60 * 60)
        let s2Start = s1End.addingTimeInterval(15 * 60)   // 15 min gap
        let s2End   = s2Start.addingTimeInterval(120 * 60)

        let s1 = SensorSession(startTime: s1Start, batteryAtStart: 80)
        s1.endTime    = s1End
        s1.source     = PolarHRMService.sourceLabel
        s1.summaryJSON = "{\"hrMean\": 80.0}"

        let s2 = SensorSession(startTime: s2Start, batteryAtStart: 80)
        s2.endTime    = s2End
        s2.source     = PolarHRMService.sourceLabel
        s2.summaryJSON = "{\"hrMean\": 60.0}"

        let nights = LFHFAggregator.coalesce(sessions: [s1, s2])
        let out = LFHFAggregator.nightlyHRFromSummaries(from: [s1, s2], coalescedNights: nights)

        #expect(out.count == 1)
        #expect(out[0].value != nil)
        #expect(abs((out[0].value ?? 0) - 66.667) < 0.1)
    }

    @Test("nightlyHRFromSummaries returns empty when coalescedNights is empty")
    func hrFromSummariesEmptyNights() {
        let s = session(0, 300)
        s.summaryJSON = "{\"hrMean\": 65.0}"
        let out = LFHFAggregator.nightlyHRFromSummaries(from: [s], coalescedNights: [])
        #expect(out.isEmpty)
    }

    @Test("nightlyHRFromSummaries skips night when all members have unparseable summaries")
    func hrFromSummariesAllUnparseable() {
        let s1 = session(0, 60)
        let s2 = session(75, 60)
        // No summaryJSON on either member.
        let nights = LFHFAggregator.coalesce(sessions: [s1, s2])
        let out = LFHFAggregator.nightlyHRFromSummaries(from: [s1, s2], coalescedNights: nights)
        #expect(out.isEmpty)
    }
}
