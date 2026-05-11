// AnxietyWatchTests/RRTimestampBackprojectionTests.swift
import Foundation
import Testing

@testable import AnxietyWatch

struct RRTimestampBackprojectionTests {

    private let arrival = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("empty input returns empty output")
    func empty() {
        let out = RRTimestampBackprojection.project(arrival: arrival, rrIntervalsMs: [])
        #expect(out.isEmpty)
    }

    @Test("single interval lands exactly at arrival")
    func single() {
        let out = RRTimestampBackprojection.project(arrival: arrival, rrIntervalsMs: [800])
        #expect(out.count == 1)
        #expect(abs(out[0].timestamp.timeIntervalSince(arrival)) < 0.001)
        #expect(out[0].rrMs == 800)
    }

    @Test("two intervals are spaced by their RR durations, last at arrival")
    func two() {
        let out = RRTimestampBackprojection.project(arrival: arrival, rrIntervalsMs: [800, 820])
        #expect(out.count == 2)
        // Last interval ends at arrival; the prior one ended 820 ms before.
        #expect(abs(out[1].timestamp.timeIntervalSince(arrival)) < 0.001)
        #expect(abs(out[0].timestamp.timeIntervalSince(arrival.addingTimeInterval(-0.820))) < 0.001)
        // RR values are preserved in order.
        #expect(out.map(\.rrMs) == [800, 820])
    }

    @Test("three intervals preserve ordering and cumulative spacing")
    func three() {
        let out = RRTimestampBackprojection.project(arrival: arrival, rrIntervalsMs: [800, 820, 810])
        #expect(out.count == 3)
        // out[2] = arrival; out[1] = arrival - 0.810; out[0] = arrival - 0.810 - 0.820
        #expect(abs(out[2].timestamp.timeIntervalSince(arrival)) < 0.001)
        #expect(abs(out[1].timestamp.timeIntervalSince(arrival.addingTimeInterval(-0.810))) < 0.001)
        #expect(abs(out[0].timestamp.timeIntervalSince(arrival.addingTimeInterval(-1.630))) < 0.001)
    }

    @Test("timestamps are monotonically increasing")
    func monotonic() {
        let out = RRTimestampBackprojection.project(arrival: arrival, rrIntervalsMs: [800, 820, 810, 790])
        let timestamps = out.map(\.timestamp)
        for i in 1..<timestamps.count {
            #expect(timestamps[i] > timestamps[i - 1])
        }
    }
}
