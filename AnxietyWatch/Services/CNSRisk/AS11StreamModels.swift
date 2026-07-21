import Foundation

/// App-internal normalized AS11 sample. NOT the wire shape — server frames are
/// decoded via `WireSample` (snake_case `ts_utc`/`bridge_id`) in
/// `AS11WebSocketClient` and mapped in through `init(wire:)`; this type is only
/// ever constructed in-process, so it is deliberately not `Decodable`.
struct AS11StreamPayload: Sendable {
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
