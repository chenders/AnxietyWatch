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

/// Foreground WebSocket source. Network receive code feeds `ingest`; cursor,
/// lifecycle, and overlap handling remain deterministic and independently
/// testable here. Socket liveness never changes the authoritative state.
@MainActor
final class AS11WebSocketClient: AS11StreamSource {
    private let baseURL: URL
    private let now: () -> Date
    private let staleTimeout: TimeInterval

    private var authoritativeState: AS11StreamState = .streamStalled
    private var samplesByID: [String: AS11StreamPayload] = [:]
    private var orderedIDs: [String] = []
    private var lastFrameAt: Date?

    private(set) var lastCursor: String?
    private(set) var isDropped = true

    init(
        baseURL: URL,
        now: @escaping () -> Date = Date.init,
        staleTimeout: TimeInterval = CNSMonitoringConstants.as11FrameStaleTimeout
    ) {
        self.baseURL = baseURL
        self.now = now
        self.staleTimeout = staleTimeout
    }

    var latestState: AS11StreamState {
        guard !isDropped,
              let lastFrameAt,
              now().timeIntervalSince(lastFrameAt) <= staleTimeout else {
            return .streamStalled
        }
        return authoritativeState
    }

    func latestSamples() -> [AS11StreamPayload] {
        orderedIDs.compactMap { samplesByID[$0] }
    }

    /// Records one server frame. The state is used verbatim while fresh.
    func ingest(state: AS11StreamState, samples: [AS11StreamPayload], receivedAt: Date) {
        authoritativeState = state
        lastFrameAt = receivedAt
        isDropped = false
        for sample in samples where samplesByID[sample.id] == nil {
            samplesByID[sample.id] = sample
            orderedIDs.append(sample.id)
        }
        if let cursor = samples.last?.id {
            lastCursor = cursor
        }
    }

    func willResignActive() {
        isDropped = true
    }

    /// Returns the URL a thin `URLSessionWebSocketTask` transport should use.
    @discardableResult
    func willBecomeActive() -> URL? {
        isDropped = false
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if let lastCursor {
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { $0.name == "since" }
            queryItems.append(URLQueryItem(name: "since", value: lastCursor))
            components.queryItems = queryItems
        }
        return components.url
    }
}
