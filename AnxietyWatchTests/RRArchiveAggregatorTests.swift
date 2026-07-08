// AnxietyWatchTests/RRArchiveAggregatorTests.swift
import Foundation
import Testing

@testable import AnxietyWatch

struct RRArchiveAggregatorTests {

    // MARK: - Fixture helpers

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rragg-\(UUID().uuidString).rr")
    }

    /// Write `samples` to a new `.rr` file at a fresh temp URL and return it.
    /// Caller is responsible for cleanup.
    private func writeFixture(_ samples: [RRIntervalSample]) throws -> URL {
        let url = tempURL()
        let writer = try RRArchiveWriter(url: url)
        for sample in samples {
            try writer.append(sample)
        }
        try writer.finalize()
        return url
    }

    @Test("60 minutes of constant 60-BPM RR yields 60 points each at 60 ± 0.001 BPM")
    func singleMemberHappyPath() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // 60 BPM == 1000 ms RR. 60 samples per minute × 60 minutes = 3600 records.
        let samples: [RRIntervalSample] = (0..<3600).map { i in
            RRIntervalSample(
                timestamp: t0.addingTimeInterval(Double(i)),  // 1 sample / sec
                rrMs: 1000
            )
        }
        let url = try writeFixture(samples)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = t0...t0.addingTimeInterval(60 * 60)
        let series = RRArchiveAggregator.perMinuteHR(rrFiles: [url], window: window)

        #expect(series.count == 60)
        for point in series {
            let bpm = try #require(point.bpm)
            #expect(abs(bpm - 60.0) < 0.001)
        }
    }

    @Test("two .rr files with a 5-minute BLE-drop gap produce nil-bpm points in the gap")
    func multiMemberWithGap() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // Member A: minutes 0..<10 at constant 60 BPM.
        let memberA: [RRIntervalSample] = (0..<600).map { i in
            RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: 1000)
        }
        // Member B: minutes 15..<25 at constant 75 BPM (800 ms RR).
        let memberBStart = t0.addingTimeInterval(15 * 60)
        let memberB: [RRIntervalSample] = (0..<750).map { i in
            RRIntervalSample(
                timestamp: memberBStart.addingTimeInterval(Double(i) * 0.8),
                rrMs: 800
            )
        }
        let urlA = try writeFixture(memberA)
        let urlB = try writeFixture(memberB)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let window = t0...t0.addingTimeInterval(25 * 60)
        let series = RRArchiveAggregator.perMinuteHR(rrFiles: [urlA, urlB], window: window)

        #expect(series.count == 25)
        // Minutes 0..<10: 60 BPM ± epsilon.
        for i in 0..<10 {
            let bpm = try #require(series[i].bpm)
            #expect(abs(bpm - 60.0) < 0.001)
        }
        // Minutes 10..<15: gap → nil.
        for i in 10..<15 {
            #expect(series[i].bpm == nil)
        }
        // Minutes 15..<25: 75 BPM ± epsilon.
        for i in 15..<25 {
            let bpm = try #require(series[i].bpm)
            #expect(abs(bpm - 75.0) < 0.001)
        }
    }

    @Test("a minute containing only out-of-range RR yields a nil-bpm point")
    func outOfRangeRRYieldsNil() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // 60 samples of 100 ms RR (= 600 BPM, well outside [250, 2000] ms range).
        let samples: [RRIntervalSample] = (0..<60).map { i in
            RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: 100)
        }
        let url = try writeFixture(samples)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = t0...t0.addingTimeInterval(60)
        let series = RRArchiveAggregator.perMinuteHR(rrFiles: [url], window: window)
        #expect(series.count == 1)
        #expect(series[0].bpm == nil)
    }

    @Test("a missing .rr file URL is silently skipped (no throw, no contribution)")
    func missingFileSkipped() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let goodSamples: [RRIntervalSample] = (0..<60).map { i in
            RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: 1000)
        }
        let goodURL = try writeFixture(goodSamples)
        defer { try? FileManager.default.removeItem(at: goodURL) }
        let bogusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).rr")

        let window = t0...t0.addingTimeInterval(60)
        let series = RRArchiveAggregator.perMinuteHR(
            rrFiles: [bogusURL, goodURL], window: window
        )
        #expect(series.count == 1)
        let bpm = try #require(series[0].bpm)
        #expect(abs(bpm - 60.0) < 0.001)
    }

    @Test("RR samples outside the window are dropped even if present in the file")
    func windowClampDropsOutOfWindowSamples() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // 60 samples at t0..t0+60s (in window), then 60 samples at t0+120..t0+180s (out of window).
        let inWindow: [RRIntervalSample] = (0..<60).map { i in
            RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: 1000)
        }
        let outOfWindow: [RRIntervalSample] = (0..<60).map { i in
            RRIntervalSample(timestamp: t0.addingTimeInterval(120 + Double(i)), rrMs: 500)
        }
        let url = try writeFixture(inWindow + outOfWindow)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = t0...t0.addingTimeInterval(60)
        let series = RRArchiveAggregator.perMinuteHR(rrFiles: [url], window: window)
        #expect(series.count == 1)
        let bpm = try #require(series[0].bpm)
        // Should reflect only the in-window 60-BPM samples, not the out-of-window
        // 500-ms (120 BPM) samples.
        #expect(abs(bpm - 60.0) < 0.001)
    }

    @Test("a bucket whose mean BPM exceeds physiological bounds yields nil")
    func preClipRejectsExtremeMean() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // 60 samples at 251 ms RR (just inside RR range, ~239 BPM > 220 cap).
        let samples: [RRIntervalSample] = (0..<60).map { i in
            RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: 251)
        }
        let url = try writeFixture(samples)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = t0...t0.addingTimeInterval(60)
        let series = RRArchiveAggregator.perMinuteHR(rrFiles: [url], window: window)
        #expect(series.count == 1)
        #expect(series[0].bpm == nil)  // 239 BPM > 220 cap
    }

    @Test("same input file yields the same HRMinutePoint.id sequence across runs")
    func deterministicPointIDs() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [RRIntervalSample] = (0..<180).map { i in
            RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: 1000)
        }
        let url = try writeFixture(samples)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = t0...t0.addingTimeInterval(3 * 60)
        let first = RRArchiveAggregator.perMinuteHR(rrFiles: [url], window: window)
        let second = RRArchiveAggregator.perMinuteHR(rrFiles: [url], window: window)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("awake intervals fully inside the window are counted; outside ones are not")
    func awakeCountWindowFiltering() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let window = t0...t0.addingTimeInterval(8 * 3600)
        let intervals: [(start: Date, end: Date)] = [
            (t0.addingTimeInterval(1 * 3600), t0.addingTimeInterval(1 * 3600 + 120)),  // in
            (t0.addingTimeInterval(3 * 3600), t0.addingTimeInterval(3 * 3600 + 60)),   // in
            (t0.addingTimeInterval(-3600), t0.addingTimeInterval(-1800)),              // out (before)
        ]
        let count = RRArchiveAggregator.awakeIntervalCount(intervals: intervals, in: window)
        #expect(count == 2)
    }

    @Test("an empty intervals array returns zero")
    func awakeCountEmpty() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let window = t0...t0.addingTimeInterval(3600)
        #expect(RRArchiveAggregator.awakeIntervalCount(intervals: [], in: window) == 0)
    }

    @Test("an interval that straddles the window's start edge still counts")
    func awakeCountStraddleCounts() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let window = t0...t0.addingTimeInterval(3600)
        // Awake span from t0-60s to t0+60s — overlaps the start of the window.
        let intervals: [(start: Date, end: Date)] = [
            (t0.addingTimeInterval(-60), t0.addingTimeInterval(60)),
        ]
        #expect(RRArchiveAggregator.awakeIntervalCount(intervals: intervals, in: window) == 1)
    }

    @Test("a session with a trailing partial minute keeps the tail bucket (ceiling, not floor)")
    func partialMinuteTailBucket() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // 90-second window: ceiling = 2 buckets, floor would be 1.
        // 60 samples at 1000 ms RR (= 60 BPM) in minute 0, 30 samples in minute 1.
        let samples: [RRIntervalSample] =
            (0..<60).map { i in
                RRIntervalSample(timestamp: t0.addingTimeInterval(Double(i)), rrMs: 1000)
            }
            + (0..<30).map { i in
                RRIntervalSample(timestamp: t0.addingTimeInterval(60 + Double(i)), rrMs: 1000)
            }
        let url = try writeFixture(samples)
        defer { try? FileManager.default.removeItem(at: url) }

        let window = t0...t0.addingTimeInterval(90)
        let series = RRArchiveAggregator.perMinuteHR(rrFiles: [url], window: window)

        // 2 buckets: minute 0 (60 samples) and minute 1 (30 samples, partial).
        #expect(series.count == 2)
        let bpm0 = try #require(series[0].bpm)
        let bpm1 = try #require(series[1].bpm)
        #expect(abs(bpm0 - 60.0) < 0.001)
        #expect(abs(bpm1 - 60.0) < 0.001)
    }
}
