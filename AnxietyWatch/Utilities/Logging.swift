import Foundation
import os

/// Centralized loggers for the app. Use these instead of print().
/// Filter in Console.app with subsystem "org.waitingforthefuture.AnxietyWatch".
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "org.waitingforthefuture.AnxietyWatch"

    /// General app lifecycle events
    static let app = Logger(subsystem: subsystem, category: "app")

    /// HealthKit queries, observers, background delivery
    static let health = Logger(subsystem: subsystem, category: "health")

    /// Data sync with the server
    static let sync = Logger(subsystem: subsystem, category: "sync")

    /// SwiftData operations, migrations, backfill
    static let data = Logger(subsystem: subsystem, category: "data")
}
