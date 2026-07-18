import XCTest
@testable import AnxietyWatchKit

final class SensorRouterTests: XCTestCase {
    
    func testMergesAllSourcesInOrder() async throws {
        let polarActor = PolarActor(bufferSize: 1000)
        let emayActor = EMAYActor(bufferSize: 1000)
        let hkActor = HealthKitAdapterActor(bufferSize: 1000)
        
        let router = SensorRouter(polar: polarActor, emay: emayActor, healthKit: hkActor)
        
        // Ingest one frame each
        let polarSample = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [800, 850])
        let emaySample = EMAYActor.OxygenSample(timestamp: 101.0, spo2Percent: 98, pulseRate: 72, signalQuality: 12, batteryPercent: 85)
        let hkSample = HealthKitAdapterActor.HKSample(timestamp: 102.0, quantityType: .heartRate, value: 75)
        
        await polarActor.ingest(polarSample)
        await emayActor.ingest(emaySample)
        await hkActor.ingest(hkSample)
        
        // Collect exactly three samples and await deterministic completion.
        // No sleep or cancellation race is needed because each upstream was
        // populated before the merged stream was consumed.
        let receivedSamples = await Task {
            var samples: [SensorRouter.AnySensorSample] = []
            let stream = await router.outbound
            for await sample in stream {
                samples.append(sample)
                if samples.count == 3 { break }
            }
            return samples
        }.value

        XCTAssertEqual(receivedSamples.count, 3)
        
        // Check that we have all three types (order may vary)
        var hasPolar = false
        var hasEmay = false
        var hasHK = false
        
        for sample in receivedSamples {
            switch sample {
            case .polar:
                hasPolar = true
            case .emay:
                hasEmay = true
            case .healthkit:
                hasHK = true
            case .oura:
                break // Oura samples not injected in this test
            }
        }
        
        XCTAssertTrue(hasPolar, "Should have received polar sample")
        XCTAssertTrue(hasEmay, "Should have received emay sample")
        XCTAssertTrue(hasHK, "Should have received hk sample")
    }
    
    func testIsIdleTrueWhenAllUpstreamsIdle() async throws {
        let polarActor = PolarActor(bufferSize: 1000)
        let emayActor = EMAYActor(bufferSize: 1000)
        
        let router = SensorRouter(polar: polarActor, emay: emayActor, healthKit: nil)
        
        // No ingest on any upstreams
        let isIdle = await router.isIdle(now: 1000.0)
        XCTAssertTrue(isIdle, "Should be idle when no frames have been ingested")
    }
    
    func testIsIdleFalseWhenAnyUpstreamActive() async throws {
        let polarActor = PolarActor(bufferSize: 1000)
        let emayActor = EMAYActor(bufferSize: 1000)
        
        let router = SensorRouter(polar: polarActor, emay: emayActor, healthKit: nil)
        
        // Ingest into one upstream at t=100
        let polarSample = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [800, 850])
        await polarActor.ingest(polarSample)
        
        // Check at t=130 with 60s BLE window - should not be idle (only 30s passed)
        let isIdle = await router.isIdle(now: 130.0)
        XCTAssertFalse(isIdle, "Should not be idle when one upstream has recent activity")
    }
    
    func testIsIdleTrueAfterAllUpstreamsQuiescent() async throws {
        let polarActor = PolarActor(bufferSize: 1000)
        let emayActor = EMAYActor(bufferSize: 1000)
        
        let router = SensorRouter(polar: polarActor, emay: emayActor, healthKit: nil)
        
        // Ingest at t=100
        let polarSample = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [800, 850])
        await polarActor.ingest(polarSample)
        
        // Check at t=200 with 60s BLE window - should be idle (100s > 60s)
        let isIdle = await router.isIdle(now: 200.0)
        XCTAssertTrue(isIdle, "Should be idle when all upstreams have been quiescent for long enough")
    }
    
    func testHKUsesLongerIdleWindow() async throws {
        let hkActor = HealthKitAdapterActor(bufferSize: 1000)
        let router = SensorRouter(polar: nil, emay: nil, healthKit: hkActor)
        
        // HK ingest at t=100
        let hkSample = HealthKitAdapterActor.HKSample(timestamp: 100.0, quantityType: .heartRate, value: 75)
        await hkActor.ingest(hkSample)
        
        // Check at t=250 with 300s HK window - should not be idle (250-100 = 150 < 300)
        let isIdle1 = await router.isIdle(now: 250.0)
        XCTAssertFalse(isIdle1, "Should not be idle when HK has recent activity within 300s window")
        
        // Check at t=500 with 300s HK window - should be idle (500-100 = 400 >= 300)
        let isIdle2 = await router.isIdle(now: 500.0)
        XCTAssertTrue(isIdle2, "Should be idle when HK has been quiescent for 300s")
    }
    
    func testNilUpstreamsTreatedAsIdle() async throws {
        // Attach only polar, leave others nil
        let polarActor = PolarActor(bufferSize: 1000)
        let router = SensorRouter(polar: polarActor, emay: nil, healthKit: nil)
        
        // No ingest on polar
        let isIdle1 = await router.isIdle(now: 1000.0)
        XCTAssertTrue(isIdle1, "Should be idle when only attached upstream is idle")
        
        // Ingest into polar
        let polarSample = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [800, 850])
        await polarActor.ingest(polarSample)
        
        // Should not be idle now
        let isIdle2 = await router.isIdle(now: 130.0)
        XCTAssertFalse(isIdle2, "Should not be idle when attached upstream has recent activity")
    }
    
    func testStorageCoordinatesCovered() async throws {
        // Test Polar coordinates
        let polarSample = SensorRouter.AnySensorSample.polar(
            PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [800, 850])
        )
        XCTAssertEqual(polarSample.storageCoordinates.source, 1, "Polar source should be 1")
        XCTAssertEqual(polarSample.storageCoordinates.type, 1, "Polar HR type should be 1")
        
        // Test EMAY coordinates
        let emaySample = SensorRouter.AnySensorSample.emay(
            EMAYActor.OxygenSample(timestamp: 100.0, spo2Percent: 98, pulseRate: 72, signalQuality: 12, batteryPercent: 85)
        )
        XCTAssertEqual(emaySample.storageCoordinates.source, 0, "EMAY source should be 0")
        XCTAssertEqual(emaySample.storageCoordinates.type, 2, "EMAY SpO2 type should be 2")
        
        // Test HealthKit coordinates (HR)
        let hkHRSample = SensorRouter.AnySensorSample.healthkit(
            HealthKitAdapterActor.HKSample(timestamp: 100.0, quantityType: .heartRate, value: 75)
        )
        XCTAssertEqual(hkHRSample.storageCoordinates.source, 2, "HealthKit source should be 2")
        XCTAssertEqual(hkHRSample.storageCoordinates.type, 1, "HealthKit HR type should be 1")
        
        // Test HealthKit coordinates (HRV)
        let hkHRVSample = SensorRouter.AnySensorSample.healthkit(
            HealthKitAdapterActor.HKSample(timestamp: 100.0, quantityType: .heartRateVariability, value: 50)
        )
        XCTAssertEqual(hkHRVSample.storageCoordinates.source, 2, "HealthKit source should be 2")
        XCTAssertEqual(hkHRVSample.storageCoordinates.type, 4, "HealthKit HRV type should be 4 (matches SamplesStore.healthKitOwnedTypes)")
    }
}