import Foundation

/// Synchronous snapshot consumed by the 1 Hz CNS coordinator. The state is
/// the server's authoritative state while its most recent frame is fresh;
/// stale or absent frames always degrade to `.streamStalled`.
@MainActor
protocol AS11StreamSource: AnyObject {
    var latestState: AS11StreamState { get }
    func latestSamples() -> [AS11StreamPayload]
}

/// Deterministic source for tests and previews.
@MainActor
final class MockAS11StreamSource: AS11StreamSource {
    var state: AS11StreamState
    var samples: [AS11StreamPayload]
    var lastFrameAt: Date?

    private let now: () -> Date
    private let staleTimeout: TimeInterval

    init(
        state: AS11StreamState = .streamStalled,
        samples: [AS11StreamPayload] = [],
        lastFrameAt: Date? = nil,
        now: @escaping () -> Date = Date.init,
        staleTimeout: TimeInterval = CNSMonitoringConstants.as11FrameStaleTimeout
    ) {
        self.state = state
        self.samples = samples
        self.lastFrameAt = lastFrameAt
        self.now = now
        self.staleTimeout = staleTimeout
    }

    var latestState: AS11StreamState {
        guard let lastFrameAt,
              now().timeIntervalSince(lastFrameAt) <= staleTimeout else {
            return .streamStalled
        }
        return state
    }

    func latestSamples() -> [AS11StreamPayload] {
        samples
    }
}
