import Foundation
import Testing

@testable import AnxietyWatch

@MainActor
struct AS11StreamSourceTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("Mock AS11 source returns its configured authoritative state and samples")
    func mockReturnsConfiguredFrame() {
        let payload = makePayload(id: "sample-1", timestamp: now, spo2: 94, hr: 61)
        let source = MockAS11StreamSource(
            state: .bridgeDown,
            samples: [payload],
            lastFrameAt: now,
            now: { self.now }
        )

        #expect(source.latestState == .bridgeDown)
        #expect(source.latestSamples().map(\.id) == ["sample-1"])
    }

    @Test("A stale AS11 frame cannot assess and never reports streaming OK")
    func staleFrameFailsSafe() {
        let source = MockAS11StreamSource(
            state: .streamingOK,
            samples: [makePayload(id: "sample-1", timestamp: now, spo2: 97, hr: 60)],
            lastFrameAt: now,
            now: { self.now.addingTimeInterval(CNSMonitoringConstants.as11FrameStaleTimeout + 1) }
        )

        #expect(source.latestState == .streamStalled)
        #expect(source.latestState != .streamingOK)
    }

    @Test("Background drop and wake reconnect preserve the cursor")
    func reconnectUsesLastCursor() throws {
        let baseURL = try #require(URL(string: "wss://example.invalid/api/cpap/as11/ws"))
        let client = AS11WebSocketClient(baseURL: baseURL, now: { self.now })
        client.ingest(
            state: .streamingOK,
            samples: [makePayload(id: "42", timestamp: now, spo2: 95, hr: 60)],
            receivedAt: now
        )

        client.willResignActive()
        #expect(client.isDropped)
        let reconnectURL = try #require(client.willBecomeActive())

        #expect(!client.isDropped)
        #expect(URLComponents(url: reconnectURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "since" })?.value == "42")
    }

    @Test("Reconnect backoff is bounded and resets after a successful frame")
    func reconnectBackoffIsBoundedAndResettable() {
        let client = AS11WebSocketClient(
            baseURL: URL(string: "wss://example.invalid/api/cpap/as11/ws")!,
            now: { self.now }
        )

        #expect(client.nextReconnectDelay() == CNSMonitoringConstants.as11ReconnectInitialDelay)
        #expect(client.nextReconnectDelay() == CNSMonitoringConstants.as11ReconnectInitialDelay * 2)
        for _ in 0..<20 { _ = client.nextReconnectDelay() }
        #expect(client.nextReconnectDelay() == CNSMonitoringConstants.as11ReconnectMaximumDelay)

        client.ingest(state: .streamingOK, samples: [], receivedAt: now)
        #expect(client.nextReconnectDelay() == CNSMonitoringConstants.as11ReconnectInitialDelay)
    }

    @Test("An intentional background drop disables automatic reconnect until foreground connect")
    func intentionalDropDisablesReconnect() {
        let client = AS11WebSocketClient(
            baseURL: URL(string: "wss://example.invalid/api/cpap/as11/ws")!,
            now: { self.now }, apiKey: { "test-key" }
        )

        client.connect()
        #expect(client.shouldMaintainConnection)
        client.willResignActive()
        #expect(!client.shouldMaintainConnection)
    }

    @Test("Real server frames decode ISO-8601 timestamps with fractional seconds")
    func decodesServerFrame() throws {
        let client = AS11WebSocketClient(
            baseURL: URL(string: "wss://example.invalid/api/cpap/as11/ws")!, now: { self.now }
        )
        let frame = Data(
            """
            {"state":"BRIDGE_DOWN","samples":[{"id":7,"bridge_id":"test-bridge",\
            "ts_utc":"2025-06-15T15:06:40.123456Z","channel":"SPO2","value":93.0}]}
            """.utf8
        )

        try client.ingestFrameData(frame, receivedAt: now)

        #expect(client.latestState == .bridgeDown)
        #expect(client.latestSamples().first?.id == "7")
        #expect(client.latestSamples().first?.spo2 == 93)
    }

    @Test("Overlapping resync frames deduplicate samples by server id")
    func overlappingFramesDeduplicate() {
        let client = AS11WebSocketClient(
            baseURL: URL(string: "wss://example.invalid/api/cpap/as11/ws")!,
            now: { self.now }
        )
        client.ingest(
            state: .streamingOK,
            samples: [
                makePayload(id: "1", timestamp: now, spo2: 96, hr: 60),
                makePayload(id: "2", timestamp: now.addingTimeInterval(1), spo2: 95, hr: 61)
            ],
            receivedAt: now
        )
        client.ingest(
            state: .bridgeDown,
            samples: [
                makePayload(id: "2", timestamp: now.addingTimeInterval(1), spo2: 95, hr: 61),
                makePayload(id: "3", timestamp: now.addingTimeInterval(2), spo2: 94, hr: 62)
            ],
            receivedAt: now.addingTimeInterval(2)
        )

        #expect(client.latestSamples().map(\.id) == ["1", "2", "3"])
        #expect(client.latestState == .bridgeDown)
        #expect(client.lastCursor == "3")
    }

    @Test("Ingest stamps each sample with the local receipt time, not the bridge timestamp")
    func ingestStampsLocalReceiptTime() {
        let client = AS11WebSocketClient(
            baseURL: URL(string: "wss://example.invalid/api/cpap/as11/ws")!,
            now: { self.now }
        )
        let bridgeTime = now.addingTimeInterval(-600) // bridge clock behind the phone
        client.ingest(
            state: .streamingOK,
            samples: [makePayload(id: "1", timestamp: bridgeTime, spo2: 96, hr: 60)],
            receivedAt: now
        )
        #expect(client.latestSamples().first?.receivedAt == now)
    }

    @Test("Samples older than the buffer retention are pruned on ingest, so the buffer stays bounded")
    func oldSamplesArePrunedFromBuffer() {
        let client = AS11WebSocketClient(
            baseURL: URL(string: "wss://example.invalid/api/cpap/as11/ws")!,
            now: { self.now }
        )
        client.ingest(
            state: .streamingOK,
            samples: [makePayload(id: "old", timestamp: now, spo2: 96, hr: 60)],
            receivedAt: now
        )
        // A later frame arriving beyond the retention window evicts the old sample.
        let later = now.addingTimeInterval(CNSMonitoringConstants.as11ClientBufferRetention + 1)
        client.ingest(
            state: .streamingOK,
            samples: [makePayload(id: "new", timestamp: later, spo2: 95, hr: 61)],
            receivedAt: later
        )
        #expect(client.latestSamples().map(\.id) == ["new"])
    }

    @Test("Disconnect resets cursor + buffer so a re-armed session can't replay a stale backlog")
    func disconnectResetsStreamState() {
        let client = AS11WebSocketClient(
            baseURL: URL(string: "wss://example.invalid/api/cpap/as11/ws")!,
            now: { self.now }
        )
        client.ingest(
            state: .streamingOK,
            samples: [makePayload(id: "1", timestamp: now, spo2: 96, hr: 60)],
            receivedAt: now
        )
        #expect(client.lastCursor == "1")
        #expect(!client.latestSamples().isEmpty)

        client.disconnect()

        #expect(client.lastCursor == nil)
        #expect(client.latestSamples().isEmpty)
        #expect(client.latestState == .streamStalled)
    }

    private func makePayload(
        id: String,
        timestamp: Date,
        spo2: Double?,
        hr: Double?
    ) -> AS11StreamPayload {
        AS11StreamPayload(
            id: id,
            bridgeId: "test-bridge",
            timestampUTC: timestamp,
            pressure: nil,
            flow: nil,
            leak: nil,
            spo2: spo2,
            hr: hr,
            state: AS11StreamState.streamingOK.rawValue
        )
    }
}
