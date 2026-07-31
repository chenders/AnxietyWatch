import Foundation

/// An actor-based throttle that coalesces rapid-fire events.
/// It waits `debounceInterval` after an event before firing,
/// but enforces a `maxDelay` from the *first* event in a burst
/// to guarantee progress during a steady trickle.
public actor CoalescingThrottle {
    private let debounceInterval: TimeInterval
    private let maxDelay: TimeInterval
    private let action: @Sendable () async -> Void

    private var pendingTask: Task<Void, Never>?
    private var firstEventTime: Date?
    private var isExecuting: Bool = false
    private var isPendingExecution: Bool = false

    /// Dependency injection for the current time to allow deterministic testing.
    private let nowProvider: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        debounceInterval: TimeInterval = 60,
        maxDelay: TimeInterval = 60,
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        },
        action: @escaping @Sendable () async -> Void
    ) {
        self.debounceInterval = debounceInterval
        self.maxDelay = maxDelay
        self.nowProvider = nowProvider
        self.sleep = sleep
        self.action = action
    }

    /// Signals that an event occurred.
    public func event() {
        let now = nowProvider()

        if firstEventTime == nil {
            firstEventTime = now
        }

        guard let firstTime = firstEventTime else { return }

        let elapsed = now.timeIntervalSince(firstTime)
        let remainingMaxDelay = maxDelay - elapsed

        let delay: TimeInterval
        if remainingMaxDelay <= 0 {
            delay = 0
        } else {
            delay = min(debounceInterval, remainingMaxDelay)
        }

        pendingTask?.cancel()
        isPendingExecution = true
        
        pendingTask = Task {
            do {
                if delay > 0 {
                    try await self.sleep(delay)
                }
            } catch {
                return // Task cancelled
            }

            guard !Task.isCancelled else { return }
            await self.executeAction()
        }
    }

    private func executeAction() async {
        isPendingExecution = false
        firstEventTime = nil
        pendingTask = nil

        // Guard against overlapping executions if maxDelay triggered exactly when another execution is running.
        // Actually, since this is an actor, this function executes serially.
        // But if action() takes time and we await it, the actor is re-entrant!
        // To prevent multiple concurrent `action()` runs, we track `isExecuting`.
        guard !isExecuting else {
            // If already executing, we dropped the trailing event's execution window!
            // We should re-schedule an event to ensure the trailing state is handled.
            self.event()
            return
        }

        isExecuting = true
        // The action can suspend. We await it here so that the throttle doesn't overlappingly fire.
        await action()
        isExecuting = false
    }
    
    /// Allows tests to wait until all pending throttled work completes.
    public func flushForTesting() async {
        pendingTask?.cancel()
        if isPendingExecution {
            isPendingExecution = false
            firstEventTime = nil
            pendingTask = nil
            await executeAction()
        }
        while isExecuting {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
