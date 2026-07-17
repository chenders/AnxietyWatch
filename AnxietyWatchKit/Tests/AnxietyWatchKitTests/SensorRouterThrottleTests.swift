import Foundation
import Testing
@testable import AnxietyWatchKit

@Suite struct SensorRouterThrottleTests {

    /// Reference-type accumulator so the test body can read what the task collected.
    private final class Collector: @unchecked Sendable {
        var snapshots: [ViewModelSnapshot] = []
    }

    @Test func testThrottleEmitsSnapshots() async throws {
        let router = SensorRouter(polar: nil, emay: nil, healthKit: nil)
        let ts = await router.throttled(rate: 5)

        // Push many samples rapidly. The per-subscriber rate limiter caps throughput.
        for i in 0..<100 {
            await router.push(SensorRouter.AnySensorSample.polar(
                PolarActor.HRSample(timestamp: Double(i) * 0.01, heartRate: 70 + (i % 10), rrIntervals: [])))
        }

        let c = Collector()
        let task = Task { for await snap in ts { c.snapshots.append(snap); if c.snapshots.count >= 10 { break } } }
        try? await Task.sleep(for: .seconds(3))
        task.cancel(); _ = await task.value

        #expect(c.snapshots.count >= 2, "Expected ≥2 snapshots, got \(c.snapshots.count)")
        #expect(c.snapshots.count <= 15, "Expected ≤15 snapshots, got \(c.snapshots.count)")
    }

    @Test func testSnapshotContainsLatestHR() async throws {
        let router = SensorRouter(polar: nil, emay: nil, healthKit: nil)
        let ts = await router.throttled(rate: 20)

        await router.push(SensorRouter.AnySensorSample.polar(
            PolarActor.HRSample(timestamp: Date().timeIntervalSince1970, heartRate: 72, rrIntervals: [])))

        let c = Collector()
        let task = Task { for await snap in ts { c.snapshots.append(snap); if c.snapshots.count >= 3 { break } } }
        try? await Task.sleep(for: .seconds(2))
        task.cancel(); _ = await task.value

        let hasHR = c.snapshots.contains { $0.latestHR == 72 }
        #expect(hasHR, "Expected HR=72, got \(c.snapshots.map(\.latestHR))")
    }

    @Test func testIdleFlagWhenNoFrames() async throws {
        let router = SensorRouter(polar: nil, emay: nil, healthKit: nil)
        let ts = await router.throttled(rate: 10)

        await router.push(SensorRouter.AnySensorSample.polar(
            PolarActor.HRSample(timestamp: Date().timeIntervalSince1970 - 100, heartRate: 70, rrIntervals: [])))

        let c = Collector()
        let task = Task { for await snap in ts { c.snapshots.append(snap); if c.snapshots.count >= 3 { break } } }
        try? await Task.sleep(for: .seconds(2))
        task.cancel(); _ = await task.value

        let hasIdle = c.snapshots.contains { $0.isIdle }
        #expect(hasIdle, "Expected idle snapshot, got \(c.snapshots.map(\.isIdle))")
    }
}
