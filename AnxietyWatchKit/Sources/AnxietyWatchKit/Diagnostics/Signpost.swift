import os

/// A thin wrapper over OSSignposter for creating signposts
public struct Signposter {
    private let signposter: OSSignposter
    
    /// Creates a Signposter for a specific category
    /// - Parameter category: The category for this signposter
    public init(category: String) {
        self.signposter = OSSignposter(subsystem: "com.anxietywatch.kit", category: category)
    }
    
    /// Begins a signpost interval.
    /// - Parameters:
    ///   - name: The name of the interval.
    ///   - id: Signpost ID for correlating begin/end across queues. Defaults to
    ///     `.exclusive`, which auto-generates a unique ID per call and is
    ///     appropriate when begin and end occur on the same actor/queue.
    /// - Returns: An interval state object to be passed to endInterval.
    public func beginInterval(_ name: StaticString,
                              id: OSSignpostID = .exclusive) -> OSSignpostIntervalState {
        return signposter.beginInterval(name, id: id)
    }

    /// Ends a signpost interval.
    public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// Emits a signpost event.
    public func emitEvent(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}

/// A collection of signposters for different modules in the AnxietyWatchKit framework
public enum Signposts {
    /// Signposter for storage-related operations
    public static let storage = Signposter(category: "storage")
    
    /// Signposter for sync-related operations
    public static let sync = Signposter(category: "sync")
    
    /// Signposter for HLC (Hybrid Logical Clock) operations
    public static let hlc = Signposter(category: "hlc")
    
    /// Signposter for BLE (Bluetooth Low Energy) operations
    public static let ble = Signposter(category: "ble")
    
    /// Signposter for pipeline operations
    public static let pipeline = Signposter(category: "pipeline")
    
    /// Signposter for transport layer operations
    public static let transport = Signposter(category: "transport")
    
    /// Signposter for WatchConnectivity operations
    public static let wc = Signposter(category: "wc")
    
    /// Signposter for panic protocol events
    public static let panic = Signposter(category: "panic")
    
    /// Signposter for migration operations
    public static let migration = Signposter(category: "migration")
    
    /// Signposter for diagnostics operations
    public static let diag = Signposter(category: "diag")
}