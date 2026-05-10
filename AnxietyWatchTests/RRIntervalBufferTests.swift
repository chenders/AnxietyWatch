// AnxietyWatchTests/RRIntervalBufferTests.swift
import Foundation
import Testing

@testable import AnxietyWatch

struct RRIntervalBufferTests {

    @Test("flush returns all intervals appended within the window")
    func flushReturnsRecent() async {
        let buffer = RRIntervalBuffer(window: 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await buffer.append(timestamp: t0, rrMs: 800)
        await buffer.append(timestamp: t0.addingTimeInterval(1), rrMs: 810)
        await buffer.append(timestamp: t0.addingTimeInterval(2), rrMs: 790)

        let intervals = await buffer.flush(at: t0.addingTimeInterval(2))
        #expect(intervals.count == 3)
        #expect(intervals.map(\.rrMs) == [800, 810, 790])
    }

    @Test("flush drops intervals older than the window")
    func flushDropsOld() async {
        let buffer = RRIntervalBuffer(window: 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await buffer.append(timestamp: t0, rrMs: 800)             // old
        await buffer.append(timestamp: t0.addingTimeInterval(70), rrMs: 810) // in window

        let intervals = await buffer.flush(at: t0.addingTimeInterval(70))
        #expect(intervals.count == 1)
        #expect(intervals.first?.rrMs == 810)
    }

    @Test("a second flush in the same window still returns the same retained samples")
    func consecutiveFlushesAreNotDestructive() async {
        let buffer = RRIntervalBuffer(window: 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await buffer.append(timestamp: t0.addingTimeInterval(5), rrMs: 800)

        let first = await buffer.flush(at: t0.addingTimeInterval(10))
        let second = await buffer.flush(at: t0.addingTimeInterval(20))
        #expect(first.count == 1)
        #expect(second.count == 1)
    }

    @Test("flush evicts future-timestamp samples to honor the [now-window, now] contract")
    func flushDropsFuture() async {
        let buffer = RRIntervalBuffer(window: 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await buffer.append(timestamp: t0, rrMs: 800)
        await buffer.append(timestamp: t0.addingTimeInterval(100), rrMs: 810)  // future relative to flush

        let intervals = await buffer.flush(at: t0.addingTimeInterval(30))
        #expect(intervals.count == 1)
        #expect(intervals.first?.rrMs == 800)
    }

    @Test("appending out-of-order timestamps is preserved as inserted")
    func outOfOrderAppendsArePreservedInInsertionOrder() async {
        let buffer = RRIntervalBuffer(window: 60)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        await buffer.append(timestamp: t0.addingTimeInterval(2), rrMs: 800)
        await buffer.append(timestamp: t0.addingTimeInterval(1), rrMs: 810)

        let intervals = await buffer.flush(at: t0.addingTimeInterval(2))
        #expect(intervals.map(\.rrMs) == [800, 810])
    }
}
