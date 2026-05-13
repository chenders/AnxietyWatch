import Foundation

/// Main-app-only extension that maps `PolarHRMState` to a Live Activity
/// `ContentState`. Kept in a separate file from the shared type
/// definition because `PolarHRMState` lives only in the main app
/// target — the widget extension that consumes
/// `HRVRecordingActivityAttributes` cannot see it.
extension HRVRecordingActivityAttributes.ContentState {

    /// Returns `nil` when there is nothing to display — the caller
    /// (the `LiveActivityCoordinator`) interprets nil as "end the
    /// activity if one is open." Visibility logic mirrors
    /// `RecordingPillContent.from(state:)` so the in-app pill and the
    /// Lock Screen surface stay consistent.
    @MainActor
    static func from(state: PolarHRMState) -> HRVRecordingActivityAttributes.ContentState? {
        switch state.status {
        case .recording:
            return HRVRecordingActivityAttributes.ContentState(
                currentHRBPM: state.currentHR,
                statusText: "Recording",
                isLive: true
            )
        case .connecting:
            // HR is intentionally suppressed during the connecting
            // phase to match `RecordingPillContent.from(state:)` — the
            // in-app pill and the Lock Screen agree on "no HR shown
            // before the session is live." In practice `state.currentHR`
            // will almost always be nil here, but a sensor that
            // streams a beat before fully transitioning to .recording
            // should still read as "Connecting / —" on both surfaces.
            return HRVRecordingActivityAttributes.ContentState(
                currentHRBPM: nil,
                statusText: "Connecting",
                isLive: false
            )
        case .idle, .scanning, .bluetoothOff, .bluetoothUnauthorized,
             .bluetoothUnsupported, .error:
            return nil
        }
    }
}
