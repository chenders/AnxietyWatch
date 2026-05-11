import Foundation
import os

/// Centralized loggers for the app. Use these instead of print().
/// Filter in Console.app with subsystem "com.groundeffectsoftware.AnxietyWatch".
/// `nonisolated` so any actor / nonisolated context can read these without
/// requiring a main-actor hop.
nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.groundeffectsoftware.AnxietyWatch"

    /// General app lifecycle events
    static let app = Logger(subsystem: subsystem, category: "app")

    /// HealthKit queries, observers, background delivery
    static let health = Logger(subsystem: subsystem, category: "health")

    /// Data sync with the server
    static let sync = Logger(subsystem: subsystem, category: "sync")

    /// SwiftData operations, migrations, backfill
    static let data = Logger(subsystem: subsystem, category: "data")
}
