import XCTest
@testable import AnxietyWatchKit

final class ClockSuspectGateTests: XCTestCase {
    
    // Mock time variables
    private var mockWall: Int64 = 0
    private var mockMono: Int64 = 0
    
    // Helper to create gate with mock time functions
    private func makeGate() -> ClockSuspectGate {
        return ClockSuspectGate(
            wallNow: { self.mockWall },
            monotonicNow: { self.mockMono },
            driftThresholdMillis: 60_000,  // 60 seconds
            setSustainedFor: 300,          // 5 minutes
            clearSustainedFor: 900         // 15 minutes
        )
    }
    
    override func setUp() async throws {
        mockWall = 0
        mockMono = 0
    }
    
    // MARK: - Tests
    
    func testInBoundsNeverSets() async throws {
        let gate = makeGate()
        
        // 20 samples all within 100ms divergence
        for i in 0..<20 {
            mockWall += 30_000  // Advance 30 seconds
            mockMono += 30_000
            await gate.sample()
            let isSuspect = await gate.isSuspect
            XCTAssertFalse(isSuspect, "Should not be suspect at sample \(i)")
        }
    }
    
    func testSetsAfterSustainedDrift() async throws {
        let gate = makeGate()

        // 10 in-bounds samples (5 minutes) — must not set.
        for _ in 0..<10 {
            mockWall += 30_000
            mockMono += 30_000
            await gate.sample()
        }
        var isSuspect = await gate.isSuspect
        XCTAssertFalse(isSuspect)

        // Introduce 61s drift. Feed samples for 5 more minutes (10 x 30s). Both
        // clocks advance together after the drift is introduced.
        mockMono = mockWall - 61_000
        for _ in 0..<11 {
            mockWall += 30_000
            mockMono += 30_000
            await gate.sample()
        }

        isSuspect = await gate.isSuspect
        XCTAssertTrue(isSuspect, "Should be suspect after sustained drift")
    }

    func testDoesNotSetOnTransientBurst() async throws {
        let gate = makeGate()

        // 3 out-of-bounds samples (≈90 s of drift) then return to bounds —
        // never sustains 5 min out-of-bounds.
        mockMono = mockWall - 100_000
        for _ in 0..<3 {
            mockWall += 30_000
            mockMono += 30_000
            await gate.sample()
        }
        // Return to bounds.
        mockMono = mockWall
        for _ in 0..<30 {
            mockWall += 30_000
            mockMono += 30_000
            await gate.sample()
        }

        let isSuspect = await gate.isSuspect
        XCTAssertFalse(isSuspect, "Transient out-of-bounds burst must not set suspect")
    }

    func testClearsAfterSustainedReturn() async throws {
        let gate = makeGate()

        // Force set: 5 min in-bounds then 5+ min drift.
        for _ in 0..<10 { mockWall += 30_000; mockMono += 30_000; await gate.sample() }
        mockMono = mockWall - 61_000
        for _ in 0..<11 { mockWall += 30_000; mockMono += 30_000; await gate.sample() }
        let suspectAfterSet1 = await gate.isSuspect
        XCTAssertTrue(suspectAfterSet1)

        // Return to in-bounds. 15 minutes (30 samples × 30s) needed for clear.
        mockMono = mockWall
        for _ in 0..<31 {
            mockWall += 30_000
            mockMono += 30_000
            await gate.sample()
        }

        let isSuspect = await gate.isSuspect
        XCTAssertFalse(isSuspect, "Should clear after sustained in-bounds")
    }

    func testDoesNotClearOnTransientReturn() async throws {
        let gate = makeGate()

        // Force set first.
        for _ in 0..<10 { mockWall += 30_000; mockMono += 30_000; await gate.sample() }
        mockMono = mockWall - 61_000
        for _ in 0..<11 { mockWall += 30_000; mockMono += 30_000; await gate.sample() }
        let suspectAfterSet2 = await gate.isSuspect
        XCTAssertTrue(suspectAfterSet2)

        // 10 in-bounds samples (5 min) then bounce out again.
        mockMono = mockWall
        for _ in 0..<10 { mockWall += 30_000; mockMono += 30_000; await gate.sample() }
        mockMono = mockWall - 65_000
        for _ in 0..<3 { mockWall += 30_000; mockMono += 30_000; await gate.sample() }

        let isSuspect = await gate.isSuspect
        XCTAssertTrue(isSuspect, "Transient in-bounds return must not clear suspect")
    }

    func testEventsFireOnSetAndClearTransitions() async throws {
        let gate = makeGate()

        // Subscribe to events BEFORE driving state.
        let events = await gate.events
        var iter = events.makeAsyncIterator()

        // Drive: in-bounds → drift → set → in-bounds → clear.
        for _ in 0..<10 { mockWall += 30_000; mockMono += 30_000; await gate.sample() }
        mockMono = mockWall - 61_000
        for _ in 0..<11 { mockWall += 30_000; mockMono += 30_000; await gate.sample() }

        let setEvent = await iter.next()
        if case .set = setEvent {} else { XCTFail("Expected .set, got \(String(describing: setEvent))") }

        mockMono = mockWall
        for _ in 0..<31 { mockWall += 30_000; mockMono += 30_000; await gate.sample() }

        let clearedEvent = await iter.next()
        if case .cleared = clearedEvent {} else { XCTFail("Expected .cleared, got \(String(describing: clearedEvent))") }
    }
}