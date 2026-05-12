import Foundation

/// Pre-formatted content for the in-app recording status pill (and, in
/// the future, the Live Activity widget). `from(state:)` returns nil
/// when the pill should be hidden — i.e. the user is not actively
/// recording or connecting to a sensor. Pulled out as a pure helper so
/// the visibility / formatting branches can be tested without standing
/// up a SwiftUI view.
struct RecordingPillContent: Equatable {
    /// Short status word — "Recording" or "Connecting".
    let statusText: String
    /// Pre-formatted heart rate, e.g. "62 BPM". Nil while the sensor is
    /// warming up and no HR has streamed yet (or for the connecting
    /// state, which precedes any HR data).
    let hrText: String?
    /// Pre-formatted elapsed duration ("M:SS" or "H:MM:SS"). Nil for the
    /// connecting state — no session has started yet.
    let elapsedText: String?
    /// `true` once we are actively recording (drives the pill's live /
    /// "pulsing" tint vs. the calmer connecting style).
    let isLive: Bool

    static func from(state: PolarHRMState) -> RecordingPillContent? {
        switch state.status {
        case .recording:
            return RecordingPillContent(
                statusText: "Recording",
                hrText: state.currentHR.map { "\($0) BPM" },
                elapsedText: RecordingFormatters.formatElapsed(state.sessionElapsed),
                isLive: true
            )
        case .connecting:
            return RecordingPillContent(
                statusText: "Connecting",
                hrText: nil,
                elapsedText: nil,
                isLive: false
            )
        case .idle, .scanning, .bluetoothOff, .bluetoothUnauthorized,
             .bluetoothUnsupported, .error:
            return nil
        }
    }
}
