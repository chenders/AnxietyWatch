import XCTest
@testable import AnxietyWatchKit

final class PolarActorTests: XCTestCase {
    
    func testIngestYieldsOnOutbound() async throws {
        let actor = PolarActor(bufferSize: 1000)
        
        // Ingest 3 samples
        let sample1 = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [800, 850])
        let sample2 = PolarActor.HRSample(timestamp: 101.0, heartRate: 72, rrIntervals: [780, 820])
        let sample3 = PolarActor.HRSample(timestamp: 102.0, heartRate: 75, rrIntervals: [750, 800, 850])
        
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
        let actor = PolarActor(bufferSize: bufferSize)
        
        // Ingest 10 samples (more than buffer size)
        for i in 0..<10 {
            let sample = PolarActor.HRSample(timestamp: Double(100 + i), heartRate: 70 + i, rrIntervals: [800 + i * 10])
            await actor.ingest(sample)
        }
        
        // Collect samples using the actor's helper method - should only get the latest 5
        let receivedSamples = await actor.collectSamples(count: bufferSize)
        
        XCTAssertEqual(receivedSamples.count, bufferSize)
        
        // Check that we got samples 5-9 (0-indexed), not 0-4
        for i in 0..<bufferSize {
            let expectedIndex = 5 + i  // Should be samples 5, 6, 7, 8, 9
            XCTAssertEqual(receivedSamples[i].timestamp, Double(100 + expectedIndex))
            XCTAssertEqual(receivedSamples[i].heartRate, 70 + expectedIndex)
        }
    }
    
    func testLastFrameAtAdvances() async throws {
        let actor = PolarActor()
        
        // Initially should be nil
        let initialLastFrame = await actor.lastFrameAtTimestamp
        XCTAssertNil(initialLastFrame)
        
        // Ingest at t=100
        let sample1 = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [])
        await actor.ingest(sample1)
        let lastFrame1 = await actor.lastFrameAtTimestamp
        XCTAssertEqual(lastFrame1, 100.0)
        
        // Ingest at t=200
        let sample2 = PolarActor.HRSample(timestamp: 200.0, heartRate: 75, rrIntervals: [])
        await actor.ingest(sample2)
        let lastFrame2 = await actor.lastFrameAtTimestamp
        XCTAssertEqual(lastFrame2, 200.0)
    }
    
    func testIsIdleTrueWhenNoFrames() async throws {
        let actor = PolarActor()
        
        // Fresh actor with no ingest should be idle
        let isIdle = await actor.isIdle(now: 1000.0)
        XCTAssertTrue(isIdle)
    }
    
    func testIsIdleFalseWithinWindow() async throws {
        let actor = PolarActor()
        
        // Ingest at t=100
        let sample = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [])
        await actor.ingest(sample)
        
        // Check at t=130 with 60s idle window - should not be idle (only 30s passed)
        let isIdle = await actor.isIdle(now: 130.0, idleAfterSeconds: 60.0)
        XCTAssertFalse(isIdle)
    }
    
    func testIsIdleTrueAfterWindow() async throws {
        let actor = PolarActor()
        
        // Ingest at t=100
        let sample = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [])
        await actor.ingest(sample)
        
        // Check at t=200 with 60s idle window - should be idle (100s passed)
        let isIdle = await actor.isIdle(now: 200.0, idleAfterSeconds: 60.0)
        XCTAssertTrue(isIdle)
    }
    
    func testHRSampleEquatable() async throws {
        let sample1 = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [800, 850])
        let sample2 = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [800, 850])
        let sample3 = PolarActor.HRSample(timestamp: 100.0, heartRate: 70, rrIntervals: [800, 900]) // Different RR intervals
        let sample4 = PolarActor.HRSample(timestamp: 101.0, heartRate: 70, rrIntervals: [800, 850]) // Different timestamp
        
        // Identical samples should be equal
        XCTAssertEqual(sample1, sample2)
        
        // Different RR intervals should not be equal
        XCTAssertNotEqual(sample1, sample3)
        
        // Different timestamps should not be equal
        XCTAssertNotEqual(sample1, sample4)
    }
}