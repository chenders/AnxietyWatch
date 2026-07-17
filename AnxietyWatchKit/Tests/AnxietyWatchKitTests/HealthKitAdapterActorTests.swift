import XCTest
@testable import AnxietyWatchKit

final class HealthKitAdapterActorTests: XCTestCase {

    func testIngestAndConsume() async throws {
        let actor = HealthKitAdapterActor()

        let s1 = HealthKitAdapterActor.HKSample(timestamp: 100.0, quantityType: .heartRate, value: 72)
        let s2 = HealthKitAdapterActor.HKSample(timestamp: 160.0, quantityType: .heartRateVariability, value: 45.5)
        let s3 = HealthKitAdapterActor.HKSample(timestamp: 220.0, quantityType: .respiratoryRate, value: 14)

        await actor.ingest(s1)
        await actor.ingest(s2)
        await actor.ingest(s3)

        let received = await actor.collectSamples(count: 3)
        XCTAssertEqual(received, [s1, s2, s3], "FIFO order preserved")

        let last = await actor.lastFrameAt
        XCTAssertEqual(last, 220.0)
    }

    func testBackpressureDropsOldest() async throws {
        let bufferSize = 5
        let actor = HealthKitAdapterActor(bufferSize: bufferSize)

        // Ingest 10 samples — more than the buffer holds.
        for i in 0..<10 {
            await actor.ingest(HealthKitAdapterActor.HKSample(
                timestamp: Double(100 + i), quantityType: .heartRate, value: Double(70 + i)))
        }

        // bufferingNewest keeps the NEWEST 5: samples 5...9.
        let received = await actor.collectSamples(count: bufferSize)
        XCTAssertEqual(received.count, bufferSize)
        for (i, sample) in received.enumerated() {
            let expected = 5 + i
            XCTAssertEqual(sample.timestamp, Double(100 + expected))
            XCTAssertEqual(sample.value, Double(70 + expected))
        }
    }

    func testAnchorRoundTrip() async throws {
        let actor = HealthKitAdapterActor()

        // Fresh actor: no anchor.
        let initial = await actor.currentAnchor
        XCTAssertNil(initial)

        // Round-trip a driver-persisted anchor blob.
        let anchorBlob = Data([0x01, 0x02, 0x03, 0x04])
        await actor.setAnchor(anchorBlob)
        let restored = await actor.currentAnchor
        XCTAssertEqual(restored, anchorBlob)

        // Clearing works too (fresh-install / reset path).
        await actor.setAnchor(nil)
        let cleared = await actor.currentAnchor
        XCTAssertNil(cleared)
    }

    func testIsIdleBoundary() async throws {
        let actor = HealthKitAdapterActor()

        // Case 1: no samples ever — idle.
        let idleNoFrames = await actor.isIdle(now: 1_000)
        XCTAssertTrue(idleNoFrames)

        await actor.ingest(HealthKitAdapterActor.HKSample(
            timestamp: 1_000, quantityType: .heartRate, value: 70))

        // Case 2: inside the 300 s window (299 s elapsed) — NOT idle.
        let idleInside = await actor.isIdle(now: 1_299)
        XCTAssertFalse(idleInside)

        // Case 3: exactly at the boundary (300 s elapsed) — idle (>=).
        let idleAtBoundary = await actor.isIdle(now: 1_300)
        XCTAssertTrue(idleAtBoundary)
    }

    func testAllQuantityTypesRoundTrip() async throws {
        let actor = HealthKitAdapterActor()

        // One sample per QuantityType — the closed HK-owned set (Spec §1.7).
        let samples = HealthKitAdapterActor.HKSample.QuantityType.allCases.enumerated().map { i, qt in
            HealthKitAdapterActor.HKSample(timestamp: Double(100 + i), quantityType: qt, value: Double(i) + 0.5)
        }
        for sample in samples {
            await actor.ingest(sample)
        }

        let received = await actor.collectSamples(count: samples.count)
        XCTAssertEqual(received, samples)
        XCTAssertEqual(Set(received.map(\.quantityType)),
                       Set(HealthKitAdapterActor.HKSample.QuantityType.allCases))

        // Raw values are the stable wire/persistence identifiers.
        XCTAssertEqual(HealthKitAdapterActor.HKSample.QuantityType.heartRate.rawValue, "heartRate")
        XCTAssertEqual(HealthKitAdapterActor.HKSample.QuantityType.heartRateVariability.rawValue, "heartRateVariability")
        XCTAssertEqual(HealthKitAdapterActor.HKSample.QuantityType.respiratoryRate.rawValue, "respiratoryRate")
    }
}
