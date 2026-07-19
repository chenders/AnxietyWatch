import Foundation

/// Incoming raw payload from the AS11 bridge backend.
struct AS11StreamPayload: Decodable, Sendable {
    let bridgeId: String
    let timestampUTC: Date
    let pressure: Double?
    let flow: Double?
    let leak: Double?
    let spo2: Double?
    let hr: Double?
    let state: String? // "STREAMING_OK", "STREAM_STALLED", "BRIDGE_DOWN", "MASK_OFF_LEAK"
}

extension AS11StreamState {
    init(from string: String?) {
        guard let string = string, let state = AS11StreamState(rawValue: string) else {
            self = .streamingOK
            return
        }
        self = state
    }
}
