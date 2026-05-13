import Foundation

/// Pure decision helper for when to push a Live Activity update.
///
/// Live HR updates fire at roughly 1 Hz during a recording session.
/// Pushing one Activity update per second would burn Apple's local-
/// update budget needlessly — and most consecutive HR readings differ
/// by 0–1 BPM, far below the resolution the Lock Screen / Dynamic
/// Island can usefully convey. This helper enforces a 10 second
/// minimum gap between updates, with one exception:
///
/// **Status-class transitions bypass the throttle**, so the user sees
/// connecting → recording (and the first HR reading after a sensor
/// warmup) immediately on the Lock Screen rather than waiting up to
/// 10 seconds for the next throttle window.
enum LiveActivityUpdateThrottle {

    /// Minimum gap between non-transition updates. 10s ≈ 360 updates
    /// per hour, comfortably under Apple's local-update budget for a
    /// multi-hour overnight session (5h × 360 = 1800 updates).
    static let minimumGap: TimeInterval = 10

    /// Returns `true` when an Activity.update should be pushed for the
    /// given state change at `now`. `lastPushedAt`/`previousState` are
    /// nil only on the very first decision after the activity was
    /// requested — that initial push is always allowed so the Lock
    /// Screen has fresh content immediately.
    static func shouldPush(
        now: Date,
        lastPushedAt: Date?,
        previousState: HRVRecordingActivityAttributes.ContentState?,
        nextState: HRVRecordingActivityAttributes.ContentState
    ) -> Bool {
        // First push after activity start.
        guard let lastPushedAt, let previousState else { return true }

        // Status-class transitions always push, regardless of the gap.
        // The user benefits from immediate visibility of:
        //   - Connecting → Recording (sensor became live)
        //   - nil HR → first HR reading (sensor warmed up)
        //   - any change in statusText or isLive
        if previousState.statusText != nextState.statusText { return true }
        if previousState.isLive != nextState.isLive { return true }
        if previousState.currentHRBPM == nil && nextState.currentHRBPM != nil {
            return true
        }

        // Within the throttle window: skip.
        if now.timeIntervalSince(lastPushedAt) < minimumGap {
            return false
        }

        // Outside the window: push if anything changed; skip otherwise
        // to avoid burning budget on a no-op identical update.
        return previousState != nextState
    }
}
