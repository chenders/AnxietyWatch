import Testing
import Foundation
@testable import AnxietyWatch

@Suite("CoalescingThrottle Tests")
struct CoalescingThrottleTests {
    
    @Test("Steady trickle yields one pass per maxDelay window")
    func steadyTrickle() async throws {
        let clock = TestClock()
        
        let counter = ActorCounter()
        let throttle = CoalescingThrottle(
            debounceInterval: 60,
            maxDelay: 60,
            nowProvider: { clock.now },
            sleep: { delay in try await clock.sleep(for: delay) }
        ) {
            await counter.increment()
        }
        
        // Deliveries spaced 10s apart over 5 minutes (300 seconds).
        // 30 deliveries total.
        for _ in 0..<30 {
            await throttle.event()
            // Advance clock by 10s
            await clock.advance(by: 10)
            // Await a small real-time sleep to allow async tasks to schedule
            try await Task.sleep(for: .milliseconds(5))
        }
        
        // At the end, maxDelay was 60s. So we should have triggered once per 60 seconds.
        // 300 seconds total / 60 seconds = 5 aggregations.
        // Let's flush anything pending
        await throttle.flushForTesting()
        
        let count = await counter.count
        // Expecting around 5 aggregations, certainly not 30.
        #expect(count >= 4 && count <= 6)
    }
    
    @Test("A single event fires after debounce")
    func singleEvent() async throws {
        let clock = TestClock()
        let counter = ActorCounter()
        let throttle = CoalescingThrottle(
            debounceInterval: 60,
            maxDelay: 60,
            nowProvider: { clock.now },
            sleep: { delay in try await clock.sleep(for: delay) }
        ) {
            await counter.increment()
        }
        
        await throttle.event()
        try await Task.sleep(for: .milliseconds(10)) // let task start
        
        let initialCount = await counter.count
        #expect(initialCount == 0)
        
        await clock.advance(by: 60)
        try await Task.sleep(for: .milliseconds(10))
        
        await throttle.flushForTesting()
        
        let finalCount = await counter.count
        #expect(finalCount == 1)
    }
}

actor ActorCounter {
    var count: Int = 0
    func increment() {
        count += 1
    }
}

actor TestClock {
    var now: Date = Date(timeIntervalSince1970: 0)
    
    struct SleepRequest {
        let id: UUID
        let resumeAt: Date
        let continuation: CheckedContinuation<Void, Error>
    }
    
    var pendingSleeps: [SleepRequest] = []
    
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let toResume = pendingSleeps.filter { $0.resumeAt <= now }
        pendingSleeps.removeAll { $0.resumeAt <= now }
        for sleep in toResume {
            sleep.continuation.resume()
        }
    }
    
    func sleep(for seconds: TimeInterval) async throws {
        let resumeAt = now.addingTimeInterval(seconds)
        let id = UUID()
        
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await self.addSleep(id: id, resumeAt: resumeAt, continuation: continuation)
                }
            }
        } onCancel: {
            Task {
                await self.cancelSleep(id: id)
            }
        }
    }
    
    private func addSleep(id: UUID, resumeAt: Date, continuation: CheckedContinuation<Void, Error>) {
        if resumeAt <= now {
            continuation.resume()
        } else {
            pendingSleeps.append(SleepRequest(id: id, resumeAt: resumeAt, continuation: continuation))
        }
    }
    
    private func cancelSleep(id: UUID) {
        if let index = pendingSleeps.firstIndex(where: { $0.id == id }) {
            let request = pendingSleeps.remove(at: index)
            request.continuation.resume(throwing: CancellationError())
        }
    }
}

