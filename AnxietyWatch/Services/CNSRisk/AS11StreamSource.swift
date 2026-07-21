import Foundation

// Reused ISO-8601 parsers: allocating an `ISO8601DateFormatter` per decoded
// timestamp is wasteful on the stream. Parsing is read-only and only runs on
// the @MainActor WS receive path, so sharing single instances is safe;
// `nonisolated(unsafe)` documents that we intentionally opt out of the Sendable
// check for these otherwise-immutable formatters.
private nonisolated(unsafe) let as11FractionalISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private nonisolated(unsafe) let as11PlainISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Synchronous snapshot consumed by the 1 Hz CNS coordinator. The state is
/// the server's authoritative state while its most recent frame is fresh;
/// stale or absent frames always degrade to `.streamStalled`.
@MainActor
protocol AS11StreamSource: AnyObject {
    var latestState: AS11StreamState { get }
    func latestSamples() -> [AS11StreamPayload]
    func connect()
    func suspend()
    func disconnect()
}

/// Deterministic source for tests and previews.
@MainActor
final class MockAS11StreamSource: AS11StreamSource {
    var state: AS11StreamState
    var samples: [AS11StreamPayload]
    var lastFrameAt: Date?
    private(set) var connectCallCount = 0
    private(set) var suspendCallCount = 0
    private(set) var disconnectCallCount = 0

    private let now: () -> Date
    private let staleTimeout: TimeInterval

    init(
        state: AS11StreamState = .streamStalled,
        samples: [AS11StreamPayload] = [],
        lastFrameAt: Date? = nil,
        now: @escaping () -> Date = Date.init,
        staleTimeout: TimeInterval? = nil
    ) {
        self.state = state
        self.samples = samples
        self.lastFrameAt = lastFrameAt
        self.now = now
        self.staleTimeout = staleTimeout ?? CNSMonitoringConstants.as11FrameStaleTimeout
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

    func connect() {
        connectCallCount += 1
    }

    func suspend() {
        suspendCallCount += 1
    }

    func disconnect() {
        disconnectCallCount += 1
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
    private let apiKey: () -> String
    private let session: URLSession

    private var authoritativeState: AS11StreamState = .streamStalled
    private var samplesByID: [String: AS11StreamPayload] = [:]
    private var orderedIDs: [String] = []
    private var lastFrameAt: Date?

    private(set) var lastCursor: String?
    private(set) var isDropped = true
    private(set) var shouldMaintainConnection = false
    private var reconnectAttempt = 0
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    init(
        baseURL: URL,
        now: @escaping () -> Date = Date.init,
        staleTimeout: TimeInterval? = nil,
        apiKey: @escaping () -> String = {
            UserDefaults.standard.string(forKey: "syncApiKey") ?? ""
        },
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.now = now
        self.staleTimeout = staleTimeout ?? CNSMonitoringConstants.as11FrameStaleTimeout
        self.apiKey = apiKey
        self.session = session
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

    /// Records one server frame. The state is used verbatim while fresh. Each
    /// admitted sample is stamped with the LOCAL `receivedAt` so downstream
    /// time-windowing never depends on the bridge host's clock, and the buffer
    /// is pruned to a bounded retention so an all-night session can't grow it
    /// without limit.
    func ingest(state: AS11StreamState, samples: [AS11StreamPayload], receivedAt: Date) {
        authoritativeState = state
        lastFrameAt = receivedAt
        isDropped = false
        reconnectAttempt = 0
        for sample in samples where samplesByID[sample.id] == nil {
            var stamped = sample
            stamped.receivedAt = receivedAt
            samplesByID[sample.id] = stamped
            orderedIDs.append(sample.id)
        }
        if let cursor = samples.last?.id {
            lastCursor = cursor
        }
        pruneExpiredSamples(asOf: receivedAt)
    }

    /// Drops samples received longer ago than `as11ClientBufferRetention`
    /// (by LOCAL receipt time) so the buffer stays bounded across a long
    /// session. Safe against resync overlap: `lastCursor` (the dedup/resume
    /// key) is never pruned, and the server only resends samples AFTER that
    /// cursor — never the older ones removed here.
    private func pruneExpiredSamples(asOf now: Date) {
        let cutoff = now.addingTimeInterval(-CNSMonitoringConstants.as11ClientBufferRetention)
        orderedIDs.removeAll { id in
            guard let received = samplesByID[id]?.receivedAt, received < cutoff else { return false }
            samplesByID[id] = nil
            return true
        }
    }

    func connect() {
        shouldMaintainConnection = true
        reconnectTask?.cancel()
        reconnectTask = nil
        openSocketIfNeeded()
    }

    private func openSocketIfNeeded() {
        guard shouldMaintainConnection, socketTask == nil,
              let url = willBecomeActive() else { return }
        var request = URLRequest(url: url)
        let token = apiKey()
        guard !token.isEmpty else {
            isDropped = true
            return
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socketTask = session.webSocketTask(with: request)
        self.socketTask = socketTask
        socketTask.resume()
        receiveTask = Task { @MainActor [weak self] in
            await self?.receiveFrames(from: socketTask)
        }
    }

    func suspend() {
        stopTransport()
    }

    func disconnect() {
        stopTransport()
        // Reset stream state at the session boundary so the NEXT monitoring
        // session starts fresh instead of resuming from a stale cursor and
        // pulling the between-sessions backlog. (A within-session
        // background/foreground resume preserves the cursor via
        // willResignActive/willBecomeActive; ending the session does not.)
        // Defense-in-depth alongside the server's recency-bounded replay.
        lastCursor = nil
        samplesByID = [:]
        orderedIDs = []
        authoritativeState = .streamStalled
        lastFrameAt = nil
    }

    /// Drop the live transport (cancel the receive loop + socket) and mark the
    /// stream dropped — used on backgrounding and by `disconnect()`. Tearing the
    /// socket down, not just flipping `isDropped`, is what makes the drop stick:
    /// otherwise an in-flight frame would immediately flip the state back to
    /// non-dropped.
    func willResignActive() {
        stopTransport()
    }

    private func stopTransport() {
        shouldMaintainConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        isDropped = true
    }

    /// Deterministic seam used by tests; advances and returns the bounded
    /// exponential-backoff delay for the next retry.
    func nextReconnectDelay() -> TimeInterval {
        let exponent = min(reconnectAttempt, 10)
        let delay = min(
            CNSMonitoringConstants.as11ReconnectInitialDelay * pow(2, Double(exponent)),
            CNSMonitoringConstants.as11ReconnectMaximumDelay
        )
        reconnectAttempt += 1
        return delay
    }

    private func scheduleReconnect() {
        guard shouldMaintainConnection, reconnectTask == nil else { return }
        let delay = nextReconnectDelay()
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            reconnectTask = nil
            openSocketIfNeeded()
        }
    }

    /// Returns the cursor-resync URL used by the WebSocket transport.
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

    private func receiveFrames(from socketTask: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socketTask.receive()
                let data: Data
                switch message {
                case .data(let received): data = received
                case .string(let string): data = Data(string.utf8)
                @unknown default: continue
                }
                try ingestFrameData(data, receivedAt: now())
            } catch {
                let wasCancelled = Task.isCancelled
                // A cancelled receive from an older backgrounded socket may
                // finish after foreground activation has already opened its
                // replacement. Never let that stale completion clear or retry
                // over the newer transport.
                guard self.socketTask === socketTask else { return }
                receiveTask = nil
                self.socketTask = nil
                if !wasCancelled {
                    isDropped = true
                    scheduleReconnect()
                }
                return
            }
        }
    }

    /// Internal decoding seam for a real server-frame regression fixture.
    func ingestFrameData(_ data: Data, receivedAt: Date) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = as11FractionalISO8601.date(from: string) { return date }
            if let date = as11PlainISO8601.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid ISO-8601 AS11 timestamp"
            )
        }
        let frame = try decoder.decode(WireFrame.self, from: data)
        ingest(
            state: AS11StreamState(from: frame.state),
            samples: frame.samples.compactMap(AS11StreamPayload.init(wire:)),
            receivedAt: receivedAt
        )
    }
}

private struct WireFrame: Decodable {
    let samples: [WireSample]
    let state: String?
}

private struct WireSample: Decodable {
    let id: Int
    let bridgeId: String
    let timestampUTC: Date
    let channel: String
    let value: Double

    enum CodingKeys: String, CodingKey {
        case id, channel, value
        case bridgeId = "bridge_id"
        case timestampUTC = "ts_utc"
    }
}

private extension AS11StreamPayload {
    init?(wire: WireSample) {
        let normalizedChannel = wire.channel.uppercased()
        guard normalizedChannel == "SPO2" || normalizedChannel == "HR" else { return nil }
        self.init(
            id: String(wire.id), bridgeId: wire.bridgeId, timestampUTC: wire.timestampUTC,
            pressure: nil, flow: nil, leak: nil,
            spo2: normalizedChannel == "SPO2" ? wire.value : nil,
            hr: normalizedChannel == "HR" ? wire.value : nil,
            state: nil
        )
    }
}
