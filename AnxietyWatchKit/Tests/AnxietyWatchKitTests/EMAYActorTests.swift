import XCTest
@testable import AnxietyWatchKit

final class EMAYActorTests: XCTestCase {
    
    func testIngestYieldsInOrder() async throws {
        let actor = EMAYActor(bufferSize: 1000)
        
        // Ingest 3 samples
        let sample1 = EMAYActor.OxygenSample(
            timestamp: 100.0, 
            spo2Percent: 98, 
            pulseRate: 70, 
            signalQuality: 12, 
            batteryPercent: 85
        )
        let sample2 = EMAYActor.OxygenSample(
            timestamp: 101.0, 
            spo2Percent: 97, 
            pulseRate: 72, 
            signalQuality: 11, 
            batteryPercent: 84
        )
        let sample3 = EMAYActor.OxygenSample(
            timestamp: 102.0, 
            spo2Percent: 99, 
            pulseRate: 75, 
            signalQuality: 13, 
            batteryPercent: 83
        )
        
        await actor.ingest(sample1)
        await actor.ingest(sample2)
        await actor.ingest(sample3)
        
        // Collect samples using the actor's helper method
        let receivedSamples = await actor.collectSamples(count: 3)
        
        XCTAssertEqual(receivedSamples.count, 3)
        XCTAssertEqual(receivedSamples[0], sample1)
        XCTAssertEqual(receivedSamples[1], sample2)
        XCTAssertEqual(receivedSamples[2], sample3)
    }
    
    func testBackpressureDropsOldest() async throws {
        let bufferSize = 5
        let actor = EMAYActor(bufferSize: bufferSize)
        
        // Ingest 10 samples (more than buffer size)
        for i in 0..<10 {
            let sample = EMAYActor.OxygenSample(
                timestamp: Double(100 + i), 
                spo2Percent: 95 + (i % 6), 
                pulseRate: 65 + i, 
                signalQuality: 10 + (i % 6), 
                batteryPercent: 80 + (i % 21)
            )
            await actor.ingest(sample)
        }
        
        // Collect samples using the actor's helper method - should only get the latest 5
        let receivedSamples = await actor.collectSamples(count: bufferSize)
        
        XCTAssertEqual(receivedSamples.count, bufferSize)
        
        // Check that we got samples 5-9 (0-indexed), not 0-4
        for i in 0..<bufferSize {
            let expectedIndex = 5 + i  // Should be samples 5, 6, 7, 8, 9
            XCTAssertEqual(receivedSamples[i].timestamp, Double(100 + expectedIndex))
            XCTAssertEqual(receivedSamples[i].spo2Percent, 95 + (expectedIndex % 6))
            XCTAssertEqual(receivedSamples[i].pulseRate, 65 + expectedIndex)
        }
    }
    
    func testLastFrameAtTracks() async throws {
        let actor = EMAYActor()
        
        // Initially should be nil
        let initialLastFrame = await actor.lastFrameAtTimestamp
        XCTAssertNil(initialLastFrame)
        
        // Ingest at t=100
        let sample1 = EMAYActor.OxygenSample(
            timestamp: 100.0, 
            spo2Percent: 98, 
            pulseRate: 70, 
            signalQuality: 12, 
            batteryPercent: nil
        )
        await actor.ingest(sample1)
        let lastFrame1 = await actor.lastFrameAtTimestamp
        XCTAssertEqual(lastFrame1, 100.0)
        
        // Ingest at t=200
        let sample2 = EMAYActor.OxygenSample(
            timestamp: 200.0, 
            spo2Percent: 97, 
            pulseRate: nil, 
            signalQuality: 11, 
            batteryPercent: 85
        )
        await actor.ingest(sample2)
        let lastFrame2 = await actor.lastFrameAtTimestamp
        XCTAssertEqual(lastFrame2, 200.0)
    }
    
    func testIsIdleBoundary() async throws {
        // Test all 3 idle cases
        
        // Case 1: No frames → should be idle
        let actor1 = EMAYActor()
        let isIdle1 = await actor1.isIdle(now: 1000.0)
        XCTAssertTrue(isIdle1, "Fresh actor with no ingest should be idle")
        
        // Case 2: Recent frame within window → should not be idle
        let actor2 = EMAYActor()
        let recentSample = EMAYActor.OxygenSample(
            timestamp: 100.0, 
            spo2Percent: 98, 
            pulseRate: 70, 
            signalQuality: 12, 
            batteryPercent: 85
        )
        await actor2.ingest(recentSample)
        let isIdle2 = await actor2.isIdle(now: 130.0, idleAfterSeconds: 60.0)
        XCTAssertFalse(isIdle2, "Should not be idle when recent frame is within window")
        
        // Case 3: Old frame beyond window → should be idle
        let actor3 = EMAYActor()
        let oldSample = EMAYActor.OxygenSample(
            timestamp: 100.0, 
            spo2Percent: 98, 
            pulseRate: 70, 
            signalQuality: 12, 
            batteryPercent: 85
        )
        await actor3.ingest(oldSample)
        let isIdle3 = await actor3.isIdle(now: 200.0, idleAfterSeconds: 60.0)
        XCTAssertTrue(isIdle3, "Should be idle when last frame is beyond idle window")
    }
    
    func testOxygenSampleEquatable() async throws {
        let sample1 = EMAYActor.OxygenSample(
            timestamp: 100.0, 
            spo2Percent: 98, 
            pulseRate: 70, 
            signalQuality: 12, 
            batteryPercent: 85
        )
        let sample2 = EMAYActor.OxygenSample(
            timestamp: 100.0, 
            spo2Percent: 98, 
            pulseRate: 70, 
            signalQuality: 12, 
            batteryPercent: 85
        )
        let sample3 = EMAYActor.OxygenSample(
            timestamp: 100.0, 
            spo2Percent: 97, // Different spo2
            pulseRate: 70, 
            signalQuality: 12, 
            batteryPercent: 85
        )
        let sample4 = EMAYActor.OxygenSample(
            timestamp: 101.0, // Different timestamp
            spo2Percent: 98, 
            pulseRate: 70, 
            signalQuality: 12, 
            batteryPercent: 85
        )
        
        // Identical samples should be equal
        XCTAssertEqual(sample1, sample2)
        
        // Different spo2 should not be equal
        XCTAssertNotEqual(sample1, sample3)
        
        // Different timestamps should not be equal
        XCTAssertNotEqual(sample1, sample4)
    }
}