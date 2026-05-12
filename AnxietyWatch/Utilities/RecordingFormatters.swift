import Foundation

/// Shared display formatters for the in-progress sensor session UI
/// (in-app pill, live session sheet, etc.). The Live Activity widget
/// relies on SwiftUI's `Text(timerInterval:)` for system-driven ticking,
/// so it does not call into these helpers.
enum RecordingFormatters {

    /// Formats elapsed seconds as `M:SS` for sub-hour durations and
    /// `H:MM:SS` once the session crosses one hour. Negative input is
    /// treated as zero rather than displayed as a negative number — the
    /// `sessionElapsed` source can go briefly negative if the device
    /// clock is adjusted backwards while a session is open, and
    /// "−0:03" would read as a bug to the user.
    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
