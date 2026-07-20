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
