import Foundation

/// Incoming raw payload from the AS11 bridge backend.
struct AS11StreamPayload: Decodable, Sendable {
    /// Server-owned cursor and deduplication key.
    let id: String
    let bridgeId: String
    let timestampUTC: Date
    let pressure: Double?
    let flow: Double?
    let leak: Double?
    let spo2: Double?
    let hr: Double?
    let state: String? // "STREAMING_OK", "STREAM_STALLED", "BRIDGE_DOWN", "MASK_OFF_LEAK"
    /// LOCAL wall-clock instant this frame was received on-device, stamped by
    /// `AS11WebSocketClient.ingest`. `timestampUTC` is authored by the bridge
    /// host (a different machine); comparing it against the coordinator's local
    /// clock in the quality-gate window would silently starve AS11 whenever the
    /// bridge clock skews (no NTP). Consumers time-window on `receivedAt` when
    /// present and fall back to `timestampUTC` only for directly-constructed
    /// payloads (tests/previews that never crossed the socket).
    var receivedAt: Date?
}

extension AS11StreamState {
    init(from string: String?) {
        guard let string = string, let state = AS11StreamState(rawValue: string) else {
            // Fail safe: unknown/omitted state is treated as stalled rather than blindly trusted
            self = .streamStalled
            return
        }
        self = state
    }
}
