import ActivityKit
import Foundation

/// Phase 4b.2 Live Activity contract. Shared between the main app
/// target (which calls `Activity.request` / `.update` / `.end`) and
/// the AnxietyWatchLiveActivitiesExtension target (the iOS widget
/// extension that renders the Lock Screen layout + Dynamic Island
/// regions — distinct from the watchOS-only AnxietyWatchWidgetsExtension
/// which is for Apple Watch complications). The file lives in the
/// main app folder; the LiveActivities target's membership is added
/// explicitly via the project's PBXFileSystemSynchronizedBuildFileExceptionSet
/// — see the project.pbxproj exception set on the AnxietyWatch root
/// group targeting AnxietyWatchLiveActivitiesExtension.
///
/// **`membershipExceptions` dual semantics** (the name is misleading
/// and not Apple-documented):
/// - When the *owning* target's exception set lists a path: the file
///   is **excluded** from that target's build (e.g., `Info.plist` in
///   AnxietyWatch's own exception set on the AnxietyWatch group).
/// - When *another* target's exception set on a foreign root lists a
///   path: the file is **included** into that target's membership
///   (e.g., the Watch App target's exception set on the AnxietyWatch
///   group lists `Models/HRVReading.swift` etc., bringing those files
///   into the Watch App). The LiveActivities target uses this same
///   inclusion pattern for `HRVRecordingActivityAttributes.swift`.
/// If a future "exception sets exclude this file from the target!"
/// review comment surfaces, remember: same pattern as the Watch App
/// + Sensor models. Empirically verified by a green build.
///
/// Design notes:
///
/// - `sessionStartedAt` is the only **static** attribute. The Lock
///   Screen and Dynamic Island use `Text(timerInterval:)` to display
///   elapsed time, which the system ticks for free. We never need to
///   push an Activity update just because a second passed.
/// - The mutating `ContentState` carries `currentHRBPM` (the only
///   value that genuinely needs cross-process updates) plus a small
///   `statusText` and `isLive` flag so the widget can render the
///   right visual style without re-deriving from numerics.
struct HRVRecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Most recent HR in BPM, nil while the sensor is warming up
        /// (or during the connecting phase before any HR has streamed).
        let currentHRBPM: Int?
        /// Short status word — "Recording" or "Connecting".
        let statusText: String
        /// `true` once we're actively recording; `false` during the
        /// connecting phase. Drives the visual treatment (red dot vs.
        /// orange) on the Lock Screen + Dynamic Island.
        let isLive: Bool
    }

    /// Bedtime / session start. Drives `Text(timerInterval:)` on every
    /// activity surface for system-ticked elapsed display.
    let sessionStartedAt: Date
}
