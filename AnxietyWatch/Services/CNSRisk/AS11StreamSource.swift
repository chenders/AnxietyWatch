import Foundation

/// Synchronous snapshot consumed by the 1 Hz CNS coordinator. The state is
/// the server's authoritative state while its most recent frame is fresh;
/// stale or absent frames always degrade to `.streamStalled`.
@MainActor
protocol AS11StreamSource: AnyObject {
    var latestState: AS11StreamState { get }
    func latestSamples() -> [AS11StreamPayload]
    func connect()
    func disconnect()
}

/// Deterministic source for tests and previews.
@MainActor
final class MockAS11StreamSource: AS11StreamSource {
    var state: AS11StreamState
    var samples: [AS11StreamPayload]
    var lastFrameAt: Date?
    private(set) var connectCallCount = 0
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
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

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

    func connect() {
        guard socketTask == nil, let url = willBecomeActive() else { return }
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

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
        willResignActive()
    }

    func willResignActive() {
        isDropped = true
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
                if !Task.isCancelled { isDropped = true }
                self.socketTask = nil
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
            for options: ISO8601DateFormatter.Options in [
                [.withInternetDateTime, .withFractionalSeconds],
                [.withInternetDateTime]
            ] {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                if let date = formatter.date(from: string) { return date }
            }
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
