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
