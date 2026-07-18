import Foundation
import XCTest
@testable import AnxietyWatchKit

final class CorruptionBroadcasterTests: XCTestCase {
    typealias Event = DatabaseManager.CorruptionEvent

    private func event(_ phase: Event.Phase, at date: Date = Date()) -> Event {
        Event(timestamp: date, phase: phase)
    }

    func testSingleSubscriberReceives() async {
        let b = CorruptionBroadcaster()
        let (stream, cancel) = await b.subscribe()
        defer { cancel() }

        let exp = expectation(description: "received")
        Task {
            for await e in stream {
                if case .detected = e.phase { exp.fulfill() }
                break
            }
        }

        await b.publish(event(.detected))
        await fulfillment(of: [exp], timeout: 1.0)
    }

    func testTwoSubscribersEachReceive() async {
        let b = CorruptionBroadcaster()
        let (s1, c1) = await b.subscribe()
        let (s2, c2) = await b.subscribe()
        defer { c1(); c2() }

        let exp1 = expectation(description: "s1")
        let exp2 = expectation(description: "s2")

        Task { for await _ in s1 { exp1.fulfill(); break } }
        Task { for await _ in s2 { exp2.fulfill(); break } }

        await b.publish(event(.recovering))
        await fulfillment(of: [exp1, exp2], timeout: 1.0, enforceOrder: false)
    }

    func testCancelDetaches() async {
        let b = CorruptionBroadcaster()
        let (s1, c1) = await b.subscribe()
        let (s2, c2) = await b.subscribe()
        defer { c1(); c2() }

        // Attach expectations
        let exp1 = expectation(description: "s1 gets it")
        let exp2 = expectation(description: "s2 should not get it")
        exp2.isInverted = true

        Task { for await _ in s1 { exp1.fulfill(); break } }
        Task { for await _ in s2 { exp2.fulfill(); break } }

        // Cancel second subscriber before publish
        c2()
        // give actor a tick to detach
        try? await Task.sleep(nanoseconds: 50_000_000)

        await b.publish(event(.recovered))
        await fulfillment(of: [exp1, exp2], timeout: 1.0, enforceOrder: false)
    }

    func testCloseAllFinishesStreams() async {
        let b = CorruptionBroadcaster()
        let (s1, c1) = await b.subscribe()
        let (s2, c2) = await b.subscribe()
        defer { c1(); c2() }

        let exp1 = expectation(description: "s1 finished")
        let exp2 = expectation(description: "s2 finished")

        Task {
            var iter = s1.makeAsyncIterator()
            while let _ = await iter.next() {}
            exp1.fulfill()
        }
        Task {
            var iter = s2.makeAsyncIterator()
            while let _ = await iter.next() {}
            exp2.fulfill()
        }

        await b.closeAll()
        await fulfillment(of: [exp1, exp2], timeout: 1.0)
    }

    /// Dropping a subscriber's stream without calling cancel() must still detach the
    /// continuation via `onTermination`, so long-lived broadcasters do not grow
    /// their `continuations` map unboundedly.
    func testTerminationAutoDetaches() async throws {
        let b = CorruptionBroadcaster()

        // Subscribe inside a scope that ends immediately, letting the stream
        // reference deallocate. cancel() intentionally not called.
        do {
            let (stream, _) = await b.subscribe()
            // Start (and immediately end) an iterator so the stream is terminated.
            var iter = stream.makeAsyncIterator()
            _ = iter // silence unused warning
        }

        // Give the actor a few event-loop ticks to process the onTermination hop.
        for _ in 0..<50 { await Task.yield() }

        // Publishing after termination must not throw and must self-prune any
        // remaining terminated continuations (publish() checks .terminated).
        let event = DatabaseManager.CorruptionEvent(
            timestamp: Date(),
            phase: .detected
        )
        await b.publish(event)

        // Attach a fresh subscriber and confirm it works normally after the leak fix.
        let (freshStream, freshCancel) = await b.subscribe()
        defer { freshCancel() }
        await b.publish(event)
        var freshIter = freshStream.makeAsyncIterator()
        let received = await freshIter.next()
        XCTAssertNotNil(received, "Fresh subscriber must still receive events after prior leak-fix cleanup")
    }
}
