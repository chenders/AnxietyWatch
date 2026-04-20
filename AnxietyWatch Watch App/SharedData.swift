import Foundation

/// Shared constants for the watch app group used by both the Watch App and Widget Extension.
/// This file is duplicated in the Widget target — keep both in sync.
enum SharedData {
    static let appGroup = "group.org.waitingforthefuture.AnxietyWatch.watch"

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
