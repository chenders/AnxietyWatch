import Foundation

/// Shared constants for the watch app group used by both the Watch App and Widget Extension.
/// This enum is duplicated in the Widget target; keep the overlapping keys aligned where both
/// targets use them. The app group identifier itself is NOT duplicated — both reference the
/// single `AppGroupIdentifier.value` source of truth.
enum SharedData {
    static let appGroup = AppGroupIdentifier.value

    static var shared: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    enum Key {
        static let lastAnxiety = "lastAnxiety"
        static let hrvAvg = "hrvAvg"
        static let restingHR = "restingHR"
        static let lastUpdate = "lastUpdate"
        static let pendingRandomCheckIn = "pendingRandomCheckIn"
    }
}
